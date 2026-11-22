/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBSimulatorAX
import FBSimulatorBridgeProtocol
@testable import FBSimulatorControl
import Foundation
import Testing

@Suite
struct AXBridgeSnapshotDecoderTests {

  @Test
  func mapsCoreStringAttributes() {
    let element = AXBridgeSnapshotDecoder.snapshot(
      fromNode: [
        AXWire.Node.label.rawValue: "General",
        AXWire.Node.value.rawValue: "On",
        AXWire.Node.identifier.rawValue: "com.apple.settings.general",
        AXWire.Node.automationType.rawValue: "Button",
      ], pid: 42)

    #expect(element.label == "General")
    #expect(element.stringValue == "On")
    #expect(element.identifier == "com.apple.settings.general")
    #expect(element.role == "Button")
    #expect(element.pid == 42)
  }

  // The guest sends null for an attribute the server could not answer; it is no label, not the text "<null>".
  @Test
  func anAttributeTheServerCouldNotAnswerIsAbsentRatherThanDescribed() {
    let element = AXBridgeSnapshotDecoder.snapshot(
      fromNode: [AXWire.Node.label.rawValue: NSNull(), AXWire.Node.identifier.rawValue: NSNull()], pid: 0)

    #expect(element.label == nil)
    #expect(element.identifier == nil)
  }

  @Test
  func parsesFrameFromDictionaryRepresentation() {
    let expected = CGRect(x: 16, y: 380, width: 370, height: 52)
    let element = AXBridgeSnapshotDecoder.snapshot(
      fromNode: [
        AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(expected) as NSDictionary
      ], pid: 0)

    let frame = element.frame
    #expect(abs(frame.origin.x - expected.origin.x) <= 0.001)
    #expect(abs(frame.origin.y - expected.origin.y) <= 0.001)
    #expect(abs(frame.size.width - expected.size.width) <= 0.001)
    #expect(abs(frame.size.height - expected.size.height) <= 0.001)
  }

  @Test
  func frameWithNullMemberKeepsTheReadableEdgesWithoutCrashing() {
    // The guest sends a non-finite frame member as JSON null (arriving as NSNull). `CGRectMakeWithDictionaryRepresentation`
    // would raise `-[NSNull _getValue:forType:]` on it, so the null is restored to a non-finite value and the other
    // edges are kept rather than collapsing the rect to `.zero` (a real position for an off-screen element).
    let frameDict = NSMutableDictionary(
      dictionary: CGRectCreateDictionaryRepresentation(CGRect(x: 0, y: 0, width: 10, height: 20)) as NSDictionary
    )
    frameDict["X"] = NSNull()
    let element = AXBridgeSnapshotDecoder.snapshot(fromNode: [AXWire.Node.frame.rawValue: frameDict], pid: 0)

    let frame = element.frame
    #expect(!frame.origin.x.isFinite, "the null member is the coordinate the guest could not send")
    #expect(frame.origin.y == 0)
    #expect(frame.size.width == 10)
    #expect(frame.size.height == 20)
  }

  @Test
  func roleMapsElementTypeNumberToReadableName() {
    let element = AXBridgeSnapshotDecoder.snapshot(fromNode: [AXWire.Node.elementType.rawValue: NSNumber(value: 9)], pid: 0)
    #expect(element.role == "Button")
  }

  @Test
  func rolePrefersAutomationTypeNameOverElementType() {
    let element = AXBridgeSnapshotDecoder.snapshot(
      fromNode: [
        AXWire.Node.automationType.rawValue: NSNumber(value: 48),
        AXWire.Node.elementType.rawValue: NSNumber(value: 9),
      ], pid: 0)
    #expect(element.role == "StaticText")
  }

  @Test
  func roleFallsBackToRawStringForUnknownElementType() {
    let element = AXBridgeSnapshotDecoder.snapshot(fromNode: [AXWire.Node.elementType.rawValue: NSNumber(value: 9999)], pid: 0)
    #expect(element.role == "9999")
  }

  // `Any` is `XCUIElementType` 0 — a successful lookup, not a miss — so it must not short-circuit past the
  // concrete class name the read already carried.
  @Test
  func roleReportsTheConcreteElementTypeRatherThanAny() {
    let element = AXBridgeSnapshotDecoder.snapshot(
      fromNode: [
        AXWire.Node.automationType.rawValue: NSNumber(value: 0),
        AXWire.Node.elementType.rawValue: "AppRefreshControl",
      ], pid: 0)

    #expect(element.role == "AppRefreshControl")
  }

  // An automation type that resolves to no name (a stringified number) must also lose to the concrete class name.
  @Test
  func roleReportsTheConcreteElementTypeRatherThanAStringifiedAutomationType() {
    let element = AXBridgeSnapshotDecoder.snapshot(
      fromNode: [
        AXWire.Node.automationType.rawValue: NSNumber(value: 9999),
        AXWire.Node.elementType.rawValue: "AppRefreshControl",
      ], pid: 0)

    #expect(element.role == "AppRefreshControl")
  }

  // With nothing better than `Any`, report `Any` — not the literal string "0".
  @Test
  func roleStillReportsAnyWhenThereIsNoConcreteElementType() {
    let element = AXBridgeSnapshotDecoder.snapshot(fromNode: [AXWire.Node.automationType.rawValue: NSNumber(value: 0)], pid: 0)

    #expect(element.role == "Any")
  }

  // The mapping is partial by construction; a bare role number must not reach a caller as an `XCUIElementType` name.
  @Test
  func unidentifiedTranslatorRoleReportsNoType() {
    let element = AXBridgeSnapshotDecoder.snapshot(fromNode: [AXWire.Node.translatorRole.rawValue: NSNumber(value: 99)], pid: 0)
    #expect(element.role == nil, "an unidentified role must not surface as a number")
  }

  // A toggle is `CheckBox` and a search field is `TextField`: `Switch` and `SearchField` live in the subrole.
  @Test
  func translatorRolesAreMappedAcrossTheDecodedTable() {
    let cases: [(Int, String)] = [
      (1, "Application"), (2, "Button"), (3, "CheckBox"), (5, "Group"),
      (6, "Heading"), (14, "StaticText"), (15, "TextField"), (21, "Grid"),
    ]
    for (raw, expected) in cases {
      let element = AXBridgeSnapshotDecoder.snapshot(fromNode: [AXWire.Node.translatorRole.rawValue: NSNumber(value: raw)], pid: 0)
      #expect(element.role == expected, "translator role \(raw)")
    }
  }

  // Both refined names are in the interactable role set; neither bare role is.
  @Test
  func aSubroleRefinesTheRoleItAccompanies() {
    let toggle = AXBridgeSnapshotDecoder.snapshot(
      fromNode: [
        AXWire.Node.translatorRole.rawValue: NSNumber(value: 3),
        AXWire.Node.translatorSubrole.rawValue: NSNumber(value: 3),
      ], pid: 0)
    #expect(toggle.role == "Switch", "a toggle is a check box with a switch subrole")

    let search = AXBridgeSnapshotDecoder.snapshot(
      fromNode: [
        AXWire.Node.translatorRole.rawValue: NSNumber(value: 15),
        AXWire.Node.translatorSubrole.rawValue: NSNumber(value: 1),
      ], pid: 0)
    #expect(search.role == "SearchField", "a search field is a text field with a search subrole")
  }

  @Test
  func anUnidentifiedSubroleFallsBackToTheRole() {
    let element = AXBridgeSnapshotDecoder.snapshot(
      fromNode: [
        AXWire.Node.translatorRole.rawValue: NSNumber(value: 2),
        AXWire.Node.translatorSubrole.rawValue: NSNumber(value: 99),
      ], pid: 0)
    #expect(element.role == "Button")
  }

  @Test
  func xcuiElementTypeOutranksTheTranslatorRole() {
    let element = AXBridgeSnapshotDecoder.snapshot(
      fromNode: [
        AXWire.Node.automationType.rawValue: NSNumber(value: 48),
        AXWire.Node.translatorRole.rawValue: NSNumber(value: 2),
      ], pid: 0)
    #expect(element.role == "StaticText")
  }

  // Only a translator-vocabulary read carries `enabled` (under the reader's own key); every other read must stay
  // unknown rather than report a fabricated `false`.
  @Test
  func enabledIsReadFromATranslatorNodeAndStaysUnknownOnEveryOtherRead() {
    let translator = AXBridgeSnapshotDecoder.snapshot(fromNode: [AXWire.Node.isEnabled.rawValue: false], pid: 7)
    #expect(translator.isEnabled == false, "the translator's enabled answer must be reported")

    let xctest = AXBridgeSnapshotDecoder.snapshot(fromNode: [AXWire.Node.label.rawValue: "General"], pid: 7)
    #expect(xctest.isEnabled == nil, "a read carrying no enabled answer must stay unknown")
  }

  // Bits 18 and 21 are `TextEntry` and `IsEditing`: a focused text field.
  @Test
  func traitsAreDecodedFromTheBitmaskEitherVocabularyCarries() {
    let bitmask = NSNumber(value: UInt64(1 << 18 | 1 << 21))
    for key in ["XC_kAXXCAttributeTraits", AXWire.Node.traits.rawValue] {
      let element = AXBridgeSnapshotDecoder.snapshot(fromNode: [key: bitmask], pid: 0)
      #expect(element.traits.map(Set.init) == ["TextEntry", "IsEditing"], "\(key)")
    }
  }

  @Test
  func absentAttributesUseSafeDefaults() {
    let element = AXBridgeSnapshotDecoder.snapshot(fromNode: [:], pid: 0)

    #expect(element.label == nil)
    #expect(element.value == nil)
    #expect(element.role == nil)
    #expect(element.title == nil)
    #expect(element.traits == nil)
    #expect(element.frame == .zero)
    #expect(element.isEnabled == nil)
    #expect(element.isHidden == false)
    #expect(element.children.isEmpty)
    #expect(element.handle == nil, "a guest read has nothing to act through")
  }
}
