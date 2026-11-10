/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import Foundation
import Testing

/// Coverage of `SimulatorHIDEvent.text(...)` — the key presses that type a string, resolved through
/// a keyboard layout table.
@Suite
struct SimulatorHIDEventTextTests {

  /// A table of exactly the strokes it is given, for one layout, which can also say what its
  /// strokes go on to type.
  private struct StubTable: SimulatorKeyboardLayoutTable {
    let strokes: [Character: [SimulatorKeyStroke]]
    var typed: String?

    func text(typedBy strokes: [SimulatorKeyStroke], layout: SimulatorKeyboardLayout) -> String? {
      typed
    }

    func keystrokes(for character: Character, layout: SimulatorKeyboardLayout) -> [SimulatorKeyStroke]? {
      layout == Self.layout ? strokes[character] : nil
    }

    static let layout = SimulatorKeyboardLayout(name: "French")
  }

  private func down(_ keyCode: UInt32) -> SimulatorHIDEvent {
    .keyboard(direction: .down, keyCode: keyCode)
  }

  private func up(_ keyCode: UInt32) -> SimulatorHIDEvent {
    .keyboard(direction: .up, keyCode: keyCode)
  }

  @Test
  func usTextIsKeyPressesWithShiftHeldAroundShiftedCharacters() throws {
    #expect(
      try SimulatorHIDEvent.text("aA1!") == .composite([
        down(0x04), up(0x04),
        down(0xE1), down(0x04), up(0x04), up(0xE1),
        down(0x1E), up(0x1E),
        down(0xE1), down(0x1E), up(0x1E), up(0xE1),
      ]))
  }

  @Test
  func modifiersGoDownShiftThenOptionAndComeUpInReverse() throws {
    let table = StubTable(strokes: [
      "Æ": [SimulatorKeyStroke(usage: 0x14, modifiers: [.option, .shift])],
      "æ": [SimulatorKeyStroke(usage: 0x14, modifiers: .option)],
    ])

    #expect(
      try SimulatorHIDEvent.text("Ææ", layout: StubTable.layout, table: table) == .composite([
        down(0xE1), down(0xE2), down(0x14), up(0x14), up(0xE2), up(0xE1),
        down(0xE2), down(0x14), up(0x14), up(0xE2),
      ]))
  }

  @Test
  func aCharacterOfSeveralStrokesIsPressedInOrder() throws {
    // A dead key, then the letter it accents.
    let table = StubTable(strokes: [
      "ê": [SimulatorKeyStroke(usage: 0x2F), SimulatorKeyStroke(usage: 0x08)],
      "Ê": [SimulatorKeyStroke(usage: 0x2F), SimulatorKeyStroke(usage: 0x08, modifiers: .shift)],
    ])

    #expect(
      try SimulatorHIDEvent.text("êÊ", layout: StubTable.layout, table: table) == .composite([
        down(0x2F), up(0x2F), down(0x08), up(0x08),
        down(0x2F), up(0x2F), down(0xE1), down(0x08), up(0x08), up(0xE1),
      ]))
  }

  @Test
  func anUnsupportedCharacterThrowsNamingItsOffsetAndTheLayoutButNotTheCharacter() {
    let table = StubTable(strokes: ["a": [SimulatorKeyStroke(usage: 0x14)]])

    let error = #expect(throws: SimulatorHIDError.self) {
      try SimulatorHIDEvent.text("aaßa", layout: StubTable.layout, table: table)
    }

    guard case let .characterNotOnKeyboardLayout(offset, layout) = error else {
      Issue.record("unexpected error: \(String(describing: error))")
      return
    }
    #expect(offset == 2)
    #expect(layout == "French")
    #expect(error?.localizedDescription == "Cannot type the character at offset 2 on the French hardware keyboard layout")
  }

  @Test
  func theFirstUnsupportedCharacterIsTheOneReported() {
    let error = #expect(throws: SimulatorHIDError.self) {
      try SimulatorHIDEvent.text("a€ß")
    }

    #expect(error?.localizedDescription == "Cannot type the character at offset 1 on the US hardware keyboard layout")
  }

  @Test
  func offsetsCountCharactersOfThePrecomposedText() {
    let table = StubTable(strokes: ["é": [SimulatorKeyStroke(usage: 0x1F)]])

    let error = #expect(throws: SimulatorHIDError.self) {
      try SimulatorHIDEvent.text("e\u{301}e\u{301}x", layout: StubTable.layout, table: table)
    }

    #expect(error?.localizedDescription == "Cannot type the character at offset 2 on the French hardware keyboard layout")
  }

  @Test
  func strokesThatWouldTypeOtherTextThrowAtTheFirstCharacterThatDiffers() {
    // A key that leaves a dead key pending changes the character typed after it.
    let strokes: [Character: [SimulatorKeyStroke]] = ["¸": [SimulatorKeyStroke(usage: 0x30)], "a": [SimulatorKeyStroke(usage: 0x04)]]

    let error = #expect(throws: SimulatorHIDError.self) {
      try SimulatorHIDEvent.text("a¸a", layout: StubTable.layout, table: StubTable(strokes: strokes, typed: "a¸â"))
    }
    #expect(error?.localizedDescription == "Cannot type the character at offset 2 on the French hardware keyboard layout")

    let truncated = #expect(throws: SimulatorHIDError.self) {
      try SimulatorHIDEvent.text("a¸a", layout: StubTable.layout, table: StubTable(strokes: strokes, typed: "a¸"))
    }
    #expect(truncated?.localizedDescription == "Cannot type the character at offset 2 on the French hardware keyboard layout")

    // Text that is typed and then added to is refused at its last character.
    let extended = #expect(throws: SimulatorHIDError.self) {
      try SimulatorHIDEvent.text("a¸a", layout: StubTable.layout, table: StubTable(strokes: strokes, typed: "a¸a^"))
    }
    #expect(extended?.localizedDescription == "Cannot type the character at offset 2 on the French hardware keyboard layout")
  }

  @Test
  func strokesThatTypeTheTextInAnotherNormalFormAreSent() throws {
    let table = StubTable(strokes: ["é": [SimulatorKeyStroke(usage: 0x1F)]], typed: "e\u{301}")

    #expect(try SimulatorHIDEvent.text("é", layout: StubTable.layout, table: table) == .composite([down(0x1F), up(0x1F)]))
  }

  @Test
  func emptyTextIsAnEmptyComposite() throws {
    #expect(try SimulatorHIDEvent.text("") == .composite([]))
  }
}
