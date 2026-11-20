/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

extension SimulatorHIDEvent {

  /// The key presses that type `text` on a hardware keyboard with `layout`.
  ///
  /// The text is typed character by character in its precomposed (NFC) form. Every character is
  /// resolved before any event is built, and the strokes are then checked to type the text when
  /// pressed in a row, so text the layout cannot type throws and nothing is sent. Each stroke holds
  /// its modifiers around the key: shift then option down, the key down and up, then the modifiers
  /// up in reverse.
  static func text(
    _ text: String,
    layout: SimulatorKeyboardLayout = .us,
    table: any SimulatorKeyboardLayoutTable = SimulatorUSKeyboardLayoutTable()
  ) throws -> SimulatorHIDEvent {
    let text = text.precomposedStringWithCanonicalMapping
    var strokes: [SimulatorKeyStroke] = []
    for (offset, character) in text.enumerated() {
      guard let characterStrokes = table.keystrokes(for: character, layout: layout) else {
        throw SimulatorHIDError.characterNotOnKeyboardLayout(offset: offset, layout: layout.name)
      }
      strokes += characterStrokes
    }
    if let typed = table.text(typedBy: strokes, layout: layout), typed != text {
      // A key can leave a dead-key state that changes the character after it.
      // Text that is all typed and then added to is put down to its last character.
      let offset = zip(typed, text).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? max(0, min(typed.count, text.count - 1))
      throw SimulatorHIDError.characterNotOnKeyboardLayout(offset: offset, layout: layout.name)
    }
    var events: [SimulatorHIDEvent] = []
    for stroke in strokes {
      let modifiers = stroke.modifiers.usages
      events += modifiers.map { .keyboard(direction: .down, keyCode: $0) }
      events.append(.keyboard(direction: .down, keyCode: stroke.usage))
      events.append(.keyboard(direction: .up, keyCode: stroke.usage))
      events += modifiers.reversed().map { .keyboard(direction: .up, keyCode: $0) }
    }
    return .composite(events)
  }
}
