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

struct RestorableDeviceNotificationState {
  let state: TargetState
  let recoveryDevice: AMRecoveryModeDevice?
}

/// An Object Wrapper around AMRestorableDevice.
// @safe: The device reference is balanced on replacement and in `deinit`; callers only see the object.
@safe public final class RestorableDevice: TargetInfo, DeviceProtocol {

  public let calls: AMDCalls
  public var allValues: [String: Any]
  var notificationState: RestorableDeviceNotificationState?
  public let workQueue: DispatchQueue
  public let asyncQueue: DispatchQueue
  public let logger: any ControlCoreLogger

  /// Owns a +1 reference: retained on assignment, released on replacement and in `deinit`.
  private var restorableDeviceRef: Unmanaged<AnyObject>

  var restorableDevice: AMRestorableDevice {
    get {
      unsafe restorableDeviceRef.takeUnretainedValue()
    }
    set {
      let replacement = unsafe Unmanaged.passRetained(newValue as AnyObject)
      unsafe restorableDeviceRef.release()
      unsafe restorableDeviceRef = unsafe replacement
    }
  }

  public init(
    calls: AMDCalls,
    restorableDevice: AMRestorableDevice,
    allValues: [String: Any],
    work workQueue: DispatchQueue,
    asyncQueue: DispatchQueue,
    logger: any ControlCoreLogger
  ) {
    self.calls = calls
    unsafe self.restorableDeviceRef = unsafe Unmanaged.passRetained(restorableDevice as AnyObject)
    self.allValues = allValues
    self.workQueue = workQueue
    self.asyncQueue = asyncQueue
    self.logger = logger
  }

  deinit {
    unsafe restorableDeviceRef.release()
  }

  /// An owned reference with the values, state and recovery handle captured for this notification.
  func notificationView() -> RestorableDevice {
    let view = RestorableDevice(
      calls: calls, restorableDevice: restorableDevice, allValues: allValues,
      work: workQueue, asyncQueue: asyncQueue, logger: logger)
    view.notificationState =
      notificationState
      ?? RestorableDeviceNotificationState(
        state: state, recoveryDevice: recoveryModeDeviceRef)
    return view
  }

  // MARK: - TargetInfo

  // Restore info dictionaries are populated by MobileDevice and may omit keys or carry
  // unexpectedly-typed values; these accessors feed Swift's nonnull String bridging, so anything
  // unexpected must degrade to the unknown value rather than trap.

  public var uniqueIdentifier: String {
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
    UnknownValue
  }

  public var name: String {
    allValues[DeviceKey.deviceName.rawValue] as? String ?? UnknownValue
  }

  public var state: TargetState {
    notificationState?.state ?? Self.targetState(forRawValue: calls.RestorableDeviceGetState(restorableDevice))
  }

  public var deviceType: DeviceType {
    let productString = allValues[DeviceKey.productType.rawValue] as? String ?? UnknownValue
    return DeviceType.generic(withName: productString)
  }

  public var architectures: [Architecture] {
    [Architecture(rawValue: UnknownValue)]
  }

  public var targetType: TargetType {
    .device
  }

  public var osVersion: OSVersion {
    OSVersion.generic(withName: UnknownValue)
  }

  public var extendedInformation: [String: Any] {
    ["device": allValues]
  }

  // MARK: - DeviceProtocol

  public var buildVersion: String? {
    UnknownValue
  }

  public var productVersion: String? {
    UnknownValue
  }

  public var amDeviceRef: AMDevice? {
    nil
  }

  public var recoveryModeDeviceRef: AMRecoveryModeDevice? {
    if let notificationState { return notificationState.recoveryDevice }
    return unsafe calls.RestorableDeviceGetRecoveryModeDevice(restorableDevice)?.takeUnretainedValue()
  }

  public var activationState: String {
    DeviceActivationState.unknown.rawValue
  }

  /// `AMRestorableGetStringForState` is private, and the mapping is simple enough to restate.
  public static func targetState(for state: AMRestorableDeviceState) -> TargetState {
    targetState(forRawValue: state.rawValue)
  }

  static func targetState(forRawValue rawValue: Int32) -> TargetState {
    switch rawValue {
    case AMRestorableDeviceState.DFU.rawValue:
      return .DFU
    case AMRestorableDeviceState.recovery.rawValue:
      return .recovery
    case AMRestorableDeviceState.restoreOS.rawValue:
      return .restoreOS
    case AMRestorableDeviceState.bootedOS.rawValue:
      return .booted
    default:
      return .unknown
    }
  }
}
