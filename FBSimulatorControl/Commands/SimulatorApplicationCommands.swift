/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
@preconcurrency import Foundation

public enum SimulatorApplicationInstallError: Error, LocalizedError {
  case installFailed(bundleDescription: String, options: String)
  case processSuspended(bundleID: String, processIdentifier: pid_t, debuggerAttached: Bool)
  case processDebuggerAttached(bundleID: String, processIdentifier: pid_t)
  case targetNotBooted(state: String)
  case targetUnavailable(reason: String)
  case installingSystemApplication(applicationDescription: String)
  case applicationMissingExecutable(path: String)
  case unsupportedArchitectures(binaryArchitectures: [String], binaryPath: String, simulatorArchitectures: [String])

  public var errorDescription: String? {
    switch self {
    case let .installFailed(bundleDescription, options):
      return "Failed to install Application \(bundleDescription) with options \(options)"
    case let .processSuspended(bundleID, processIdentifier, debuggerAttached):
      let processDescription = "Cannot install '\(bundleID)' because its existing process (PID \(processIdentifier)) is suspended."
      if debuggerAttached {
        return "\(processDescription) A debugger is attached; detach the debugger or terminate the app, then retry."
      }
      return "\(processDescription) Resume or terminate the app, then retry."
    case let .processDebuggerAttached(bundleID, processIdentifier):
      return "Cannot install '\(bundleID)' because a debugger is attached to its existing process (PID \(processIdentifier)). Detach the debugger or terminate the app, then retry."
    case let .targetNotBooted(state):
      return "Cannot install an application because the Simulator is not booted (state: \(state)). Boot it, then retry."
    case let .targetUnavailable(reason):
      return "Cannot install an application because CoreSimulator reports the target as unavailable: \(reason)"
    case let .installingSystemApplication(applicationDescription):
      return "Cannot install app as it is a system app \(applicationDescription)"
    case let .applicationMissingExecutable(path):
      return "Cannot install the app at \(path) as it has no executable"
    case let .unsupportedArchitectures(binaryArchitectures, binaryPath, simulatorArchitectures):
      return "Simulator does not support any of the architectures (\(CollectionInformation.oneLineDescription(from: binaryArchitectures))) of the executable at \(binaryPath). Simulator Archs (\(CollectionInformation.oneLineDescription(from: simulatorArchitectures)))"
    }
  }
}

public enum SimulatorApplicationUninstallError: Error, LocalizedError {
  case uninstallingSystemApplication(applicationDescription: String)
  case uninstallFailed(bundleID: String, underlying: Error)

  public var errorDescription: String? {
    switch self {
    case let .uninstallingSystemApplication(applicationDescription):
      return "Can't uninstall '\(applicationDescription)' as it is a system Application"
    case let .uninstallFailed(bundleID, _):
      return "Failed to uninstall '\(bundleID)'"
    }
  }
}

public enum SimulatorApplicationLaunchError: Error, LocalizedError {
  case launchingUninstalledApplication(bundleID: String, underlying: Error)
  case foregroundIfRunningIncompatibleWithWaitForDebugger
  case applicationAlreadyRunning(bundleID: String, processIdentifier: pid_t)
  case noDataDirectory(bundleID: String)

  public var errorDescription: String? {
    switch self {
    case let .launchingUninstalledApplication(bundleID, underlying):
      return "App \(bundleID) can't be launched as it isn't installed: \(underlying)"
    case .foregroundIfRunningIncompatibleWithWaitForDebugger:
      return "'Foreground if running' and 'wait for debugger cannot be applied simultaneously"
    case let .applicationAlreadyRunning(bundleID, processIdentifier):
      return "App '\(bundleID)' can't be launched as it is already running (PID=\(processIdentifier))"
    case let .noDataDirectory(bundleID):
      return "Cannot launch \(bundleID) as the Simulator has no data directory"
    }
  }
}

public enum SimulatorApplicationLookupError: Error, LocalizedError {
  case servicePatternConstructionFailed
  case searchPatternConstructionFailed(bundleID: String)
  case installInfoFieldNotAString(field: String, value: String, key: String, info: String)
  case dataContainerNotAURL(value: String, key: String, info: String)
  case applicationInfoUnavailable(path: String)

  public var errorDescription: String? {
    switch self {
    case .servicePatternConstructionFailed:
      return "Couldn't build the UIKitApplication service pattern"
    case let .searchPatternConstructionFailed(bundleID):
      return "Couldn't build search pattern for '\(bundleID)'"
    case let .installInfoFieldNotAString(field, value, key, info):
      return "\(field) \(value) is not a String for \(key) in \(info)"
    case let .dataContainerNotAURL(value, key, info):
      return "Data Container \(value) is not a NSURL for \(key) in \(info)"
    case let .applicationInfoUnavailable(path):
      return "Could not determine Application information for path \(path)"
    }
  }
}

enum SimulatorApplicationInstallAttempt {
  case initial
  case retry
}

public struct SimulatorApplicationCommands: ApplicationCommands {

  internal let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Async

  public func install(atPath path: String) async throws -> InstalledApplication {
    try confirmApplicationInstallTargetIsReady()
    let appBundle = try await confirmCompatibilityOfApplication(atPath: path)
    let options: [String: Any] = ["CFBundleIdentifier": appBundle.identifier]
    let appURL = URL(fileURLWithPath: appBundle.path)
    return try await Self.installAndResolveApplication(
      install: { attempt in
        try await self.confirmApplicationInstallPreconditions(bundleID: appBundle.identifier)
        if attempt == .retry {
          simulator.logger.log("Retrying install due to reinstall bug")
        }
        try Task.checkCancellation()
        try simulator.device.installApplication(appURL, withOptions: options as [AnyHashable: Any])
      },
      resolveInstalledApplication: { try await self.installed(bundleID: appBundle.identifier) },
      installFailure: {
        .installFailed(bundleDescription: String(describing: appBundle), options: String(describing: options))
      })
  }

  public func launch(_ configuration: ApplicationLaunchConfiguration) async throws -> LaunchedApplication {
    try await ensureApplicationIsInstalled(configuration.bundleID)
    try await confirmApplicationLaunchState(configuration.bundleID, launchMode: configuration.launchMode, waitForDebugger: configuration.waitForDebugger)
    var outputs: [FileBackedOutput] = []
    do {
      outputs.append(try Self.fileBackedOutput(configuration.stdOut))
      outputs.append(try Self.fileBackedOutput(configuration.stdErr))
      let processIdentifier = try await launch(configuration, stdOutPath: outputs[0].path, stdErrPath: outputs[1].path)
      return SimulatorLaunchedApplication(simulator: simulator, configuration: configuration, outputs: outputs, processIdentifier: processIdentifier)
    } catch {
      for output in outputs {
        await output.finish()
      }
      throw error
    }
  }

  public func kill(bundleID: String) async throws {
    try simulator.device.terminateApplication(withID: bundleID)
  }

  public func installed() async throws -> [InstalledApplication] {
    let installedApps = try simulator.device.installedApps()
    var applications: [InstalledApplication] = []
    for appInfo in installedApps.values {
      guard let dict = appInfo as? [String: Any],
        let application = try? SimulatorApplicationCommands.installedApplication(fromInfo: dict)
      else {
        continue
      }
      applications.append(application)
    }
    return applications
  }

  public func uninstall(bundleID: String) async throws {
    let installedApplication = try await installed(bundleID: bundleID)
    if installedApplication.installType == .system {
      throw SimulatorApplicationUninstallError.uninstallingSystemApplication(applicationDescription: String(describing: installedApplication))
    }
    _ = try? await kill(bundleID: bundleID)
    do {
      try simulator.device.uninstallApplication(bundleID, withOptions: nil)
    } catch {
      throw SimulatorApplicationUninstallError.uninstallFailed(bundleID: bundleID, underlying: error)
    }
  }

  public func installed(bundleID: String) async throws -> InstalledApplication {
    try fetchInstalledApplication(bundleID: bundleID)
  }

  public func running() async throws -> [String: pid_t] {
    guard let uiKitApplicationPattern = try? NSRegularExpression(pattern: "UIKitApplication:", options: []) else {
      throw SimulatorApplicationLookupError.servicePatternConstructionFailed
    }
    let serviceNameToProcessIdentifier = try await simulator.launchCtl.serviceNamesAndProcessIdentifiers(matching: uiKitApplicationPattern)
    var mapping: [String: pid_t] = [:]
    for (serviceName, processIdentifier) in serviceNameToProcessIdentifier {
      if let bundleName = SimulatorLaunchCtlCommands.extractApplicationBundleIdentifier(fromServiceName: serviceName) {
        mapping[bundleName] = processIdentifier
      }
    }
    return mapping
  }

  public func processID(forBundleID bundleID: String) async throws -> pid_t {
    let pattern = "UIKitApplication:\(NSRegularExpression.escapedPattern(for: bundleID))(\\[|$)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      throw SimulatorApplicationLookupError.searchPatternConstructionFailed(bundleID: bundleID)
    }
    do {
      let (_, processIdentifier) = try await simulator.launchCtl.firstServiceNameAndProcessIdentifier(matching: regex)
      return processIdentifier
    } catch SimulatorLaunchCtlError.noMatchingProcesses {
      // Fall through to the prefix-agnostic lookup below.
    }
    // Remote sheets (SafariViewService and similar) run without a
    // `UIKitApplication:` label, so the primary lookup reports no match while
    // the service is live.
    let candidates = try await simulator.launchCtl.runningServices(matchingBundleID: bundleID)
    guard candidates.count <= 1, let (_, processIdentifier) = candidates.first else {
      if candidates.isEmpty {
        throw SimulatorLaunchCtlError.noMatchingProcesses(pattern: regex.pattern)
      }
      throw SimulatorLaunchCtlError.multipleMatchingProcesses(pattern: regex.pattern, matches: candidates)
    }
    return processIdentifier
  }

  // MARK: - Private

  private func fetchInstalledApplication(bundleID: String) throws -> InstalledApplication {
    let device = simulator.device
    var applicationType: NSString?
    try device.applicationIsInstalled(bundleID, type: &applicationType)
    let appInfo = try device.properties(ofApplication: bundleID)
    return try SimulatorApplicationCommands.installedApplication(fromInfo: appInfo)
  }

  // MARK: - Install Helpers

  static func installAndResolveApplication<T>(
    install: (SimulatorApplicationInstallAttempt) async throws -> Void,
    resolveInstalledApplication: () async throws -> T,
    installFailure: () -> SimulatorApplicationInstallError
  ) async throws -> T {
    do {
      try await install(.initial)
      try Task.checkCancellation()
      let installedApplication = try await resolveInstalledApplication()
      try Task.checkCancellation()
      return installedApplication
    } catch let error as CancellationError {
      throw error
    } catch let error as SimulatorApplicationInstallError {
      try Task.checkCancellation()
      throw Self.surfaced(error, otherwise: installFailure)
    } catch {
      try Task.checkCancellation()
      guard (error as NSError).description.contains("Failed to load Info.plist from bundle at path") else {
        throw installFailure()
      }
    }

    do {
      try await install(.retry)
      try Task.checkCancellation()
    } catch let error as CancellationError {
      throw error
    } catch let error as SimulatorApplicationInstallError {
      try Task.checkCancellation()
      throw Self.surfaced(error, otherwise: installFailure)
    } catch {
      try Task.checkCancellation()
      throw installFailure()
    }
    let installedApplication = try await resolveInstalledApplication()
    try Task.checkCancellation()
    return installedApplication
  }

  /// Lets the install errors a caller can act on through, and reports every other one as `installFailure()`.
  private static func surfaced(
    _ error: SimulatorApplicationInstallError, otherwise installFailure: () -> SimulatorApplicationInstallError
  ) -> SimulatorApplicationInstallError {
    switch error {
    case .processSuspended,
      .processDebuggerAttached,
      .targetNotBooted,
      .targetUnavailable:
      return error
    default:
      return installFailure()
    }
  }

  private func confirmApplicationInstallPreconditions(bundleID: String) async throws {
    try confirmApplicationInstallTargetIsReady()
    let processFetcher = ProcessFetcher()
    try await Self.confirmApplicationProcessIsInstallable(
      bundleID: bundleID,
      resolveProcessIdentifier: { try await self.processID(forBundleID: bundleID) },
      processIsSuspended: { (try? processFetcher.isProcessStopped($0)) == true },
      debuggerIsAttached: { (try? processFetcher.isDebuggerAttached(to: $0)) == true })
  }

  private func confirmApplicationInstallTargetIsReady() throws {
    let state = simulator.state
    try Self.confirmApplicationInstallTargetIsReady(
      state: state,
      stateDescription: state.stateString.rawValue,
      checkAvailability: { try simulator.device.isAvailable() })
  }

  static func confirmApplicationInstallTargetIsReady(
    state: TargetState,
    stateDescription: String,
    checkAvailability: () throws -> Void
  ) throws {
    guard state == .booted else {
      throw SimulatorApplicationInstallError.targetNotBooted(state: stateDescription)
    }
    do {
      try checkAvailability()
    } catch {
      throw SimulatorApplicationInstallError.targetUnavailable(reason: error.localizedDescription)
    }
  }

  static func confirmApplicationProcessIsInstallable(
    bundleID: String,
    resolveProcessIdentifier: () async throws -> pid_t,
    processIsSuspended: (pid_t) -> Bool,
    debuggerIsAttached: (pid_t) -> Bool
  ) async throws {
    let processIdentifier: pid_t
    do {
      processIdentifier = try await resolveProcessIdentifier()
    } catch let error as CancellationError {
      throw error
    } catch {
      return
    }

    // Process inspection is advisory: ProcessFetcher imports false and inspection failures as
    // throws, so either result fails open rather than blocking an otherwise valid install.
    let processSuspended = processIsSuspended(processIdentifier)
    let debuggerAttached = debuggerIsAttached(processIdentifier)
    if processSuspended {
      throw SimulatorApplicationInstallError.processSuspended(
        bundleID: bundleID,
        processIdentifier: processIdentifier,
        debuggerAttached: debuggerAttached)
    }
    if debuggerAttached {
      throw SimulatorApplicationInstallError.processDebuggerAttached(
        bundleID: bundleID,
        processIdentifier: processIdentifier)
    }
  }

  // MARK: - Private

  private func ensureApplicationIsInstalled(_ bundleID: String) async throws {
    do {
      _ = try await installed(bundleID: bundleID)
    } catch {
      throw SimulatorApplicationLaunchError.launchingUninstalledApplication(bundleID: bundleID, underlying: error)
    }
  }

  private func confirmApplicationLaunchState(_ bundleID: String, launchMode: ApplicationLaunchMode, waitForDebugger: Bool) async throws {
    try await Self.confirmApplicationLaunchState(
      bundleID: bundleID,
      launchMode: launchMode,
      waitForDebugger: waitForDebugger,
      runningProcessIdentifier: { try await processID(forBundleID: bundleID) },
      kill: { try await kill(bundleID: bundleID) })
  }

  /// Refuses or prepares a launch according to whether the app is already running.
  ///
  /// Asks whether the app is running only when the answer changes the launch: finding the pid runs
  /// `launchctl` in the simulator, which takes a large part of a launch.
  static func confirmApplicationLaunchState(
    bundleID: String,
    launchMode: ApplicationLaunchMode,
    waitForDebugger: Bool,
    runningProcessIdentifier: () async throws -> pid_t,
    kill: () async throws -> Void
  ) async throws {
    let relaunch: Bool
    switch launchMode {
    case .foregroundIfRunning:
      if waitForDebugger {
        throw SimulatorApplicationLaunchError.foregroundIfRunningIncompatibleWithWaitForDebugger
      }
      // Launches whether or not the app is running.
      return
    case .failIfRunning:
      relaunch = false
    case .relaunchIfRunning:
      relaunch = true
    }

    let pid: pid_t
    do {
      pid = try await runningProcessIdentifier()
    } catch {
      // Process not running: treat as launchable.
      return
    }

    if relaunch {
      try await kill()
    } else {
      throw SimulatorApplicationLaunchError.applicationAlreadyRunning(bundleID: bundleID, processIdentifier: pid)
    }
  }

  private static func fileBackedOutput(_ output: ApplicationOutput) throws -> FileBackedOutput {
    switch output {
    case .nullDevice:
      return .nullDevice
    case let .consumer(consumer):
      return try .fifo(draining: consumer)
    }
  }

  private func launch(_ configuration: ApplicationLaunchConfiguration, stdOutPath: String?, stdErrPath: String?) async throws -> pid_t {
    guard let dataDirectory = simulator.dataDirectory else {
      throw SimulatorApplicationLaunchError.noDataDirectory(bundleID: configuration.bundleID)
    }
    let options = SimulatorApplicationCommands.simDeviceLaunchOptions(
      for: configuration,
      stdOutPath: translateAbsolutePath(stdOutPath, toPathRelativeTo: dataDirectory),
      stdErrPath: translateAbsolutePath(stdErrPath, toPathRelativeTo: dataDirectory))

    let logger = simulator.logger
    let bundleID = configuration.bundleID
    logger.log("Launching Application \(bundleID) with \(CollectionInformation.oneLineDescription(from: configuration.arguments)) \(CollectionInformation.oneLineDescription(from: configuration.environment))")

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<pid_t, Error>) in
      simulator.device.launchApplicationAsync(withID: bundleID, options: options, completionQueue: simulator.workQueue) { error, pid in
        if let error {
          logger.log("Failed to launch Application \(bundleID) \(error)")
          continuation.resume(throwing: error)
        } else {
          logger.log("Launched Application \(bundleID) with pid \(pid)")
          continuation.resume(returning: pid)
        }
      }
    }
  }

  private func translateAbsolutePath(_ absolutePath: String?, toPathRelativeTo referencePath: String) -> String? {
    guard let absolutePath else { return nil }
    if !absolutePath.hasPrefix("/") {
      return absolutePath
    }
    var translatedPath = ""
    for _ in (referencePath as NSString).pathComponents {
      translatedPath = (translatedPath as NSString).appendingPathComponent("..")
    }
    return (translatedPath as NSString).appendingPathComponent(absolutePath)
  }

  static func simDeviceLaunchOptions(for configuration: ApplicationLaunchConfiguration, stdOutPath: String?, stdErrPath: String?) -> [String: Any] {
    var options = SimulatorSubprocessLauncher.launchOptions(
      withArguments: configuration.arguments,
      environment: configuration.environment,
      waitForDebugger: configuration.waitForDebugger)
    if let stdOutPath {
      options["stdout"] = stdOutPath
    }
    if let stdErrPath {
      options["stderr"] = stdErrPath
    }
    return options
  }

  private static let keyDataContainer = "DataContainer"

  private static func installedApplication(fromInfo appInfo: [String: Any]) throws -> InstalledApplication {
    guard let appName = appInfo[ApplicationInstallInfoKey.bundleName.rawValue] as? String else {
      throw SimulatorApplicationLookupError.installInfoFieldNotAString(
        field: "Bundle Name",
        value: String(describing: appInfo[ApplicationInstallInfoKey.bundleName.rawValue] ?? "nil"),
        key: ApplicationInstallInfoKey.bundleName.rawValue,
        info: String(describing: appInfo))
    }
    guard appInfo[ApplicationInstallInfoKey.bundleIdentifier.rawValue] as? String != nil else {
      throw SimulatorApplicationLookupError.installInfoFieldNotAString(
        field: "Bundle Identifier",
        value: String(describing: appInfo[ApplicationInstallInfoKey.bundleIdentifier.rawValue] ?? "nil"),
        key: ApplicationInstallInfoKey.bundleIdentifier.rawValue,
        info: String(describing: appInfo))
    }
    guard let appPath = appInfo[ApplicationInstallInfoKey.path.rawValue] as? String else {
      throw SimulatorApplicationLookupError.installInfoFieldNotAString(
        field: "App Path",
        value: String(describing: appInfo[ApplicationInstallInfoKey.path.rawValue] ?? "nil"),
        key: ApplicationInstallInfoKey.path.rawValue,
        info: String(describing: appInfo))
    }
    guard let typeString = appInfo[ApplicationInstallInfoKey.applicationType.rawValue] as? String else {
      throw SimulatorApplicationLookupError.installInfoFieldNotAString(
        field: "Install Type",
        value: String(describing: appInfo[ApplicationInstallInfoKey.applicationType.rawValue] ?? "nil"),
        key: ApplicationInstallInfoKey.applicationType.rawValue,
        info: String(describing: appInfo))
    }
    let dataContainer = appInfo[keyDataContainer]
    if let dataContainer, !(dataContainer is URL) {
      throw SimulatorApplicationLookupError.dataContainerNotAURL(value: String(describing: dataContainer), key: keyDataContainer, info: String(describing: appInfo))
    }

    let bundle = try BundleDescriptor(path: appPath)

    _ = appName // used for validation only
    return InstalledApplication(
      bundle: bundle,
      installTypeString: typeString,
      signerIdentity: nil,
      dataContainer: (dataContainer as? URL)?.path)
  }

  private func confirmCompatibilityOfApplication(atPath path: String) async throws -> BundleDescriptor {
    guard let application = try? BundleDescriptor(path: path) else {
      throw SimulatorApplicationLookupError.applicationInfoUnavailable(path: path)
    }

    let installed: InstalledApplication?
    do {
      installed = try await self.installed(bundleID: application.identifier)
    } catch {
      installed = nil
    }
    if let installed, installed.installType == .system {
      throw SimulatorApplicationInstallError.installingSystemApplication(applicationDescription: String(describing: installed))
    }
    guard let binary = application.binary else {
      throw SimulatorApplicationInstallError.applicationMissingExecutable(path: path)
    }
    let binaryArchRawValues = Set(binary.architectures.map { $0.rawValue })
    let supportedArchitectures = TargetConfiguration.baseArchsToCompatibleArch(simulator.architectures)
    let supportedArchRawValues = Set(supportedArchitectures.map { $0.rawValue })
    if binaryArchRawValues.isDisjoint(with: supportedArchRawValues) {
      throw SimulatorApplicationInstallError.unsupportedArchitectures(
        binaryArchitectures: Array(binaryArchRawValues),
        binaryPath: binary.path,
        simulatorArchitectures: Array(supportedArchRawValues))
    }
    return application
  }
}
