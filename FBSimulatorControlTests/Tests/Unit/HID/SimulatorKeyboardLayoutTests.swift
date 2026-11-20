/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import Foundation
import Testing

/// Reading a simulator's hardware keyboard layout out of its keyboard settings.
@Suite
struct SimulatorKeyboardLayoutTests {

  // MARK: - Input mode identifiers

  @Test
  func anIdentifierNamesItsModeAndLayouts() throws {
    let french = try #require(SimulatorInputMode(identifier: "fr_FR@sw=AZERTY-French;hw=French"))
    #expect(french.name == "fr_FR")
    #expect(french.language == "fr")
    #expect(french.softwareLayout == "AZERTY-French")
    #expect(french.hardwareLayout == "French")

    let english = try #require(SimulatorInputMode(identifier: "en_US@sw=QWERTY;hw=Automatic"))
    #expect(english.name == "en_US")
    #expect(english.language == "en")
    #expect(english.hardwareLayout == "Automatic")

    let spanish = try #require(SimulatorInputMode(identifier: "es_ES@sw=QWERTY-Spanish;hw=Spanish - ISO"))
    #expect(spanish.hardwareLayout == "Spanish - ISO")
    #expect(spanish.multilingualGroup == nil)

    let multilingual = try #require(SimulatorInputMode(identifier: "en_US@sw=QWERTY;hw=Automatic;ml=2"))
    #expect(multilingual.hardwareLayout == "Automatic")
    #expect(multilingual.multilingualGroup == "2")
    #expect(SimulatorInputMode(identifier: "en_US@ml=2")?.multilingualGroup == "2")

    let pinyin = try #require(SimulatorInputMode(identifier: "zh_Hans-Pinyin@sw=Pinyin10-Simplified;hw=Automatic"))
    #expect(pinyin.name == "zh_Hans-Pinyin")
    #expect(pinyin.language == "zh")
  }

  @Test
  func anIdentifierNeedNotNameAHardwareLayout() throws {
    let emoji = try #require(SimulatorInputMode(identifier: "emoji@sw=Emoji"))
    #expect(emoji.name == "emoji")
    #expect(emoji.softwareLayout == "Emoji")
    #expect(emoji.hardwareLayout == nil)

    let bare = try #require(SimulatorInputMode(identifier: "fr_FR"))
    #expect(bare.softwareLayout == nil)
    #expect(bare.hardwareLayout == nil)
  }

  @Test
  func whatIsNotAnIdentifierIsNotParsed() {
    for identifier in ["", "@sw=QWERTY;hw=US", "../fr@hw=French", "not an input mode", "fr_FR@hw", "(\n)"] {
      #expect(SimulatorInputMode(identifier: identifier) == nil, "\(identifier.debugDescription)")
    }
  }

  // MARK: - The active input mode

  private static let english = "en_US@sw=QWERTY;hw=Automatic"
  private static let frenchKeyboard = "fr_FR@sw=AZERTY-French;hw=Automatic"
  private static let emoji = "emoji@sw=Emoji"

  /// The active identifier where the runtime's default software layouts and input modes are these.
  private func activeIdentifier(
    _ keyboards: [String],
    expanded: Bool = true,
    languages: [String] = ["en-US"],
    lastUsed: String?
  ) -> String? {
    SimulatorInputMode.activeIdentifier(
      keyboards: keyboards,
      expanded: expanded,
      languages: languages,
      lastUsed: lastUsed,
      defaultSoftwareLayout: { ["en_US": "QWERTY", "fr_FR": "AZERTY-French", "de_DE": "QWERTZ-German"][$0.name] },
      defaultInputModes: {
        ["en-US": ["en_US"], "en-FR": ["en_US"], "fr-FR": ["fr_FR"], "de-DE": ["de_DE"], "en-IN": ["en_IN@ml=100", "hi_Latn@ml=100"]][$0] ?? []
      })
  }

  @Test
  func theKeyboardLastUsedIsActiveWhileItIsOneOfTheKeyboards() {
    let (english, french, emoji) = (Self.english, Self.frenchKeyboard, Self.emoji)
    #expect(activeIdentifier([french, english, emoji], lastUsed: english) == english)
    #expect(activeIdentifier([english, emoji, french], lastUsed: english) == english)
    #expect(activeIdentifier([english, emoji], lastUsed: english) == english)
    #expect(activeIdentifier([english, emoji, french], lastUsed: french) == french)
  }

  @Test
  func theFirstKeyboardIsActiveOtherwise() {
    for lastUsed in [nil, "", "de_DE@sw=QWERTZ-German;hw=German"] {
      #expect(activeIdentifier([Self.frenchKeyboard, Self.english, Self.emoji], lastUsed: lastUsed) == Self.frenchKeyboard)
    }
    #expect(activeIdentifier([], lastUsed: Self.english) == nil)
  }

  @Test
  func aKeyboardThatIsNoInputModeIsNotTheKeyboardLastUsed() {
    // A keyboard extension is listed by its bundle identifier.
    let keyboards = ["fr_FR@sw=AZERTY-French;hw=French", "com.example.app.KeyboardExtension"]
    for lastUsed in [nil, "", Self.english] {
      #expect(activeIdentifier(keyboards, lastUsed: lastUsed) == "fr_FR@sw=AZERTY-French;hw=French")
    }
    #expect(activeIdentifier(keyboards.reversed(), lastUsed: nil) == "com.example.app.KeyboardExtension")
  }

  @Test
  func aMultilingualKeyboardTypesWithTheLayoutOfItsFirstKeyboard() {
    let (english, french, emoji) = (Self.english, Self.frenchKeyboard, Self.emoji)
    let (english1, english2, french1, french2) = (english + ";ml=1", english + ";ml=2", french + ";ml=1", french + ";ml=2")

    var keyboards = [french2, english2, english1, french1, emoji]
    #expect(activeIdentifier(keyboards, lastUsed: english2) == french2)
    #expect(activeIdentifier(keyboards, lastUsed: english1) == english1)
    #expect(activeIdentifier(keyboards, lastUsed: french1) == english1)
    #expect(activeIdentifier(keyboards, lastUsed: french2) == french2)

    // The first of a group is the first that names it, wherever the others are.
    keyboards = [english1, french2, english2, french1, emoji]
    #expect(activeIdentifier(keyboards, lastUsed: english2) == french2)
    #expect(activeIdentifier(keyboards, lastUsed: french1) == english1)

    keyboards = [english2, french2, english1, french1, emoji]
    #expect(activeIdentifier(keyboards, lastUsed: french2) == english2)
    #expect(activeIdentifier(keyboards, lastUsed: english2) == english2)

    // Only the first keyboard's hardware layout counts.
    let german2 = "fr_FR@sw=AZERTY-French;hw=German;ml=2"
    #expect(activeIdentifier([german2, english2, english1, french1, emoji], lastUsed: english2) == german2)
    let englishGerman2 = "en_US@sw=QWERTY;hw=German;ml=2"
    #expect(activeIdentifier([french2, englishGerman2, english1, french1, emoji], lastUsed: englishGerman2) == french2)

    let german1 = "de_DE@sw=QWERTY;hw=Automatic;ml=1"
    #expect(activeIdentifier([english1, german1, emoji, french], lastUsed: german1) == english1)
  }

  @Test
  func theKeyboardLastUsedIsMatchedAgainstKeyboardsWrittenInFull() {
    let english = Self.english
    #expect(activeIdentifier([english, "fr_FR"], lastUsed: "fr_FR") == english)
    #expect(activeIdentifier([english, "fr_FR@sw=AZERTY-French"], lastUsed: "fr_FR@sw=AZERTY-French") == english)
    #expect(activeIdentifier([english, "fr_FR@sw=AZERTY-French"], lastUsed: Self.frenchKeyboard) == "fr_FR@sw=AZERTY-French")
    #expect(activeIdentifier([english, "fr_FR"], lastUsed: Self.frenchKeyboard) == "fr_FR")
    #expect(activeIdentifier([english, "en_US@ml=2", "fr_FR@ml=2"], lastUsed: Self.frenchKeyboard + ";ml=2") == "en_US@ml=2")
    #expect(activeIdentifier(["fr_FR"], lastUsed: nil) == "fr_FR")
    // A mode with no default software layout is written without one.
    #expect(activeIdentifier([english, "xx_XX"], lastUsed: "xx_XX@hw=Automatic") == "xx_XX")
    #expect(activeIdentifier([english, "xx_XX"], lastUsed: "xx_XX") == english)
  }

  @Test
  func keyboardsThatAreNotExpandedGiveWayToTheDefaultInputModesOfTheLanguages() {
    let english = Self.english
    #expect(activeIdentifier([], expanded: false, languages: ["de-DE"], lastUsed: nil) == "de_DE")
    #expect(activeIdentifier([], expanded: false, languages: ["fr-FR"], lastUsed: nil) == "fr_FR")
    #expect(activeIdentifier([], expanded: false, languages: ["fr-FR", "en-FR"], lastUsed: english) == "en_US")
    #expect(activeIdentifier([english, Self.emoji], expanded: false, languages: ["fr-FR"], lastUsed: english) == "fr_FR")
    #expect(activeIdentifier([Self.frenchKeyboard], expanded: false, languages: ["en-US"], lastUsed: nil) == "en_US")
    // Default input modes are not grouped into a multilingual keyboard.
    #expect(activeIdentifier([], expanded: false, languages: ["en-IN"], lastUsed: nil) == "en_IN@ml=100")
    #expect(activeIdentifier([], expanded: false, languages: ["en-IN"], lastUsed: "hi_Latn@hw=Automatic;ml=100") == "hi_Latn@ml=100")
    #expect(activeIdentifier([english], expanded: false, languages: ["xx-XX"], lastUsed: english) == nil)
    #expect(activeIdentifier([english], expanded: false, languages: [], lastUsed: english) == nil)
  }

  // MARK: - Reading the layout

  private static let french = SimulatorKeyboardLayout(name: "French")

  private func reading(
    _ identifier: String?,
    automatic: SimulatorKeyboardLayout? = nil,
    known: Set<SimulatorKeyboardLayout> = [french]
  ) -> SimulatorKeyboardLayoutReading {
    .reading(ofInputMode: .success(identifier), automaticLayout: { _ in automatic }, hasKeyMap: known.contains)
  }

  @Test
  func aNamedHardwareLayoutIsTheLayout() {
    #expect(reading("fr_FR@sw=AZERTY-French;hw=French", automatic: .us) == .resolved(Self.french))
    #expect(reading("en_US@sw=QWERTY;hw=US", known: []) == .resolved(.us))
  }

  @Test
  func anAutomaticOrUnnamedHardwareLayoutIsTheModesOwn() {
    #expect(reading("fr_FR@sw=AZERTY-French;hw=Automatic", automatic: Self.french) == .resolved(Self.french))
    #expect(reading("fr_FR", automatic: Self.french) == .resolved(Self.french))
    #expect(reading("en_US@sw=QWERTY;hw=Automatic", automatic: .us) == .resolved(.us))
  }

  @Test
  func aLayoutThatCannotBeDeterminedIsAssumedToBeUS() {
    let unreadable = "the simulator's keyboard settings name no input mode"
    #expect(reading(nil) == .assumed(.us, reason: unreadable))
    #expect(reading("") == .assumed(.us, reason: unreadable))
    #expect(reading("not an input mode") == .assumed(.us, reason: "\"not an input mode\" is not an input mode identifier"))
    #expect(
      reading("emoji@sw=Emoji") == .assumed(.us, reason: "the runtime lists no hardware keyboard layout for the input mode emoji"))
    #expect(
      reading("de_DE@sw=QWERTZ-German;hw=German")
        == .assumed(.us, reason: "the runtime has no key map for the German hardware keyboard layout"))
    #expect(reading("").layout == .us)
  }

  @Test
  func aGroupOfLayoutsIsNotALayout() {
    #expect(
      reading("en_SG@sw=QWERTY;hw=Automatic", automatic: SimulatorKeyboardLayout(name: "Group-Latin"))
        == .assumed(.us, reason: "the input mode en_SG types on Group-Latin, a group of hardware keyboard layouts and not one of them"))
  }

  @Test
  func settingsThatCannotBeReadAreSaidToBeSo() {
    struct Unreadable: LocalizedError {
      var errorDescription: String? { "defaults export failed" }
    }
    let reading = SimulatorKeyboardLayoutReading.reading(
      ofInputMode: .failure(Unreadable()), automaticLayout: { _ in nil }, hasKeyMap: { _ in false })
    #expect(reading == .assumed(.us, reason: "the simulator's keyboard settings could not be read: defaults export failed"))
  }

  // MARK: - Choosing the table

  @Test
  func usIsTypedFromTheStaticTableWhateverTheRuntimeHas() throws {
    #expect(try SimulatorKeyboardCommands.typingEvent(for: "aA1!", layout: .us, table: nil) == SimulatorHIDEvent.text("aA1!"))
  }

  @Test
  func aCharacterTheStaticUSTableLacksIsRefusedWithoutTheRuntimesUSLayout() {
    for table in [nil, SimulatorUCHRKeyboardLayoutTable(runtimeRoot: "/nonexistent")] {
      let error = #expect(throws: SimulatorHIDError.self) {
        try SimulatorKeyboardCommands.typingEvent(for: "café", layout: .us, table: table)
      }
      #expect(error?.localizedDescription == "Cannot type the character at offset 3 on the US hardware keyboard layout")
    }
  }

  @Test
  func aLayoutTheRuntimeDoesNotHaveIsUnknown() {
    let table = SimulatorUCHRKeyboardLayoutTable(runtimeRoot: "/nonexistent")
    for table in [nil, table] {
      let error = #expect(throws: SimulatorHIDError.self) {
        try SimulatorKeyboardCommands.typingEvent(for: "a", layout: Self.french, table: table)
      }
      guard case .unknownKeyboardLayout(name: "French") = error else {
        Issue.record("unexpected error: \(String(describing: error))")
        continue
      }
    }
  }
}
