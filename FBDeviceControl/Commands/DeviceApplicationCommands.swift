/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import MobileDeviceAPI

// MARK: - DeviceApplicationError

public enum DeviceApplicationError: Error {
  case awaitingTerminationUnsupported
  case installFailed(applicationName: String, status: Int32, message: String, recentEvents: String)
  case uninstallFailed(bundleID: String, status: Int32, message: String, recentEvents: String)
  case uninstallingApplicationNotInstalled(bundleID: String)
  case applicationNotInstalled(bundleID: String, installed: [String])
  case noProcessID(bundleID: String)
  case ambiguousProcess(bundleID: String, executable: String, sharedWith: [String])
  case applicationLookupFailed(status: Int32, message: String)
  case applicationLookupMalformed
  case pidListRequestFailed(underlying: any Error)
  case pidListAcknowledgementFailed(underlying: any Error)
  case pidListResponseFailed(underlying: any Error)
  case pidListResponseNotADictionary(response: String)
  case pidListRequestUnsuccessful
  case missingBundleIdentifier(key: String, application: String)
}

extension DeviceApplicationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .awaitingTerminationUnsupported:
      return "Awaiting termination is not supported for device applications"
    case let .installFailed(applicationName, status, message, recentEvents):
      return "Failed to install application \(applicationName) 0x\(String(UInt32(bitPattern: status), radix: 16)) (\(message)). \(recentEvents)"
    case let .uninstallFailed(bundleID, status, message, recentEvents):
      return "Failed to uninstall application '\(bundleID)' with error 0x\(String(UInt32(bitPattern: status), radix: 16)) (\(message)). \(recentEvents)"
    case let .uninstallingApplicationNotInstalled(bundleID):
      return "Cannot uninstall \(bundleID): no application with this bundle ID is installed"
    case let .applicationNotInstalled(bundleID, installed):
      return "Application with bundle ID: \(bundleID) is not installed. Installed apps \(CollectionInformation.oneLineDescription(from: installed))"
    case let .noProcessID(bundleID):
      return "No pid for \(bundleID)"
    case let .ambiguousProcess(bundleID, executable, sharedWith):
      return "Cannot tell whether \(bundleID) is running: a process named \(executable) is running, and \(CollectionInformation.oneLineDescription(from: sharedWith)) share that executable name with it"
    case let .applicationLookupFailed(status, message):
      return "Failed to get list of applications 0x\(String(UInt32(bitPattern: status), radix: 16)) (\(message))"
    case .applicationLookupMalformed:
      return "Application lookup did not return a mapping of bundle identifiers to attributes"
    case let .pidListRequestFailed(underlying):
      return "Failed to request PidList \(underlying)"
    case let .pidListAcknowledgementFailed(underlying):
      return "Failed to receive 1 byte after PidList \(underlying)"
    case let .pidListResponseFailed(underlying):
      return "Failed to receive PidList response \(underlying)"
    case let .pidListResponseNotADictionary(response):
      return "PidList response \(response) is not a dictionary"
    case .pidListRequestUnsuccessful:
      return "Request to PidList is not RequestSuccessful"
    case let .missingBundleIdentifier(key, application):
      return "No \(key) in installed application \(application)"
    }
  }
}

// MARK: - DeviceWorkflowStatistics

private class DeviceWorkflowStatistics {
  let workflowType: String
  let logger: any ControlCoreLogger
  var lastEvent: [String: Any]?

  init(workflowType: String, logger: any ControlCoreLogger) {
    self.workflowType = workflowType
    self.logger = logger
  }

  func pushProgress(_ event: [String: Any]) {
    logger.log("\(workflowType) Progress: \(CollectionInformation.oneLineDescription(from: event))")
    lastEvent = event
  }

  var summaryOfRecentEvents: String {
    guard let lastEvent else {
      return "No events recorded"
    }
    return "Last event \(CollectionInformation.oneLineDescription(from: lastEvent))"
  }
}

private func workflowCallback(_ callbackDictionary: [String: Any]?, _ context: UnsafeMutableRawPointer?) {
  guard let context = unsafe context, let callbackDictionary else { return }
  let statistics = unsafe Unmanaged<DeviceWorkflowStatistics>.fromOpaque(context).takeUnretainedValue()
  statistics.pushProgress(callbackDictionary)
}

// MARK: - DeviceLaunchedApplication

private class DeviceLaunchedApplication: LaunchedApplication {
  let processIdentifier: pid_t
  private let _configuration: ApplicationLaunchConfiguration
  private let commands: DeviceApplicationCommands
  private let queue: DispatchQueue

  init(processIdentifier: pid_t, configuration: ApplicationLaunchConfiguration, commands: DeviceApplicationCommands, queue: DispatchQueue) {
    self.processIdentifier = processIdentifier
    self._configuration = configuration
    self.commands = commands
    self.queue = queue
  }

  func waitForTermination() async throws {
    throw DeviceApplicationError.awaitingTerminationUnsupported
  }

  func terminate() async throws {
    try await commands.killApplication(processIdentifier: processIdentifier)
    // A device does not relay the application's output, so its streams end once it has been stopped.
    for case let .consumer(consumer) in [_configuration.stdOut, _configuration.stdErr] {
      consumer.consumeEndOfFile()
    }
  }

  var bundleID: String {
    _configuration.bundleID
  }
}

// MARK: - DeviceApplicationCommands

public final class DeviceApplicationCommands: ApplicationCommands {
  private let device: Device

  // MARK: - Initializers

  public init(device: Device) {
    self.device = device
  }

  // MARK: - Async

  public func install(atPath path: String) async throws -> InstalledApplication {
    let bundle = try BundleDescriptor(path: path)
    let appURL = URL(fileURLWithPath: path, isDirectory: true)
    let options: [String: Any] = [
      "CFBundleIdentifier": bundle.identifier,
      "CloseOnInvalidate": 1,
      "InvalidateOnDetach": 1,
      "IsUserInitiated": 1,
      "PackageType": "Developer",
      "ShadowParentKey": device.deltaUpdateDirectory,
    ]
    try await device.withConnectedDevice(purpose: "install") { connectedDevice in
      device.logger.log("Installing Application \(appURL)")
      let statistics = DeviceWorkflowStatistics(workflowType: "Install", logger: connectedDevice.logger)
      let context = unsafe Unmanaged.passUnretained(statistics).toOpaque()
      let status =
        unsafe connectedDevice.calls.SecureInstallApplicationBundle?(
          connectedDevice.amDeviceRef,
          appURL as CFURL,
          options as CFDictionary,
          workflowCallback,
          context
        ) ?? -1
      if status != 0 {
        let errorMessage = unsafe connectedDevice.calls.CopyErrorText?(status)?.takeRetainedValue() as String? ?? "Unknown error"
        throw DeviceApplicationError.installFailed(applicationName: appURL.lastPathComponent, status: status, message: errorMessage, recentEvents: statistics.summaryOfRecentEvents)
      }
      device.logger.log("Installed Application \(appURL)")
    }
    return try await installed(bundleID: bundle.identifier)
  }

  public func uninstall(bundleID: String) async throws {
    // The device's uninstall succeeds for a bundle ID that is not installed, so that is checked first.
    guard try await installedApplicationsData(Self.namingLookupAttributes)[bundleID] != nil else {
      throw DeviceApplicationError.uninstallingApplicationNotInstalled(bundleID: bundleID)
    }
    try await device.withConnectedDevice(purpose: "uninstall_\(bundleID)") { connectedDevice in
      let statistics = DeviceWorkflowStatistics(workflowType: "Uninstall", logger: connectedDevice.logger)
      device.logger.log("Uninstalling Application \(bundleID)")
      let context = unsafe Unmanaged.passUnretained(statistics).toOpaque()
      let status =
        unsafe connectedDevice.calls.SecureUninstallApplication?(
          nil,
          connectedDevice.amDeviceRef,
          bundleID as CFString,
          0,
          workflowCallback,
          context
        ) ?? -1
      if status != 0 {
        let internalMessage = unsafe connectedDevice.calls.CopyErrorText?(status)?.takeRetainedValue() as String? ?? "Unknown error"
        throw DeviceApplicationError.uninstallFailed(bundleID: bundleID, status: status, message: internalMessage, recentEvents: statistics.summaryOfRecentEvents)
      }
      device.logger.log("Uninstalled Application \(bundleID)")
    }
  }

  public func installed() async throws -> [InstalledApplication] {
    let applicationData = try await installedApplicationsData(Self.installedApplicationLookupAttributes)
    var installedApplications: [InstalledApplication] = []
    for app in applicationData.values {
      let application = try DeviceApplicationCommands.installedApplication(from: app)
      installedApplications.append(application)
    }
    return installedApplications
  }

  public func installed(bundleID: String) async throws -> InstalledApplication {
    let applicationData = try await installedApplicationsData(Self.installedApplicationLookupAttributes)
    guard let app = applicationData[bundleID] else {
      throw DeviceApplicationError.applicationNotInstalled(bundleID: bundleID, installed: Array(applicationData.keys))
    }
    return try DeviceApplicationCommands.installedApplication(from: app)
  }

  public func running() async throws -> [String: pid_t] {
    try await runningApplications().resolved
  }

  public func processID(forBundleID bundleID: String) async throws -> pid_t {
    let running = try await runningApplications()
    if let pid = running.resolved[bundleID] {
      return pid
    }
    if let ambiguity = running.ambiguous[bundleID] {
      throw DeviceApplicationError.ambiguousProcess(bundleID: bundleID, executable: ambiguity.executable, sharedWith: ambiguity.sharedWith)
    }
    throw DeviceApplicationError.noProcessID(bundleID: bundleID)
  }

  public func kill(bundleID: String) async throws {
    let pid = try await processID(forBundleID: bundleID)
    try await killApplication(processIdentifier: pid)
  }

  public func launch(_ configuration: ApplicationLaunchConfiguration) async throws -> any LaunchedApplication {
    let pid: pid_t
    if device.osVersion.version.majorVersion >= 17 {
      let devicectl = AppleDevicectlCommandExecutor(device: device)
      pid = try await devicectl.launchApplication(configuration: configuration)
    } else {
      pid = try await withRemoteInstrumentsClient { client in
        try client.launchApplication(configuration)
      }
    }
    return DeviceLaunchedApplication(
      processIdentifier: pid,
      configuration: configuration,
      commands: self,
      queue: device.workQueue
    )
  }

  // MARK: - Private

  /// An executable name that more than one installed application has, with a running process
  /// that could not be attributed to one of them.
  private struct Ambiguity {
    let executable: String
    let sharedWith: [String]
  }

  /// Running applications by bundle identifier, and the installed applications that cannot be
  /// told apart from a running process.
  ///
  /// The trace relay names each process after its executable, which can differ from the bundle
  /// name (Settings runs as `Preferences`) and can be shared by several installed applications. A
  /// process whose name only one installed application has belongs to that application. One whose
  /// name several share belongs to the application whose bundle holds its executable, where
  /// `devicectl` reports the path; otherwise it is attributed to none of them.
  private func runningApplications() async throws -> (resolved: [String: pid_t], ambiguous: [String: Ambiguity]) {
    let pidToRunningProcessName = try await pidToRunningProcessName()
    let bundleIdentifierToAttributes = try await installedApplicationsData(Self.namingLookupAttributes)
    var processNameToBundleIdentifiers: [String: [String]] = [:]
    for (bundleIdentifier, attributes) in bundleIdentifierToAttributes {
      let processName = attributes[Self.bundleExecutableKey] as? String ?? attributes[ApplicationInstallInfoKey.bundleName.rawValue] as? String
      if let processName {
        processNameToBundleIdentifiers[processName, default: []].append(bundleIdentifier)
      }
    }
    var resolved: [String: pid_t] = [:]
    var shared: [pid_t: (processName: String, bundleIdentifiers: [String])] = [:]
    for (pid, processName) in pidToRunningProcessName {
      guard let bundleIdentifiers = processNameToBundleIdentifiers[processName] else {
        continue
      }
      if bundleIdentifiers.count == 1 {
        resolved[bundleIdentifiers[0]] = pid
      } else {
        shared[pid] = (processName, bundleIdentifiers.sorted())
      }
    }
    guard !shared.isEmpty else {
      return (resolved, [:])
    }
    let executablePaths = await processExecutablePaths()
    let bundlePath = { (bundleIdentifier: String) in bundleIdentifierToAttributes[bundleIdentifier]?[ApplicationInstallInfoKey.path.rawValue] as? String }
    var ambiguous: [String: Ambiguity] = [:]
    for (pid, process) in shared {
      if let executablePath = executablePaths[pid],
        let owner = process.bundleIdentifiers.first(where: { bundlePath($0).map { Self.path(executablePath, isInsideBundle: $0) } ?? false })
      {
        resolved[owner] = pid
        continue
      }
      for bundleIdentifier in process.bundleIdentifiers {
        ambiguous[bundleIdentifier] = Ambiguity(executable: process.processName, sharedWith: process.bundleIdentifiers.filter { $0 != bundleIdentifier })
      }
    }
    for bundleIdentifier in resolved.keys {
      ambiguous.removeValue(forKey: bundleIdentifier)
    }
    return (resolved, ambiguous)
  }

  /// The executable path of each running process, where `devicectl` can report it; empty otherwise.
  private func processExecutablePaths() async -> [pid_t: String] {
    guard device.osVersion.version.majorVersion >= 17 else {
      return [:]
    }
    do {
      return try await AppleDevicectlCommandExecutor(device: device).processExecutablePaths()
    } catch {
      device.logger.log("Could not read process executable paths to tell apps with the same executable apart: \(error.localizedDescription)")
      return [:]
    }
  }

  /// Whether `executablePath` is inside the bundle at `bundlePath`, ignoring the `/private`
  /// prefix one of them may carry.
  private static func path(_ executablePath: String, isInsideBundle bundlePath: String) -> Bool {
    func normalized(_ path: String) -> String {
      path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
    let bundle = normalized(bundlePath)
    return normalized(executablePath).hasPrefix(bundle.hasSuffix("/") ? bundle : bundle + "/")
  }

  fileprivate func killApplication(processIdentifier: pid_t) async throws {
    if device.osVersion.version.majorVersion >= 17 {
      try await AppleDevicectlCommandExecutor(device: device).terminateProcess(processIdentifier: processIdentifier)
      return
    }
    try await withRemoteInstrumentsClient { client in
      try client.killProcess(processIdentifier)
    }
  }

  private func installedApplicationsData(_ returnAttributes: [String]) async throws -> [String: [String: Any]] {
    return try await device.withConnectedDevice(purpose: "installed_apps") { connectedDevice in
      let options: [String: Any] = [
        "ReturnAttributes": returnAttributes
      ]
      var applications = unsafe Unmanaged<CFDictionary>.passUnretained(NSDictionary() as CFDictionary)
      let status =
        unsafe connectedDevice.calls.LookupApplications?(
          connectedDevice.amDeviceRef,
          options as CFDictionary,
          &applications
        ) ?? -1
      if status != 0 {
        let errorMessage = unsafe connectedDevice.calls.CopyErrorText?(status)?.takeRetainedValue() as String? ?? "Unknown error"
        throw DeviceApplicationError.applicationLookupFailed(status: status, message: errorMessage)
      }
      guard let result = unsafe applications.takeRetainedValue() as? [String: [String: Any]] else {
        throw DeviceApplicationError.applicationLookupMalformed
      }
      return result
    }
  }

  private func withRemoteInstrumentsClient<R>(_ body: (InstrumentsClient) throws -> R) async throws -> R {
    let usesSecureConnection = device.osVersion.version.majorVersion >= 14
    _ = try await device.developerDiskImage.ensureMounted()
    let serviceName = usesSecureConnection ? "com.apple.instruments.remoteserver.DVTSecureSocketProxy" : "com.apple.instruments.remoteserver"
    return try await device.withServiceConnection(serviceName) { connection in
      try body(InstrumentsClient(connection: connection, logger: device.logger))
    }
  }

  private func pidToRunningProcessName() async throws -> [pid_t: String] {
    return try await device.withServiceConnection("com.apple.os_trace_relay") { connection in
      do {
        try connection.sendMessage(["Request": "PidList"])
      } catch {
        throw DeviceApplicationError.pidListRequestFailed(underlying: error)
      }
      do {
        _ = try connection.receive(1)
      } catch {
        throw DeviceApplicationError.pidListAcknowledgementFailed(underlying: error)
      }
      let response: Any
      do {
        response = try connection.receiveMessage()
      } catch {
        throw DeviceApplicationError.pidListResponseFailed(underlying: error)
      }
      guard let responseDict = response as? [String: Any] else {
        throw DeviceApplicationError.pidListResponseNotADictionary(response: String(describing: response))
      }
      let status = responseDict["Status"] as? String
      if status != "RequestSuccessful" {
        throw DeviceApplicationError.pidListRequestUnsuccessful
      }
      let payload = responseDict["Payload"] as? NSDictionary ?? [:]
      var pidToRunningProcessName: [pid_t: String] = [:]
      for (key, value) in payload {
        // Process identifiers are numbers on older iOS versions and decimal strings on newer ones.
        let processIdentifier: pid_t? =
          switch key {
          case let number as NSNumber: pid_t(exactly: number.int64Value)
          case let string as String: pid_t(string)
          default: nil
          }
        guard let processIdentifier,
          let contents = value as? [String: Any],
          let processName = contents["ProcessName"] as? String
        else {
          continue
        }
        pidToRunningProcessName[processIdentifier] = processName
      }
      return pidToRunningProcessName
    }
  }

  private static func installedApplication(from app: [String: Any]) throws -> InstalledApplication {
    let bundleName = app[ApplicationInstallInfoKey.bundleName.rawValue] as? String ?? ""
    let path = app[ApplicationInstallInfoKey.path.rawValue] as? String ?? ""
    guard let bundleID = app[ApplicationInstallInfoKey.bundleIdentifier.rawValue] as? String else {
      throw DeviceApplicationError.missingBundleIdentifier(key: ApplicationInstallInfoKey.bundleIdentifier.rawValue, application: String(describing: app))
    }

    let bundle = BundleDescriptor(name: bundleName, identifier: bundleID, path: path, binary: nil)

    return InstalledApplication(
      bundle: bundle,
      installTypeString: app[ApplicationInstallInfoKey.applicationType.rawValue] as? String ?? "",
      signerIdentity: app[ApplicationInstallInfoKey.signerIdentity.rawValue] as? String ?? "",
      dataContainer: nil
    )
  }

  private static let installedApplicationLookupAttributes: [String] = [
    ApplicationInstallInfoKey.applicationType.rawValue,
    ApplicationInstallInfoKey.bundleIdentifier.rawValue,
    ApplicationInstallInfoKey.bundleName.rawValue,
    ApplicationInstallInfoKey.path.rawValue,
    ApplicationInstallInfoKey.signerIdentity.rawValue,
  ]

  private static let bundleExecutableKey = "CFBundleExecutable"

  private static let namingLookupAttributes: [String] = [
    ApplicationInstallInfoKey.bundleIdentifier.rawValue,
    ApplicationInstallInfoKey.bundleName.rawValue,
    ApplicationInstallInfoKey.path.rawValue,
    bundleExecutableKey,
  ]
}
