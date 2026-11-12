/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
import Foundation

/// Typing on the simulator's hardware keyboard, whatever layout it is set to.
public struct SimulatorKeyboardCommands: Sendable {

  private let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Typing

  /// The key presses that type `text` on `layout`, or on the simulator's active hardware keyboard
  /// layout if none is given.
  ///
  /// The active layout is the one the simulator's keyboard settings give a newly launched app:
  /// that of the keyboard last used if it is still one of the simulator's keyboards, otherwise of
  /// the first of them. A keyboard that is part of a multilingual keyboard types with the layout
  /// of the first keyboard in it, and a simulator whose keyboards are not yet set up types with
  /// the default keyboard of its language. An app keeps the layout it was launched with, so that
  /// is the layout of the app being typed into only if the app was launched since the simulator's
  /// keyboards last changed; name the layout otherwise. An active layout that cannot be determined
  /// is taken to be US.
  ///
  /// Throws, building nothing, for a layout the runtime does not have and for text the layout
  /// cannot type.
  public func typingEvent(for text: String, layout: SimulatorKeyboardLayout? = nil) async throws -> SimulatorHIDEvent {
    let table = layoutTable
    guard let layout else {
      let reading = try await activeHardwareLayout()
      if case let .assumed(layout, reason) = reading {
        simulator.logger.log("Typing on the \(layout.name) hardware keyboard layout, as \(reason)")
      }
      return try Self.typingEvent(for: text, layout: reading.layout, table: table)
    }
    return try Self.typingEvent(for: text, layout: layout, table: table)
  }

  /// US is typed from the static table, so its key presses are the same whatever the runtime
  /// ships; only text with a character that table lacks goes on to the runtime's US layout for
  /// it. Any other layout is typed from the runtime's own, and is unknown without it.
  static func typingEvent(
    for text: String, layout: SimulatorKeyboardLayout, table: SimulatorUCHRKeyboardLayoutTable?
  ) throws -> SimulatorHIDEvent {
    guard layout != .us else {
      do {
        return try .text(text, layout: layout)
      } catch let error as SimulatorHIDError {
        guard case .characterNotOnKeyboardLayout = error, let table, table.hasLayout(layout) else { throw error }
        return try .text(text, layout: layout, table: SimulatorUSKeyboardLayoutTable(fallback: table))
      }
    }
    guard let table, table.hasLayout(layout) else {
      throw SimulatorHIDError.unknownKeyboardLayout(name: layout.name)
    }
    return try .text(text, layout: layout, table: table)
  }

  // MARK: - Layout

  /// The hardware keyboard layout the simulator's keyboard settings give a newly launched app,
  /// assumed to be US if it cannot be determined.
  func activeHardwareLayout() async throws -> SimulatorKeyboardLayoutReading {
    let table = layoutTable
    let identifier: Result<String?, any Error>
    do {
      identifier = .success(try await activeInputModeIdentifier())
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      identifier = .failure(error)
    }
    return SimulatorKeyboardLayoutReading.reading(
      ofInputMode: identifier,
      automaticLayout: { table?.automaticLayout(for: $0) },
      hasKeyMap: { table?.hasLayout($0) ?? false })
  }

  // MARK: - Private

  private var layoutTable: SimulatorUCHRKeyboardLayoutTable? {
    guard let runtimeRoot = simulator.device.runtime.root else {
      return nil
    }
    return simulator.commandCache.resolve { SimulatorUCHRKeyboardLayoutTable(runtimeRoot: runtimeRoot) }
  }

  /// The identifier of the input mode whose hardware layout a newly launched app types with, or
  /// `nil` if the simulator's keyboard settings name none.
  private func activeInputModeIdentifier() async throws -> String? {
    let defaults = SimulatorDefaults(simulator: simulator)
    async let globalPreferences = defaults.exportedPreferences(domain: nil)
    async let keyboardPreferences = defaults.exportedPreferences(domain: "com.apple.keyboard.preferences")
    let global = try Self.preferences(try await globalPreferences)
    let keyboard = try Self.preferences(try await keyboardPreferences)
    let table = layoutTable
    return SimulatorInputMode.activeIdentifier(
      keyboards: global["AppleKeyboards"] as? [String] ?? [],
      expanded: global["AppleKeyboardsExpanded"] as? Bool ?? false,
      languages: global["AppleLanguages"] as? [String] ?? [],
      lastUsed: keyboard["KeyboardLastUsed"] as? String,
      defaultSoftwareLayout: { table?.defaultSoftwareLayout(for: $0) },
      defaultInputModes: { table?.defaultInputModes(forLanguage: $0) ?? [] })
  }

  private static func preferences(_ exported: Data) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: exported, format: nil) as? [String: Any] ?? [:]
  }
}
