/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorAX
import FBSimulatorBridgeProtocol
@testable import FBSimulatorControl
import Foundation
import XCTest

/// `interactable` over every condition it can report.
///
/// Driven through the real serializer against a guest-shaped attribute tree, so what is covered is the
/// derivation as a read actually performs it — not a hand-built sum-type value.
final class AXInteractableTests: XCTestCase {

  private static let occluderFrame = CGRect(x: 0, y: 791, width: 402, height: 83)

  /// A node in the shape the guest emits, with only the attributes a case needs.
  private static func node(
    frame: CGRect = CGRect(x: 134.33, y: 705, width: 133.33, height: 178.67),
    isVisible: Bool? = true,
    visiblePoint: CGPoint? = CGPoint(x: 201, y: 794.33),
    centrePoint: CGPoint? = CGPoint(x: 201, y: 794.33),
    userInteractionEnabled: Bool? = true
  ) -> [String: Any] {
    var node: [String: Any] = [
      AXWire.Node.label.rawValue: "Explore Grid Cell",
      AXWire.Node.identifier.rawValue: "media-thumbnail-cell",
      AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(frame) as NSDictionary,
    ]
    if let isVisible {
      node[AXWire.Node.isVisible.rawValue] = isVisible
    }
    if let visiblePoint {
      node[AXWire.Node.visiblePoint.rawValue] = CGPointCreateDictionaryRepresentation(visiblePoint) as NSDictionary
    }
    if let centrePoint {
      node[AXWire.Node.centerPoint.rawValue] = CGPointCreateDictionaryRepresentation(centrePoint) as NSDictionary
    }
    if let userInteractionEnabled {
      node[AXWire.Node.userInteractionEnabled.rawValue] = userInteractionEnabled
    }
    return node
  }

  private static func interactable(_ node: [String: Any]) -> AccessibilityInteractable?? {
    AXTreeWalk.describeAllElements(
      fromTree: node, keys: [.interactable], nestedFormat: false, pid: 13515
    ).first?.interactable
  }

  // MARK: - Actionable

  // The point the accessibility server reports, not the frame centre — those coincide here.
  func testAnUnobstructedElementIsActionableAtItsReachablePoint() throws {
    let value = try XCTUnwrap(Self.interactable(Self.node()) ?? nil)
    XCTAssertEqual(value, .actionable(at: AccessibilityPoint(x: 201, y: 794.33)))
  }

  // MARK: - Blocked

  // Numbers measured on a real Explore grid: the tab bar covers the bottom of the cell, so the reachable point is
  // 4.83pt above the centre.
  func testAnElementWhoseCentreIsCoveredIsActionableAtTheReachablePoint() throws {
    let value = try XCTUnwrap(
      Self.interactable(
        Self.node(visiblePoint: CGPoint(x: 201, y: 789.5), centrePoint: CGPoint(x: 201, y: 794.33))
      ) ?? nil
    )
    XCTAssertEqual(value, .actionable(at: AccessibilityPoint(x: 201, y: 789.5)))
  }

  // No reachable point at all. The `(-1, -1)` sentinel the runtime reports must not surface as a point.
  func testAnElementWithNoReachablePointIsBlockedAsNotHittable() throws {
    let value = try XCTUnwrap(
      Self.interactable(Self.node(isVisible: false, visiblePoint: CGPoint(x: -1, y: -1))) ?? nil
    )
    XCTAssertEqual(value, .blocked(reasons: [.notHittable]))
  }

  // There is no `enabled` attribute in the `XC_kAXXCAttribute*` namespace (`IsUserInteractionEnabled` answers a
  // different question), so a guest-backed read answers nil — serialized as an explicit null — and `disabled` is
  // claimed only on a definite false.
  func testTheSerializedEnabledIsNullOnAGuestBackedRead() throws {
    let node = AXTreeWalk.describeAllElements(
      fromTree: Self.node(), keys: [.enabled], nestedFormat: false, pid: 13515
    ).first
    XCTAssertNil(try XCTUnwrap(node?.enabled))
  }

  func testAViewThatTakesNoTouchesIsBlocked() throws {
    let value = try XCTUnwrap(Self.interactable(Self.node(userInteractionEnabled: false)) ?? nil)
    XCTAssertEqual(value, .blocked(reasons: [.userInteractionDisabled]))
  }

  func testAnElementWithNoAreaIsBlocked() throws {
    let value = try XCTUnwrap(
      Self.interactable(Self.node(frame: CGRect(x: 10, y: 20, width: 0, height: 44))) ?? nil
    )
    XCTAssertEqual(value, .blocked(reasons: [.zeroSize]))
  }

  // Reasons accumulate rather than short-circuit: a caller told only the first would fix it and hit the
  // next. Order is the order they are checked, which is what the encoding pins.
  func testEveryApplicableReasonIsReported() throws {
    let value = try XCTUnwrap(
      Self.interactable(
        Self.node(
          frame: CGRect(x: 10, y: 20, width: 0, height: 44),
          isVisible: false,
          visiblePoint: CGPoint(x: -1, y: -1),
          userInteractionEnabled: false
        )
      ) ?? nil
    )
    XCTAssertEqual(
      value, .blocked(reasons: [.zeroSize, .userInteractionDisabled, .notHittable]),
      "explanations keep their derivation order; notHittable sorts last")
  }

  // MARK: - Cannot answer

  // Without the visibility attributes the read cannot judge, and must not invent a verdict from `enabled`, which is
  // hardcoded `true` on this backend.
  func testABackendWithoutTheAttributesReportsNull() {
    let value = Self.interactable(Self.node(isVisible: nil, visiblePoint: nil, centrePoint: nil, userInteractionEnabled: nil))
    XCTAssertNotNil(value as Any?, "the key was requested, so it must be present")
    XCTAssertNil(value ?? nil, "and its value must be an explicit null")
  }

  // `isVisible` answered but no visible point: the hittability check passes, and the derivation then finds no point.
  func testHittableWithNoPointReportsNoVerdict() throws {
    let value = try XCTUnwrap(
      Self.interactable(Self.node(visiblePoint: nil, centrePoint: nil, userInteractionEnabled: nil)),
      "the key was requested, so it must be present"
    )

    XCTAssertNil(value, "interactable is null when no visible point was fetched")
  }

  // MARK: - Encoding

  // The union is internally tagged, so a consumer branches on `status` rather than probing for whichever
  // key happens to be present. These are the exact tokens a consumer matches on.
  func testActionableEncodesWithItsStatusAndPoint() throws {
    let encoded = try Self.encode(.actionable(at: AccessibilityPoint(x: 201, y: 789.5)))
    XCTAssertEqual(encoded["status"] as? String, "actionable")
    XCTAssertEqual((encoded["at"] as? [String: Any])?["x"] as? Double, 201)
    XCTAssertEqual((encoded["at"] as? [String: Any])?["y"] as? Double, 789.5)
    XCTAssertNil(encoded["reasons"], "the actionable case carries no reasons")
  }

  func testBlockedEncodesItsReasonKindsAndNoPoint() throws {
    let encoded = try Self.encode(.blocked(reasons: [.occluded(by: nil), .userInteractionDisabled]))
    XCTAssertEqual(encoded["status"] as? String, "blocked")
    XCTAssertNil(encoded["at"], "the blocked case carries no point")
    let reasons = try XCTUnwrap(encoded["reasons"] as? [[String: Any]])
    XCTAssertEqual(reasons.map { $0["kind"] as? String }, ["occluded", "user_interaction_disabled"])
    XCTAssertNil(reasons[0]["by"], "no occluder is named until a hit-test is paid for")
  }

  // Every reason's wire spelling, pinned — these are the tokens a consumer branches on, so a rename is a
  // silent break for anyone matching them.
  func testReasonWireSpellings() {
    let expected: [(AccessibilityInteractable.Reason, String)] = [
      (.notHittable, "not_hittable"),
      (.clippedByScreen, "clipped_by_screen"),
      (.occluded(by: nil), "occluded"),
      (.userInteractionDisabled, "user_interaction_disabled"),
      (.disabled, "disabled"),
      (.hidden, "hidden"),
      (.zeroSize, "zero_size"),
    ]
    for (reason, kind) in expected {
      XCTAssertEqual(reason.kind, kind)
    }
  }

  // MARK: - Clipped by the screen edge

  private static let screen = AccessibilityScreenInfo(width: 402, height: 874)

  /// Runs the post-serialization refinement the way `describeTree` does.
  private static func clipped(
    frame: CGRect,
    reasons: [AccessibilityInteractable.Reason] = [.notHittable]
  ) -> AccessibilityInteractable? {
    var element = AccessibilityDocumentElement()
    element.frame = .some(AccessibilityFrame(frame))
    element.interactable = .some(.blocked(reasons: reasons))
    return AXScreenBoundsClassifier.notingScreenClipping(element, screen: screen).interactable ?? nil
  }

  // The measured case: a row scrolled so its top is above the screen. Both facts are reported — it cannot
  // be reached, and the edge is cutting it off — because they license different recoveries.
  func testAnElementStraddlingTheTopEdgeIsNotedAsClipped() {
    XCTAssertEqual(
      Self.clipped(frame: CGRect(x: 16, y: -21.3, width: 370, height: 52)),
      .blocked(reasons: [.clippedByScreen, .notHittable]))
  }

  func testAnElementStraddlingTheBottomEdgeIsNotedAsClipped() {
    XCTAssertEqual(
      Self.clipped(frame: CGRect(x: 16, y: 850, width: 370, height: 52)),
      .blocked(reasons: [.clippedByScreen, .notHittable]))
  }

  func testAnElementStraddlingASideEdgeIsNotedAsClipped() {
    XCTAssertEqual(
      Self.clipped(frame: CGRect(x: -30, y: 400, width: 370, height: 52)),
      .blocked(reasons: [.clippedByScreen, .notHittable]))
  }

  // Wholly within the screen: whatever blocks it, the edge is not part of it.
  func testAnElementWithinTheScreenIsNotNotedAsClipped() {
    XCTAssertEqual(
      Self.clipped(frame: CGRect(x: 16, y: 400, width: 370, height: 52)),
      .blocked(reasons: [.notHittable]))
  }

  // Accumulates against whatever was already there rather than replacing it, and does not assume the
  // element is unreachable for a geometric reason — a disabled control clipped by the edge is both.
  func testClippingAccumulatesAgainstAnyOtherReason() {
    XCTAssertEqual(
      Self.clipped(frame: CGRect(x: 16, y: -10, width: 370, height: 52), reasons: [.userInteractionDisabled]),
      .blocked(reasons: [.userInteractionDisabled, .clippedByScreen])
    )
  }

  // Idempotent, so a refinement that runs twice cannot double the reason; ordering is applied at encode, so the
  // value is returned untouched.
  func testClippingIsNotAddedTwice() {
    XCTAssertEqual(
      Self.clipped(frame: CGRect(x: 16, y: -10, width: 370, height: 52), reasons: [.notHittable, .clippedByScreen]),
      .blocked(reasons: [.notHittable, .clippedByScreen])
    )
  }

  // Whatever order a value was built in, the encoded form leads with an explanation.
  func testTheEncodedFormIsAlwaysOrderedMostSpecificFirst() throws {
    let encoded = try Self.encode(.blocked(reasons: [.notHittable, .clippedByScreen]))
    let reasons = try XCTUnwrap(encoded["reasons"] as? [[String: Any]])
    XCTAssertEqual(reasons.map { $0["kind"] as? String }, ["clipped_by_screen", "not_hittable"])
  }

  func testAnActionableElementIsNeverNotedAsClipped() {
    var element = AccessibilityDocumentElement()
    element.frame = .some(AccessibilityFrame(CGRect(x: 16, y: -10, width: 370, height: 52)))
    element.interactable = .some(.actionable(at: AccessibilityPoint(x: 201, y: 20)))
    let refined: AccessibilityInteractable? =
      AXScreenBoundsClassifier.notingScreenClipping(element, screen: Self.screen).interactable ?? nil
    XCTAssertEqual(refined, AccessibilityInteractable.actionable(at: AccessibilityPoint(x: 201, y: 20)))
  }

  // A consumer that reads only `reasons[0]` must get an explanation, never `notHittable`.
  func testNotHittableSortsBehindEveryExplanation() {
    let reasons: [AccessibilityInteractable.Reason] =
      [.notHittable, .clippedByScreen, .userInteractionDisabled]
    XCTAssertEqual(reasons.mostSpecificFirst, [.clippedByScreen, .userInteractionDisabled, .notHittable])
    XCTAssertFalse(reasons.mostSpecificFirst[0].isUnexplained)
  }

  // Ordering is a partition, not a sort, so explanations keep the order the checks derived them in.
  func testExplanationsKeepTheirDerivationOrder() {
    let reasons: [AccessibilityInteractable.Reason] =
      [.zeroSize, .notHittable, .hidden, .disabled]
    XCTAssertEqual(reasons.mostSpecificFirst, [.zeroSize, .hidden, .disabled, .notHittable])
  }

  // A lone `notHittable` is left alone — it is the commonest blocked shape, not a degenerate one.
  func testALoneObservationIsUnchanged() {
    XCTAssertEqual([AccessibilityInteractable.Reason.notHittable].mostSpecificFirst, [.notHittable])
  }

  // MARK: - Handled by a relative

  func testHandledByHasItsOwnWireSpelling() {
    XCTAssertEqual(AccessibilityInteractable.Reason.handledBy(nil).kind, "handled_by")
  }

  // Both cases that can name an element encode it under the same key, so a consumer reads `by` once
  // rather than once per reason kind.
  func testHandledByEncodesTheElementThatTookTheTouch() throws {
    let owner = AccessibilityElementRef(
      type: "Button", identifier: "standby", label: "StandBy",
      frame: AccessibilityFrame(CGRect(x: 16, y: 744, width: 370, height: 52)), pid: 3283
    )
    let encoded = try Self.encode(.blocked(reasons: [.handledBy(owner)]))
    let reasons = try XCTUnwrap(encoded["reasons"] as? [[String: Any]])
    XCTAssertEqual(reasons[0]["kind"] as? String, "handled_by")
    let by = try XCTUnwrap(reasons[0]["by"] as? [String: Any])
    XCTAssertEqual(by["label"] as? String, "StandBy")
    XCTAssertEqual(by["type"] as? String, "Button")
  }

  // Unnamed when no hit-test was paid for, the same as an unnamed occluder.
  func testHandledByOmitsTheElementWhenNoHitTestWasPaidFor() throws {
    let encoded = try Self.encode(.blocked(reasons: [.handledBy(nil)]))
    let reasons = try XCTUnwrap(encoded["reasons"] as? [[String: Any]])
    XCTAssertEqual(reasons[0]["kind"] as? String, "handled_by")
    XCTAssertNil(reasons[0]["by"])
  }

  // It explains, so it sorts ahead of `notHittable` like every other explanation.
  func testHandledByIsAnExplanationNotAnObservation() {
    XCTAssertFalse(AccessibilityInteractable.Reason.handledBy(nil).isUnexplained)
    XCTAssertEqual(
      [AccessibilityInteractable.Reason.notHittable, .handledBy(nil)].mostSpecificFirst,
      [.handledBy(nil), .notHittable]
    )
  }

  // An element explained by a relative counts as explained in the summary.
  func testAnElementHandledByARelativeIsNotUnexplained() throws {
    var handled = AccessibilityDocumentElement()
    handled.interactable = .some(.blocked(reasons: [.handledBy(nil)]))
    var bare = AccessibilityDocumentElement()
    bare.interactable = .some(.blocked(reasons: [.notHittable]))
    let summary = try XCTUnwrap(AccessibilityInteractionSummary(elements: [handled, bare]))
    XCTAssertEqual(summary.blocked, 2)
    XCTAssertEqual(summary.unexplained, 1)
  }

  // MARK: - What `occluded_by` needs serialized

  // `occluded_by` hit-tests the element's centre (from the frame) and then compares identity fields both reads can
  // see, so requesting it implies all of them.
  func testOccludedByImpliesTheKeysItsHitTestNeeds() {
    let keys = AccessibilityRequestOptions(keys: [.occludedBy]).serializationKeys
    XCTAssertTrue(keys.contains(.interactable), "the thing it enriches")
    XCTAssertTrue(keys.contains(.frameDict), "the frame its hit-test is aimed by")
    XCTAssertTrue(keys.contains(.uniqueID), "and the fields identity is compared on")
    XCTAssertTrue(keys.contains(.type))
    XCTAssertTrue(keys.contains(.label))
    XCTAssertTrue(keys.isSuperset(of: AXKeys.occluderIdentityKeys))
  }

  // MARK: - Explanatory power

  private static func element(_ value: AccessibilityInteractable?) -> AccessibilityDocumentElement {
    var element = AccessibilityDocumentElement()
    element.interactable = .some(value)
    return element
  }

  func testTheSummaryCountsVerdictsByOutcome() throws {
    let summary = try XCTUnwrap(
      AccessibilityInteractionSummary(elements: [
        Self.element(.actionable(at: AccessibilityPoint(x: 1, y: 2))),
        Self.element(.blocked(reasons: [.notHittable])),
        Self.element(.blocked(reasons: [.clippedByScreen, .notHittable])),
      ]))
    XCTAssertEqual(summary.actionable, 1)
    XCTAssertEqual(summary.blocked, 2)
  }

  // An element carrying a cause alongside the bare observation is explained.
  func testUnexplainedCountsOnlyElementsWithNoExplanationAtAll() throws {
    let summary = try XCTUnwrap(
      AccessibilityInteractionSummary(elements: [
        Self.element(.blocked(reasons: [.notHittable])),
        Self.element(.blocked(reasons: [.clippedByScreen, .notHittable])),
        Self.element(.blocked(reasons: [.userInteractionDisabled])),
      ]))
    XCTAssertEqual(summary.blocked, 3)
    XCTAssertEqual(summary.unexplained, 1, "only the bare-observation-only element is unexplained")
    XCTAssertEqual(try XCTUnwrap(summary.unexplainedRatio), 1.0 / 3.0, accuracy: 0.0001)
  }

  // Children are counted, not just roots — a nested read is the normal shape.
  func testTheSummaryCountsNestedElements() throws {
    var root = Self.element(.actionable(at: AccessibilityPoint(x: 1, y: 2)))
    root.children = [Self.element(.blocked(reasons: [.notHittable]))]
    let summary = try XCTUnwrap(AccessibilityInteractionSummary(elements: [root]))
    XCTAssertEqual(summary.actionable, 1)
    XCTAssertEqual(summary.unexplained, 1)
  }

  // Nil rather than zeroes when nothing carried a verdict, so a backend that cannot judge is not
  // mistaken for a screen with nothing blocked.
  func testTheSummaryIsAbsentWhenNothingCarriedAVerdict() {
    XCTAssertNil(AccessibilityInteractionSummary(elements: [Self.element(nil), Self.element(nil)]))
    XCTAssertNil(AccessibilityInteractionSummary(elements: []))
  }

  // No blocked elements means the ratio has no denominator, and reporting 0.0 would read as "perfectly
  // explained" rather than "nothing to explain".
  func testTheRatioIsAbsentWhenNothingIsBlocked() throws {
    let summary = try XCTUnwrap(
      AccessibilityInteractionSummary(
        elements: [Self.element(.actionable(at: AccessibilityPoint(x: 1, y: 2)))]
      ))
    XCTAssertEqual(summary.blocked, 0)
    XCTAssertNil(summary.unexplainedRatio)
  }

  // MARK: - The `interactable` filter

  /// A two-element flat read: a reachable button and a covered one, both button-like.
  private static func mixedRead() -> [AccessibilityDocumentElement] {
    var reachable = AccessibilityDocumentElement()
    reachable.label = .some("StandBy")
    reachable.role = .some("AXButton")
    reachable.interactable = .some(.actionable(at: AccessibilityPoint(x: 201, y: 770)))
    var covered = AccessibilityDocumentElement()
    covered.label = .some("Screen Time")
    covered.role = .some("AXButton")
    covered.interactable = .some(.blocked(reasons: [.notHittable]))
    return [reachable, covered]
  }

  // The covered button is button-like by every structural measure; the backend's verdict outranks the heuristic.
  func testTheFilterKeepsOnlyElementsTheBackendReportsActionable() {
    let kept = AccessibilityElementFilter.interactable.apply(to: Self.mixedRead(), screen: nil)
    XCTAssertEqual(kept.compactMap { $0.label ?? nil }, ["StandBy"])
  }

  // Where the backend returned no verdict, the structural heuristic still answers — so the flag degrades
  // in precision on the legacy path rather than reporting an empty screen.
  func testTheFilterFallsBackToTheHeuristicWhenTheBackendCannotAnswer() {
    var unjudged = AccessibilityDocumentElement()
    unjudged.label = .some("Screen Time")
    unjudged.role = .some("AXButton")
    unjudged.interactable = .some(nil)
    XCTAssertEqual(AccessibilityElementFilter.interactable.apply(to: [unjudged], screen: nil).count, 1)

    var unlabelledContainer = AccessibilityDocumentElement()
    unlabelledContainer.interactable = .some(nil)
    XCTAssertTrue(
      AccessibilityElementFilter.interactable.apply(to: [unlabelledContainer], screen: nil).isEmpty,
      "the fallback is the old heuristic, not keep-everything"
    )
  }

  private static func encode(_ value: AccessibilityInteractable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
