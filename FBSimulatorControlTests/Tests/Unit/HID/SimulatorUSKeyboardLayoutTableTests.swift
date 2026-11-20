/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import Foundation
import Testing

/// The US ANSI character table, pinned entry by entry so that it cannot drift from the one
/// `idb ui text` carries in `idb/common/hid.py`.
@Suite
struct SimulatorUSKeyboardLayoutTableTests {

  /// Every entry of `KEY_MAP` in `idb/common/hid.py`: the character, its usage, and whether shift is held.
  private static let keyMap: [(Character, UInt32, Bool)] = [
    ("a", 4, false), ("b", 5, false), ("c", 6, false), ("d", 7, false), ("e", 8, false),
    ("f", 9, false), ("g", 10, false), ("h", 11, false), ("i", 12, false), ("j", 13, false),
    ("k", 14, false), ("l", 15, false), ("m", 16, false), ("n", 17, false), ("o", 18, false),
    ("p", 19, false), ("q", 20, false), ("r", 21, false), ("s", 22, false), ("t", 23, false),
    ("u", 24, false), ("v", 25, false), ("w", 26, false), ("x", 27, false), ("y", 28, false),
    ("z", 29, false), ("A", 4, true), ("B", 5, true), ("C", 6, true), ("D", 7, true),
    ("E", 8, true), ("F", 9, true), ("G", 10, true), ("H", 11, true), ("I", 12, true),
    ("J", 13, true), ("K", 14, true), ("L", 15, true), ("M", 16, true), ("N", 17, true),
    ("O", 18, true), ("P", 19, true), ("Q", 20, true), ("R", 21, true), ("S", 22, true),
    ("T", 23, true), ("U", 24, true), ("V", 25, true), ("W", 26, true), ("X", 27, true),
    ("Y", 28, true), ("Z", 29, true), ("1", 30, false), ("2", 31, false), ("3", 32, false),
    ("4", 33, false), ("5", 34, false), ("6", 35, false), ("7", 36, false), ("8", 37, false),
    ("9", 38, false), ("0", 39, false), ("\n", 40, false), (";", 51, false), ("=", 46, false),
    (",", 54, false), ("-", 45, false), (".", 55, false), ("/", 56, false), ("`", 53, false),
    ("[", 47, false), ("\\", 49, false), ("]", 48, false), ("'", 52, false), (" ", 44, false),
    ("!", 30, true), ("@", 31, true), ("#", 32, true), ("$", 33, true), ("%", 34, true),
    ("^", 35, true), ("&", 36, true), ("*", 37, true), ("(", 38, true), (")", 39, true),
    ("_", 45, true), ("+", 46, true), ("{", 47, true), ("}", 48, true), (":", 51, true),
    ("\"", 52, true), ("|", 49, true), ("<", 54, true), (">", 55, true), ("?", 56, true),
    ("~", 53, true),
  ]

  @Test
  func matchesEveryKeyMapEntry() {
    let table = SimulatorUSKeyboardLayoutTable()
    #expect(Self.keyMap.count == 96)
    for (character, usage, shifted) in Self.keyMap {
      #expect(
        table.keystrokes(for: character, layout: .us) == [SimulatorKeyStroke(usage: usage, modifiers: shifted ? .shift : [])],
        "\(character.debugDescription)")
    }
  }

  @Test
  func tabIsTheTabKey() {
    #expect(SimulatorUSKeyboardLayoutTable().keystrokes(for: "\t", layout: .us) == [SimulatorKeyStroke(usage: 0x2B)])
  }

  @Test
  func charactersOffTheLayoutHaveNoKeystrokes() {
    let table = SimulatorUSKeyboardLayoutTable()
    for character: Character in ["ß", "é", "€", "\r", "\r\n", "\u{1F600}"] {
      #expect(table.keystrokes(for: character, layout: .us) == nil, "\(character.debugDescription)")
    }
  }

  @Test
  func aCharacterItHasNoKeyForIsLookedUpInItsFallback() {
    struct Fallback: SimulatorKeyboardLayoutTable {
      func keystrokes(for character: Character, layout: SimulatorKeyboardLayout) -> [SimulatorKeyStroke]? {
        [SimulatorKeyStroke(usage: 0x64)]
      }

      func text(typedBy strokes: [SimulatorKeyStroke], layout: SimulatorKeyboardLayout) -> String? {
        "replayed"
      }
    }
    let table = SimulatorUSKeyboardLayoutTable(fallback: Fallback())

    #expect(table.keystrokes(for: "a", layout: .us) == [SimulatorKeyStroke(usage: 0x04)])
    #expect(table.keystrokes(for: "é", layout: .us) == [SimulatorKeyStroke(usage: 0x64)])
    #expect(table.text(typedBy: [], layout: .us) == "replayed")
    #expect(SimulatorUSKeyboardLayoutTable().text(typedBy: [], layout: .us) == nil)
  }
}
