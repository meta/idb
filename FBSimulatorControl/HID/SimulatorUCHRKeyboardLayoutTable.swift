/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreServices
import Foundation
import os

/// The key strokes that type each character of one hardware keyboard layout, inverted from the
/// layout's `uchr` data as a simulator runtime ships it.
struct SimulatorUCHRKeyMap: Sendable {

  private let uchr: Data
  private let strokes: [Character: [SimulatorKeyStroke]]

  /// `nil` if `uchr` is not well-formed `uchr` data.
  init?(uchr: Data) {
    guard Self.isWellFormed(uchr) else {
      return nil
    }
    let keys = Self.keys.flatMap { key in Self.modifiers.map { SimulatorKeyStroke(usage: key, modifiers: $0) } }
    // What every key types, and the state it leaves, with no dead key pending.
    let alone = keys.map { Self.translate($0, uchr: uchr) }
    // Whether a state left behind changes what the next key types. A state that is not zero is
    // harmless otherwise, and is what most completed compositions leave.
    var disturbing: [UInt32: Bool] = [0: false]
    func disturbs(_ state: UInt32) -> Bool {
      if let known = disturbing[state] {
        return known
      }
      let disturbs = zip(keys, alone).contains { Self.translate($0, uchr: uchr, deadKeyState: state).text != $1.text }
      disturbing[state] = disturbs
      return disturbs
    }
    var direct: [Character: SimulatorKeyStroke] = [:]
    var deadKeys: [(key: SimulatorKeyStroke, state: UInt32)] = []
    for (key, (text, state)) in zip(keys, alone) {
      if let character = text.first, text.count == 1 {
        if direct[character].map({ Self.cost(key) < Self.cost($0) }) ?? true, !disturbs(state) {
          direct[character] = key
        }
      } else if text.isEmpty, state != 0 {
        deadKeys.append((key, state))
      }
    }
    var composed: [Character: (dead: SimulatorKeyStroke, key: SimulatorKeyStroke)] = [:]
    for (dead, deadState) in deadKeys {
      // The second key is one that types a character of its own. For a key that types nothing the
      // layout data ends the dead key with its character alone, which is not what the guest types.
      for (key, typed) in zip(keys, alone) where !typed.text.isEmpty {
        // A completed composition is one character and a failed one is two. A dead key's own
        // character is composed with space.
        let (text, state) = Self.translate(key, uchr: uchr, deadKeyState: deadState)
        guard let character = text.first, text.count == 1, direct[character] == nil else { continue }
        if let current = composed[character], Self.cost(current.dead) + Self.cost(current.key) <= Self.cost(dead) + Self.cost(key) { continue }
        if !disturbs(state) {
          composed[character] = (dead, key)
        }
      }
    }
    var strokes = direct.mapValues { [$0] }
    for (character, sequence) in composed {
      strokes[character] = [sequence.dead, sequence.key]
    }
    // Return types a carriage return in every layout; a line feed is what text carries.
    strokes["\n"] = [SimulatorKeyStroke(usage: Self.returnKey)]
    strokes["\t"] = [SimulatorKeyStroke(usage: 0x2B)]
    self.uchr = uchr
    self.strokes = strokes
  }

  /// The strokes that type `character`, or `nil` if the layout cannot type it. A character of
  /// several scalars that has no key of its own is typed scalar by scalar.
  func keystrokes(for character: Character) -> [SimulatorKeyStroke]? {
    if let strokes = strokes[character] {
      return strokes
    }
    let scalars = character.unicodeScalars
    guard scalars.count > 1 else {
      return nil
    }
    var sequence: [SimulatorKeyStroke] = []
    for scalar in scalars {
      guard let strokes = strokes[Character(scalar)] else {
        return nil
      }
      sequence += strokes
    }
    return sequence
  }

  /// What `strokes` type when pressed one after another, each key meeting whatever dead-key state
  /// the keys before it left behind.
  func text(typedBy strokes: [SimulatorKeyStroke]) -> String {
    var state: UInt32 = 0
    var typed = ""
    for stroke in strokes {
      let (text, next) = Self.translate(stroke, uchr: uchr, deadKeyState: state)
      typed += stroke.usage == Self.returnKey && text == "\r" ? "\n" : text
      state = next
    }
    return typed
  }

  // MARK: - Private

  private static let returnKey: UInt32 = 0x28

  /// The printing keys, as USB HID usages (page 0x07): letters and digits, space through slash,
  /// the ISO key beside left shift, and the two extra JIS keys. Usage 0x32 is left out: the
  /// layout data has no output for it, and puts the ISO key beside return at 0x31.
  private static let keys: [UInt32] = Array(0x04...0x27) + Array(0x2C...0x31) + Array(0x33...0x38) + [0x64, 0x87, 0x89]

  private static let modifiers: [SimulatorKeyModifiers] = [[], .shift, .option, [.shift, .option]]

  /// Fewer modifiers first, and shift before option. `keys` is ascending, so of two keys that
  /// cost the same the one found first, with the lower usage, is kept.
  private static func cost(_ stroke: SimulatorKeyStroke) -> Int {
    (stroke.modifiers.contains(.shift) ? 1 : 0) + (stroke.modifiers.contains(.option) ? 2 : 0)
  }

  private static func translate(_ stroke: SimulatorKeyStroke, uchr: Data, deadKeyState: UInt32 = 0) -> (text: String, deadKeyState: UInt32) {
    // Carbon's `shiftKey` and `optionKey` event modifiers, shifted down a byte.
    let modifierState: UInt32 = (stroke.modifiers.contains(.shift) ? 0x02 : 0) | (stroke.modifiers.contains(.option) ? 0x08 : 0)
    var state = deadKeyState
    var length = 0
    var characters = [UniChar](repeating: 0, count: 8)
    let status = uchr.withUnsafeBytes { bytes -> OSStatus in
      guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
        return OSStatus(paramErr)
      }
      // A runtime's uchr data is indexed by HID usage, where macOS's is by virtual key code.
      return UCKeyTranslate(
        layout, UInt16(truncatingIfNeeded: stroke.usage), UInt16(kUCKeyActionDown), modifierState, 0, 0, &state,
        characters.count, &length, &characters)
    }
    guard status == noErr else {
      return ("", 0)
    }
    return (String(utf16CodeUnits: characters, count: min(length, characters.count)), state)
  }

  // MARK: - Validation

  /// Whether `uchr` has the layout header, and every table its keyboard types point at has the
  /// format it should and lies inside the data, along with everything those tables' own counts
  /// and offsets take in. `UCKeyTranslate` is given no length and follows the offsets it finds,
  /// so truncated or corrupted data would have it read out of bounds. What the entries of the
  /// tables refer to in one another is not checked.
  private static func isWellFormed(_ uchr: Data) -> Bool {
    let bytes = [UInt8](uchr)
    func u16(_ offset: Int) -> Int? {
      guard offset >= 0, offset + 2 <= bytes.count else { return nil }
      return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }
    func u32(_ offset: Int) -> Int? {
      guard let low = u16(offset), let high = u16(offset + 2) else { return nil }
      return low | high << 16
    }
    func contains(_ offset: Int, _ count: Int) -> Bool {
      offset >= 0 && count >= 0 && offset + count <= bytes.count
    }
    // UCKeyboardLayout: format, version, feature info offset, then the keyboard type headers.
    guard u16(0) == Int(kUCKeyLayoutHeaderFormat), let featureInfo = u32(4), let typeCount = u32(8), typeCount >= 1,
      featureInfo == 0 || contains(featureInfo, 8)
    else {
      return false
    }
    for type in 0..<typeCount {
      // UCKeyboardTypeHeader: first and last type, then five table offsets, the last three optional.
      let header = 12 + type * 28
      guard let modifiers = u32(header + 8), let tables = u32(header + 12), let records = u32(header + 16),
        let terminators = u32(header + 20), let sequences = u32(header + 24)
      else {
        return false
      }
      // UCKeyModifiersToTableNum: format, default table, count, then a table number per modifier state.
      guard u16(modifiers) == Int(kUCKeyModifiersToTableNumFormat), let modifierCount = u32(modifiers + 4),
        contains(modifiers + 8, modifierCount)
      else {
        return false
      }
      // UCKeyToCharTableIndex: format, table size, count, then an offset per table.
      guard u16(tables) == Int(kUCKeyToCharTableIndexFormat), let tableSize = u16(tables + 2), let tableCount = u32(tables + 4),
        contains(tables + 8, tableCount * 4)
      else {
        return false
      }
      for table in 0..<tableCount {
        guard let offset = u32(tables + 8 + table * 4), contains(offset, tableSize * 2) else {
          return false
        }
      }
      if records != 0 {
        // UCKeyStateRecordsIndex: format, count, then an offset per record. A record is four
        // 16-bit fields, then entries of four or eight bytes by its format.
        guard u16(records) == Int(kUCKeyStateRecordsIndexFormat), let recordCount = u16(records + 2),
          contains(records + 4, recordCount * 4)
        else {
          return false
        }
        for record in 0..<recordCount {
          guard let offset = u32(records + 4 + record * 4), let entryCount = u16(offset + 4), let format = u16(offset + 6),
            contains(offset + 8, entryCount * (format == Int(kUCKeyStateEntryTerminalFormat) ? 4 : 8))
          else {
            return false
          }
        }
      }
      if terminators != 0 {
        // UCKeyStateTerminators: format, count, then a character per state.
        guard u16(terminators) == Int(kUCKeyStateTerminatorsFormat), let count = u16(terminators + 2),
          contains(terminators + 4, count * 2)
        else {
          return false
        }
      }
      if sequences != 0 {
        // UCKeySequenceDataIndex: format, count, then count + 1 offsets from its start, each the
        // end of one sequence and the start of the next, which follow the offsets.
        guard u16(sequences) == Int(kUCKeySequenceDataIndexFormat), let count = u16(sequences + 2) else {
          return false
        }
        var previous = 4 + (count + 1) * 2
        for index in 0...count {
          guard let offset = u16(sequences + 4 + index * 2), offset >= previous, contains(sequences, offset) else {
            return false
          }
          previous = offset
        }
      }
    }
    return true
  }
}

/// The hardware keyboard layouts of a simulator runtime, read from the layout data the guest
/// itself types with. Each layout's keys are read once, when the layout is first asked for.
final class SimulatorUCHRKeyboardLayoutTable: SimulatorKeyboardLayoutTable {

  private struct State {
    /// The file of each layout the runtime has, by the layout's name.
    var files: [String: String]?
    var keyMaps: [SimulatorKeyboardLayout: SimulatorUCHRKeyMap] = [:]
    var inputModes: [String: InputModes] = [:]
  }

  /// What the runtime says of one language's input modes, by mode name unless noted.
  private struct InputModes {
    var hardwareLayouts: [String: [String]] = [:]
    var softwareLayouts: [String: [String]] = [:]
    /// The identifiers of the default input modes of each language or locale, such as `fr_CA`.
    var defaults: [String: [String]] = [:]
  }

  private let runtimeRoot: URL
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(runtimeRoot: String) {
    self.runtimeRoot = URL(fileURLWithPath: runtimeRoot)
  }

  func keystrokes(for character: Character, layout: SimulatorKeyboardLayout) -> [SimulatorKeyStroke]? {
    keyMap(for: layout)?.keystrokes(for: character)
  }

  func text(typedBy strokes: [SimulatorKeyStroke], layout: SimulatorKeyboardLayout) -> String? {
    keyMap(for: layout)?.text(typedBy: strokes)
  }

  /// Whether the runtime has `layout`.
  func hasLayout(_ layout: SimulatorKeyboardLayout) -> Bool {
    keyMap(for: layout) != nil
  }

  /// The layout that `hw=Automatic` stands for in `inputMode`: the first hardware layout the
  /// runtime lists for the mode.
  func automaticLayout(for inputMode: SimulatorInputMode) -> SimulatorKeyboardLayout? {
    inputModes(forLanguage: inputMode.language)?.hardwareLayouts[inputMode.name]?.first.map(SimulatorKeyboardLayout.init(name:))
  }

  /// The software layout of `inputMode` where its identifier names none: the first the runtime
  /// lists for the mode.
  func defaultSoftwareLayout(for inputMode: SimulatorInputMode) -> String? {
    inputModes(forLanguage: inputMode.language)?.softwareLayouts[inputMode.name]?.first
  }

  /// The identifiers of the input modes a language such as `fr-CA` has by default, the most
  /// preferred first: those the runtime lists for the language in its region, or else for the
  /// language alone.
  func defaultInputModes(forLanguage language: String) -> [String] {
    // A language comes from the guest's preferences and goes into a path, as a mode's name does,
    // so it is held to what a mode's name can be.
    guard let name = SimulatorInputMode(identifier: language)?.name else {
      return []
    }
    var parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
    guard let base = parts.first, let defaults = inputModes(forLanguage: base)?.defaults else {
      return []
    }
    while !parts.isEmpty {
      if let modes = defaults[parts.joined(separator: "_")] {
        return modes
      }
      parts.removeLast()
    }
    return []
  }

  // MARK: - Private

  private var layoutsBundle: URL {
    runtimeRoot.appendingPathComponent("System/Library/KeyboardLayouts/USBKeyboardLayouts.bundle")
  }

  /// Only what was read is kept: a layout the runtime has, so that the names a caller asks for
  /// cannot grow the cache, and never a failure to read. The files are read outside the lock; two
  /// first askers of a layout both read it.
  private func keyMap(for layout: SimulatorKeyboardLayout) -> SimulatorUCHRKeyMap? {
    let (files, known) = state.withLock { ($0.files, $0.keyMaps[layout]) }
    if let known {
      return known
    }
    guard let layoutFiles = files ?? loadLayoutFiles() else {
      return nil
    }
    if files == nil {
      state.withLock { $0.files = layoutFiles }
    }
    guard let file = layoutFiles[layout.name],
      let uchr = try? Data(contentsOf: layoutsBundle.appendingPathComponent("uchrs").appendingPathComponent(file)),
      let keyMap = SimulatorUCHRKeyMap(uchr: uchr)
    else {
      return nil
    }
    state.withLock { $0.keyMaps[layout] = keyMap }
    return keyMap
  }

  private func inputModes(forLanguage language: String) -> InputModes? {
    if let known = state.withLock({ $0.inputModes[language] }) {
      return known
    }
    // A language with few modes has no bundle of its own and is described in the `mul` one.
    for bundle in [language, "mul"] {
      let url = runtimeRoot.appendingPathComponent("System/Library/TextInput/TextInput_\(bundle).bundle/InputMode_\(language).plist")
      guard let plist = Self.propertyList(at: url) else { continue }
      var inputModes = InputModes()
      for (name, mode) in plist["UIKeyboardSupportedInputModes"] as? [String: [String: Any]] ?? [:] {
        inputModes.hardwareLayouts[name] = mode["HWLayouts"] as? [String]
        inputModes.softwareLayouts[name] = mode["SWLayouts"] as? [String]
      }
      inputModes.defaults = plist["UIKeyboardDefaultLanguageInputModes"] as? [String: [String]] ?? [:]
      state.withLock { [inputModes] in $0.inputModes[language] = inputModes }
      return inputModes
    }
    return nil
  }

  private func loadLayoutFiles() -> [String: String]? {
    let layouts = Self.propertyList(at: layoutsBundle.appendingPathComponent("USBKeyboardLayouts.plist")) as? [String: [String: Any]]
    return layouts?.compactMapValues { $0["KeyLayoutFileName"] as? String }
  }

  private static func propertyList(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else {
      return nil
    }
    return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
  }
}
