/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// A hardware keyboard layout: what decides which character a key usage types in the guest.
public struct SimulatorKeyboardLayout: Equatable, Hashable, Sendable {
  public let name: String

  public init(name: String) {
    self.name = name
  }

  /// US ANSI.
  public static let us = SimulatorKeyboardLayout(name: "US")
}

/// An input mode identifier such as `fr_FR@sw=AZERTY-French;hw=French`, taken apart.
struct SimulatorInputMode: Equatable, Sendable {
  /// The mode: `fr_FR`, `zh_Hans-Pinyin`.
  let name: String
  /// The `sw=` software keyboard layout.
  let softwareLayout: String?
  /// The `hw=` hardware keyboard layout, which is `Automatic` for the mode's own.
  let hardwareLayout: String?
  /// The `ml=` group: the keyboards that share one make up a single multilingual keyboard.
  let multilingualGroup: String?

  /// The language of the mode, which names the runtime bundle that describes it: `fr` for `fr_FR`.
  var language: String {
    String(name.prefix { $0 != "_" && $0 != "-" })
  }

  /// `nil` if `identifier` is not an input mode identifier.
  init?(identifier: String) {
    let parts = identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    let name = String(parts[0])
    guard let first = name.unicodeScalars.first, Self.letters.contains(first),
      name.unicodeScalars.allSatisfy({ Self.letters.contains($0) || Self.others.contains($0) })
    else {
      return nil
    }
    var options: [String: String] = [:]
    for option in parts.dropFirst().joined().split(separator: ";") {
      let pair = option.split(separator: "=", maxSplits: 1)
      guard pair.count == 2 else {
        return nil
      }
      options[String(pair[0])] = String(pair[1])
    }
    self.name = name
    self.softwareLayout = options["sw"]
    self.hardwareLayout = options["hw"]
    self.multilingualGroup = options["ml"]
  }

  /// The identifier of the input mode whose hardware layout a newly launched app types with.
  ///
  /// With the keyboards expanded, it is among `keyboards`: the keyboard last used if it is one of
  /// them, otherwise the first. A keyboard in a multilingual group types with the hardware layout
  /// of the first keyboard in that group. Otherwise the guest ignores `keyboards` for the default
  /// input modes of `languages`: the keyboard last used if it is one of those, otherwise the first.
  /// `nil` if that leaves no input mode.
  ///
  /// The keyboard last used is compared with each candidate written out in full, its software
  /// layout `defaultSoftwareLayout` and its hardware layout `Automatic` where it names none.
  ///
  /// `keyboards`, `expanded` and `languages` are the global `AppleKeyboards`,
  /// `AppleKeyboardsExpanded` and `AppleLanguages`; `lastUsed` is the `KeyboardLastUsed` of
  /// `com.apple.keyboard.preferences`.
  static func activeIdentifier(
    keyboards: [String],
    expanded: Bool,
    languages: [String],
    lastUsed: String?,
    defaultSoftwareLayout: (SimulatorInputMode) -> String?,
    defaultInputModes: (String) -> [String]
  ) -> String? {
    let candidates = expanded ? keyboards : languages.flatMap(defaultInputModes)
    let modes = candidates.map { SimulatorInputMode(identifier: $0) }
    let lastUsedIndex = lastUsed.flatMap { lastUsed in
      modes.firstIndex { $0?.writtenInFull(defaultSoftwareLayout: defaultSoftwareLayout) == lastUsed }
    }
    let active = lastUsedIndex ?? candidates.startIndex
    guard candidates.indices.contains(active) else {
      return nil
    }
    guard expanded, let group = modes[active]?.multilingualGroup else {
      return candidates[active]
    }
    return modes.firstIndex { $0?.multilingualGroup == group }.map { candidates[$0] }
  }

  private func writtenInFull(defaultSoftwareLayout: (SimulatorInputMode) -> String?) -> String {
    let options = [
      (softwareLayout ?? defaultSoftwareLayout(self)).map { "sw=\($0)" },
      "hw=\(hardwareLayout ?? Self.automaticHardwareLayout)",
      multilingualGroup.map { "ml=\($0)" },
    ]
    return "\(name)@\(options.compactMap { $0 }.joined(separator: ";"))"
  }

  static let automaticHardwareLayout = "Automatic"

  private static let letters = CharacterSet(charactersIn: "a"..."z").union(CharacterSet(charactersIn: "A"..."Z"))
  private static let others = CharacterSet(charactersIn: "0"..."9").union(CharacterSet(charactersIn: "_-"))
}

/// What a simulator's hardware keyboard layout was found to be.
enum SimulatorKeyboardLayoutReading: Equatable, Sendable {
  /// The layout the simulator is set to.
  case resolved(SimulatorKeyboardLayout)
  /// The layout could not be determined, for `reason`, so this one stands in for it.
  case assumed(SimulatorKeyboardLayout, reason: String)

  var layout: SimulatorKeyboardLayout {
    switch self {
    case let .resolved(layout), let .assumed(layout, _):
      return layout
    }
  }

  /// The layout of the input mode `identifier`, or of none if reading it failed. `automaticLayout` names the layout that
  /// `hw=Automatic` stands for in a mode, and `hasKeyMap` says whether a layout's keys are known.
  ///
  /// A hardware layout the guest does not know types as US there, which is what is assumed for it.
  static func reading(
    ofInputMode identifier: Result<String?, any Error>,
    automaticLayout: (SimulatorInputMode) -> SimulatorKeyboardLayout?,
    hasKeyMap: (SimulatorKeyboardLayout) -> Bool
  ) -> SimulatorKeyboardLayoutReading {
    let read: String?
    do {
      read = try identifier.get()
    } catch {
      return .assumed(.us, reason: "the simulator's keyboard settings could not be read: \(error.localizedDescription)")
    }
    guard let identifier = read, !identifier.isEmpty else {
      return .assumed(.us, reason: "the simulator's keyboard settings name no input mode")
    }
    guard let inputMode = SimulatorInputMode(identifier: identifier) else {
      return .assumed(.us, reason: "\"\(identifier)\" is not an input mode identifier")
    }
    let layout: SimulatorKeyboardLayout
    if let name = inputMode.hardwareLayout, name != SimulatorInputMode.automaticHardwareLayout {
      layout = SimulatorKeyboardLayout(name: name)
    } else if let automatic = automaticLayout(inputMode) {
      layout = automatic
    } else {
      return .assumed(.us, reason: "the runtime lists no hardware keyboard layout for the input mode \(inputMode.name)")
    }
    guard !layout.name.hasPrefix("Group-") else {
      // A group of layouts, not one of them; which of the group the guest types with is not known.
      return .assumed(.us, reason: "the input mode \(inputMode.name) types on \(layout.name), a group of hardware keyboard layouts and not one of them")
    }
    guard layout == .us || hasKeyMap(layout) else {
      return .assumed(.us, reason: "the runtime has no key map for the \(layout.name) hardware keyboard layout")
    }
    return .resolved(layout)
  }
}
