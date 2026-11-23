/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

public enum SimulatorDeviceSetError: Error, LocalizedError {
  case simDeviceSetUnavailable
  case defaultPathUnavailable

  public var errorDescription: String? {
    switch self {
    case .simDeviceSetUnavailable:
      return "SimDeviceSet is not present after loading CoreSimulator"
    case .defaultPathUnavailable:
      return "SimDeviceSet did not provide a default device set path"
    }
  }
}

public struct SimulatorControlConfiguration: Equatable, Hashable, CustomStringConvertible {

  public let deviceSetPath: String?
  public let logger: any ControlCoreLogger
  public let hidEventLogging: SimulatorHIDEventLogging
  public let accessibilityTiming: SimulatorAccessibilityTiming

  /// - Parameter logger: nil means `ControlCoreGlobalConfiguration.defaultLogger` (os_log-only
  ///   by default — see its documentation).
  /// - Parameter hidEventLogging: how much of each HID event the set's simulators log.
  /// - Parameter accessibilityTiming: how long the set's simulators' accessibility reads may take, unless a
  ///   read asks for its own.
  public init(
    deviceSetPath: String?, logger: (any ControlCoreLogger)?, hidEventLogging: SimulatorHIDEventLogging = .redacted,
    accessibilityTiming: SimulatorAccessibilityTiming = .default
  ) {
    self.deviceSetPath = deviceSetPath
    self.logger = logger ?? ControlCoreGlobalConfiguration.defaultLogger
    self.hidEventLogging = hidEventLogging
    self.accessibilityTiming = accessibilityTiming
  }

  // MARK: - Equatable, Hashable

  /// Identity is the device set path alone; the logger and logging level are dependencies, not data.
  public static func == (lhs: SimulatorControlConfiguration, rhs: SimulatorControlConfiguration) -> Bool {
    lhs.deviceSetPath == rhs.deviceSetPath
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(deviceSetPath)
  }

  public var description: String {
    "Pool Config | Set Path \(deviceSetPath ?? "(null)")"
  }

  /// The default CoreSimulator device-set path. Loads the private frameworks on demand and throws
  /// when they cannot be loaded or the path cannot be resolved.
  public static func defaultDeviceSetPath() throws -> String {
    try SimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(nil)
    guard let deviceSetClass = unsafe objc_lookUpClass("SimDeviceSet") else {
      throw SimulatorDeviceSetError.simDeviceSetUnavailable
    }
    let cls = deviceSetClass as AnyObject
    if let result = unsafe cls.perform(NSSelectorFromString("defaultSetPath"))?.takeUnretainedValue() as? String {
      return result
    }
    guard
      let defaultSet = unsafe cls.perform(NSSelectorFromString("defaultSet"))?.takeUnretainedValue(),
      let setPath = unsafe (defaultSet as AnyObject).perform(NSSelectorFromString("setPath"))?.takeUnretainedValue() as? String
    else {
      throw SimulatorDeviceSetError.defaultPathUnavailable
    }
    return setPath
  }
}
