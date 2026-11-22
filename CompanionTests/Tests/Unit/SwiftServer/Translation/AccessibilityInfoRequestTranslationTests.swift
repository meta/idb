/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBControlCore
import FBSimulatorAX
import FBSimulatorBridgeProtocol
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import Testing

/// Pins the `accessibility_info` request → framework translation and the legacy output byte shape.
@Suite
struct AccessibilityInfoRequestTranslationTests {

  // MARK: - Format mapping

  @Test
  func outputFormatMapsLegacyAndNested() {
    #expect((AccessibilityInfoRequestTranslation.outputFormat(from: .legacy)) == (.default))
    #expect((AccessibilityInfoRequestTranslation.outputFormat(from: .nested)) == (.nested))
  }

  @Test
  func unrecognizedFormatFallsBackToLegacy() {
    #expect((AccessibilityInfoRequestTranslation.outputFormat(from: .UNRECOGNIZED(99))) == (.default), "an unknown format from a newer client degrades to the historical output rather than failing the call")
  }

  @Test
  func completeFormatMapsThroughUnchanged() {
    #expect((AccessibilityInfoRequestTranslation.outputFormat(from: .complete)) == (.complete))
  }

  // MARK: - Searchable-key mapping

  @Test
  func searchableKeyMapsEveryWireValue() {
    let expected: [(Idb_AccessibilityActionRequest.SearchableKey, AXSearchableKey)] = [
      (.label, .label), (.uniqueID, .uniqueID), (.value, .value), (.title, .title),
      (.role, .role), (.roleDescription, .roleDescription), (.subrole, .subrole),
      (.help, .help), (.placeholder, .placeholder),
    ]
    #expect((expected.count) == (Idb_AccessibilityActionRequest.SearchableKey.allCases.count), "a searchable key added to the proto must be added to this map")
    for (wire, key) in expected {
      #expect((AccessibilityInfoRequestTranslation.searchableKey(from: wire)) == (key))
    }
  }

  @Test
  func unrecognizedSearchableKeyFallsBackToLabel() {
    #expect((AccessibilityInfoRequestTranslation.searchableKey(from: .UNRECOGNIZED(42))) == (.label))
  }

  // MARK: - Query construction

  @Test
  func emptyMarkerIsNotAMarkerQuery() {
    #expect((AccessibilityInfoRequestTranslation.markerQuery(from: .init())) == nil)
  }

  @Test
  func markerQueryCarriesValueKeyAndDepth() {
    var request = Idb_AccessibilityInfoRequest()
    request.marker = "Settings"
    request.matchKey = .uniqueID
    request.depth = 7
    #expect((AccessibilityInfoRequestTranslation.markerQuery(from: request)) == (.marker(value: "Settings", key: .uniqueID, depth: 7)))
  }

  @Test
  func markerQueryIsCaseSensitiveUnlessAsked() {
    var request = Idb_AccessibilityInfoRequest()
    request.marker = "ok"
    #expect(
      AccessibilityInfoRequestTranslation.markerQuery(from: request)
        == .marker(value: "ok", key: .label, depth: 0, ignoresCase: false)
    )
    request.ignoreCase = true
    #expect(
      AccessibilityInfoRequestTranslation.markerQuery(from: request)
        == .marker(value: "ok", key: .label, depth: 0, ignoresCase: true)
    )
  }

  // MARK: - Match construction

  @Test
  func emptyMatchIsNotAMatch() {
    #expect(
      AccessibilityInfoRequestTranslation.match(from: .init()) == nil,
      "an empty substring is contained in every value, so it is the absence of a narrowing rather than one that keeps everything"
    )
  }

  @Test
  func matchCarriesValueKeyAndCaseSensitivity() throws {
    var request = Idb_AccessibilityInfoRequest()
    request.match = "Cart"
    request.matchKey = .value
    request.ignoreCase = true
    let match = try #require(AccessibilityInfoRequestTranslation.match(from: request))
    #expect(match.value == "Cart")
    #expect(match.key == .value)
    #expect(match.ignoresCase)
  }

  @Test
  func matchDefaultsToTheLabelAndToCaseSensitivity() throws {
    var request = Idb_AccessibilityInfoRequest()
    request.match = "Cart"
    let match = try #require(AccessibilityInfoRequestTranslation.match(from: request))
    #expect(match.key == .label)
    #expect(!match.ignoresCase)
  }

  @Test
  func unrecognizedMatchKeyFallsBackToLabel() throws {
    var request = Idb_AccessibilityInfoRequest()
    request.match = "Cart"
    request.matchKey = .UNRECOGNIZED(42)
    let match = try #require(AccessibilityInfoRequestTranslation.match(from: request))
    #expect(
      match.key == .label,
      "a key a newer client knows and this companion does not degrades to the default search rather than failing the call"
    )
  }

  // MARK: - Filter selection

  @Test
  func filterMapsEveryWireValue() {
    let expected: [(Idb_AccessibilityInfoRequest.Filter, AccessibilityElementFilter)] = [
      (.all, .all), (.interactable, .interactable),
    ]
    #expect(
      expected.count == Idb_AccessibilityInfoRequest.Filter.allCases.count,
      "a filter added to the proto must be added to this map"
    )
    for (wire, filter) in expected {
      #expect(AccessibilityInfoRequestTranslation.filter(from: wire) == filter)
    }
  }

  @Test
  func unsetAndUnrecognizedFiltersBothReadEverything() {
    #expect(AccessibilityInfoRequestTranslation.filter(from: Idb_AccessibilityInfoRequest().filter) == .all)
    #expect(AccessibilityInfoRequestTranslation.filter(from: .UNRECOGNIZED(9)) == .all)
  }

  @Test
  func optionsCarryTheFilterAndTheMatch() throws {
    var request = Idb_AccessibilityInfoRequest()
    request.match = "Cart"
    request.filter = .interactable
    let options = try AccessibilityInfoRequestTranslation.options(from: request, format: .complete)
    #expect(options.filter == .interactable)
    #expect(options.match?.value == "Cart")
  }

  @Test
  func optionsDefaultToAnUnnarrowedRead() throws {
    let options = try AccessibilityInfoRequestTranslation.options(from: .init(), format: .default)
    #expect(options.filter == .all)
    #expect(options.match == nil)
  }

  // MARK: - Validation

  @Test
  func markerAndMatchTogetherAreRejected() {
    var request = Idb_AccessibilityInfoRequest()
    request.marker = "Login"
    request.match = "Cart"
    do {
      try AccessibilityInfoRequestTranslation.validate(request)
      Issue.record("expected an invalidArgument RPCError")
    } catch let status as RPCError {
      #expect(
        status.code == .invalidArgument,
        "the two select elements by different rules, and there is no reading of both that is not a guess at which the caller meant"
      )
    } catch {
      Issue.record("expected RPCError, got \(error)")
    }
  }

  @Test
  func eitherMarkerOrMatchAloneIsAccepted() throws {
    var marker = Idb_AccessibilityInfoRequest()
    marker.marker = "Login"
    try AccessibilityInfoRequestTranslation.validate(marker)
    var match = Idb_AccessibilityInfoRequest()
    match.match = "Cart"
    try AccessibilityInfoRequestTranslation.validate(match)
    try AccessibilityInfoRequestTranslation.validate(.init())
  }

  // MARK: - Point

  @Test
  func noPointMeansFrontmost() {
    #expect((AccessibilityInfoRequestTranslation.point(from: .init())) == nil)
  }

  @Test
  func pointRoundTrips() throws {
    var request = Idb_AccessibilityInfoRequest()
    request.point = .with {
      $0.x = 12
      $0.y = 34
    }
    let value = try #require(AccessibilityInfoRequestTranslation.point(from: request))
    #expect((value.pointValue) == (NSPoint(x: 12, y: 34)))
  }

  // MARK: - Keys

  @Test
  func emptyKeysSelectTheDefaultSet() throws {
    let options = try AccessibilityInfoRequestTranslation.options(from: .init(), format: .default)
    #expect((options.keys) == (AXKeys.defaultSet))
  }

  @Test
  func unrecognizedKeysInAPartiallyValidListAreDropped() throws {
    var request = Idb_AccessibilityInfoRequest()
    request.keys = ["AXLabel", "not-a-key"]
    let options = try AccessibilityInfoRequestTranslation.options(from: request, format: .default)
    let label = try #require(AXKeys(rawValue: "AXLabel"))
    #expect((options.keys) == (Set([label])), "deliberately lenient: invalid keys drop silently as long as one key is recognized")
  }

  @Test
  func allInvalidKeysAreRejected() {
    var request = Idb_AccessibilityInfoRequest()
    request.keys = ["not-a-key", "also-not-a-key"]
    do {
      _ = try AccessibilityInfoRequestTranslation.options(from: request, format: .default)
      Issue.record("expected an invalidArgument RPCError")
    } catch let status as RPCError {
      #expect(status.code == .invalidArgument)
    } catch {
      Issue.record("expected RPCError, got \(error)")
    }
  }

  @Test
  func optionsPinTheHandlerDefaults() throws {
    let options = try AccessibilityInfoRequestTranslation.options(from: .init(), format: .nested)
    #expect((options.format) == (.nested))
    #expect(!(options.enableProfiling), "profiling is collected only when the request asks")
    #expect(!(options.collectFrameCoverage), "frame coverage is collected only when the request asks")
  }

  @Test
  func optionsForwardProfilingAndFrameCoverageFlags() throws {
    var request = Idb_AccessibilityInfoRequest()
    request.profile = true
    request.collectFrameCoverage = true
    let options = try AccessibilityInfoRequestTranslation.options(from: request, format: .complete)
    #expect((options.enableProfiling))
    #expect((options.collectFrameCoverage))
  }

  // MARK: - Backend selection

  @Test
  func unspecifiedBackendDefaultsToAccessibilityBackend() {
    #expect((AccessibilityInfoRequestTranslation.backend(from: .unspecified)) == (.accessibility))
  }

  @Test
  func backendMapsWireValuesToFrameworkBackends() {
    #expect((AccessibilityInfoRequestTranslation.backend(from: .ax)) == (.accessibility))
    #expect((AccessibilityInfoRequestTranslation.backend(from: .axCoresimulator)) == (.coreSimulatorAccessibility))
    #expect((AccessibilityInfoRequestTranslation.backend(from: .axbridge)) == (.axBridge(persistence: .exclusive, frontmostMethod: .windowServer, automationMode: true)), "axbridge must select the companion-owned transport")
    #expect((AccessibilityInfoRequestTranslation.backend(from: .axbridgePersistent)) == (.axBridge(persistence: .exclusive, frontmostMethod: .windowServer, automationMode: true)), "the historical wire value must select the same companion-owned transport")

  }

  @Test
  func unrecognizedBackendDefaultsToAccessibilityBackend() {
    #expect((AccessibilityInfoRequestTranslation.backend(from: .UNRECOGNIZED(9))) == (.accessibility))
  }

  // MARK: - Requesting client

  @Test
  func unspecifiedClientTypeNamesNoClient() throws {
    let options = try AccessibilityInfoRequestTranslation.options(from: Idb_AccessibilityInfoRequest(), format: .default)
    #expect(options.clientType == nil)
    #expect(options.resolvedClientType == AccessibilityRequestOptions().resolvedClientType)
  }

  @Test
  func everyWireClientTypeMapsToTheClientOfTheSameName() throws {
    let expected: [(Idb_AccessibilityInfoRequest.ClientType, String)] = [
      (.noClient, "noClient"), (.unidentified, "unidentified"), (.application, "application"), (.xcodeHelper, "xcodeHelper"),
      (.xctest, "xctest"), (.scripter, "scripter"), (.systemEvents, "systemEvents"), (.voiceOver, "voiceOver"),
      (.switchControl, "switchControl"), (.fullKeyboardAccess, "fullKeyboardAccess"), (.voiceControl, "voiceControl"),
      (.accessibilityInspector, "accessibilityInspector"),
    ]
    #expect(expected.count == AXClientType.allCases.count, "every client type is reachable over the wire")
    for (wire, name) in expected {
      var request = Idb_AccessibilityInfoRequest()
      request.clientType = wire
      #expect(try AccessibilityInfoRequestTranslation.options(from: request, format: .default).clientType?.name == name)
    }
  }

  @Test
  func unrecognizedClientTypeIsRefused() {
    var request = Idb_AccessibilityInfoRequest()
    request.clientType = .UNRECOGNIZED(99)
    #expect(throws: RPCError.self) { try AccessibilityInfoRequestTranslation.options(from: request, format: .default) }
  }

  // MARK: - Legacy output shape

  @Test
  func treeSerializesAsABareArray() throws {
    let response = AccessibilityElementsResponse(elements: .tree([AccessibilityDocumentElement()]))
    let data = try AccessibilityInfoRequestTranslation.legacyJSON(from: response)
    #expect((String(data: data, encoding: .utf8)) == ("[{}]"), "point/frontmost reads emit the bare element array — not the {\"elements\":…} envelope the marker path uses")
  }

  @Test
  func singleSerializesAsABareObject() throws {
    let response = AccessibilityElementsResponse(elements: .single(AccessibilityDocumentElement()))
    let data = try AccessibilityInfoRequestTranslation.legacyJSON(from: response)
    #expect((String(data: data, encoding: .utf8)) == ("{}"))
  }

  @Test
  func responseJSONKeepsTheLegacyShapesByteIdentical() throws {
    let response = AccessibilityElementsResponse(elements: .tree([AccessibilityDocumentElement()]))
    for format in [AccessibilityOutputFormat.default, .nested] {
      #expect((try AccessibilityInfoRequestTranslation.responseJSON(from: response, format: format)) == (try AccessibilityInfoRequestTranslation.legacyJSON(from: response)), "the legacy formats are byte-untouched by the format-aware encoder")
    }
  }

  @Test
  func responseJSONEmitsTheCompleteDocument() throws {
    let response = AccessibilityElementsResponse(elements: .tree([AccessibilityDocumentElement()]), backend: .ax)
    let data = try AccessibilityInfoRequestTranslation.responseJSON(from: response, format: .complete)
    let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((document["backend"] as? String) == ("ax"))
    #expect((document["elements"]) != nil, "the complete document is the client-detectable shape: an object naming the backend that served it")
  }

  @Test
  func theAllTokenExpandsToEveryKey() throws {
    var request = Idb_AccessibilityInfoRequest()
    request.keys = [AXKeys.everythingToken]
    let options = try AccessibilityInfoRequestTranslation.options(from: request, format: .default)
    #expect((options.keys) == (AXKeys.everything))
  }

  // `all` beside a named key still means all; intersecting would return less than either alone.
  @Test
  func theAllTokenWinsOverKeysNamedBesideIt() throws {
    var request = Idb_AccessibilityInfoRequest()
    request.keys = ["AXLabel", AXKeys.everythingToken]
    let options = try AccessibilityInfoRequestTranslation.options(from: request, format: .default)
    #expect((options.keys) == (AXKeys.everything))
  }

  @Test
  func theAllTokenIsNotItselfAKey() {
    #expect((AXKeys(rawValue: AXKeys.everythingToken)) == nil)
  }

}
