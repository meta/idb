/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import MobileDeviceAPI

/// The Activation State of the device.
public enum DeviceActivationState: String, Sendable, CaseIterable {
  case unknown = "Unknown"
  case unactivated = "Unactivated"
  case activated = "Activated"

  /// The canonical activation state for whatever the device reported.
  init(coercing activationState: String) {
    self = DeviceActivationState(rawValue: activationState) ?? .unknown
  }
}

/// Keys of the device information dictionaries MobileDevice populates.
public enum DeviceKey: String, Sendable, CaseIterable {
  case chipID = "ChipID"
  case deviceClass = "DeviceClass"
  case deviceName = "DeviceName"
  case locationID = "LocationID"
  case productType = "ProductType"
  case serialNumber = "SerialNumber"
  case uniqueChipID = "UniqueChipID"
  case uniqueDeviceID = "UniqueDeviceID"
  case cpuArchitecture = "CPUArchitecture"
  case buildVersion = "BuildVersion"
  case productVersion = "ProductVersion"
  case activationState = "ActivationState"
  case isPaired = "IsPaired"
}

/// Defines properties that are required on classes related to the implementation of Device.
public protocol DeviceProtocol: AnyObject {

  /// The AMDevice Calls to use.
  var calls: AMDCalls { get }

  /// The underlying AMDeviceRef. This may be nil.
  var amDeviceRef: AMDevice? { get }

  /// The underlying AMRecoveryModeDeviceRef if in recovery. This may be nil.
  var recoveryModeDeviceRef: AMRecoveryModeDevice? { get }

  /// The Device's Logger.
  var logger: any ControlCoreLogger { get }

  /// The Device's 'Product Version'.
  var productVersion: String? { get }

  /// The Device's 'Build Version'.
  var buildVersion: String? { get }

  /// The Device's 'Activation State'.
  var activationState: String { get }

  /// All of the Device Values available.
  var allValues: [String: Any] { get }
}

/// Defines Device-Specific commands, off which others are based.
public protocol DeviceCommands: DeviceProtocol {

  /// Connects for the duration of `body`, handing it the connected device.
  ///
  /// The device is connected and a session opened on it before `body` runs, and released once
  /// `body` returns or throws. Scopes nest and overlap, so the users of a device's session are
  /// counted: overlapping scopes share one session and only the last to end closes it.
  func withConnectedDevice<T>(
    purpose: String,
    _ body: (any DeviceCommands) async throws -> T
  ) async throws -> T

  /// Starts house arrest for a given bundle id, handing its AFC connection to `body`.
  func withHouseArrestAFCConnection<T>(
    forBundleID bundleID: String,
    afcCalls: AFCCalls,
    _ body: (FileConduit) async throws -> T
  ) async throws -> T
}
