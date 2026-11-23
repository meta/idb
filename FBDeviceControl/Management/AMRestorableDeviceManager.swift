/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import MobileDeviceAPI

// @safe: Retains the device in `init` and releases it in `deinit`; callers only see the object.
@safe private final class RestorableDeviceNotificationPayload {
  private let reference: Unmanaged<AnyObject>
  let status: AMRestorableDeviceNotificationType
  let identifier: String
  let state: RestorableDeviceNotificationState
  let values: [String: Any]

  var device: AMRestorableDevice {
    unsafe reference.takeUnretainedValue()
  }

  init(device: AMRestorableDevice, status: AMRestorableDeviceNotificationType, calls: AMDCalls) {
    unsafe self.reference = unsafe Unmanaged.passRetained(device as AnyObject)
    self.status = status
    let ecid = calls.RestorableDeviceGetECID(device)
    self.identifier = String(ecid)
    self.state = unsafe RestorableDeviceNotificationState(
      state: RestorableDevice.targetState(forRawValue: calls.RestorableDeviceGetState(device)),
      recoveryDevice: calls.RestorableDeviceGetRecoveryModeDevice(device)?.takeUnretainedValue())
    if status == .connected {
      self.values = unsafe [
        DeviceKey.chipID.rawValue: Int(calls.RestorableDeviceGetChipID(device)),
        DeviceKey.deviceClass.rawValue: Int(calls.RestorableDeviceGetDeviceClass(device)),
        DeviceKey.locationID.rawValue: Int(calls.RestorableDeviceGetLocationID(device)),
        DeviceKey.serialNumber.rawValue: calls.RestorableDeviceCopySerialNumber(device)?.takeRetainedValue() as String? ?? NSNull(),
        DeviceKey.deviceName.rawValue: calls.RestorableDeviceCopyUserFriendlyName(device)?.takeRetainedValue() as String? ?? NSNull(),
        DeviceKey.productType.rawValue: calls.RestorableDeviceCopyProductString(device)?.takeRetainedValue() as String? ?? NSNull(),
        DeviceKey.uniqueChipID.rawValue: NSNumber(value: ecid),
      ]
    } else {
      self.values = [:]
    }
  }

  deinit {
    unsafe reference.release()
  }
}

private func notificationTypeDescription(_ status: AMRestorableDeviceNotificationType) -> String {
  switch status {
  case .connected:
    return "connected"
  case .disconnected:
    return "disconnected"
  @unknown default:
    return "unknown"
  }
}

/// The C callback MobileDevice delivers restorable device notifications to.
///
/// A C function cannot capture, so the manager travels as the context pointer that
/// `startListening` registers. It is bridged back unretained: the registration holds the only
/// retain, and gives it back when it is torn down.
private func restorableDeviceListenerCallback(
  _ device: AMRestorableDevice?,
  _ status: AMRestorableDeviceNotificationType,
  _ context: UnsafeMutableRawPointer?
) {
  guard let device, let context = unsafe context else {
    return
  }
  let manager = unsafe Unmanaged<AMRestorableDeviceManager>.fromOpaque(context).takeUnretainedValue()
  let payload = manager.captureNotification(device: device, status: status)
  manager.notifications.enqueue {
    manager.handleNotification(payload)
  }
}

/// Obtains `RestorableDevice` instances.
// @safe: The notification context is created at registration and released at unregistration, only here.
@safe final class AMRestorableDeviceManager: DeviceManager<RestorableDevice> {

  private let calls: AMDCalls
  private let workQueue: DispatchQueue
  private let asyncQueue: DispatchQueue
  private let ecidFilter: String?
  private var registrationID: Int32 = 0
  private var notificationContext: UnsafeMutableRawPointer?

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

  // MARK: - Notifications

  fileprivate func captureNotification(
    device: AMRestorableDevice, status: AMRestorableDeviceNotificationType
  ) -> RestorableDeviceNotificationPayload {
    RestorableDeviceNotificationPayload(device: device, status: status, calls: calls)
  }

  fileprivate func handleNotification(_ payload: RestorableDeviceNotificationPayload) {
    let device = payload.device
    let identifier = payload.identifier
    logger.log(
      "\(device) \(notificationTypeDescription(payload.status)) in state \(payload.state.state.stateString.rawValue)")

    if let ecidFilter, identifier != ecidFilter {
      logger.log("Ignoring \(device) as it does not match filter of \(ecidFilter)")
      return
    }

    switch payload.status {
    case .connected:
      logger.log("Caching restorable device values \(payload.values)")
      deviceConnected(device, identifier: identifier, info: payload.values) { restorableDevice in
        restorableDevice.allValues = payload.values
        restorableDevice.notificationState = payload.state
      }
    case .disconnected:
      deviceDisconnected(device, identifier: identifier)
    @unknown default:
      logger.log("Unknown Restorable Notification \(payload.status.rawValue)")
    }
  }

  // MARK: - Abstract Implementation

  override func startListening() throws {
    guard registrationID == 0 else {
      throw AMRestorableDeviceManagerError.alreadyRegistered
    }
    // Retained for as long as the registration lasts: the callback bridges this back unretained, so
    // the manager must not be deallocated while MobileDevice can still deliver a notification.
    // Balanced in `stopListening`, and below if the registration itself fails.
    let context = unsafe Unmanaged.passRetained(self).toOpaque()
    notifications.resume()
    let registrationID = unsafe calls.RestorableDeviceRegisterForNotifications(
      restorableDeviceListenerCallback,
      context,
      0,
      0)
    guard registrationID >= 1 else {
      notifications.pause()
      unsafe Unmanaged<AMRestorableDeviceManager>.fromOpaque(context).release()
      throw AMRestorableDeviceManagerError.registrationFailed(status: registrationID)
    }
    self.registrationID = registrationID
    unsafe self.notificationContext = unsafe context
  }

  override func stopListening() throws {
    notifications.pause()
    let registrationID = self.registrationID
    self.registrationID = 0
    guard registrationID >= 1 else {
      throw AMRestorableDeviceManagerError.notRegistered
    }

    // The return of AMRestorableDeviceUnregisterForNotifications seems to be some random number.
    // However, giving an invalid registrationID is fine and we still get logging.
    _ = calls.RestorableDeviceUnregisterForNotifications(registrationID)
    // No further notification can be delivered, so the callback's context can be given back.
    if let context = unsafe notificationContext {
      unsafe notificationContext = nil
      unsafe Unmanaged<AMRestorableDeviceManager>.fromOpaque(context).release()
    }
  }

  override func constructPublic(
    _ privateDevice: CFTypeRef,
    identifier: String,
    info: [String: Any]?
  ) -> RestorableDevice {
    RestorableDevice(
      calls: calls,
      restorableDevice: privateDevice,
      allValues: info ?? [:],
      work: workQueue,
      asyncQueue: asyncQueue,
      logger: logger.withName(identifier))
  }

  override class func updatePublicReference(
    _ publicDevice: RestorableDevice,
    privateDevice: CFTypeRef,
    identifier: String,
    info: [String: Any]?
  ) {
    publicDevice.restorableDevice = privateDevice
    publicDevice.allValues = info ?? [:]
  }

  override class func extractPrivateReference(_ publicDevice: RestorableDevice) -> Unmanaged<AnyObject>? {
    unsafe Unmanaged.passUnretained(publicDevice.restorableDevice)
  }

}

public enum AMRestorableDeviceManagerError: Error, LocalizedError {
  case alreadyRegistered
  case registrationFailed(status: Int32)
  case notRegistered

  public var errorDescription: String? {
    switch self {
    case .alreadyRegistered:
      return "Already registered for restorable device notifications"
    case let .registrationFailed(status):
      return "AMRestorableDeviceRegisterForNotifications failed with \(status)"
    case .notRegistered:
      return "Cannot unregister from AMRestorableDevice notifications, no subscription"
    }
  }
}
