/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBSimulatorBridgeProtocol
import Foundation
@_implementationOnly import SimulatorFrameworkBridgeSupport
import Testing

@Suite
struct AccessibilityServiceTests {

  /// The fields of the answer `data` encodes.
  private static func FBAXTestsParse(data: Data) -> NSDictionary? {
    (try? JSONDecoder().decode(BridgeAXAnswer.self, from: data)).map { answerFields($0) as NSDictionary }
  }

  private static func FBAXTestsTree(_ node: BridgeAXNode) -> BridgeAXAnswer {
    .tree(BridgeAXTreeResponse(tree: node, pid: 1, truncated: false))
  }

  // A non-finite coordinate has no JSON form; the answer still encodes, without that edge.
  @Test
  func infiniteFrameValueIsLeftOut() {
    var node = BridgeAXNode()
    node.label = .string("icon")
    node.frame = BridgeAXRect(x: .infinity, y: 0, width: 10, height: 20)
    let parsed = Self.FBAXTestsParse(data: Self.FBAXTestsTree(node).encoded())
    #expect(parsed?["ok"] as? NSNumber == NSNumber(value: true))
    let tree = parsed?["tree"] as? NSDictionary
    let frame = tree?["XC_kAXXCAttributeFrame"] as? NSDictionary
    #expect(frame?["X"] == nil, "the non-finite member must be left out")
    #expect(frame?["Height"] as? NSNumber == 20, "finite members must be preserved")
    #expect(tree?["XC_kAXXCAttributeLabel"] as? String == "icon", "the rest of the node must survive")
  }

  // An answer that cannot be encoded must still reach the host as a failure it can read, never abort the guest
  // and sever the connection.
  @Test
  func unencodableAnswerYieldsAnErrorFrameRatherThanRaising() {
    var node = BridgeAXNode()
    node.value = .number(.nan)
    let parsed = Self.FBAXTestsParse(data: Self.FBAXTestsTree(node).encoded())
    #expect(parsed?["ok"] as? NSNumber == NSNumber(value: false))
    #expect(parsed?["error"] != nil)
  }

  @Test
  func nonStringVerbIsRejectedWithAnErrorFrame() {
    for verb in [123, ["a": 1], ["describe"], NSNull()] as [Any] {
      let response = AccessibilityService.handleRequest(["verb": verb])
      #expect(response["ok"] as? NSNumber == NSNumber(value: false), "a \(type(of: verb)) verb must be rejected")
      #expect(response["error"] is String, "a \(type(of: verb)) verb must carry an error message")
      #expect(response["error_kind"] as? String == "bad_request", "a \(type(of: verb)) verb")
    }
  }

  // `nil` takes `isEqualToString:` without complaint and matches no verb.
  @Test
  func missingVerbIsRejectedWithAnErrorFrame() {
    let response = AccessibilityService.handleRequest(["pid": 1234])
    #expect(response["ok"] as? NSNumber == NSNumber(value: false))
    #expect(response["error"] as? String == "unsupported verb: (nil)")
    #expect(response["error_kind"] as? String == "bad_request")
  }

  // The host maps `application_unavailable` onto a typed error, so a pid that names no process must carry
  // that kind on every verb.
  @Test
  func nonPositivePidIsReportedAsAnUnavailableApplication() {
    let requests: [[String: Any]] = [["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": 0], ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": (-1) as NSNumber], ["verb": "hittest", "clientType": 0, "pid": 0, "x": 200, "y": 400], ["verb": "hittest", "clientType": 0, "pid": (-1) as NSNumber, "x": 200, "y": 400], ["verb": "perform", "pid": 0, "x": 200, "y": 400, "action": "press"], ["verb": "perform", "pid": (-1) as NSNumber, "x": 200, "y": 400, "action": "press"], ["verb": "setvalue", "pid": 0, "x": 200, "y": 400, "value": "hello"], ["verb": "setvalue", "pid": (-1) as NSNumber, "x": 200, "y": 400, "value": "hello"]]
    for request in requests {
      let response = AccessibilityService.handleRequest(request)
      #expect(response["ok"] as? NSNumber == NSNumber(value: false), "\(String(describing: request))")
      #expect(
        response["error_kind"] as? String == "application_unavailable",
        "\(String(describing: request))"
      )
      #expect(response["pid"] as? NSNumber == request["pid"] as? NSNumber, "the rejected pid must be named back")
    }
  }

  // MARK: - Wire contract

  // Pins the spellings the guest sends to the literals the host pins in `AXWireContractTests`, so a rename in
  // the shared vocabulary cannot change the wire unnoticed.
  @Test
  func guestWireConstantsMatchTheHostContract() {
    let expected = [
      "node.elementType": "XC_kAXXCAttributeElementType", "node.elementBaseType": "XC_kAXXCAttributeElementBaseType", "node.label": "XC_kAXXCAttributeLabel", "node.value": "XC_kAXXCAttributeValue", "node.identifier": "XC_kAXXCAttributeIdentifier", "node.frame": "XC_kAXXCAttributeFrame", "node.automationType": "XC_kAXXCAttributeAutomationType", "node.children": "XC_kAXXCAttributeChildren", "node.windowDisplayID": "XC_kAXXCAttributeWindowDisplayId", "request.verb": "verb", "request.pid": "pid", "request.maxDepth": "maxDepth", "request.maxNodes": "maxNodes", "request.automationMode": "automationMode", "request.attributes": "attributes", "request.traversal": "traversal", "request.clientType": "clientType", "request.explainUnreachable": "explainUnreachable", "node.explainedBy": "FBExplainedBy", "node.isEnabled": "FBIsEnabled", "node.translatorRole": "FBTranslatorRole", "node.translatorSubrole": "FBTranslatorSubrole", "node.traits": "FBTraits", "node.elementIdentity": "FBElementIdentity", "request.displayID": "displayID", "request.x": "x", "request.y": "y", "request.method": "method", "request.action": "action", "request.value": "value", "request.setting": "setting", "request.enabled": "enabled", "request.assertKey": "assertKey", "request.assertValue": "assertValue", "request.busyThresholdMs": "busyThresholdMs", "request.quietWindowMs": "quietWindowMs", "envelope.ok": "ok", "envelope.enabled": "enabled", "envelope.tree": "tree", "envelope.error": "error", "envelope.empty": "empty", "envelope.errorKind": "error_kind", "envelope.errorKindApplicationUnavailable": "application_unavailable", "envelope.errorKindApplicationNotResponding": "application_not_responding", "envelope.errorKindFrontmostUnresolved": "frontmost_unresolved", "envelope.errorKindCapabilityUnavailable": "capability_unavailable", "envelope.errorKindReaderUnavailable": "reader_unavailable", "envelope.errorKindBadRequest": "bad_request", "envelope.errorKindAssertionFailed": "assertion_failed",
      "envelope.truncated": "truncated", "envelope.pid": "pid", "envelope.method": "method",
      "envelope.modal": "modal", "envelope.automation": "automation",
      "envelope.phases": "phases",
      "phases.traverse": "traverse_ms",
      "phases.machRoundTrips": "mach_round_trips",
      "automation.enabled": "enabled", "automation.asserted": "asserted", "modal.kind": "kind", "modal.kindSystem": "system", "modal.kindApp": "app", "modal.elementType": "elementType", "modal.label": "label", "modal.systemAlertWindowClass": "SBAlertItemWindow", "modal.alertControllerClassPrefix": "_UIAlertController", "verb.displays": "displays", "verb.describe": "describe", "verb.hittest": "hittest", "verb.perform": "perform", "verb.setvalue": "setvalue", "verb.settingsGet": "settings-get", "verb.settingsSet": "settings-set", "verb.settingsObserve": "settings-observe", "verb.quiet": "quiet", "action.press": "press", "action.scrollUp": "scroll-up", "action.scrollDown": "scroll-down", "action.scrollLeft": "scroll-left", "action.scrollRight": "scroll-right", "action.scrollToVisible": "scroll-to-visible", "method.centerPoint": "center-point", "method.windowServer": "window-server", "method.runningBoard": "runningboard",
    ]
    // Whole-dictionary equality also fails on any guest constant this test forgot to pin (or any removed),
    // not just a changed value.
    #expect(AccessibilityService.wireConstantsForTesting() == expected)
  }

  // MARK: - Modal detection

  private func node(_ elementType: String, label: String? = nil, children: [BridgeAXNode] = []) -> BridgeAXNode {
    var node = BridgeAXNode()
    node.elementType = .string(elementType)
    node.label = label.map(BridgeAXScalar.string)
    node.children = children
    return node
  }

  @Test
  func modalDescriptorReportsSystemAlertWindowAsSystemKind() {
    let tree = node("UIApplication", label: "root", children: [node("SBAlertItemWindow")])
    #expect(AccessibilityService.modal(in: tree) == BridgeAXModal(kind: .system, elementType: "SBAlertItemWindow", label: nil))
  }

  // `_UIAlertController*` is matched by prefix; the concrete class varies.
  @Test
  func modalDescriptorReportsAlertControllerAsAppKindWithElementTypeAndLabel() {
    let tree = node("UIApplication", label: "root", children: [node("_UIAlertControllerView", label: "Delete this item?")])
    #expect(AccessibilityService.modal(in: tree) == BridgeAXModal(kind: .app, elementType: "_UIAlertControllerView", label: "Delete this item?"))
  }

  @Test
  func modalDescriptorPrefersSystemKindWhenBothAlertsPresent() {
    let tree = node(
      "UIApplication", label: "root", children: [node("SBAlertItemWindow"), node("_UIAlertControllerView", label: "Allow")])
    #expect(
      AccessibilityService.modal(in: tree) == BridgeAXModal(kind: .system, elementType: "_UIAlertControllerView", label: "Allow"),
      "a system alert window wins over an app alert, and the captured alert-controller class is still reported")
  }

  @Test
  func modalDescriptorReturnsNilWhenNoAlertPresent() {
    let tree = node("UIApplication", label: "root", children: [node("XCUIElementTypeButton", label: "OK")])
    #expect(AccessibilityService.modal(in: tree) == nil)
  }

  // The one-shot command line builds its request from flags. One that does not decode prints the failure, as one sent
  // over a socket is answered, and exits non-zero, for a unary verb and a streaming one alike.
  @Test
  func aCommandLineRequestThatDoesNotDecodePrintsItsFailure() throws {
    let cases: [(String, [String], String)] = [
      ("hittest", ["--x", "1", "--y", "2"], "a read or hit-test requires a client type: an integer from 0 to 11"),
      ("perform", ["--x", "1", "--y", "2", "--action", "tap"], "unsupported action: tap"),
      ("settings-set", ["--setting", "voiceover", "--enabled", "maybe"], "settings-set requires a boolean enabled value"),
      ("quiet", ["--busy-threshold-ms", "-1"], "busyThresholdMs must not be negative, got -1"),
      ("settings-observe", [], "device settings require a setting name"),
    ]
    for (action, arguments, message) in cases {
      var written: [Data] = []
      let status = AccessibilityService.handleAction(action, arguments: arguments) {
        written.append($0)
        return true
      }
      #expect(status == 1, "\(action)")
      #expect(written.count == 1, "\(action)")
      let answer = try #require(written.first.flatMap(Self.FBAXTestsParse(data:)), "\(action)")
      #expect(answer == ["ok": false, "error_kind": "bad_request", "error": message] as NSDictionary, "\(action)")
    }
  }
}
