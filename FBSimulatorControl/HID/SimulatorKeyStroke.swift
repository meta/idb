/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// The modifier keys held while a key is pressed.
struct SimulatorKeyModifiers: OptionSet, Hashable, Sendable {
  let rawValue: UInt8

  init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  /// Left shift.
  static let shift = SimulatorKeyModifiers(rawValue: 1 << 0)
  /// Left option.
  static let option = SimulatorKeyModifiers(rawValue: 1 << 1)

  /// The USB HID usages (page 0x07) of the held modifiers, in the order they are pressed.
  var usages: [UInt32] {
    var usages: [UInt32] = []
    if contains(.shift) { usages.append(0xE1) }
    if contains(.option) { usages.append(0xE2) }
    return usages
  }
}

/// One key press: a USB HID keyboard usage (page 0x07) and the modifiers held around it.
struct SimulatorKeyStroke: Equatable, Hashable, Sendable {
  let usage: UInt32
  let modifiers: SimulatorKeyModifiers

  init(usage: UInt32, modifiers: SimulatorKeyModifiers = []) {
    self.usage = usage
    self.modifiers = modifiers
  }
}

/// Maps a character to the key strokes that type it on a hardware keyboard layout.
protocol SimulatorKeyboardLayoutTable: Sendable {
  /// The strokes that type `character` on `layout`, in order, or `nil` if the layout cannot type
  /// it. More than one stroke is a dead-key sequence.
  func keystrokes(for character: Character, layout: SimulatorKeyboardLayout) -> [SimulatorKeyStroke]?

  /// What `strokes` type on `layout` when pressed one after another, for a table that can tell.
  /// Dead keys make that differ from the characters the strokes were looked up for.
  func text(typedBy strokes: [SimulatorKeyStroke], layout: SimulatorKeyboardLayout) -> String?
}

extension SimulatorKeyboardLayoutTable {
  func text(typedBy strokes: [SimulatorKeyStroke], layout: SimulatorKeyboardLayout) -> String? {
    nil
  }
}

/// The US ANSI table. It knows no other layout, so it answers for US ANSI whichever one is asked
/// for. A character it has no key for is looked up in `fallback`, if there is one.
struct SimulatorUSKeyboardLayoutTable: SimulatorKeyboardLayoutTable {
  var fallback: (any SimulatorKeyboardLayoutTable)?

  func keystrokes(for character: Character, layout: SimulatorKeyboardLayout) -> [SimulatorKeyStroke]? {
    Self.keystroke(for: character).map { [$0] } ?? fallback?.keystrokes(for: character, layout: layout)
  }

  func text(typedBy strokes: [SimulatorKeyStroke], layout: SimulatorKeyboardLayout) -> String? {
    fallback?.text(typedBy: strokes, layout: layout)
  }

  private static func keystroke(for character: Character) -> SimulatorKeyStroke? {
    if let ascii = character.asciiValue {
      switch ascii {
      case 0x61...0x7A: return SimulatorKeyStroke(usage: UInt32(ascii - 0x61) + 0x04) // a-z
      case 0x41...0x5A: return SimulatorKeyStroke(usage: UInt32(ascii - 0x41) + 0x04, modifiers: .shift) // A-Z
      case 0x31...0x39: return SimulatorKeyStroke(usage: UInt32(ascii - 0x31) + 0x1E) // 1-9
      default: break
      }
    }
    if let usage = unshifted[character] {
      return SimulatorKeyStroke(usage: usage)
    }
    if let usage = shifted[character] {
      return SimulatorKeyStroke(usage: usage, modifiers: .shift)
    }
    return nil
  }

  private static let unshifted: [Character: UInt32] = [
    "0": 0x27, "\n": 0x28, "\t": 0x2B, " ": 0x2C, "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30,
    "\\": 0x31, ";": 0x33, "'": 0x34, "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38,
  ]

  private static let shifted: [Character: UInt32] = [
    "!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24, "*": 0x25,
    "(": 0x26, ")": 0x27, "_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30, "|": 0x31, ":": 0x33,
    "\"": 0x34, "~": 0x35, "<": 0x36, ">": 0x37, "?": 0x38,
  ]
}
