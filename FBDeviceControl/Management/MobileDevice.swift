/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import MobileDeviceAPI

private let UnknownValue = "unknown"

/// The OS name a device class implies, where it implies one.
private let DeviceClassOSPrefixes = [
  "iPhone": "iOS",
  "iPad": "iOS",
]

/// An Object Wrapper around AMDeviceRef.
public final class MobileDevice: TargetInfo, DeviceCommands, CustomStringConvertible {

  // MARK: - Properties

  public let calls: AMDCalls
  public var allValues: [String: Any] {
    didSet { notificationViewStorage = nil }
  }
  private let connectionReuseTimeout: TimeInterval?
  private let serviceReuseTimeout: TimeInterval?
  private var notificationViewStorage: MobileDevice?
  public let workQueue: DispatchQueue
  public let asyncQueue: DispatchQueue
  public let logger: any ControlCoreLogger
  // Created eagerly at the end of the initializer: both are constructed with this object, so they
  // cannot be `let` properties, and `lazy` would make first access from two threads a race. The
  // storage is populated before the object is shared, which is what makes the unsynchronised
  // accessors safe.
  private var sessionStorage: AMDeviceSession?
  private var serviceManagerStorage: AMDeviceServiceManager?

  var session: AMDeviceSession {
    guard let sessionStorage else {
      preconditionFailure("The session is created in the initializer")
    }
    return sessionStorage
  }

  var serviceManager: AMDeviceServiceManager {
    guard let serviceManagerStorage else {
      preconditionFailure("The service manager is created in the initializer")
    }
    return serviceManagerStorage
  }

  /// Ownership runs through the AMDevice call table rather than ARC, so the setter takes a
  /// reference on the incoming device and drops the one it replaces.
  private var amDeviceReference: AMDevice?

  public var amDeviceRef: AMDevice? {
    get {
      amDeviceReference
    }
    set {
      notificationViewStorage = nil
      let old = amDeviceReference
      amDeviceReference = newValue
      if let newValue {
        calls.Retain(newValue)
      }
      if let old {
        calls.Release(old)
      }
    }
  }

  public var amDevice: AMDevice? {
    amDeviceReference
  }

  // MARK: - Initializers

  public init(
    allValues: [String: Any],
    calls: AMDCalls,
    connectionReuseTimeout: TimeInterval?,
    serviceReuseTimeout: TimeInterval?,
    work workQueue: DispatchQueue,
    asyncQueue: DispatchQueue,
    logger: any ControlCoreLogger
  ) {
    self.connectionReuseTimeout = connectionReuseTimeout
    self.serviceReuseTimeout = serviceReuseTimeout
    self.allValues = allValues
    self.calls = calls
    self.workQueue = workQueue
    self.asyncQueue = asyncQueue
    let udid = allValues[DeviceKey.uniqueDeviceID.rawValue] as? String ?? UnknownValue
    self.logger = logger.withName(udid)
    // The un-named logger: only this object's own logger is decorated with the udid.
    self.sessionStorage = AMDeviceSession(
      device: self, reuseTimeout: connectionReuseTimeout, logger: logger)
    self.serviceManagerStorage = AMDeviceServiceManager(
      device: self, serviceTimeout: serviceReuseTimeout)
  }

  deinit {
    if let amDeviceReference { calls.Release(amDeviceReference) }
  }

  /// A connection view whose values and owned native reference remain paired.
  /// Reuses session and service pools until the manager replaces this connection or its values.
  func notificationView() -> MobileDevice {
    if let notificationViewStorage { return notificationViewStorage }
    let view = MobileDevice(
      allValues: allValues, calls: calls,
      connectionReuseTimeout: connectionReuseTimeout, serviceReuseTimeout: serviceReuseTimeout,
      work: workQueue, asyncQueue: asyncQueue, logger: logger)
    view.amDeviceRef = amDeviceRef
    notificationViewStorage = view
    return view
  }

  // MARK: - TargetInfo

  public var uniqueIdentifier: String {
    // The chip identifier arrives as a number on some devices and a string on others.
    let value = allValues[DeviceKey.uniqueChipID.rawValue]
    if let number = value as? NSNumber {
      return number.stringValue
    }
    if let string = value as? String {
      return string
    }
    return UnknownValue
  }

  public var udid: String {
    allValues[DeviceKey.uniqueDeviceID.rawValue] as? String ?? UnknownValue
  }

  public var name: String {
    allValues[DeviceKey.deviceName.rawValue] as? String ?? UnknownValue
  }

  public var architectures: [Architecture] {
    guard let architecture = allValues[DeviceKey.cpuArchitecture.rawValue] as? String else {
      return []
    }
    // CPUArchitecture can name a CPU subtype variant as `<arch>.<variant>` (`arm64e.x1`), which runs `<arch>` code.
    return [Architecture(rawValue: String(architecture.prefix { $0 != "." }))]
  }

  public var deviceType: DeviceType {
    let productType = allValues[DeviceKey.productType.rawValue] as? String ?? UnknownValue
    let family: ProductFamily
    switch allValues[DeviceKey.deviceClass.rawValue] as? String {
    case "iPhone", "iPod": family = .iPhone
    case "iPad": family = .iPad
    case "AppleTV": family = .appleTV
    case "Watch": family = .appleWatch
    case "Mac": family = .mac
    default: family = .unknown
    }
    return DeviceType(model: DeviceModel(rawValue: legacyDeviceNames[productType] ?? productType), family: family)
  }

  public var osVersion: OSVersion {
    let name = Self.osVersionName(
      deviceClass: allValues[DeviceKey.deviceClass.rawValue] as? String,
      productVersion: productVersion)
    return OSVersion(name: OSVersionName(rawValue: name), versionString: productVersion ?? "")
  }

  public var state: TargetState {
    .booted
  }

  public var targetType: TargetType {
    .device
  }

  public var extendedInformation: [String: Any] {
    ["device": CollectionOperations.recursiveFilteredJSONSerializableRepresentation(of: allValues)]
  }

  // MARK: - DeviceProtocol

  public var buildVersion: String? {
    allValues[DeviceKey.buildVersion.rawValue] as? String
  }

  public var productVersion: String? {
    allValues[DeviceKey.productVersion.rawValue] as? String
  }

  public var recoveryModeDeviceRef: AMRecoveryModeDevice? {
    nil
  }

  public var activationState: String {
    guard let activationState = allValues[DeviceKey.activationState.rawValue] as? String else {
      return DeviceActivationState.unknown.rawValue
    }
    return DeviceActivationState(coercing: activationState).rawValue
  }

  // MARK: - DeviceCommands

  public func withConnectedDevice<T>(
    purpose: String,
    _ body: (any DeviceCommands) async throws -> T
  ) async throws -> T {
    logger.log("Taking the device into use for \(purpose)")
    try await session.acquire()
    defer { session.release() }
    return try await body(self)
  }

  /// The AMDevice session is held only while `body` runs; the AFC connection outlives it, pooled
  /// for the device's service reuse timeout so a following operation on the same bundle re-uses it.
  public func withHouseArrestAFCConnection<T>(
    forBundleID bundleID: String,
    afcCalls: AFCCalls,
    _ body: (FileConduit) async throws -> T
  ) async throws -> T {
    try await withConnectedDevice(purpose: "house_arrest") { _ in
      let service = self.serviceManager.houseArrestService(forBundleID: bundleID, afcCalls: afcCalls)
      let connection = try await service.acquire()
      defer { service.release() }
      return try await body(connection)
    }
  }

  public var description: String {
    "AMDevice \(udid) | \(name)"
  }

  private static func osVersionName(deviceClass: String?, productVersion: String?) -> String {
    guard let productVersion else {
      return UnknownValue
    }
    guard let deviceClass, let osPrefix = DeviceClassOSPrefixes[deviceClass] else {
      return productVersion
    }
    return "\(osPrefix) \(productVersion)"
  }
}

extension MobileDevice {

  /// Starts a service on the device, invalidating the connection once `body` returns or throws.
  ///
  /// Two lifetimes are in play and they are not the same: the AMDevice *session* is released as
  /// soon as the service has started, while the service *connection* is invalidated when `body`
  /// is done. A session times out after 60 seconds, so holding one open for the duration of a
  /// long-running service fails the next operation on the device.
  func withServiceConnection<T>(
    _ service: String,
    _ body: (LockdownServiceConnection) async throws -> T
  ) async throws -> T {
    let connection = try await openServiceConnection(service)
    do {
      let result = try await body(connection)
      await Self.invalidateServiceConnection(connection, service: service, logger: logger)
      return result
    } catch {
      await Self.invalidateServiceConnection(connection, service: service, logger: logger)
      throw error
    }
  }

  /// Starts a device link service, invalidating the connection once `body` returns or throws.
  ///
  /// The device link handshake is performed before `body` runs, so the client it receives is ready
  /// to process messages.
  func withDeviceLinkClient<T>(
    _ service: String,
    _ body: (DeviceLinkClient) async throws -> T
  ) async throws -> T {
    try await withServiceConnection(service) { connection in
      let client = try await DeviceLinkClient(connection: connection)
      return try await body(client)
    }
  }

  /// Starts a service and wraps it in an AFC client, tearing both down once `body` returns or
  /// throws.
  ///
  /// The AFC connection is closed before the service connection beneath it is invalidated, so the
  /// two are released innermost first.
  func withAFCConnection<T>(
    _ service: String,
    calls afcCalls: AFCCalls = FileConduit.defaultCalls,
    _ body: (FileConduit) async throws -> T
  ) async throws -> T {
    let logger = self.logger
    return try await withServiceConnection(service) { connection in
      let afc = try FileConduit.afc(from: connection, calls: afcCalls, logger: logger)
      defer { try? afc.close() }
      return try await body(afc)
    }
  }

  /// Starts a service whose connection outlives this call, handing ownership to the caller, who
  /// hands it back to `invalidateServiceConnection`. `withServiceConnection` covers a connection
  /// whose lifetime fits inside a call.
  func openServiceConnection(_ service: String) async throws -> LockdownServiceConnection {
    let calls = self.calls
    let logger = self.logger
    return try await withConnectedDevice(purpose: "start_service_\(service)") { device in
      try Self.startService(service, on: device, calls: calls, logger: logger)
    }
  }

  /// Invalidates a connection handed out by `openServiceConnection`.
  static func invalidateServiceConnection(
    _ connection: LockdownServiceConnection?,
    service: String,
    logger: any ControlCoreLogger
  ) async {
    guard let connection else {
      return
    }
    logger.log("Invalidating service \(service)")
    do {
      try await connection.invalidate()
      logger.log("Invalidated service \(service)")
    } catch {
      logger.log("Failed to invalidate service \(service) with error \(error)")
    }
  }

  private static func startService(
    _ service: String,
    on connectedDevice: any DeviceCommands,
    calls: AMDCalls,
    logger: any ControlCoreLogger
  ) throws -> LockdownServiceConnection {
    logger.log("Starting service \(service)")
    let userInfo: [String: Any] = ["CloseOnInvalidate": 1, "InvalidateOnDetach": 1]
    var serviceConnection: Unmanaged<CFTypeRef>?
    let status =
      unsafe calls.SecureStartService?(
        connectedDevice.amDeviceRef,
        service as CFString,
        userInfo as CFDictionary,
        &serviceConnection
      ) ?? -1
    guard status == 0 else {
      let message = unsafe calls.CopyErrorText?(status)?.takeRetainedValue() as String? ?? "Unknown error"
      throw AMDeviceServiceError.secureStartServiceFailed(service: service, status: status, message: message)
    }
    guard let amDeviceRef = connectedDevice.amDeviceRef, let serviceConnection = unsafe serviceConnection else {
      throw AMDeviceServiceError.deviceNotConnected(service: service)
    }
    // Unretained: the raw reference is handed straight to the connection, which owns it from here.
    let connection = unsafe LockdownServiceConnection(
      name: service,
      connection: serviceConnection.takeUnretainedValue(),
      device: amDeviceRef,
      calls: calls,
      logger: logger)
    logger.log("Service \(service) started")
    return connection
  }

}
