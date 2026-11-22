/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
@testable import FBSimulatorAX
import FBSimulatorBridgeProtocol
@testable import FBSimulatorControl
import XCTest

final class AXElementSnapshotTests: XCTestCase {

  // MARK: - Plans

  func testPlanForTheDefaultKeysNamesWhatTheSerializerConsumes() {
    let plan = AXReadPlan(keys: AXKeys.defaultSet, depth: .unlimited)
    XCTAssertEqual(
      plan.attributes,
      [.role, .label, .value, .identifier, .title, .help, .enabled, .customActions, .roleDescription, .subrole, .required, .traits])
  }

  func testTypeAloneStillPlansTheRole() {
    XCTAssertEqual(AXReadPlan(keys: [.type], depth: .unlimited).attributes, [.role])
  }

  func testInteractablePlansHittabilityAndItsExplanation() {
    XCTAssertEqual(AXReadPlan(keys: [.interactable], depth: .unlimited).attributes, [.hittability, .explainedBy])
  }

  func testOccludedByReadsWhatInteractableReads() {
    XCTAssertEqual(AXReadPlan(keys: [.occludedBy], depth: .unlimited).attributes, [.hittability, .explainedBy])
  }

  func testTheGuestFetchListFollowsThePlan() {
    XCTAssertNil(AXWire.Node.fetchList(for: AXReadPlan(keys: [.traits], depth: .unlimited)), "the default list fetches traits")
    XCTAssertEqual(
      AXWire.Node.fetchList(for: AXReadPlan(keys: [.label], depth: .unlimited)),
      AXWire.Node.defaultFetchList.filter { $0 != AXWire.Node.xcTraits.rawValue },
      "a plan without traits drops the bitmask")
    XCTAssertEqual(
      AXWire.Node.fetchList(for: AXReadPlan(keys: [.traits, .interactable], depth: .unlimited)),
      AXWire.Node.defaultFetchList + AXWire.Node.interactableAttributes.map(\.rawValue),
      "a plan reading hittability fetches what it is derived from")
  }

  func testKeysAnsweredWithoutAReadPlanNothing() {
    XCTAssertEqual(AXReadPlan(keys: [.frame, .frameDict, .pid, .isRemote], depth: .unlimited).attributes, [])
  }

  func testDepthCountsDownToTheLastLevel() {
    XCTAssertEqual(AXReadPlan.Depth.unlimited.descendant, .unlimited)
    XCTAssertEqual(AXReadPlan.Depth.limited(2).descendant, .limited(1))
    XCTAssertNil(AXReadPlan.Depth.limited(0).descendant)
  }
}
