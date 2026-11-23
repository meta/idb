/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
import Foundation
import SimulatorFrameworkBridgeSupport
import Testing

/// Requests spelled as flat parameters, as the one-shot command line gives them.
@Suite
struct AccessibilityParametersTests {
  private let options = BridgeAXReadOptions(
    maxDepth: 7, maxNodes: 300, attributes: ["XC_kAXXCAttributeLabel"], explainUnreachable: true, traversal: .viewHierarchy, automationMode: false, clientType: .noClient)

  /// Every request beside the flat parameters that spell it.
  private var sentRequests: [(BridgeAXRequest, String)] {
    [
      (
        .read(pid: 42, options: options, displayID: 3),
        #"{"attributes":["XC_kAXXCAttributeLabel"],"automationMode":false,"clientType":0,"displayID":3,"explainUnreachable":true,"maxDepth":7,"maxNodes":300,"pid":42,"traversal":"view-hierarchy","verb":"describe"}"#
      ),
      (
        .read(pid: 42, options: BridgeAXReadOptions(maxDepth: 1, maxNodes: 2, attributes: nil, explainUnreachable: false, traversal: .semantic, automationMode: nil, clientType: .xctest)),
        #"{"clientType":4,"maxDepth":1,"maxNodes":2,"pid":42,"traversal":"semantic","verb":"describe"}"#
      ),
      (
        .read(pid: 42, options: BridgeAXReadOptions(maxDepth: 1, maxNodes: 2, attributes: nil, explainUnreachable: false, traversal: .singleFetch, automationMode: true, clientType: .noClient)),
        #"{"automationMode":true,"clientType":0,"maxDepth":1,"maxNodes":2,"pid":42,"traversal":"single-fetch","verb":"describe"}"#
      ),
      (
        .readFrontmost(x: 10.5, y: 20, method: .centerPoint, options: options),
        #"{"attributes":["XC_kAXXCAttributeLabel"],"automationMode":false,"clientType":0,"explainUnreachable":true,"maxDepth":7,"maxNodes":300,"method":"center-point","traversal":"view-hierarchy","verb":"describe","x":10.5,"y":20}"#
      ),
      (
        .readFrontmost(x: 0, y: 0, method: .runningBoard, options: options, displayID: 9),
        #"{"attributes":["XC_kAXXCAttributeLabel"],"automationMode":false,"clientType":0,"displayID":9,"explainUnreachable":true,"maxDepth":7,"maxNodes":300,"method":"runningboard","traversal":"view-hierarchy","verb":"describe","x":0,"y":0}"#
      ),
      (.hitTest(x: 1, y: 2, attributes: nil, clientType: .noClient), #"{"clientType":0,"verb":"hittest","x":1,"y":2}"#),
      (
        .hitTest(x: 1, y: 2, attributes: ["XC_kAXXCAttributeFrame"], clientType: .voiceOver, displayID: 4, pid: 77),
        #"{"attributes":["XC_kAXXCAttributeFrame"],"clientType":7,"displayID":4,"pid":77,"verb":"hittest","x":1,"y":2}"#
      ),
      (.write(BridgeAXWriteRequest(kind: .perform(.scrollDown), x: 3, y: 4, pid: nil, assertion: nil)), #"{"action":"scroll-down","verb":"perform","x":3,"y":4}"#),
      (
        .write(
          BridgeAXWriteRequest(
            kind: .setValue("hello"), x: 3, y: 4, pid: 12, assertion: BridgeAXWriteAssertion(key: .visiblePoint, value: "{1, 2}"), displayID: 5,
            attributes: ["XC_kAXXCAttributeVisiblePoint"])),
        #"{"assertKey":"XC_kAXXCAttributeVisiblePoint","assertValue":"{1, 2}","attributes":["XC_kAXXCAttributeVisiblePoint"],"displayID":5,"pid":12,"value":"hello","verb":"setvalue","x":3,"y":4}"#
      ),
      (.deviceSettingRead("voiceover"), #"{"setting":"voiceover","verb":"settings-get"}"#),
      (.deviceSettingWrite("reduce-motion", enabled: true), #"{"enabled":true,"setting":"reduce-motion","verb":"settings-set"}"#),
      (.deviceSettingChanges("reduce-motion"), #"{"setting":"reduce-motion","verb":"settings-observe"}"#),
      (.quiescence(pid: nil, busyThresholdMs: nil, quietWindowMs: nil), #"{"verb":"quiet"}"#),
      (
        .quiescence(pid: 8, busyThresholdMs: 5, quietWindowMs: 0, displayID: 2, method: .centerPoint, x: 6, y: 7),
        #"{"busyThresholdMs":5,"displayID":2,"method":"center-point","pid":8,"quietWindowMs":0,"verb":"quiet","x":6,"y":7}"#
      ),
      (.displays, #"{"verb":"displays"}"#),
    ]
  }

  @Test
  func everyRequestReadsFromItsParameters() throws {
    for (request, parameters) in sentRequests {
      #expect(try Self.request(parameters) == request, "\(parameters)")
    }
  }

  @Test
  func omittedReadFieldsTakeTheDefaults() throws {
    let request = try Self.request(#"{"verb":"describe","pid":5,"traversal":"view-hierarchy","clientType":0}"#)
    #expect(request == .read(pid: 5, options: Self.defaults(.viewHierarchy)))
  }

  @Test
  func eachTraversalDecodesFromItsNameAndStringFlagsReadAsFoundationDoes() throws {
    for traversal in BridgeAXTraversal.allCases {
      let request = try Self.request(#"{"verb":"describe","pid":5,"traversal":"\#(traversal.rawValue)","clientType":0,"explainUnreachable":"NO"}"#)
      guard case let .read(_, options, _) = request else {
        Issue.record("\(request)")
        return
      }
      #expect(options.traversal == traversal)
      #expect(!options.explainUnreachable)
    }
  }

  @Test
  func eachClientTypeDecodesFromItsIntegerOnReadsAndHitTests() throws {
    for clientType in BridgeAXClientType.allCases {
      guard case let .read(_, options, _) = try Self.request(#"{"verb":"describe","pid":5,"traversal":"semantic","clientType":\#(clientType.rawValue)}"#) else {
        Issue.record("not a read")
        return
      }
      #expect(options.clientType == clientType)
      guard case let .hitTest(_, _, _, hitClient, _, _) = try Self.request(#"{"verb":"hittest","x":1,"y":2,"clientType":\#(clientType.rawValue)}"#) else {
        Issue.record("not a hit-test")
        return
      }
      #expect(hitClient == clientType)
    }
  }

  @Test
  func anXCTestTraversalAcceptsOnlyNoClient() throws {
    for traversal in [BridgeAXTraversal.viewHierarchy, .singleFetch] {
      guard case let .read(_, options, _) = try Self.request(#"{"verb":"describe","pid":5,"traversal":"\#(traversal.rawValue)","clientType":0}"#) else {
        Issue.record("not a read")
        return
      }
      #expect(options.clientType == .noClient)
    }
  }

  @Test
  func aReadOrHitTestWithoutAClientTypeIsRefused() {
    for parameters in [#"{"verb":"describe","pid":5,"traversal":"semantic"}"#, #"{"verb":"hittest","x":1,"y":2}"#] {
      #expect(throws: BridgeAXRequestError.unsupportedClientType(nil), "\(parameters)") { try Self.request(parameters) }
    }
  }

  @Test
  func aReadWithoutATraversalIsRefused() {
    #expect(throws: BridgeAXRequestError.unsupportedTraversal(nil)) { try Self.request(#"{"verb":"describe","pid":5,"clientType":0}"#) }
  }

  @Test
  func nonStringAttributesAreDropped() throws {
    let request = try Self.request(#"{"verb":"hittest","x":1,"y":2,"clientType":0,"attributes":["a",3,"b"]}"#)
    #expect(request == .hitTest(x: 1, y: 2, attributes: ["a", "b"], clientType: .noClient))
  }

  // What the guest has always accepted beyond what the host sends: numbers in any JSON form, flags as strings, and
  // fields a verb does not use. A host is built with its guest, but a person can send these with the one-shot command.
  @Test
  func parametersDecodeAsLenientlyAsTheGuestHasAlwaysReadThem() throws {
    let point = #""x":1,"y":2,"clientType":0"#
    let cases: [(String, BridgeAXRequest)] = [
      (#"{"verb":"describe","pid":5.0,"traversal":"view-hierarchy","clientType":0}"#, .read(pid: 5, options: Self.defaults(.viewHierarchy))),
      (
        #"{"verb":"describe","pid":5,"traversal":"view-hierarchy","clientType":0,"maxDepth":7.9,"maxNodes":true}"#,
        .read(pid: 5, options: Self.defaults(.viewHierarchy, maxDepth: 7))
      ),
      (
        #"{"verb":"describe","pid":5,"traversal":"view-hierarchy","clientType":0,"explainUnreachable":"YES"}"#,
        .read(pid: 5, options: Self.defaults(.viewHierarchy, explainUnreachable: true))
      ),
      (
        #"{"verb":"describe","pid":5,"traversal":"view-hierarchy","clientType":0,"explainUnreachable":1}"#,
        .read(pid: 5, options: Self.defaults(.viewHierarchy, explainUnreachable: true))
      ),
      (
        #"{"verb":"describe","pid":5,"traversal":"view-hierarchy","clientType":0,"automationMode":1}"#,
        .read(pid: 5, options: Self.defaults(.viewHierarchy, automationMode: true))
      ),
      (
        #"{"verb":"describe","pid":5,"traversal":"view-hierarchy","clientType":0,"automationMode":"true"}"#,
        .read(pid: 5, options: Self.defaults(.viewHierarchy))
      ),
      (#"{"verb":"describe","pid":5,"traversal":"semantic","clientType":0,"explainUnreachable":{}}"#, .read(pid: 5, options: Self.defaults(.semantic))),
      (#"{"verb":"describe","pid":5,"traversal":"view-hierarchy","clientType":0,"displayID":3.0}"#, .read(pid: 5, options: Self.defaults(.viewHierarchy), displayID: 3)),
      (
        #"{"verb":"describe","x":1,"y":2,"traversal":"view-hierarchy","clientType":0}"#,
        .readFrontmost(x: 1, y: 2, method: .windowServer, options: Self.defaults(.viewHierarchy))
      ),
      (#"{"verb":"hittest",\#(point),"attributes":[]}"#, .hitTest(x: 1, y: 2, attributes: nil, clientType: .noClient)),
      (#"{"verb":"hittest",\#(point),"attributes":"a"}"#, .hitTest(x: 1, y: 2, attributes: nil, clientType: .noClient)),
      (#"{"verb":"hittest",\#(point),"pid":3,"setting":"ignored","value":"ignored"}"#, .hitTest(x: 1, y: 2, attributes: nil, clientType: .noClient, pid: 3)),
      (#"{"verb":"hittest","x":1.5,"y":-2,"clientType":0}"#, .hitTest(x: 1.5, y: -2, attributes: nil, clientType: .noClient)),
      (
        #"{"verb":"perform","action":"press","x":1,"y":2,"attributes":["a"]}"#,
        .write(BridgeAXWriteRequest(kind: .perform(.press), x: 1, y: 2, pid: nil, assertion: nil, attributes: ["a"]))
      ),
      (#"{"verb":"settings-set","setting":"voiceover","enabled":1}"#, .deviceSettingWrite("voiceover", enabled: true)),
      (#"{"verb":"settings-set","setting":"voiceover","enabled":0}"#, .deviceSettingWrite("voiceover", enabled: false)),
      (#"{"verb":"quiet","busyThresholdMs":5.5,"pid":2}"#, .quiescence(pid: 2, busyThresholdMs: 5, quietWindowMs: nil)),
      (#"{"verb":"quiet","method":"runningboard","x":3}"#, .quiescence(pid: nil, busyThresholdMs: nil, quietWindowMs: nil, method: .runningBoard)),
      (#"{"verb":"displays","pid":3}"#, .displays),
    ]
    for (parameters, expected) in cases {
      #expect(try Self.request(parameters) == expected, "\(parameters)")
    }
  }

  @Test
  func malformedPayloadsNameWhatIsWrong() {
    let point = #""x":1,"y":2"#
    let cases: [(String, BridgeAXRequestError)] = [
      (#"{}"#, .unsupportedVerb(nil)),
      (#"{"verb":3}"#, .unsupportedVerb(.integer(3))),
      (#"{"verb":"dance"}"#, .unsupportedVerb(.string("dance"))),
      (#"{"verb":1.5}"#, .unsupportedVerb(.number(1.5))),
      (#"{"verb":true}"#, .unsupportedVerb(.bool(true))),
      (#"{"verb":null}"#, .unsupportedVerb(.null)),
      (#"{"verb":["describe"]}"#, .unsupportedVerb(.array)),
      (#"{"verb":{"name":"describe"}}"#, .unsupportedVerb(.object)),
      (#"{"verb":"describe","pid":0}"#, .nonPositivePid(0)),
      (#"{"verb":"settings-get","pid":-4}"#, .nonPositivePid(-4)),
      (#"{"verb":"hittest",\#(point),"displayID":0}"#, .invalidDisplayID),
      (#"{"verb":"hittest",\#(point),"displayID":true}"#, .invalidDisplayID),
      (#"{"verb":"hittest",\#(point),"displayID":1.5}"#, .invalidDisplayID),
      (#"{"verb":"hittest",\#(point),"displayID":null}"#, .invalidDisplayID),
      (#"{"verb":"hittest","x":"left","y":2}"#, .missingPoint(.hitTest)),
      (#"{"verb":"hittest","x":true,"y":2,"clientType":0}"#, .missingPoint(.hitTest)),
      (#"{"verb":"describe","traversal":"view-hierarchy","clientType":0}"#, .missingPoint(.describe)),
      (#"{"verb":"describe",\#(point),"method":"guess","traversal":"view-hierarchy","clientType":0}"#, .unsupportedFrontmostMethod("guess")),
      (#"{"verb":"perform",\#(point)}"#, .unsupportedAction(nil)),
      (#"{"verb":"perform",\#(point),"action":"tap"}"#, .unsupportedAction(.string("tap"))),
      (#"{"verb":"perform","action":"press"}"#, .missingPoint(.perform)),
      (#"{"verb":"setvalue",\#(point),"value":1}"#, .missingValue),
      (#"{"verb":"setvalue",\#(point),"value":"v","assertKey":"XC_kAXXCAttributeLabel"}"#, .unpairedAssertion),
      (#"{"verb":"perform",\#(point),"action":"press","assertKey":"Nope","assertValue":"v"}"#, .unassertableKey("Nope")),
      (#"{"verb":"settings-get"}"#, .missingSetting),
      (#"{"verb":"settings-observe"}"#, .missingSetting),
      (#"{"verb":"settings-observe","setting":true}"#, .missingSetting),
      (#"{"verb":"settings-set","setting":"voiceover","enabled":"yes"}"#, .missingEnabled),
      (#"{"verb":"settings-set","setting":"voiceover"}"#, .missingEnabled),
      (#"{"verb":"quiet","busyThresholdMs":-1}"#, .negativeTunable(.busyThresholdMs, -1)),
      (#"{"verb":"quiet","quietWindowMs":-1}"#, .negativeTunable(.quietWindowMs, -1)),
      (#"{"verb":"quiet","method":"guess"}"#, .unsupportedFrontmostMethod("guess")),
      (#"{"verb":"describe","pid":5,"traversal":null}"#, .unsupportedTraversal(.null)),
      (#"{"verb":"describe","pid":5,"traversal":"sideways"}"#, .unsupportedTraversal(.string("sideways"))),
      (#"{"verb":"describe","pid":5,"traversal":"semantic","clientType":12}"#, .unsupportedClientType(.integer(12))),
      (#"{"verb":"describe","pid":5,"traversal":"view-hierarchy","clientType":4}"#, .clientTypeNeedsSemanticTraversal(.viewHierarchy)),
      (#"{"verb":"describe","pid":5,"traversal":"single-fetch","clientType":4}"#, .clientTypeNeedsSemanticTraversal(.singleFetch)),
      (#"{"verb":"describe","pid":5,"traversal":"semantic","clientType":"xctest"}"#, .unsupportedClientType(.string("xctest"))),
      (#"{"verb":"describe","pid":5,"clientType":0}"#, .unsupportedTraversal(nil)),
      (#"{"verb":"describe","pid":5,"traversal":"semantic"}"#, .unsupportedClientType(nil)),
      (#"{"verb":"hittest","x":1,"y":2}"#, .unsupportedClientType(nil)),
      (#"{"verb":"hittest","x":1,"y":2,"clientType":-1}"#, .unsupportedClientType(.integer(-1))),
      (#"{"verb":"describe","pid":5,"traversal":"view-hierarchy","clientType":0,"explainUnreachable":{}}"#, .malformedFlag(.explainUnreachable)),
    ]
    for (parameters, expected) in cases {
      #expect(throws: expected, "\(parameters)") { try Self.request(parameters) }
    }
  }

  /// The request `parameters`, a JSON object, spells.
  private static func request(_ parameters: String) throws(BridgeAXRequestError) -> BridgeAXRequest {
    try AccessibilityParameters.request(json: Data(parameters.utf8))
  }

  private static func defaults(
    _ traversal: BridgeAXTraversal, maxDepth: Int = BridgeAXReadOptions.defaultMaxDepth, explainUnreachable: Bool = false, automationMode: Bool? = nil
  ) -> BridgeAXReadOptions {
    BridgeAXReadOptions(
      maxDepth: maxDepth, maxNodes: BridgeAXReadOptions.defaultMaxNodes, attributes: nil, explainUnreachable: explainUnreachable, traversal: traversal,
      automationMode: automationMode, clientType: .noClient)
  }
}
