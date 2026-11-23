/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
import Foundation
import SimulatorFrameworkBridgeRuntime
import SimulatorFrameworkBridgeSupport
import XCTest

final class AccessibilityExceptionTests: XCTestCase {
  override func tearDown() {
    FBAXClientProvider.setRuntimeForTesting(nil)
    super.tearDown()
  }

  func testEveryRuntimeExceptionStopsTheRequestAndAllowsTheNextRequest() {
    let describe: [String: Any] = ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": 4321]
    let snapshot: [String: Any] = [
      "verb": "describe", "clientType": 0, "pid": 4321, "traversal": "single-fetch",
      "attributes": ["XC_kAXXCAttributeLabel", "XC_kAXXCAttributeFrame", "XC_kAXXCAttributeVisiblePoint"],
    ]
    let cases: [(String, [String: Any])] = [
      ("applicationElement", describe),
      ("readAttributes", describe),
      ("snapshot", snapshot),
      ("snapshotOwner", snapshot),
      ("snapshotContinuation", snapshot),
      ("getRect", snapshot),
      ("getPoint", snapshot),
      ("hitTest", ["verb": "hittest", "clientType": 0, "x": 1, "y": 2]),
      ("performAction", ["verb": "perform", "x": 1, "y": 2, "action": "press"]),
      ("setValue", ["verb": "setvalue", "x": 1, "y": 2, "value": "changed"]),
      ("windowServerFrontmost", ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": 1, "y": 2, "method": "window-server"]),
      ("runningBoardFrontmost", ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": 1, "y": 2, "method": "runningboard"]),
      ("translatorAttributes", ["verb": "describe", "clientType": 0, "pid": 4321, "traversal": "semantic"]),
      ("automationRead", describe),
      ("automationWrite", ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": 4321, "automationMode": true]),
      ("settingRead", ["verb": "settings-get", "setting": "reduce-motion"]),
      ("settingWrite", ["verb": "settings-set", "setting": "reduce-motion", "enabled": true]),
    ]
    for (operation, request) in cases {
      let runtime = seededRuntime()
      FBAXClientProvider.setRuntimeForTesting(runtime)
      runtime.raiseOnOperation = operation

      XCTAssertEqual(AccessibilityService.handleRequest(request) as NSDictionary, exceptionResponse("injected \(operation)"), operation)
      XCTAssertEqual(runtime.operations.lastObject as? String, operation)

      runtime.raiseOnOperation = nil
      XCTAssertEqual(AccessibilityService.handleRequest(request)["ok"] as? NSNumber, true, operation)
    }
  }

  func testChildExceptionAbortsTheWholeTreeAndNextReadRecovers() {
    let runtime = seededRuntime()
    let root = runtime.applicationElements[4321] as? FBAXFakeElement
    let child = root?.children.first
    child?.readRaiseReason = "child disappeared"
    FBAXClientProvider.setRuntimeForTesting(runtime)
    let request: [String: Any] = ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": 4321]

    XCTAssertEqual(AccessibilityService.handleRequest(request) as NSDictionary, exceptionResponse("child disappeared"))
    XCTAssertEqual(runtime.operations.lastObject as? String, "readAttributes")

    child?.readRaiseReason = nil
    let response = AccessibilityService.handleRequest(request)
    XCTAssertEqual(response["ok"] as? NSNumber, true)
    let tree = response["tree"] as? [String: Any]
    let children = tree?["XC_kAXXCAttributeChildren"] as? [[String: Any]]
    XCTAssertEqual(children?.first?["XC_kAXXCAttributeLabel"] as? String, "child")
  }

  func testAssertionReadExceptionPreventsBothKindsOfWrite() {
    for verb in ["perform", "setvalue"] {
      let runtime = seededRuntime()
      runtime.raiseOnOperation = "readAttributes"
      FBAXClientProvider.setRuntimeForTesting(runtime)
      let request: [String: Any] = [
        "verb": verb, "x": 1, "y": 2, "action": "press", "value": "changed",
        "assertKey": "XC_kAXXCAttributeLabel", "assertValue": "root",
      ]

      XCTAssertEqual(AccessibilityService.handleRequest(request) as NSDictionary, exceptionResponse("injected readAttributes"))
      XCTAssertEqual(runtime.hitTestCount, 1)
      XCTAssertEqual(runtime.performCount, 0)
      XCTAssertEqual(runtime.setValueCount, 0)
      XCTAssertEqual(runtime.operations as NSArray, ["hitTest", "readAttributes"] as NSArray)
    }
  }

  private func exceptionResponse(_ reason: String) -> NSDictionary {
    ["ok": false, "error": "the reader raised while answering: \(reason)"]
  }

  private func seededRuntime() -> FBAXFakeRuntime {
    let runtime = FBAXFakeRuntime()
    let root = FBAXFakeElement.readable("root")
    root.owningProcessIdentifier = 4321
    root.attributes = [
      "XC_kAXXCAttributeLabel": "root",
      "XC_kAXXCAttributeFrame": FBAXFakeRectValue.withRect(CGRect(x: 1, y: 2, width: 3, height: 4)),
      "XC_kAXXCAttributeVisiblePoint": FBAXFakePointValue.withPoint(CGPoint(x: 2, y: 3)),
    ]
    let child = FBAXFakeElement.readable("child")
    child.owningProcessIdentifier = 8765
    let grandchild = FBAXFakeElement.readable("grandchild")
    grandchild.owningProcessIdentifier = 8765
    child.children = [grandchild]
    root.children = [child]
    runtime.applicationElements[4321] = root
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(root, owningProcessIdentifier: 4321)
    runtime.windowServerOutcome = FBAXFrontmostOutcome.resolved(4321)
    runtime.runningBoardOutcome = FBAXFrontmostOutcome.resolved(4321)
    runtime.translatorAttributeValues = [NSNumber(value: BridgeAXTranslatorAttribute.label.rawValue): "root"]
    runtime.deviceSettings[NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)] = false
    return runtime
  }
}
