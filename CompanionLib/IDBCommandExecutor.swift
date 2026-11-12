/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBArtifactStaging
import FBControlCore
import FBDeviceControl
import FBSimulatorAX
import FBSimulatorCodeInjection
import FBSimulatorControl
import FBSimulatorServices
import FBSimulatorXCTest
import FBVideoCore
import FBXCTestCore
import Foundation

public enum IDBCommandError: Error {
  case simulatorOnlyOperation(operation: String, targetDescription: String)
  case notASimulator(targetDescription: String)
  case invalidURL(urlString: String)
  case multipleCrashLogs(predicateDescription: String)
  case noCrashLogs(predicateDescription: String)
  case replTestsUnsupported(targetDescription: String)
  case replSessionsUnsupported(targetDescription: String)
  case replAppLaunchesUnsupported(targetDescription: String)
  case replHostAppMissing
  case replIDBLibraryMissing
  case noDebugServer
  case debugServerAlreadyRunning
  case notPersistedApplication(bundleID: String, suitable: [String])
  case userDevelopmentSigningRequired(applicationDescription: String)
}

extension IDBCommandError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .simulatorOnlyOperation(operation, targetDescription):
      return "Target is not a simulator, cannot \(operation): \(targetDescription)"
    case let .notASimulator(targetDescription):
      return "Target is not a simulator: \(targetDescription)"
    case let .invalidURL(urlString):
      return "\(urlString) is not a valid URL"
    case let .multipleCrashLogs(predicateDescription):
      return "More than one crash log matching \(predicateDescription)"
    case let .noCrashLogs(predicateDescription):
      return "No crashes matching \(predicateDescription)"
    case let .replTestsUnsupported(targetDescription):
      return "\(targetDescription) does not support running REPL tests"
    case let .replSessionsUnsupported(targetDescription):
      return "\(targetDescription) does not support running REPL sessions"
    case let .replAppLaunchesUnsupported(targetDescription):
      return "\(targetDescription) does not support REPL app launches"
    case .replHostAppMissing:
      return "ReplHost.app not found in the companion Resources directory"
    case .replIDBLibraryMissing:
      return "libReplIDB-iOS.dylib not found in the companion Resources directory"
    case .noDebugServer:
      return "No debug server running"
    case .debugServerAlreadyRunning:
      return "Debug server is already running"
    case let .notPersistedApplication(bundleID, suitable):
      return "\(bundleID) not persisted application and is therefore not debuggable. Suitable applications: \(CollectionInformation.oneLineDescription(from: suitable))"
    case let .userDevelopmentSigningRequired(applicationDescription):
      return "Requested debuggable install of \(applicationDescription) but User Development signing is required"
    }
  }
}

/// Receives the events of an install as it runs.
public protocol InstallEventObserving: Sendable {
  func observe(_ event: InstallEvent)
}

public final class IDBCommandExecutor {

  private let target: CompanionTarget
  /// The companion's own log, named `grpc_handler`, which handlers log their work to.
  public let logger: IDBLogger
  private let debugserverPort: in_port_t

  public let storageManager: IDBStorageManager
  public var debugServer: DebugServer?
  public let temporaryDirectory: TemporaryDirectory

  // MARK: - Initializers

  /// Logs to `logger`, named `grpc_handler`.
  public init(target: CompanionTarget, storageManager: IDBStorageManager, temporaryDirectory: TemporaryDirectory, debugserverPort: in_port_t, logger: IDBLogger) {
    self.target = target
    self.storageManager = storageManager
    self.temporaryDirectory = temporaryDirectory
    self.debugserverPort = debugserverPort
    self.logger = logger.named("grpc_handler")
  }

  // MARK: - Installation

  /// The cache `IDB_INSTALL_CACHE_DIR` names, shared by every companion given it; `nil`, and nothing cached, without it.
  private static let installCache = DownloadCache.fromEnvironment()

  public func listApps(_ fetchProcessState: Bool) async throws -> [InstalledApplication: Any] {
    let installedApps = try await target.application.installed()
    let runningApps: [String: pid_t]
    if fetchProcessState {
      runningApps = try await target.application.running()
    } else {
      runningApps = [:]
    }
    var listing: [InstalledApplication: Any] = [:]
    for application in installedApps {
      if let pid = runningApps[application.bundle.identifier] {
        listing[application] = NSNumber(value: pid)
      } else {
        listing[application] = NSNull()
      }
    }
    return listing
  }

  /// Stages `source`, finds the artifact `destination` names in it and installs that, reporting each stage, how an archive
  /// was unpacked and how a download went through `onEvent`.
  public func install(
    _ destination: InstallDestination,
    from source: InstallSource,
    options: InstallOptions = InstallOptions(),
    observer: (any InstallEventObserving)? = nil
  ) async throws -> InstalledArtifact {
    return try await Staging.install(
      source, as: destination.kind, options: options, cache: Self.installCache, temporaryDirectory: temporaryDirectory,
      logger: target.logger, onEvent: { observer?.observe($0) }
    ) { artifact, inPlace in
      try await install(artifact, as: destination, inPlace: inPlace)
    }
  }

  // MARK: - Public Methods

  /// The accessibility reads and actions on the target.
  var accessibility: CompanionAccessibility {
    CompanionAccessibility(target: target)
  }

  /// Screenshot commands remain behind the shared executor when an RPC's child task holds it.
  func screenshot(configuration: ScreenshotConfiguration) async throws -> ScreenshotResult {
    try await target.screenshot.take(configuration: configuration)
  }

  // MARK: - REPL screenshot & recording

  /// The companion-host directory the target uses for per-target files. REPL
  /// screenshot/video artifacts are staged under a session subdirectory here.
  public var auxillaryDirectory: String {
    target.auxillaryDirectory
  }

  /// Captures a screenshot, optionally cropped to `cropRect` (in screen points),
  /// encoded as uncompressed TIFF (`asPNG == false`) or PNG.
  public func replScreenshot(cropRect: CGRect?, asPNG: Bool) async throws -> Data {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.simulatorOnlyOperation(operation: "take a screenshot", targetDescription: String(describing: target))
    }
    return try await simulator.screenshot.takeForRepl(cropRect: cropRect, asPNG: asPNG)
  }

  /// Starts recording the target's screen to `filePath`. The returned handle's
  /// `stop()` finalizes the file. Only one recording runs at a time.
  public func replStartRecording(toFile filePath: String) async throws -> any VideoRecording {
    try await target.videoRecording.start(toFile: filePath)
  }

  /// Resolves when the app with `bundleID` terminates on the target. Used to drop a
  /// REPL recording that outlived the app that started it. Throws if the app's
  /// process cannot be resolved (e.g. it is not running).
  public func replWaitForAppTermination(bundleID: String) async throws {
    let pid = try await target.application.processID(forBundleID: bundleID)
    await waitForProcessExit(pid: pid)
  }

  public func audioInjectionAppLaunchEnvironment(
    _ environment: [String: String]
  ) async -> [String: String] {
    guard let simulator = try? target.simulator() else {
      return environment
    }
    return await simulator.audioInjection.appLaunchEnvironment(environment)
  }

  public func videoInjectionAppLaunchEnvironment(_ environment: [String: String]) -> [String: String] {
    guard let simulator = try? target.simulator() else {
      return environment
    }
    return simulator.videoInjection.appLaunchEnvironment(environment)
  }

  public func clearKeychain() async throws {
    try await target.simulator().keychain.clear()
  }

  public func uninstallApplication(_ bundleID: String) async throws {
    try await target.application.uninstall(bundleID: bundleID)
  }

  public func killApplication(_ bundleID: String) async throws {
    do {
      try await target.application.kill(bundleID: bundleID)
    } catch {
      // Killing an app that is not running is a no-op.
    }
  }

  /// Injects code into a logic test bundle for the `test` REPL context. The session is hosted by
  /// the test run, which finishes once the session is closed.
  public func replStartTest(bundlePath: String) async throws -> CodeInjectionSession {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.replTestsUnsupported(targetDescription: String(describing: target))
    }
    return try await simulator.codeInjection.inject(into: .logicTestBundle(path: bundlePath), additionalLibraries: replIDBLibraries(), connectTimeout: Self.replConnectTimeout)
  }

  /// The product family ("iphone", "ipad", "watch", "tv", "mac", "unknown") of
  /// the target this companion is connected to. Reported to the client as part
  /// of the REPL handshake.
  public var replDeviceType: String {
    target.deviceType.family.stringRepresentation
  }

  /// The installed app's bundle path and main executable UUID, which the REPL
  /// compares with an `Execute`'s expected build before loading a dylib.
  public func replInstalledApplication(bundleID: String) async throws -> (bundlePath: String, executableUUID: UUID?) {
    let app = try await target.application.installed(bundleID: bundleID)
    return (app.bundle.path, app.bundle.binary?.uuid)
  }

  /// The OS version ("26.2") of the target this companion is connected to.
  /// Reported to the client in the REPL handshake so it can compile injected
  /// code for the runtime's deployment target.
  public var replOSVersion: String {
    target.osVersion.versionString
  }

  /// Injects code into the simulator's guest bridge for the "simulator" REPL context. The session
  /// is hosted by the bridge process, which exits once the session is closed.
  public func replStartSimulator() async throws -> CodeInjectionSession {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.replSessionsUnsupported(targetDescription: String(describing: target))
    }
    return try await simulator.codeInjection.inject(into: .simulator, additionalLibraries: replIDBLibraries(), connectTimeout: Self.replConnectTimeout)
  }

  /// Injects code into an installed app for the `app` REPL context -- or, when `reuseSession` is
  /// true, reattaches to a session the running app still serves. The session is hosted by the app,
  /// which outlives it (it resets and waits for the next client on disconnect).
  public func replStartApp(bundleID: String, reuseSession: Bool) async throws -> CodeInjectionSession {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.replSessionsUnsupported(targetDescription: String(describing: target))
    }
    return try await simulator.codeInjection.inject(into: .application(bundleID: bundleID, reattach: reuseSession), additionalLibraries: replIDBLibraries(), connectTimeout: Self.replConnectTimeout)
  }

  /// How long a REPL host has to serve its control socket once started.
  static let replConnectTimeout: TimeInterval = 120

  // Keep in sync with the PRODUCT_BUNDLE_IDENTIFIER in defs.bzl
  // `make_repl_host_app` and in REPLHost/project.yml.
  static let replHostBundleID = "com.facebook.idb.replhost"

  /// Ensures the bundled ReplHost app is installed on the target and returns its
  /// bundle id. Installs it from the companion's Resources/ only if it is not
  /// already installed, so the common (already-installed) case does no filesystem
  /// work. Used by the `app` REPL context when no bundle id is given.
  public func ensureReplHostAppInstalled() async throws -> String {
    let bundleID = Self.replHostBundleID
    if (try? await target.application.installed(bundleID: bundleID)) != nil {
      return bundleID
    }
    // Not installed: locate ReplHost.app in the Resources/ directory next to the
    // companion binary (the same directory the shim dylibs load from) and install it.
    guard let appPath = BundledResources.path(forItem: "ReplHost.app") else {
      throw IDBCommandError.replHostAppMissing
    }
    _ = try await install(.application(makeDebuggable: false), from: .localPath(appPath))
    return bundleID
  }

  /// The environment that arms an app launch for the REPL (DYLD-inject the shim and
  /// libReplIDB + the IDB_REPL_* vars), used by `idb launch --enable-repl`. The control-socket
  /// path is deterministic, so a later `idb-repl app` reattaches. Simulator
  /// targets only.
  public func replAppLaunchEnvironment(bundleID: String) async throws -> [String: String] {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.replAppLaunchesUnsupported(targetDescription: String(describing: target))
    }
    return try simulator.codeInjection.launchEnvironment(forApplication: bundleID, additionalLibraries: replIDBLibraries())
  }

  /// The interface of the `IDB` module that libReplIDB implements, reported to the driver so
  /// injected code can import it. Read host-side, so a host's sandbox need not contain it.
  public var replIDBInterfacePaths: [String] {
    BundledResources.path(forItem: "IDBAPI.swiftinterface").map { [$0] } ?? []
  }

  /// The `IDB` command API that injected code calls, loaded into every REPL host alongside the
  /// shim. The shim itself carries no idb API.
  private func replIDBLibraries() throws -> [String] {
    guard let path = BundledResources.path(forItem: "libReplIDB-iOS.dylib") else {
      throw IDBCommandError.replIDBLibraryMissing
    }
    return [path]
  }

  public func debugserverStart(_ bundleID: String) async throws -> DebugServer {
    let bundle = try debugserverPrepare(bundleID)
    let server = try await target.debugServer.launch(forHostApplication: bundle, port: debugserverPort)
    debugServer = server
    return server
  }

  public func debugserverStatus() throws -> DebugServer {
    guard let debugServer else {
      throw IDBCommandError.noDebugServer
    }
    return debugServer
  }

  public func debugserverStop() async throws -> DebugServer {
    let server = try debugserverStatus()
    try await server.cancel()
    debugServer = nil
    return server
  }

  public func hid(_ event: SimulatorHIDEvent) async throws {
    // The shared HID outlives the call, and `simulator.hid.disconnect()` drains it when closing it.
    try await connectToHID().send(event: event, logger: logger, drain: .onClose)
  }

  /// Types `text` as key presses on the simulator's hardware keyboard layout. Throws, sending
  /// nothing, if the layout cannot type the text.
  public func hid(text: String) async throws {
    try await hid(target.simulator().keyboard.typingEvent(for: text))
  }

  public func hid<S: AsyncSequence>(events: S) async throws where S.Element == SimulatorHIDEvent {
    let hid = try await connectToHID()
    try await hid.send(events: events, logger: logger)
  }

  // MARK: - File Commands

  func pushFileFromTar(_ tarData: Data, toPath destinationPath: String, containerType: String?) async throws {
    try await temporaryDirectory.withArchiveExtracted(tarData) { extractDir in
      let paths = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
      try await self.pushFiles(paths, toPath: destinationPath, containerType: containerType)
    }
  }

  public func pushFiles(_ paths: [URL], toPath destinationPath: String, containerType: String?) async throws {
    try await withFileContainer(for: containerType) { container in
      for originPath in paths {
        try await container.copy(fromHost: originPath.path, toContainer: destinationPath)
      }
    }
  }

  public func pullFilePath(_ path: String, destinationPath: String, containerType: String?) async throws -> String {
    return try await withFileContainer(for: containerType) { container in
      try await container.copy(fromContainer: path, toHost: destinationPath)
    }
  }

  public func withDapServer<Result: Sendable>(path dapPath: String, input: InputSource, output: any DataConsumer, _ body: (RunningSubprocess) async throws -> Result) async throws -> Result {
    try await target.simulator().dapServer.withServer(dapPath, input: input, output: output, body)
  }

  public func clean() async throws {
    if target.state != .shutdown {
      try await uninstallAllApplications()
    }
    try await removeAllStorageAndClearKeychain()
  }

  // MARK: - Private Methods

  private func removeAllStorageAndClearKeychain() async throws {
    try storageManager.clean()
    try await clearKeychain()
  }

  private func uninstallAllApplications() async throws {
    let apps = try await listApps(false)
    for app in apps.keys where app.installType == .user {
      try await killApplication(app.bundle.identifier)
      try await uninstallApplication(app.bundle.identifier)
    }
  }

  private func debugserverPrepare(_ bundleID: String) throws -> BundleDescriptor {
    if debugServer != nil {
      throw IDBCommandError.debugServerAlreadyRunning
    }
    let persisted = storageManager.application.persistedBundles
    guard let bundle = persisted[bundleID] else {
      throw IDBCommandError.notPersistedApplication(bundleID: bundleID, suitable: Array(persisted.keys))
    }
    return bundle
  }

  func withFileContainer<R>(
    for containerType: String?,
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    guard let containerType, !containerType.isEmpty else {
      if target is Device {
        return try await target.file.withMediaDirectory { container in
          try await body(container)
        }
      }
      return try await target.file.withRootFilesystem { container in
        try await body(container)
      }
    }
    if containerType == FileContainerKind.crashes.rawValue {
      return try await target.crashLog.withFiles { container in
        try await body(container)
      }
    }
    if containerType == FileContainerKind.xctest.rawValue {
      return try await body(storageManager.xctest.asFileContainer())
    }
    if containerType == FileContainerKind.dylib.rawValue {
      return try await body(storageManager.dylib.asFileContainer())
    }
    if containerType == FileContainerKind.dsym.rawValue {
      return try await body(storageManager.dsym.asFileContainer())
    }
    if containerType == FileContainerKind.framework.rawValue {
      return try await body(storageManager.framework.asFileContainer())
    }
    if containerType == FileContainerKind.application.rawValue {
      return try await target.file.withApplicationContainers { container in
        try await body(container)
      }
    }
    if containerType == FileContainerKind.group.rawValue {
      return try await target.file.withGroupContainers { container in
        try await body(container)
      }
    }
    if containerType == FileContainerKind.media.rawValue {
      return try await target.file.withMediaDirectory { container in
        try await body(container)
      }
    }
    if containerType == FileContainerKind.root.rawValue {
      return try await target.file.withRootFilesystem { container in
        try await body(container)
      }
    }
    if containerType == FileContainerKind.provisioningProfiles.rawValue {
      return try await target.file.withProvisioningProfiles { container in
        try await body(container)
      }
    }
    if containerType == FileContainerKind.mdmProfiles.rawValue {
      return try await target.file.withMDMProfiles { container in
        try await body(container)
      }
    }
    if containerType == FileContainerKind.springboardIcons.rawValue {
      return try await target.file.withSpringboardIconLayout { container in
        try await body(container)
      }
    }
    if containerType == FileContainerKind.wallpaper.rawValue {
      return try await target.file.withWallpaper { container in
        try await body(container)
      }
    }
    if containerType == FileContainerKind.diskImages.rawValue {
      return try await target.file.withDiskImages { container in
        try await body(container)
      }
    }
    if containerType == FileContainerKind.symbols.rawValue {
      return try await target.file.withSymbols { container in
        try await body(container)
      }
    }
    if containerType == FileContainerKind.auxillary.rawValue {
      return try await target.file.withAuxiliary { container in
        try await body(container)
      }
    }
    return try await target.file.withContainerApplication(containerType) { container in
      try await body(container)
    }
  }

  private func connectToHID() async throws -> SimulatorHID {
    let simulator = try target.simulator()
    try SimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(target.logger)
    return try await simulator.hid.connect()
  }

  private func installAppBundle(_ appBundle: BundleDescriptor, makeDebuggable: Bool, persistByMoving: Bool) async throws -> InstalledArtifact {
    let userDevelopmentAppIsRequired = target is Device
    try storageManager.application.checkArchitecture(appBundle)
    // TODO: currently we have to persist it even if app is not used for debugging
    // as installed apps are referenced from xctestrun files and expanded by idb
    // by using its own application storage. Fix this by replacing xctestrun
    // placeholders by app bundle paths instead
    let persisted = try await storageManager.application.saveBundle(appBundle, usingSymlink: !persistByMoving, skipSigningBundles: false)
    let installedApp: InstalledApplication
    do {
      // A moved bundle no longer exists at its staging path, and a Mac target registers the app where it is installed from.
      installedApp = try await target.application.install(atPath: persistByMoving ? persisted.path.path : appBundle.path)
    } catch {
      // `saveBundle` recreates a directory per bundle ID, holding only the bundle it just persisted.
      try? FileManager.default.removeItem(at: persisted.path.deletingLastPathComponent())
      throw error
    }
    if makeDebuggable && installedApp.installType != .userDevelopment && userDevelopmentAppIsRequired {
      throw IDBCommandError.userDevelopmentSigningRequired(applicationDescription: String(describing: installedApp))
    }
    return InstalledArtifact(name: appBundle.identifier, uuid: appBundle.binary?.uuid as NSUUID?, path: URL(fileURLWithPath: installedApp.bundle.path))
  }

  /// Stores `artifact` and installs it on the target if it is an application. An artifact that is in place is linked into
  /// storage; anything staged is moved there, since its staging directory is deleted once the install returns.
  private func install(_ artifact: Artifact, as destination: InstallDestination, inPlace: Bool) async throws -> InstalledArtifact {
    switch artifact {
    case .application(let bundle):
      return try await installAppBundle(bundle, makeDebuggable: destination.makeDebuggable, persistByMoving: !inPlace)
    case .testBundle(let url):
      return try await storageManager.xctest.saveTestBundle(url, usingSymlink: inPlace, skipSigningBundles: destination.skipSigningBundles)
    case .testRun(let url):
      return try storageManager.xctest.saveTestRun(url)
    case .framework(let bundle):
      return try await storageManager.framework.saveBundle(bundle, usingSymlink: inPlace, skipSigningBundles: false)
    case .dylib(let url):
      return try storageManager.dylib.saveFile(url)
    case .dsym(let url):
      return try await installAndLinkDsym(url, intoStorage: storageManager.dsym, linkTo: destination.linkTo)
    }
  }

  private func installAndLinkDsym(_ extractionDir: URL, intoStorage storage: FileStorage, linkTo: DsymInstallLinkToBundle?) async throws -> InstalledArtifact {
    let artifact = try storage.saveFileInUniquePath(extractionDir)
    guard let linkTo else {
      return artifact
    }
    let bundlePathURL: URL
    if linkTo.bundleType == .app {
      let app = try await target.application.installed(bundleID: linkTo.bundleID)
      logger.log("Going to create a symlink for app bundle: \(app.bundle.name)")
      bundlePathURL = URL(fileURLWithPath: app.bundle.path)
    } else {
      let testDescriptor = try storageManager.xctest.testDescriptor(withID: linkTo.bundleID)
      logger.log("Going to create a symlink for test bundle: \(testDescriptor.name)")
      bundlePathURL = testDescriptor.url
    }
    let bundleUrl = bundlePathURL.deletingLastPathComponent()
    let dsymURL = bundleUrl.appendingPathComponent(artifact.path.lastPathComponent)
    try? FileManager.default.removeItem(at: dsymURL)
    logger.log("Deleted a symlink for dsym if it already exists: \(dsymURL)")
    try FileManager.default.createSymbolicLink(at: dsymURL, withDestinationURL: artifact.path)
    logger.log("Created a symlink for dsym from: \(dsymURL) to \(artifact.path)")
    return artifact
  }
}
