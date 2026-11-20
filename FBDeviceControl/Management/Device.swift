/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import FBVideoCore
import Foundation
import MobileDeviceAPI

/// Backed by a `MobileDevice`, a `RestorableDevice`, or both, caching the target
/// information of whichever it holds.
///
/// A `DeviceSet` preserves this object's identity across notifications. Its backing objects hold
/// the values and native handles of the processed notification; cached target information may
/// retain richer values across recovery transitions. Holding this object does not freeze later
/// notifications.
public final class Device: Target, DeviceCommands, CustomStringConvertible {

  // MARK: - Properties

  public let commandCache: TargetCommandCache
  public private(set) var logger: any ControlCoreLogger
  private let backingLock = NSLock()
  private var amDeviceStorage: MobileDevice?
  private var restorableDeviceStorage: RestorableDevice?
  private var cachedValues: CachedValues
  private var callsStorage: AMDCalls

  public var calls: AMDCalls { backingLock.withLock { callsStorage } }

  public var amDevice: MobileDevice? {
    get { backingLock.withLock { amDeviceStorage } }
    set {
      let incoming = newValue.map { CachedValues(from: $0) }
      let replaced = backingLock.withLock {
        let replaced = (amDeviceStorage, cachedValues)
        amDeviceStorage = newValue
        if let newValue, let incoming {
          callsStorage = newValue.calls
          cachedValues.merge(incoming, overwrite: true)
        }
        return replaced
      }
      withExtendedLifetime(replaced) {}
    }
  }

  var restorableDevice: RestorableDevice? {
    get { backingLock.withLock { restorableDeviceStorage } }
    set {
      let incoming = newValue.map { CachedValues(from: $0) }
      let replaced = backingLock.withLock {
        let replaced = (restorableDeviceStorage, cachedValues)
        restorableDeviceStorage = newValue
        if let newValue, let incoming {
          callsStorage = newValue.calls
          cachedValues.merge(incoming, overwrite: false)
        }
        return replaced
      }
      withExtendedLifetime(replaced) {}
    }
  }

  // MARK: - Cached target information

  private struct CachedValues {
    var state: TargetState
    var uniqueIdentifier: String?
    var udid: String?
    var name: String?
    var deviceType: DeviceType?
    var architectures: [Architecture]?
    var osVersion: OSVersion?
    var extendedInformation: [String: Any]?
    var targetType: TargetType?
    var buildVersion: String?
    var productVersion: String?
    var activationState: String?
    var allValues: [String: Any]?

    init(from info: any TargetInfo & DeviceProtocol) {
      state = info.state
      uniqueIdentifier = info.uniqueIdentifier
      udid = info.udid
      name = info.name
      deviceType = info.deviceType
      architectures = info.architectures
      osVersion = info.osVersion
      extendedInformation = info.extendedInformation
      targetType = info.targetType
      buildVersion = info.buildVersion
      productVersion = info.productVersion
      activationState = info.activationState
      allValues = info.allValues
    }

    mutating func merge(_ incoming: Self, overwrite: Bool) {
      state = incoming.state
      uniqueIdentifier = overwrite ? incoming.uniqueIdentifier : uniqueIdentifier ?? incoming.uniqueIdentifier
      udid = overwrite ? incoming.udid : udid ?? incoming.udid
      name = overwrite ? incoming.name : name ?? incoming.name
      deviceType = overwrite ? incoming.deviceType : deviceType ?? incoming.deviceType
      architectures = overwrite ? incoming.architectures : architectures ?? incoming.architectures
      osVersion = overwrite ? incoming.osVersion : osVersion ?? incoming.osVersion
      extendedInformation = overwrite ? incoming.extendedInformation : extendedInformation ?? incoming.extendedInformation
      targetType = overwrite ? incoming.targetType : targetType ?? incoming.targetType
      buildVersion = overwrite ? incoming.buildVersion : buildVersion ?? incoming.buildVersion
      productVersion = overwrite ? incoming.productVersion : productVersion ?? incoming.productVersion
      activationState = overwrite ? incoming.activationState : activationState ?? incoming.activationState
      allValues = overwrite ? incoming.allValues : allValues ?? incoming.allValues
    }
  }

  public var state: TargetState { backingLock.withLock { cachedValues.state } }

  /// The developer disk images this device can mount.
  public let developerDiskImages: any DeveloperDiskImageProviding

  /// Spawns the `devicectl` processes that operate this device.
  let devicectlLauncher: any SubprocessLauncher

  public var uniqueIdentifier: String { backingLock.withLock { cachedValues.uniqueIdentifier } ?? "" }
  public var udid: String { backingLock.withLock { cachedValues.udid } ?? "" }
  public var name: String { backingLock.withLock { cachedValues.name } ?? "" }
  public var deviceType: DeviceType { backingLock.withLock { cachedValues.deviceType } ?? DeviceType.generic(withName: "unknown") }
  public var architectures: [Architecture] { backingLock.withLock { cachedValues.architectures } ?? [] }
  public var osVersion: OSVersion { backingLock.withLock { cachedValues.osVersion } ?? OSVersion.generic(withName: "unknown") }
  public var extendedInformation: [String: Any] { backingLock.withLock { cachedValues.extendedInformation } ?? [:] }
  public var targetType: TargetType { backingLock.withLock { cachedValues.targetType } ?? .none }
  public var buildVersion: String? { backingLock.withLock { cachedValues.buildVersion } }
  public var productVersion: String? { backingLock.withLock { cachedValues.productVersion } }
  public var activationState: String { backingLock.withLock { cachedValues.activationState } ?? "" }
  public var allValues: [String: Any] { backingLock.withLock { cachedValues.allValues } ?? [:] }

  public init(
    amDevice: MobileDevice?,
    restorableDevice: RestorableDevice?,
    logger: any ControlCoreLogger,
    developerDiskImages: any DeveloperDiskImageProviding = InstalledDeveloperDiskImages(),
    devicectlLauncher: any SubprocessLauncher = HostSubprocessLauncher()
  ) {
    self.amDeviceStorage = amDevice
    self.restorableDeviceStorage = restorableDevice
    self.commandCache = TargetCommandCache()
    self.developerDiskImages = developerDiskImages
    self.devicectlLauncher = devicectlLauncher
    guard let info: any TargetInfo & DeviceProtocol = amDevice ?? restorableDevice else {
      preconditionFailure("A MobileDevice or RestorableDevice must be provided")
    }
    self.cachedValues = CachedValues(from: info)
    self.callsStorage = info.calls
    self.logger = logger
    self.logger = logger.withName(udid)
  }

  // MARK: - Target

  public var workQueue: DispatchQueue {
    // One of the two backing devices is always present, per the initializer's contract.
    (amDevice?.workQueue ?? restorableDevice?.workQueue) ?? DispatchQueue.main
  }

  public var asyncQueue: DispatchQueue {
    (amDevice?.asyncQueue ?? restorableDevice?.asyncQueue) ?? DispatchQueue.global()
  }

  private var temporaryDirectoryStorage: TemporaryDirectory?

  public var temporaryDirectory: TemporaryDirectory {
    if let temporaryDirectoryStorage {
      return temporaryDirectoryStorage
    }
    let created = TemporaryDirectory(logger: logger)
    temporaryDirectoryStorage = created
    return created
  }

  private let deltaUpdateDirectoryLock = NSLock()
  private var deltaUpdateDirectoryStorage: URL?

  /// The staging directory application installs share, so that a reinstall can be applied as a delta.
  /// Created on first use.
  var deltaUpdateDirectory: URL {
    deltaUpdateDirectoryLock.withLock {
      if let deltaUpdateDirectoryStorage {
        return deltaUpdateDirectoryStorage
      }
      let created = temporaryDirectory.temporaryDirectory()
      deltaUpdateDirectoryStorage = created
      return created
    }
  }

  public var auxillaryDirectory: String {
    let cwd = FileManager.default.currentDirectoryPath
    return FileManager.default.isWritableFile(atPath: cwd) ? cwd : "/tmp"
  }

  public var platformRootDirectory: String {
    get async {
      (XcodeConfiguration.developerDirectory as NSString).appendingPathComponent("Platforms/iPhoneOS.platform")
    }
  }

  public var runtimeRootDirectory: String {
    get async { await platformRootDirectory }
  }

  public var screenInfo: TargetScreenInfo? {
    nil
  }

  public var customDeviceSetPath: String? {
    nil
  }

  public func requiresBundlesToBeSigned() -> Bool {
    true
  }

  public func replacementMapping() -> [String: String] {
    [:]
  }

  public func environmentAdditions() -> [String: String] {
    [:]
  }

  public var description: String {
    self.targetDescription
  }

  // MARK: - DeviceProtocol

  public var amDeviceRef: AMDevice? {
    amDevice?.amDeviceRef
  }

  public var recoveryModeDeviceRef: AMRecoveryModeDevice? {
    restorableDevice?.recoveryModeDeviceRef
  }

  // MARK: - DeviceCommands

  public func withConnectedDevice<T>(
    purpose: String,
    _ body: (any DeviceCommands) async throws -> T
  ) async throws -> T {
    guard let amDevice else {
      throw AMDeviceServiceError.notAMDeviceBacked(service: purpose)
    }
    return try await amDevice.withConnectedDevice(purpose: purpose, body)
  }

  public func withHouseArrestAFCConnection<T>(
    forBundleID bundleID: String,
    afcCalls: AFCCalls,
    _ body: (FileConduit) async throws -> T
  ) async throws -> T {
    guard let amDevice else {
      throw AMDeviceServiceError.notAMDeviceBacked(service: "withHouseArrestAFCConnection(forBundleID:afcCalls:)")
    }
    return try await amDevice.withHouseArrestAFCConnection(forBundleID: bundleID, afcCalls: afcCalls, body)
  }

}

// Commands that own something outliving a single call — a notifier, an in-flight video, a set of
// AFC calls — are memoized through `commandCache` (`TargetCommandCache`), whose lock also stops
// two callers racing the first construction, and hold their device weakly so the cache slot does
// not close a cycle. Commands that only wrap the device are built per call and hold it strongly:
// nothing outlives the call that builds them.
extension Device {

  // MARK: - Shared accessors

  public var application: DeviceApplicationCommands {
    DeviceApplicationCommands(device: self)
  }

  public var crashLog: DeviceCrashLogCommands {
    commandCache.resolve { DeviceCrashLogCommands(device: self) }
  }

  public var screenshot: DeviceScreenshotCommands {
    DeviceScreenshotCommands(device: self)
  }

  public var location: DeviceLocationCommands {
    DeviceLocationCommands(device: self)
  }

  public var debugServer: DeviceDebugServerCommands {
    DeviceDebugServerCommands(device: self)
  }

  public var file: DeviceFileCommands {
    DeviceFileCommands(device: self)
  }

  public var lifecycle: DeviceLifecycleCommands {
    DeviceLifecycleCommands(device: self)
  }

  public var log: DeviceLogCommands {
    DeviceLogCommands(device: self)
  }

  public var xctest: DeviceXCTestCommands {
    commandCache.resolve { DeviceXCTestCommands(device: self) }
  }

  public var xctraceRecord: TargetXCTraceRecordCommands {
    TargetXCTraceRecordCommands(target: self)
  }

  // MARK: - Device-only accessors

  public var diagnosticInformation: DeviceDiagnosticInformationCommands {
    DeviceDiagnosticInformationCommands(device: self)
  }

  public var power: DevicePowerCommands {
    DevicePowerCommands(device: self)
  }

  public var provisioningProfile: DeviceProvisioningProfileCommands {
    DeviceProvisioningProfileCommands(device: self)
  }

  public var recovery: DeviceRecoveryCommands {
    DeviceRecoveryCommands(device: self)
  }

  public var debugSymbols: DeviceDebugSymbolsCommands {
    DeviceDebugSymbolsCommands(device: self)
  }

  public var developerDiskImage: DeviceDeveloperDiskImageCommands {
    DeviceDeveloperDiskImageCommands(device: self)
  }

  public var socketForwarding: DeviceSocketForwardingCommands {
    DeviceSocketForwardingCommands(device: self)
  }

  public var springboard: DeviceSpringboardCommands {
    DeviceSpringboardCommands(device: self)
  }

  // MARK: - Command verbs

  public func details(_ keys: Set<TargetDetailKey>) async throws -> TargetDetails {
    var details = TargetDetails(unsupported: keys)
    guard keys.contains(.diagnostics) else {
      return details
    }
    do {
      details.diagnostics = .read(try await diagnosticInformation.fetch())
    } catch let error as CancellationError {
      throw error
    } catch {
      details.diagnostics = .failed(error)
    }
    return details
  }
}

extension Device {

  /// Starts a service on the device, invalidating the connection once `body` returns or throws.
  ///
  /// The async counterpart of `startService`, which this mirrors including its restriction to
  /// AMDevice-backed devices.
  func withServiceConnection<T>(
    _ service: String,
    _ body: (LockdownServiceConnection) async throws -> T
  ) async throws -> T {
    guard let amDevice else {
      throw AMDeviceServiceError.notAMDeviceBacked(service: service)
    }
    return try await amDevice.withServiceConnection(service, body)
  }

  /// Starts a service whose connection outlives this call, handing ownership to the caller, who
  /// hands it back to `MobileDevice.invalidateServiceConnection`.
  func openServiceConnection(_ service: String) async throws -> LockdownServiceConnection {
    guard let amDevice else {
      throw AMDeviceServiceError.notAMDeviceBacked(service: service)
    }
    return try await amDevice.openServiceConnection(service)
  }

  /// Starts a device link service, invalidating the connection once `body` returns or throws.
  func withDeviceLinkClient<T>(
    _ service: String,
    _ body: (DeviceLinkClient) async throws -> T
  ) async throws -> T {
    guard let amDevice else {
      throw AMDeviceServiceError.notAMDeviceBacked(service: service)
    }
    return try await amDevice.withDeviceLinkClient(service, body)
  }

  /// Starts a service and wraps it in an AFC client, tearing both down once `body` returns or
  /// throws.
  func withAFCConnection<T>(
    _ service: String,
    calls afcCalls: AFCCalls = FileConduit.defaultCalls,
    _ body: (FileConduit) async throws -> T
  ) async throws -> T {
    guard let amDevice else {
      throw AMDeviceServiceError.notAMDeviceBacked(service: service)
    }
    return try await amDevice.withAFCConnection(service, calls: afcCalls, body)
  }
}

extension Device: VideoTarget {

  public var videoRecording: DeviceVideoRecordingCommands {
    commandCache.resolve { DeviceVideoRecordingCommands(device: self) }
  }

  public var videoStream: DeviceVideoStreamCommands {
    DeviceVideoStreamCommands(device: self)
  }
}
