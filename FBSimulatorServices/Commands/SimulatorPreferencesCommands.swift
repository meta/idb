/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
import FBSimulatorBridgeProtocol
import FBSimulatorControl
@preconcurrency import Foundation

/// Dark/Light mode appearance.
/// Values match UIUserInterfaceStyle used by SimDevice's setUIInterfaceStyle:error:.
public enum SimulatorAppearance: Int, Sendable {
  case light = 1 // UIUserInterfaceStyleLight
  case dark = 2 // UIUserInterfaceStyleDark
}

/// Dynamic Type content size categories.
/// Values match the integer indices used by SimDevice's setContentSizeCategory:error:.
public enum SimulatorContentSizeCategory: Int, Sendable {
  case extraSmall = 1
  case small = 2
  case medium = 3
  case large = 4
  case extraLarge = 5
  case extraExtraLarge = 6
  case extraExtraExtraLarge = 7
  case accessibilityMedium = 8
  case accessibilityLarge = 9
  case accessibilityExtraLarge = 10
  case accessibilityExtraExtraLarge = 11
  case accessibilityExtraExtraExtraLarge = 12
}

enum SimulatorIncreaseContrastMode: Int {
  case disabled = 1
  case enabled = 2
}

private let slowAnimationsNotification = "com.apple.UIKit.SimulatorSlowMotionAnimationState"

public enum SimulatorPreferencesError: Error, LocalizedError {
  case settingNotPreferenceBacked(setting: String)
  case accessibilitySettingsReadbackMismatch(setting: String, expected: Bool, actual: Bool)
  case unexpectedAppearance(Int)
  case unexpectedContentSizeCategory(Int)
  case unexpectedIncreaseContrastMode(Int)

  public var errorDescription: String? {
    switch self {
    case let .settingNotPreferenceBacked(setting):
      return "Setting '\(setting)' is not backed by a preference"
    case let .accessibilitySettingsReadbackMismatch(setting, expected, actual):
      return "The simulator reported \(setting)=\(actual) after \(expected) was requested"
    case let .unexpectedAppearance(appearance):
      return "The simulator returned an unknown appearance value: \(appearance)"
    case let .unexpectedContentSizeCategory(category):
      return "The simulator returned an unknown content size category: \(category)"
    case let .unexpectedIncreaseContrastMode(mode):
      return "The simulator returned an unknown Increase Contrast mode: \(mode)"
    }
  }
}

/// Reads and writes the simulated device's settings, both the curated ones and raw preferences.
public struct SimulatorPreferencesCommands {

  private let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Applying

  public func apply(_ setting: SimulatorSetting) async throws {
    switch setting {
    case let .hardwareKeyboard(enabled):
      try await setHardwareKeyboardEnabled(enabled)
    case let .slowAnimations(enabled):
      try await setSlowAnimationsEnabled(enabled)
    case let .increaseContrast(enabled):
      try await setIncreaseContrastEnabled(enabled)
    case let .reduceMotion(enabled):
      try await setAccessibilitySetting(.reduceMotion, enabled: enabled)
    case let .reduceTransparency(enabled):
      try await setAccessibilitySetting(.reduceTransparency, enabled: enabled)
    case let .buttonShapes(enabled):
      try await setAccessibilitySetting(.buttonShapes, enabled: enabled)
    case let .voiceOver(enabled):
      try await setAccessibilitySetting(.voiceOver, enabled: enabled)
    case let .autoFillPasswords(enabled):
      try await setPreferenceBacked(.autoFillPasswords, value: enabled ? "true" : "false", type: "bool")
    case let .appearance(appearance):
      try await setAppearance(appearance)
    case let .contentSize(category):
      try await setContentSizeCategory(category)
    case let .locale(localeIdentifier):
      try await setPreferenceBacked(.locale, value: localeIdentifier, type: nil)
    }
  }

  public func apply(_ resolution: SimulatorSettingResolution) async throws {
    switch resolution {
    case let .setting(setting):
      try await apply(setting)
    case let .preference(name, value, type, domain):
      try await setPreference(name, value: value, type: type, domain: domain)
    }
  }

  // MARK: - Reading

  public func currentPreference(_ name: String, domain: String?) async throws -> String {
    try await SimulatorDefaults(simulator: simulator)
      .currentPreference(name, domain: domain)
  }

  /// Reads the current value of a curated setting by name, falling back to a raw preference read for
  /// any other name.
  public func currentSettingValue(name: String, domain: String?) async throws -> String {
    guard let key = SimulatorSettingKey(rawValue: name) else {
      return try await currentPreference(name, domain: domain)
    }
    switch key {
    case .autoFillPasswords, .locale:
      guard let backing = key.preferenceBacking else {
        return try await currentPreference(name, domain: domain)
      }
      return try await currentPreference(backing.key, domain: backing.domain)
    case .appearance:
      return (try await currentAppearance()).argumentName ?? "light"
    case .contentSize:
      return (try await currentContentSizeCategory()).argumentName ?? "large"
    case .increaseContrast:
      return try currentIncreaseContrastEnabled() ? "enabled" : "disabled"
    case .reduceMotion, .reduceTransparency, .buttonShapes, .voiceOver:
      return try await currentAccessibilitySettingEnabled(key) ? "enabled" : "disabled"
    case .hardwareKeyboard, .slowAnimations:
      // Set-only (SimDevice API / Darwin notification with no getter); no readable current value.
      return try await currentPreference(name, domain: domain)
    }
  }

  /// Publishes the current supported settings, followed by changes from a dedicated guest observer.
  ///
  /// The guest registers its observer before its initial authoritative read and rereads after coalesced
  /// notifications. This host stream keeps only the newest event for a slow consumer, including a
  /// terminal availability event that can replace an unconsumed value.
  public func settings() -> AsyncStream<SimulatorSettingsEvent> {
    let transport = simulator.frameworkBridgeTransport(scope: .exclusive)
    return SimulatorSettingsPublisher {
      try await transport.stream(.deviceSettingChanges("state-settings"))
    }.events()
  }

  /// Publishes the current appearance and subsequent native changes, keeping only the newest unread value.
  public func appearanceChanges() async throws -> AsyncThrowingStream<SimulatorAppearance, any Error> {
    let simulator = self.simulator
    let subscription = try await SimulatorDarwinNotificationObserver.subscribe(
      on: simulator, name: "com.apple.UIKit.SystemUIServiceUserInterfaceStyleNotification")
    return SimulatorDarwinNotificationObserver.values(subscription: subscription) { _ in
      try await SimulatorPreferencesCommands(simulator: simulator).currentAppearance()
    }
  }

  /// Publishes the current Dynamic Type category and subsequent native changes.
  public func contentSizeChanges() async throws -> AsyncThrowingStream<SimulatorContentSizeCategory, any Error> {
    let simulator = self.simulator
    let subscription = try await SimulatorDarwinNotificationObserver.subscribe(
      on: simulator, name: "ApplePreferredContentSizeCategoryChangedNotification")
    return SimulatorDarwinNotificationObserver.values(subscription: subscription) { _ in
      try await SimulatorPreferencesCommands(simulator: simulator).currentContentSizeCategory()
    }
  }

  // MARK: - Private

  static func appearance(rawValue: Int) throws -> SimulatorAppearance {
    guard let appearance = SimulatorAppearance(rawValue: rawValue) else {
      throw SimulatorPreferencesError.unexpectedAppearance(rawValue)
    }
    return appearance
  }

  static func contentSizeCategory(rawValue: Int) throws -> SimulatorContentSizeCategory {
    guard let category = SimulatorContentSizeCategory(rawValue: rawValue) else {
      throw SimulatorPreferencesError.unexpectedContentSizeCategory(rawValue)
    }
    return category
  }

  private func currentAppearance() async throws -> SimulatorAppearance {
    try Self.appearance(rawValue: simulator.device.currentUIInterfaceStyle())
  }

  private func setAppearance(_ appearance: SimulatorAppearance) async throws {
    try simulator.device.setUIInterfaceStyle(appearance.rawValue)
  }

  private func currentContentSizeCategory() async throws -> SimulatorContentSizeCategory {
    try Self.contentSizeCategory(rawValue: simulator.device.currentContentSizeCategory())
  }

  private func setContentSizeCategory(_ category: SimulatorContentSizeCategory) async throws {
    try simulator.device.setContentSizeCategory(category.rawValue)
  }

  /// What writing the hardware keyboard setting takes, in order.
  enum HardwareKeyboardStep: Equatable {
    case enableAutomaticMinimization
    case write(enabled: Bool)
  }

  // Apps only hide the software keyboard when the keyboard daemon's automatic minimization
  // preference is also on. It is unset on a new simulator, and the daemon only sets it when it
  // sees the keyboard attach while an app's software keyboard is up.
  static func hardwareKeyboardSteps(enabled: Bool) -> [HardwareKeyboardStep] {
    enabled ? [.enableAutomaticMinimization, .write(enabled: true)] : [.write(enabled: false)]
  }

  private func setHardwareKeyboardEnabled(_ enabled: Bool) async throws {
    for step in Self.hardwareKeyboardSteps(enabled: enabled) {
      switch step {
      case .enableAutomaticMinimization:
        try await setPreference(
          "AutomaticMinimizationEnabled", value: "true", type: "bool", domain: "com.apple.keyboard.preferences")
      case let .write(enabled):
        try simulator.device.setHardwareKeyboardEnabled(enabled, keyboardType: 0)
      }
    }
  }

  private func setSlowAnimationsEnabled(_ enabled: Bool) async throws {
    try await setDarwinNotificationState(enabled, name: slowAnimationsNotification)
  }

  private func currentAccessibilitySettingEnabled(_ key: SimulatorSettingKey) async throws -> Bool {
    guard let settingName = key.accessibilityBridgeName else {
      throw SimulatorPreferencesError.settingNotPreferenceBacked(setting: key.rawValue)
    }
    let reply = try await AXBridgeOneshotTransport(simulator: simulator)
      .send(.deviceSettingRead(settingName))
    return try AXDeviceSettingResponse(answer: reply.answer).enabled
  }

  private func setAccessibilitySetting(_ key: SimulatorSettingKey, enabled: Bool) async throws {
    guard let settingName = key.accessibilityBridgeName else {
      throw SimulatorPreferencesError.settingNotPreferenceBacked(setting: key.rawValue)
    }
    let reply = try await AXBridgeOneshotTransport(simulator: simulator)
      .send(.deviceSettingWrite(settingName, enabled: enabled))
    let actual = try AXDeviceSettingResponse(answer: reply.answer).enabled
    guard actual == enabled else {
      throw SimulatorPreferencesError.accessibilitySettingsReadbackMismatch(
        setting: settingName,
        expected: enabled,
        actual: actual)
    }
  }

  private func currentIncreaseContrastEnabled() throws -> Bool {
    let rawMode = simulator.device.currentIncreaseContrastMode()
    guard let mode = SimulatorIncreaseContrastMode(rawValue: rawMode) else {
      throw SimulatorPreferencesError.unexpectedIncreaseContrastMode(rawMode)
    }
    return mode == .enabled
  }

  private func setIncreaseContrastEnabled(_ enabled: Bool) async throws {
    try simulator.device.setIncreaseContrastEnabled(enabled)
  }

  private func setPreferenceBacked(_ key: SimulatorSettingKey, value: String, type: String?) async throws {
    guard let backing = key.preferenceBacking else {
      throw SimulatorPreferencesError.settingNotPreferenceBacked(setting: key.rawValue)
    }
    try await setPreference(backing.key, value: value, type: type, domain: backing.domain)
  }

  private func setDarwinNotificationState(_ enabled: Bool, name: String) async throws {
    try simulator.device.darwinNotificationSetState(enabled ? 1 : 0, name: name)
    try simulator.device.postDarwinNotification(name)
  }

  private func setPreference(_ name: String, value: String, type: String?, domain: String?) async throws {
    try await SimulatorDefaults(simulator: simulator)
      .setPreference(name, value: value, type: type, domain: domain)
  }
}
