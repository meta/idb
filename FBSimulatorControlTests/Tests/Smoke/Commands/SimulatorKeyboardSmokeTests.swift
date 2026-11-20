/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
@testable import FBSimulatorControl
import XCTest

/// The key strokes read out of the provided simulator's runtime, whose hardware keyboard layouts
/// are the ones its guest types with.
final class SimulatorKeyboardSmokeTests: ProvidedSimulatorTestCase {

  private let french = SimulatorKeyboardLayout(name: "French")
  private let german = SimulatorKeyboardLayout(name: "German")

  private func layoutsBundle() throws -> URL {
    let root = try XCTUnwrap(simulator.device.runtime.root)
    let bundle = URL(fileURLWithPath: root).appendingPathComponent("System/Library/KeyboardLayouts/USBKeyboardLayouts.bundle")
    guard FileManager.default.fileExists(atPath: bundle.path) else {
      throw XCTSkip("This simulator's runtime ships no hardware keyboard layouts")
    }
    return bundle
  }

  private func table() throws -> SimulatorUCHRKeyboardLayoutTable {
    _ = try layoutsBundle()
    return SimulatorUCHRKeyboardLayoutTable(runtimeRoot: try XCTUnwrap(simulator.device.runtime.root))
  }

  private func stroke(_ usage: UInt32, _ modifiers: SimulatorKeyModifiers = []) -> SimulatorKeyStroke {
    SimulatorKeyStroke(usage: usage, modifiers: modifiers)
  }

  func testFrenchKeysAreWhereAZERTYPutsThem() throws {
    let table = try table()
    XCTAssertEqual(table.keystrokes(for: "a", layout: french), [stroke(0x14)])
    XCTAssertEqual(table.keystrokes(for: "q", layout: french), [stroke(0x04)])
    XCTAssertEqual(table.keystrokes(for: "m", layout: french), [stroke(0x33)])
    XCTAssertEqual(table.keystrokes(for: "A", layout: french), [stroke(0x14, .shift)])
    XCTAssertEqual(table.keystrokes(for: "1", layout: french), [stroke(0x1E, .shift)])
    XCTAssertEqual(table.keystrokes(for: ".", layout: french), [stroke(0x36, .shift)])
    XCTAssertEqual(table.keystrokes(for: "@", layout: french), [stroke(0x64)])
    XCTAssertEqual(table.keystrokes(for: "ê", layout: french), [stroke(0x08, .option)])
    XCTAssertEqual(table.keystrokes(for: "€", layout: french), [stroke(0x30, .option)])
  }

  func testGermanSwapsYAndZAndTypesAtWithOption() throws {
    let table = try table()
    XCTAssertEqual(table.keystrokes(for: "z", layout: german), [stroke(0x1C)])
    XCTAssertEqual(table.keystrokes(for: "y", layout: german), [stroke(0x1D)])
    XCTAssertEqual(table.keystrokes(for: "@", layout: german), [stroke(0x0F, .option)])
  }

  func testACharacterBehindADeadKeyIsTheDeadKeyThenTheKeyItAccents() throws {
    let table = try table()
    XCTAssertEqual(table.keystrokes(for: "ñ", layout: french), [stroke(0x11, .option), stroke(0x11)])
    XCTAssertEqual(table.keystrokes(for: "é", layout: german), [stroke(0x2E), stroke(0x08)])
    // A dead key's own character is the dead key, then space.
    XCTAssertEqual(table.keystrokes(for: "^", layout: french), [stroke(0x2F), stroke(0x2C)])
  }

  func testNoSequenceLeavesADeadKeyPendingForTheNextCharacter() throws {
    let table = try table()
    // Two dead keys in a row type a cedilla on this layout and leave the second one pending, so
    // that an "a" after it would arrive as "â". No other keys type the cedilla alone.
    let canadianFrench = SimulatorKeyboardLayout(name: "CanadianFrench-PC")
    guard table.text(typedBy: [stroke(0x30), stroke(0x2F), stroke(0x04)], layout: canadianFrench) == "¸â" else {
      throw XCTSkip("This simulator's runtime has no CanadianFrench-PC layout whose cedilla and circumflex are dead keys")
    }
    XCTAssertNil(table.keystrokes(for: "¸", layout: canadianFrench))
    for text in ["ça va", "à â ë", "Où"] {
      let strokes = try text.map { try XCTUnwrap(table.keystrokes(for: $0, layout: canadianFrench), "\($0)") }.flatMap { $0 }
      XCTAssertEqual(table.text(typedBy: strokes, layout: canadianFrench), text)
      XCTAssertNoThrow(try SimulatorHIDEvent.text(text, layout: canadianFrench, table: table))
    }
  }

  func testACharacterOfSeveralScalarsIsTypedScalarByScalar() throws {
    let table = try table()
    let devanagari = SimulatorKeyboardLayout(name: "Devanagari")
    let ka = try XCTUnwrap(table.keystrokes(for: "क", layout: devanagari))
    let vowelSign = try XCTUnwrap(table.keystrokes(for: "\u{93F}", layout: devanagari))
    XCTAssertEqual(table.keystrokes(for: "कि", layout: devanagari), ka + vowelSign)
    XCTAssertNoThrow(try SimulatorHIDEvent.text("कि", layout: devanagari, table: table))
  }

  func testReturnAndTabAreTheirOwnKeysInEveryLayout() throws {
    let table = try table()
    for layout in [french, german, .us] {
      XCTAssertEqual(table.keystrokes(for: "\n", layout: layout), [stroke(0x28)])
      XCTAssertEqual(table.keystrokes(for: "\t", layout: layout), [stroke(0x2B)])
      XCTAssertEqual(table.text(typedBy: [stroke(0x04), stroke(0x28), stroke(0x2B)], layout: layout)?.dropFirst(), "\n\t")
    }
  }

  func testACharacterTheLayoutHasNoKeyForHasNoKeystrokes() throws {
    let table = try table()
    for character: Character in ["日", "\u{1F600}"] {
      XCTAssertNil(table.keystrokes(for: character, layout: french))
    }
  }

  func testTheRuntimesUSLayoutAgreesWithTheStaticUSTable() throws {
    let table = try table()
    let us = SimulatorUSKeyboardLayoutTable()
    let characters = (0x20...0x7E).map { Character(UnicodeScalar($0)) } + ["\n", "\t"]
    for character in characters {
      XCTAssertEqual(
        table.keystrokes(for: character, layout: .us), us.keystrokes(for: character, layout: .us), "\(character.debugDescription)")
    }
  }

  func testEveryLayoutTheRuntimeShipsIsRead() throws {
    let table = try table()
    let data = try Data(contentsOf: try layoutsBundle().appendingPathComponent("USBKeyboardLayouts.plist"))
    let layouts = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    XCTAssertFalse(layouts.isEmpty)
    for name in layouts.keys {
      XCTAssertTrue(table.hasLayout(SimulatorKeyboardLayout(name: name)), name)
    }
    for name in ["Bogus", "../French", "french"] {
      XCTAssertFalse(table.hasLayout(SimulatorKeyboardLayout(name: name)), name)
    }
  }

  func testATruncatedLayoutIsNotRead() throws {
    let french = try Data(contentsOf: try layoutsBundle().appendingPathComponent("uchrs/French.uchr"))
    XCTAssertNotNil(SimulatorUCHRKeyMap(uchr: french))
    for count in [12, 40, french.count / 2, french.count * 3 / 4] {
      XCTAssertNil(SimulatorUCHRKeyMap(uchr: french.prefix(count)), "\(count) of \(french.count) bytes")
    }
  }

  func testAnAutomaticHardwareLayoutIsTheFirstTheRuntimeListsForTheMode() throws {
    let table = try table()
    let expected = [
      ("fr_FR", "French"), ("de_DE", "German"), ("en_US", "US"), ("es_ES", "Spanish - ISO"), ("en_GB", "British"),
    ]
    for (mode, layout) in expected {
      let inputMode = try XCTUnwrap(SimulatorInputMode(identifier: "\(mode)@hw=Automatic"))
      XCTAssertEqual(table.automaticLayout(for: inputMode), SimulatorKeyboardLayout(name: layout), mode)
    }
    XCTAssertNil(table.automaticLayout(for: try XCTUnwrap(SimulatorInputMode(identifier: "emoji@sw=Emoji"))))
    XCTAssertNil(table.automaticLayout(for: try XCTUnwrap(SimulatorInputMode(identifier: "xx_XX"))))
  }

  func testTheRuntimeNamesTheDefaultSoftwareLayoutAndInputModesOfALanguage() throws {
    let table = try table()
    XCTAssertEqual(table.defaultSoftwareLayout(for: try XCTUnwrap(SimulatorInputMode(identifier: "fr_FR"))), "AZERTY-French")
    XCTAssertEqual(table.defaultSoftwareLayout(for: try XCTUnwrap(SimulatorInputMode(identifier: "en_US"))), "QWERTY")
    XCTAssertNil(table.defaultSoftwareLayout(for: try XCTUnwrap(SimulatorInputMode(identifier: "xx_XX"))))
    XCTAssertEqual(table.defaultInputModes(forLanguage: "fr-FR").first, "fr_FR")
    XCTAssertEqual(table.defaultInputModes(forLanguage: "de-DE").first, "de_DE")
    XCTAssertEqual(table.defaultInputModes(forLanguage: "en-US").first, "en_US")
    XCTAssertEqual(table.defaultInputModes(forLanguage: "en-FR").first, "en_US")
    XCTAssertEqual(table.defaultInputModes(forLanguage: "en-GB").first, "en_GB")
    XCTAssertEqual(table.defaultInputModes(forLanguage: "xx-XX"), [])
    XCTAssertEqual(table.defaultInputModes(forLanguage: ""), [])
  }

  func testACharacterTheStaticUSTableLacksIsTypedFromTheRuntimesUSLayout() throws {
    let table = try table()
    func down(_ keyCode: UInt32) -> SimulatorHIDEvent { .keyboard(direction: .down, keyCode: keyCode) }
    func up(_ keyCode: UInt32) -> SimulatorHIDEvent { .keyboard(direction: .up, keyCode: keyCode) }

    XCTAssertEqual(try SimulatorKeyboardCommands.typingEvent(for: "aA1!\n", layout: .us, table: table), try SimulatorHIDEvent.text("aA1!\n"))
    XCTAssertEqual(
      try SimulatorKeyboardCommands.typingEvent(for: "aéñ€", layout: .us, table: table),
      .composite([
        down(0x04), up(0x04),
        // Option-e is the acute dead key and option-n the tilde.
        down(0xE2), down(0x08), up(0x08), up(0xE2), down(0x08), up(0x08),
        down(0xE2), down(0x11), up(0x11), up(0xE2), down(0x11), up(0x11),
        down(0xE1), down(0xE2), down(0x1F), up(0x1F), up(0xE2), up(0xE1),
      ]))
    XCTAssertThrowsError(try SimulatorKeyboardCommands.typingEvent(for: "a日", layout: .us, table: table))
  }

  // MARK: - The simulator's keyboards

  private static let globalDomain = "Apple Global Domain"
  private static let keyboardDomain = "com.apple.keyboard.preferences"

  private func defaults(_ arguments: String...) async throws -> Data {
    let simulator = self.simulator!
    let output = try await skippingIfGuestServiceSpawnUnavailable {
      try await simulator.runtimeTools.run("usr/bin/defaults", arguments: arguments)
    }
    XCTAssertEqual(output.exitCode, 0, "defaults \(arguments.joined(separator: " ")): \(String(decoding: output.stderr, as: UTF8.self))")
    return output.stdout
  }

  private func preferences(_ domain: String) async throws -> [String: Any] {
    let exported = try await defaults("export", domain, "-")
    return try XCTUnwrap(try PropertyListSerialization.propertyList(from: exported, format: nil) as? [String: Any])
  }

  /// Writes the simulator's keyboards for the test, putting back what was there when it ends.
  private func setKeyboards(_ keyboards: [String], lastUsed: String) async throws {
    let global = try await preferences(Self.globalDomain)
    let keyboard = try await preferences(Self.keyboardDomain)
    let originals: [(domain: String, key: String, write: [String]?)] = [
      (Self.globalDomain, "AppleKeyboards", (global["AppleKeyboards"] as? [String]).map { ["-array"] + $0 }),
      (Self.globalDomain, "AppleKeyboardsExpanded", (global["AppleKeyboardsExpanded"] as? Bool).map { ["-bool", $0 ? "YES" : "NO"] }),
      (Self.keyboardDomain, "KeyboardLastUsed", (keyboard["KeyboardLastUsed"] as? String).map { ["-string", $0] }),
    ]
    let simulator = self.simulator!
    addTeardownBlock {
      for original in originals {
        let arguments = original.write.map { ["write", original.domain, original.key] + $0 } ?? ["delete", original.domain, original.key]
        _ = try await simulator.runtimeTools.run("usr/bin/defaults", arguments: arguments)
      }
    }
    _ = try await defaults("write", Self.globalDomain, "AppleKeyboards", "-array", keyboards[0], keyboards[1])
    _ = try await defaults("write", Self.globalDomain, "AppleKeyboardsExpanded", "-bool", "YES")
    _ = try await defaults("write", Self.keyboardDomain, "KeyboardLastUsed", "-string", lastUsed)
  }

  func testTextIsTypedOnTheLayoutOfTheKeyboardLastUsed() async throws {
    let table = try table()
    let (german, french) = ("de_DE@sw=QWERTZ-German;hw=German", "fr_FR@sw=AZERTY-French;hw=Automatic")

    try await setKeyboards([german, french], lastUsed: french)
    let frenchReading = try await simulator.keyboard.activeHardwareLayout()
    XCTAssertEqual(frenchReading, .resolved(self.french))
    let frenchEvent = try await simulator.keyboard.typingEvent(for: "a")
    XCTAssertEqual(frenchEvent, try SimulatorHIDEvent.text("a", layout: self.french, table: table))
    XCTAssertEqual(frenchEvent, .composite([.keyboard(direction: .down, keyCode: 0x14), .keyboard(direction: .up, keyCode: 0x14)]))

    // A keyboard last used that is no longer one of the keyboards gives way to the first of them.
    _ = try await defaults("write", Self.keyboardDomain, "KeyboardLastUsed", "-string", "en_US@sw=QWERTY;hw=Automatic")
    let germanReading = try await simulator.keyboard.activeHardwareLayout()
    XCTAssertEqual(germanReading, .resolved(self.german))
    let germanEvent = try await simulator.keyboard.typingEvent(for: "z")
    XCTAssertEqual(germanEvent, .composite([.keyboard(direction: .down, keyCode: 0x1C), .keyboard(direction: .up, keyCode: 0x1C)]))
  }
}
