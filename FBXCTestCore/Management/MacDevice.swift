/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import IOKit

@objc private protocol XCTestManager_XPCControl {
  func _XCT_requestConnectedSocketForTransport(_ arg1: @escaping (FileHandle?, (any Error)?) -> Void)
}

public enum MacDeviceError: Error {
  case testManagerProxyNonConformant(proxyDescription: String)
  case transportUnavailable
  case applicationNotLaunched(bundleID: String)
  case applicationNotInstalled(bundleID: String)
  case bundleNotRegistered(bundleID: String)
  case applicationNotFound(bundleID: String)
  case applicationHasNoExecutable(bundleID: String)
  case testBundleHasNoBinary(path: String)
  case unexpectedReporter(reporterDescription: String)
  case notImplemented(selector: String)
  case commandUnsupported(command: String)
}

extension MacDeviceError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .testManagerProxyNonConformant(proxyDescription):
      return "The testmanagerd proxy \(proxyDescription) does not conform to XCTestManager_XPCControl"
    case .transportUnavailable:
      return "Unknown error getting transport"
    case let .applicationNotLaunched(bundleID):
      return "Application with bundleID (\(bundleID)) was not launched by XCTestBootstrap"
    case let .applicationNotInstalled(bundleID):
      return "Application with bundleID (\(bundleID)) was not installed by XCTestBootstrap"
    case let .bundleNotRegistered(bundleID):
      return "No bundle for \(bundleID)"
    case let .applicationNotFound(bundleID):
      return "Could not find application for \(bundleID)"
    case let .applicationHasNoExecutable(bundleID):
      return "Application bundle \(bundleID) has no executable"
    case let .testBundleHasNoBinary(path):
      return "Test bundle at \(path) has no binary to read architectures from"
    case let .unexpectedReporter(reporterDescription):
      return "Expected an XCTestReporter, got \(reporterDescription)"
    case let .notImplemented(selector):
      return "-[MacDevice \(selector)] is not implemented"
    case let .commandUnsupported(command):
      return "\(command) is not supported on the mac target"
    }
  }
}

public final class MacDevice: Target {

  // MARK: - Target synthesized properties

  public let architectures: [Architecture]
  public let asyncQueue: DispatchQueue
  public let auxillaryDirectory: String
  public var name: String
  public var logger: any ControlCoreLogger
  public let osVersion: OSVersion
  public var state: TargetState
  public let targetType: TargetType
  public let workQueue: DispatchQueue
  public let screenInfo: TargetScreenInfo?
  public var deviceType: DeviceType = DeviceType.generic(withName: "Mac")
  public let udid: String
  public let temporaryDirectory: TemporaryDirectory

  // MARK: - Private properties

  private var bundleIDToProductMap: [String: BundleDescriptor]
  private var bundleIDToRunningTask: [String: RunningSubprocess]
  private var connection: NSXPCConnection?
  private let workingDirectory: String
  private let catalyst: Bool

  // MARK: - Static

  private static let _applicationInstallDirectory: String = {
    let uuid = UUID().uuidString
    let parentDir = NSSearchPathForDirectoriesInDomains(.applicationDirectory, .userDomainMask, true).last ?? NSTemporaryDirectory()
    return (parentDir as NSString).appendingPathComponent(uuid)
  }()

  public static var applicationInstallDirectory: String {
    _applicationInstallDirectory
  }

  public static func fetchInstalledApplications() -> [String: BundleDescriptor] {
    var mapping: [String: BundleDescriptor] = [:]
    let content = try? FileManager.default.contentsOfDirectory(atPath: applicationInstallDirectory)
    for fileOrDirectory in content ?? [] {
      if (fileOrDirectory as NSString).pathExtension != "app" {
        continue
      }
      let path = (applicationInstallDirectory as NSString).appendingPathComponent(fileOrDirectory)
      if let bundle = try? BundleDescriptor(path: path) {
        mapping[bundle.identifier] = bundle
      }
    }
    return mapping
  }

  // MARK: - Initializers

  public convenience init() {
    self.init(logger: ControlCoreGlobalConfiguration.defaultLogger, catalyst: false)
  }

  public convenience init(logger: any ControlCoreLogger) {
    self.init(logger: logger, catalyst: false)
  }

  public init(logger: any ControlCoreLogger, catalyst: Bool) {
    architectures = Array(ArchitectureProcessAdapter.hostMachineSupportedArchitectures())
    asyncQueue = DispatchQueue.global(qos: .userInitiated)
    let explicitTmpDirectory = ProcessInfo.processInfo.environment["IDB_MAC_AUXILLIARY_DIR"]
    if let explicitTmpDirectory {
      auxillaryDirectory = (explicitTmpDirectory as NSString).appendingPathComponent("idb-mac-aux/\(ProcessInfo.processInfo.globallyUniqueString)")
    } else {
      auxillaryDirectory = (NSTemporaryDirectory() as NSString).appendingPathComponent("idb-mac-cwd/\(ProcessInfo.processInfo.globallyUniqueString)")
    }
    bundleIDToProductMap = MacDevice.fetchInstalledApplications()
    bundleIDToRunningTask = [:]
    udid = MacDevice.resolveDeviceUDID()
    state = .booted
    targetType = .localMac
    workQueue = DispatchQueue.main
    workingDirectory = (NSTemporaryDirectory() as NSString).appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
    screenInfo = nil
    osVersion = OSVersion.generic(withName: "mac")
    name = Host.current().localizedName ?? ""
    self.logger = logger
    self.catalyst = catalyst
    temporaryDirectory = TemporaryDirectory(logger: logger)
  }

  // MARK: - Public

  /// Kills every launched application and uninstalls every registered one, reporting the first
  /// failure only after every teardown has run.
  func restorePrimaryDeviceState() throws {
    var firstFailure: (any Error)?
    for bundleID in Array(bundleIDToRunningTask.keys) {
      do {
        try killApplication(withBundleID: bundleID)
      } catch {
        firstFailure = firstFailure ?? error
      }
    }
    for bundleID in Array(bundleIDToProductMap.keys) {
      do {
        try uninstallApplication(withBundleID: bundleID)
      } catch {
        firstFailure = firstFailure ?? error
      }
    }
    if let firstFailure {
      throw firstFailure
    }
  }

  // MARK: - Paths

  public var runtimeRootDirectory: String {
    get async { await platformRootDirectory }
  }

  public var platformRootDirectory: String {
    get async {
      (XcodeConfiguration.developerDirectory as NSString).appendingPathComponent("Platforms/MacOSX.platform")
    }
  }

  public var path: String {
    (XcodeConfiguration.developerDirectory as NSString).appendingPathComponent("usr/bin/xctest")
  }

  // MARK: - Device UDID

  private static func resolveDeviceUDID() -> String {
    let platformExpert = unsafe IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard platformExpert != 0 else {
      return ""
    }
    let serialNumberAsCFString = unsafe IORegistryEntryCreateCFProperty(
      platformExpert,
      kIOPlatformSerialNumberKey as CFString,
      kCFAllocatorDefault,
      0
    )
    IOObjectRelease(platformExpert)
    return unsafe serialNumberAsCFString?.takeRetainedValue() as? String ?? ""
  }

  // MARK: - Transport

  private func makeTransportForTestManagerService() throws -> FileHandle {
    let logger = self.logger
    let connection = NSXPCConnection(machServiceName: "com.apple.testmanagerd.control", options: [])
    let interface = NSXPCInterface(with: (any XCTestManager_XPCControl).self)
    connection.remoteObjectInterface = interface
    connection.interruptionHandler = { [weak self] in
      self?.connection = nil
      logger.log("Connection with test manager daemon was interrupted")
    }
    connection.invalidationHandler = { [weak self] in
      self?.connection = nil
      logger.log("Invalidated connection with test manager daemon")
    }
    connection.resume()
    var proxyError: (any Error)?
    let rawProxy = connection.synchronousRemoteObjectProxyWithErrorHandler { [weak self] error in
      logger.log("Error occurred during synchronousRemoteObjectProxyWithErrorHandler call: \(error.localizedDescription)")
      self?.connection = nil
      proxyError = error
    }
    guard let proxy = rawProxy as? any XCTestManager_XPCControl else {
      throw MacDeviceError.testManagerProxyNonConformant(proxyDescription: String(describing: rawProxy))
    }

    self.connection = connection
    var error: (any Error)?
    var transport: FileHandle?
    proxy._XCT_requestConnectedSocketForTransport { file, xctError in
      if file == nil {
        logger.log("Error requesting connection with test manager daemon: \(xctError?.localizedDescription ?? "")")
        error = xctError
        return
      }
      transport = file
    }
    guard let transport else {
      throw error ?? proxyError ?? MacDeviceError.transportUnavailable
    }
    return transport
  }

  public func processID(withBundleID bundleID: String) throws -> pid_t {
    guard let task = bundleIDToRunningTask[bundleID] else {
      throw MacDeviceError.applicationNotLaunched(bundleID: bundleID)
    }
    return task.processIdentifier
  }

  var consoleString: String {
    assertionFailure("consoleString is not yet supported")
    return ""
  }

  // MARK: - Target

  public func requiresBundlesToBeSigned() -> Bool {
    false
  }

  public func installApplication(withPath path: String) throws -> InstalledApplication {
    let bundle = try BundleDescriptor(path: path)
    bundleIDToProductMap[bundle.identifier] = bundle
    return InstalledApplication(bundle: bundle, installType: .mac, dataContainer: nil)
  }

  /// Installing only registers the bundle where it already is, so uninstalling forgets it and leaves the bundle to whoever owns that path.
  public func uninstallApplication(withBundleID bundleID: String) throws {
    guard bundleIDToProductMap.removeValue(forKey: bundleID) != nil else {
      throw MacDeviceError.applicationNotInstalled(bundleID: bundleID)
    }
  }

  public func installedApplication(withBundleID bundleID: String) throws -> InstalledApplication {
    guard let existingBundle = bundleIDToProductMap[bundleID] else {
      throw MacDeviceError.bundleNotRegistered(bundleID: bundleID)
    }
    let bundle = try BundleDescriptor(path: existingBundle.path)
    return InstalledApplication(bundle: bundle, installType: .mac, dataContainer: nil)
  }

  public func killApplication(withBundleID bundleID: String) throws {
    guard let task = bundleIDToRunningTask[bundleID] else {
      throw MacDeviceError.applicationNotLaunched(bundleID: bundleID)
    }
    Task {
      await task.terminate(gracePeriod: 2)
    }
    bundleIDToRunningTask.removeValue(forKey: bundleID)
  }

  public var uniqueIdentifier: String {
    udid
  }

  public var extendedInformation: [String: Any] {
    [:]
  }

  public func compare(_ target: any TargetInfo) -> ComparisonResult {
    .orderedSame
  }

  public var customDeviceSetPath: String? {
    nil
  }

  public func replacementMapping() -> [String: String] {
    [:]
  }

  public func environmentAdditions() -> [String: String] {
    if catalyst {
      return ["DYLD_FORCE_PLATFORM": "6"]
    } else {
      return [:]
    }
  }

  // MARK: - XCTestExtendedCommands

  public func listTests(forBundleAtPath bundlePath: String, timeout: TimeInterval, withAppAtPath appPath: String?) async throws -> [String] {
    let bundleDescriptor = try BundleDescriptor(path: bundlePath, fallbackIdentifier: true)
    guard let binary = bundleDescriptor.binary else {
      throw MacDeviceError.testBundleHasNoBinary(path: bundlePath)
    }
    let configuration = ListTestConfiguration(
      environment: [:],
      workingDirectory: auxillaryDirectory,
      testBundlePath: bundlePath,
      runnerAppPath: appPath,
      waitForDebugger: false,
      timeout: timeout,
      architectures: Set(binary.architectures.map { $0.rawValue })
    )

    return try await ListTestRunner(target: self, configuration: configuration, logger: self.logger).listTests()
  }

}

// MARK: - MacDevice+XCTestExtendedCommands

extension MacDevice: XCTestExtendedCommands {

  public func runTest(
    launchConfiguration: TestLaunchConfiguration,
    reporter: AnyObject,
    logger: any ControlCoreLogger
  ) async throws {
    guard let typedReporter = reporter as? any XCTestReporter else {
      throw MacDeviceError.unexpectedReporter(reporterDescription: String(describing: reporter))
    }
    try await ManagedTestRunner.runToCompletion(
      withTarget: self,
      configuration: launchConfiguration,
      codesign: nil,
      workingDirectory: workingDirectory,
      reporter: typedReporter,
      logger: logger
    )
  }

  public func extendedTestShim() async throws -> String {
    try await XCTestShimConfiguration.sharedShimConfiguration().macOSTestShimPath
  }

  public func withTransportForTestManagerService<R>(
    body: (Int32) async throws -> R
  ) async throws -> R {
    let transport = try makeTransportForTestManagerService()
    defer { transport.closeFile() }
    return try await body(transport.fileDescriptor)
  }
}

// MARK: - MacDevice+ApplicationCommands

extension MacDevice: ApplicationCommands {

  public func install(atPath path: String) async throws -> InstalledApplication {
    try installApplication(withPath: path)
  }

  public func uninstall(bundleID: String) async throws {
    try uninstallApplication(withBundleID: bundleID)
  }

  public func launch(_ configuration: ApplicationLaunchConfiguration) async throws -> any LaunchedApplication {
    guard let bundle = bundleIDToProductMap[configuration.bundleID] else {
      throw MacDeviceError.applicationNotFound(bundleID: configuration.bundleID)
    }
    guard let binary = bundle.binary else {
      throw MacDeviceError.applicationHasNoExecutable(bundleID: bundle.identifier)
    }
    // The unset builder default buffered both streams into memory that
    // nothing ever read; an open null device discards them outright.
    let task = try await Subprocess(executable: binary.path, arguments: configuration.arguments, environment: .exact(configuration.environment))
      .launch(output: .nullDevice, error: .nullDevice, logger: logger)
    bundleIDToRunningTask[bundle.identifier] = task
    return MacLaunchedApplication(
      bundleID: bundle.identifier,
      processIdentifier: task.processIdentifier,
      device: self,
      queue: workQueue
    )
  }

  public func kill(bundleID: String) async throws {
    try killApplication(withBundleID: bundleID)
  }

  public func installed() async throws -> [InstalledApplication] {
    try bundleIDToProductMap.values.map { existingBundle in
      let bundle = try BundleDescriptor(path: existingBundle.path)
      return InstalledApplication(bundle: bundle, installType: .mac, dataContainer: nil)
    }
  }

  public func installed(bundleID: String) async throws -> InstalledApplication {
    try installedApplication(withBundleID: bundleID)
  }

  public func running() async throws -> [String: pid_t] {
    var result: [String: pid_t] = [:]
    for (bundleId, task) in bundleIDToRunningTask {
      result[bundleId] = task.processIdentifier
    }
    return result
  }

  public func processID(forBundleID bundleID: String) async throws -> pid_t {
    try processID(withBundleID: bundleID)
  }
}

// MARK: - MacDevice+CrashLogCommands

extension MacDevice: CrashLogCommands {

  public func crashes(matching predicate: CrashLogPredicate, useCache: Bool) async throws -> [CrashLogInfo] {
    throw MacDeviceError.notImplemented(selector: "crashes:useCache:")
  }

  public func notifyOfCrash(matching predicate: CrashLogPredicate) async throws -> CrashLogInfo {
    try await CrashLogNotifier.sharedInstance.nextCrashLog(forPredicate: predicate)
  }

  public func prune(matching predicate: CrashLogPredicate) async throws -> [CrashLogInfo] {
    throw MacDeviceError.notImplemented(selector: "prune:")
  }

  public func withFiles<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw MacDeviceError.notImplemented(selector: "crashLogFiles")
  }
}

// MacDevice has no equivalent for these simulator/device-oriented commands; each throws rather than silently no-ops.

// MARK: - Unsupported command helper

extension MacDevice {

  fileprivate func macUnsupported(_ command: String) -> any Error {
    MacDeviceError.commandUnsupported(command: command)
  }
}

// MARK: - Command nouns

// `MacDevice` implements every capability inline rather than through command types, so each noun
// resolves to the device itself. Splitting those implementations into command types is a separate
// change; the nouns can be stated regardless.
extension MacDevice {

  public var application: MacDevice { self }

  public var crashLog: MacDevice { self }

  public var debugServer: MacDevice { self }

  public var file: MacDevice { self }

  public var lifecycle: MacDevice { self }

  public var location: MacDevice { self }

  public var log: MacDevice { self }

  public var power: MacDevice { self }

  public var screenshot: MacDevice { self }

  public var xctest: MacDevice { self }

  public var xctraceRecord: MacDevice { self }
}

// MARK: - MacDevice+DebugServerCommands

extension MacDevice: DebugServerCommands {

  // Qualified: `Target`'s `DebugServer` associated type resolves to `MacDevice` inside this scope
  // and shadows the protocol of the same name.
  public func launch(forHostApplication application: BundleDescriptor, port: in_port_t) async throws -> any FBControlCore.DebugServer {
    throw macUnsupported("launch")
  }
}

// MARK: - MacDevice+Erase

extension MacDevice {

  public func erase() async throws {
    throw macUnsupported("erase")
  }
}

// MARK: - MacDevice+FileCommands

extension MacDevice: FileCommands {

  public func withContainerApplication<R>(_ bundleID: String, body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw macUnsupported("file commands for application container")
  }

  public func withAuxiliary<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw macUnsupported("file commands for the auxillary directory")
  }

  public func withApplicationContainers<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw macUnsupported("file commands for application containers")
  }

  public func withGroupContainers<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw macUnsupported("file commands for group containers")
  }

  public func withRootFilesystem<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw macUnsupported("file commands for the root filesystem")
  }

  public func withMediaDirectory<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw macUnsupported("file commands for the media directory")
  }

  public func withProvisioningProfiles<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw macUnsupported("file commands for provisioning profiles")
  }

  public func withMDMProfiles<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw macUnsupported("file commands for MDM profiles")
  }

  public func withSpringboardIconLayout<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw macUnsupported("file commands for the springboard icon layout")
  }

  public func withWallpaper<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw macUnsupported("file commands for the wallpaper")
  }

  public func withDiskImages<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw macUnsupported("file commands for disk images")
  }

  public func withSymbols<R>(body: (any AsyncFileContainer) async throws -> R) async throws -> R {
    throw macUnsupported("file commands for symbols")
  }
}

// MARK: - MacDevice+LocationCommands

extension MacDevice: LocationCommands {

  public func set(longitude: Double, latitude: Double) async throws {
    throw macUnsupported("set")
  }
}

// MARK: - MacDevice+LogCommands

extension MacDevice: LogCommands {

  public func tail(arguments: [String], consumer: any DataConsumer) async throws -> any LogOperation {
    throw macUnsupported("tail")
  }
}

// MARK: - MacDevice+ScreenshotCommands

extension MacDevice: ScreenshotCommands {

  public func take(configuration: ScreenshotConfiguration) async throws -> ScreenshotResult {
    throw macUnsupported("take")
  }
}

// MARK: - MacDevice+XCTraceRecordCommands

extension MacDevice: XCTraceRecordCommands {

  public func start(configuration: XCTraceRecordConfiguration, logger: any ControlCoreLogger) async throws -> XCTraceRecordOperation {
    throw macUnsupported("start")
  }
}

// MARK: - MacDevice+LifecycleCommands

extension MacDevice: LifecycleCommands {

  public func resolveState(_ state: TargetState) async throws {
    throw macUnsupported("resolveState")
  }

  public func resolveLeavesState(_ state: TargetState) async throws {
    throw macUnsupported("resolveLeavesState")
  }
}

// MARK: - MacDevice+PowerCommands

extension MacDevice: PowerCommands {

  public func shutdown() async throws {
    throw macUnsupported("shutdown")
  }

  public func reboot() async throws {
    throw macUnsupported("reboot")
  }
}

// MARK: - MacDevice+LogicTestTarget

extension MacDevice: LogicTestTarget {

  public var subprocessLauncher: any SubprocessLauncher {
    HostSubprocessLauncher()
  }
}
