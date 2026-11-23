/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import MobileDeviceAPI

private let mobileBackupDomain = "com.apple.mobile.backup"
private let serviceReuseTimeout: TimeInterval = 6.0

// @safe: Releases the reference in `deinit` exactly when `init` retained it; callers only see the object.
@safe private final class AMDeviceNotificationPayload {
  let reference: Unmanaged<AnyObject>
  let status: AMDeviceNotificationType
  private let calls: AMDCalls

  var ownsReference: Bool {
    status == .connected || status == .paired
  }

  init(reference: Unmanaged<AnyObject>, status: AMDeviceNotificationType, calls: AMDCalls) {
    unsafe self.reference = unsafe reference
    self.status = status
    self.calls = calls
    if ownsReference {
      unsafe calls.Retain(reference.takeUnretainedValue())
    }
  }

  deinit {
    if ownsReference {
      unsafe calls.Release(reference.takeUnretainedValue())
    }
  }
}

/// Brings a newly-seen device far enough up to read its values, then registers it.
///
/// Pairing is allowed to fail: an unpaired device still yields the default domain, so it is
/// reported with degraded information rather than dropped.
private func amDeviceConnected(_ device: AMDevice, manager: AMDeviceManager) {
  let logger = manager.logger
  let calls = manager.calls

  do {
    try AMDeviceUsage.startConnection(to: device, calls: calls, logger: logger)
  } catch {
    logger.error().log("Cannot connect to device, ignoring device \(error)")
    return
  }

  // Erased to `AnyObject` because the call table under-declares `CopyValue` as returning
  // `CFStringRef` while MobileDevice returns whatever CF type the key holds. The ECID comes back
  // as a number on some devices and a string on others, so accepting only one silently drops the
  // devices reporting the other.
  let rawChipID = unsafe calls.CopyValue(device, nil, DeviceKey.uniqueChipID.rawValue as CFString)?.takeRetainedValue() as AnyObject?
  guard let uniqueChipID = (rawChipID as? NSNumber)?.stringValue ?? (rawChipID as? String) else {
    AMDeviceUsage.stopConnection(to: device, calls: calls, logger: logger)
    logger.error().log("Ignoring device as cannot obtain ECID for it")
    return
  }

  if let ecidFilter = manager.ecidFilter, uniqueChipID != ecidFilter {
    AMDeviceUsage.stopConnection(to: device, calls: calls, logger: logger)
    logger.error().log("Ignoring device as ECID \(uniqueChipID) does not match filter \(ecidFilter)")
    return
  }

  var pairedWithSession = true
  do {
    try AMDeviceUsage.startSessionByPairing(with: device, calls: calls, logger: logger)
  } catch {
    pairedWithSession = false
    logger.log("Device is not paired, degraded device information will be provided \(error)")
  }

  let info = AMDeviceUsage.obtainDeviceValues(device, calls: calls)

  if pairedWithSession {
    AMDeviceUsage.stopSession(with: device, calls: calls, logger: logger)
  }
  AMDeviceUsage.stopConnection(to: device, calls: calls, logger: logger)

  guard let info else {
    logger.error().log("Ignoring device as no values were returned for it")
    return
  }
  guard info[DeviceKey.uniqueDeviceID.rawValue] != nil else {
    logger.error().log("Ignoring device as \(DeviceKey.uniqueDeviceID.rawValue) is not present in \(info)")
    return
  }
  logger.debug().log("Obtained Device Values \(info)")
  manager.deviceConnected(device, identifier: uniqueChipID, info: info)
}

/// The C callback MobileDevice delivers device notifications to.
///
/// A C function cannot capture, so the manager travels as the context pointer registered with the
/// subscription and is bridged back unretained; the subscription holds the only retain.
private func amDeviceListenerCallback(
  _ notification: UnsafeMutablePointer<AMDeviceNotification>?,
  _ context: UnsafeMutableRawPointer?
) {
  guard let notification = unsafe notification, let context = unsafe context else {
    return
  }
  let manager = unsafe Unmanaged<AMDeviceManager>.fromOpaque(context).takeUnretainedValue()
  let payload = unsafe AMDeviceNotificationPayload(
    reference: notification.pointee.amDevice,
    status: notification.pointee.status,
    calls: manager.calls)
  manager.notifications.enqueue {
    handleAMDeviceNotification(payload, manager: manager)
  }
}

private func handleAMDeviceNotification(_ payload: AMDeviceNotificationPayload, manager: AMDeviceManager) {
  let logger = manager.logger

  switch payload.status {
  case .connected, .paired:
    unsafe amDeviceConnected(payload.reference.takeUnretainedValue(), manager: manager)
  case .disconnected:
    let address = unsafe payload.reference.toOpaque()
    guard let identifier = unsafe manager.identifier(forDeviceAddress: address) else {
      logger.log(unsafe "Cannot obtain identifier for device at \(address)")
      return
    }
    unsafe manager.deviceDisconnected(identifier: identifier, address: address)
  case .unsubscribed:
    logger.log("Unsubscribed from AMDeviceNotificationSubscribe")
  default:
    logger.log("Got Unknown status \(payload.status.rawValue) from AMDeviceNotificationSubscribe")
  }
}

/// Obtains `MobileDevice` instances.
// @safe: The notification subscription is registered and unregistered only here, and never handed out.
@safe final class AMDeviceManager: DeviceManager<MobileDevice> {

  // MARK: - Properties

  internal let calls: AMDCalls
  internal let ecidFilter: String?
  private let workQueue: DispatchQueue
  private let asyncQueue: DispatchQueue
  private var subscription: AMDNotificationSubscription?

  init(
    calls: AMDCalls,
    work workQueue: DispatchQueue,
    asyncQueue: DispatchQueue,
    ecidFilter: String?,
    logger: any ControlCoreLogger
  ) {
    self.calls = calls
    self.workQueue = workQueue
    self.asyncQueue = asyncQueue
    self.ecidFilter = ecidFilter
    super.init(logger: logger)
  }

  // MARK: - DeviceManager Implementation

  override func startListening() throws {
    guard unsafe subscription == nil else {
      throw AMDeviceManagerError.alreadySubscribed
    }

    // Retained for as long as the subscription lasts, so the callback's context stays valid.
    // Tidied up when unsubscribing.
    let context = unsafe Unmanaged.passRetained(self).toOpaque()
    notifications.resume()
    var subscription: AMDNotificationSubscription?
    let result = unsafe calls.NotificationSubscribe(
      amDeviceListenerCallback,
      0,
      0,
      context,
      &subscription)
    guard result == 0 else {
      notifications.pause()
      unsafe Unmanaged<AMDeviceManager>.fromOpaque(context).release()
      throw AMDeviceManagerError.subscribeFailed(status: result)
    }

    unsafe self.subscription = unsafe subscription
  }

  override func stopListening() throws {
    guard let subscription = unsafe subscription else {
      throw AMDeviceManagerError.notSubscribed
    }

    let result = unsafe calls.NotificationUnsubscribe(subscription)
    guard result == 0 else {
      throw AMDeviceManagerError.unsubscribeFailed(status: result)
    }

    notifications.pause()
    // Balances the retain taken in startListening.
    unsafe Unmanaged.passUnretained(self).release()
    unsafe self.subscription = nil
  }

  override func constructPublic(
    _ privateDevice: CFTypeRef,
    identifier: String,
    info: [String: Any]?
  ) -> MobileDevice {
    MobileDevice(
      allValues: info ?? [:],
      calls: calls,
      connectionReuseTimeout: nil,
      serviceReuseTimeout: serviceReuseTimeout,
      work: workQueue,
      asyncQueue: asyncQueue,
      logger: logger)
  }

  override class func updatePublicReference(
    _ publicDevice: MobileDevice,
    privateDevice: CFTypeRef,
    identifier: String,
    info: [String: Any]?
  ) {
    publicDevice.amDeviceRef = privateDevice
    publicDevice.allValues = info ?? [:]
  }

  override class func extractPrivateReference(_ publicDevice: MobileDevice) -> Unmanaged<AnyObject>? {
    guard let reference = publicDevice.amDeviceRef else {
      return nil
    }
    return unsafe Unmanaged.passUnretained(reference as AnyObject)
  }

  // MARK: - Private

  fileprivate func identifier(forDeviceAddress address: UnsafeMutableRawPointer) -> String? {
    // Compared by address: equality on the bridged opaque reference is not reliable.
    for device in storage.referenced.values {
      if let reference = device.amDeviceRef, unsafe Unmanaged.passUnretained(reference as AnyObject).toOpaque() == address {
        return device.uniqueIdentifier
      }
    }
    return nil
  }

}

public enum AMDeviceManagerError: Error, LocalizedError {
  case alreadySubscribed
  case notSubscribed
  case subscribeFailed(status: Int32)
  case unsubscribeFailed(status: Int32)
  case connectFailed(device: String, message: String)
  case notPaired(device: String, message: String)
  case pairingValidationFailed(device: String, message: String)
  case sessionFailed(message: String)

  public var errorDescription: String? {
    switch self {
    case .alreadySubscribed:
      return "An AMDeviceNotification Subscription already exists"
    case .notSubscribed:
      return "An AMDeviceNotification Subscription does not exist"
    case let .subscribeFailed(status):
      return "AMDeviceNotificationSubscribe failed with \(status)"
    case let .unsubscribeFailed(status):
      return "AMDeviceNotificationUnsubscribe failed with \(status)"
    case let .connectFailed(device, message):
      return "Failed to connect to \(device). (\(message))"
    case let .notPaired(device, message):
      return "\(device) is not paired with this host \(message)"
    case let .pairingValidationFailed(device, message):
      return "Failed to validate pairing for \(device). (\(message))"
    case let .sessionFailed(message):
      return "Failed to start session with device. (\(message))"
    }
  }
}
