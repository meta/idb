/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import MobileDeviceAPI

public enum DeviceRecoveryError: Error {
  case callUnavailable(function: String)
  case enterRecoveryFailed(message: String)
  case notInRecovery(deviceDescription: String)
  case autoBootFailed(recoveryDevice: String, message: String)
  case exitRecoveryFailed(recoveryDevice: String, message: String)
}

extension DeviceRecoveryError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .callUnavailable(function):
      return "\(function) function not available"
    case let .enterRecoveryFailed(message):
      return "Failed have device enter recovery \(message)"
    case let .notInRecovery(deviceDescription):
      return "Device \(deviceDescription) is not in recovery mode"
    case let .autoBootFailed(recoveryDevice, message):
      return "Failed to set autoboot for recovery device \(recoveryDevice) \(message)"
    case let .exitRecoveryFailed(recoveryDevice, message):
      return "Failed have device \(recoveryDevice) exit recovery \(message)"
    }
  }
}

public struct DeviceRecoveryCommands {
  let device: Device

  public init(device: Device) {
    self.device = device
  }

  // MARK: - Recovery

  public func enter() async throws {
    try await device.withConnectedDevice(purpose: "enter_recovery") { connectedDevice in
      guard let enterRecoveryFunc = connectedDevice.calls.EnterRecovery else {
        throw DeviceRecoveryError.callUnavailable(function: "EnterRecovery")
      }
      let status = enterRecoveryFunc(connectedDevice.amDeviceRef)
      if status != 0 {
        throw DeviceRecoveryError.enterRecoveryFailed(message: Self.errorMessage(for: status, calls: connectedDevice.calls))
      }
    }
  }

  public func exit() async throws {
    guard let recoveryDevice = device.recoveryModeDeviceRef else {
      throw DeviceRecoveryError.notInRecovery(deviceDescription: String(describing: device))
    }
    guard let setAutoBootFunc = device.calls.RecoveryModeDeviceSetAutoBoot else {
      throw DeviceRecoveryError.callUnavailable(function: "RecoveryModeDeviceSetAutoBoot")
    }
    var status = setAutoBootFunc(recoveryDevice, 1)
    if status != 0 {
      throw DeviceRecoveryError.autoBootFailed(recoveryDevice: String(describing: recoveryDevice), message: Self.errorMessage(for: status, calls: device.calls))
    }
    guard let rebootFunc = device.calls.RecoveryDeviceReboot else {
      throw DeviceRecoveryError.callUnavailable(function: "RecoveryDeviceReboot")
    }
    status = rebootFunc(recoveryDevice)
    if status != 0 {
      throw DeviceRecoveryError.exitRecoveryFailed(recoveryDevice: String(describing: recoveryDevice), message: Self.errorMessage(for: status, calls: device.calls))
    }
  }

  private static func errorMessage(for status: Int32, calls: AMDCalls) -> String {
    if let copyErrorTextFunc = unsafe calls.CopyErrorText {
      return unsafe copyErrorTextFunc(status)?.takeRetainedValue() as String? ?? "Unknown error"
    }
    return "Unknown error"
  }
}
