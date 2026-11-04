/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBSimulatorControl
import Foundation
import Testing

/// Coverage of the `SimulatorHIDEvent` composite factories — the value-level decomposition of a
/// gesture into its ordered primitive sub-events (touch/button/keyboard/two-finger + delays). The
/// byte-level Indigo payloads are pinned by `SimulatorIndigoHIDTests`; the tvOS `pan`/`remoteButton`
/// factories by their own suites. This fills the gap for `tapAt`, `swipe`, `pinchAt`, and the
/// button/keyboard short-press factories, so the event model is a stable contract for the backends
/// that render it.
@Suite
struct SimulatorHIDEventRenderingTests {

  // MARK: - Helpers

  private func touches(_ event: SimulatorHIDEvent) throws -> [(SimulatorHIDDirection, Double, Double)] {
    try #require(event.subEvents).compactMap {
      if case let .touch(direction, x, y, _) = $0 { return (direction, x, y) }
      return nil
    }
  }

  private func twoFingerTouches(_ event: SimulatorHIDEvent) throws -> [(SimulatorHIDDirection, CGPoint, CGPoint)] {
    try #require(event.subEvents).compactMap {
      if case let .twoFingerTouch(direction, finger1, finger2) = $0 { return (direction, finger1, finger2) }
      return nil
    }
  }

  private func delayCount(_ event: SimulatorHIDEvent) throws -> Int {
    try #require(event.subEvents).filter {
      if case .delay = $0 { return true }
      return false
    }.count
  }

  /// The distance travelled between consecutive samples, and the time each step takes.
  private func steps(_ event: SimulatorHIDEvent) throws -> (distances: [Double], delay: Double) {
    let points = try touches(event).filter { $0.0 == .down }.map { ($0.1, $0.2) }
    let delays = try #require(event.subEvents).compactMap {
      if case let .delay(seconds) = $0 { return seconds }
      return nil
    }
    let distances = zip(points, points.dropFirst()).map { hypot($1.0 - $0.0, $1.1 - $0.1) }
    return (distances, try #require(delays.first))
  }

  private func edges(_ event: SimulatorHIDEvent) throws -> [SimulatorHIDEdge] {
    try #require(event.subEvents).compactMap {
      if case let .touch(_, _, _, edge) = $0 { return edge }
      return nil
    }
  }

  // MARK: - Edge swipe

  // The gesture is derived from the screen, so the caller names an edge and nothing else. It starts
  // one point inside the named edge — the far edge of a 874-point screen is y=873 — and travels half
  // way across, which is the direction that edge implies.
  @Test
  func edgeSwipeGeometry() throws {
    let screen = CGSize(width: 402, height: 874)
    let expected: [(SimulatorHIDEdge, CGPoint, CGPoint)] = [
      (.bottom, CGPoint(x: 201, y: 873), CGPoint(x: 201, y: 437)),
      (.top, CGPoint(x: 201, y: 1), CGPoint(x: 201, y: 437)),
      (.left, CGPoint(x: 1, y: 437), CGPoint(x: 201, y: 437)),
      (.right, CGPoint(x: 401, y: 437), CGPoint(x: 201, y: 437)),
    ]
    for (edge, start, end) in expected {
      let touches = try touches(.edgeSwipe(edge, screenSize: screen, duration: 0.4))
      let first = try #require(touches.first)
      let last = try #require(touches.last)
      #expect(abs(first.1 - Double(start.x)) <= 1e-9, "\(edge.name) start x")
      #expect(abs(first.2 - Double(start.y)) <= 1e-9, "\(edge.name) start y")
      #expect(abs(last.1 - Double(end.x)) <= 1e-9, "\(edge.name) end x")
      #expect(abs(last.2 - Double(end.y)) <= 1e-9, "\(edge.name) end y")
    }
  }

  // Every contact carries the edge, not just the first: the guest reads the flag off whichever
  // contact it inspects, so a gesture that dropped it after touch-down reads as an ordinary drag.
  @Test
  func edgeSwipeTagsEveryContact() throws {
    let event = SimulatorHIDEvent.edgeSwipe(.bottom, screenSize: CGSize(width: 402, height: 874), duration: 0.4)
    let edges = try edges(event)
    #expect(edges.count > 2, "an edge swipe interpolates several contacts")
    #expect(edges.allSatisfy { $0 == .bottom }, "every contact should carry the edge, got \(edges)")
  }

  // It lifts at the end like any other swipe, so the gesture completes rather than leaving a contact
  // held down.
  @Test
  func edgeSwipeEndsWithTouchUp() throws {
    let event = SimulatorHIDEvent.edgeSwipe(.bottom, screenSize: CGSize(width: 402, height: 874), duration: 0.4)
    let last = try #require(touches(event).last)
    #expect(last.0 == .up)
  }

  // A plain swipe is unaffected: it defaults to no edge, so the existing gesture keeps producing
  // untagged contacts.
  @Test
  func plainSwipeCarriesNoEdge() throws {
    let event = SimulatorHIDEvent.swipe(0, yStart: 0, xEnd: 0, yEnd: 100, delta: 10, duration: 0.3)
    #expect(try edges(event).allSatisfy { $0 == .none })
  }

  // MARK: - Tap

  @Test
  func tapLowersToDownUp() {
    #expect(
      SimulatorHIDEvent.tapAt(x: 12, y: 34)
        == .composite([
          .touch(direction: .down, x: 12, y: 34),
          .touch(direction: .up, x: 12, y: 34),
        ]))
  }

  @Test
  func tapWithDurationInsertsDelayBetweenDownAndUp() {
    #expect(
      SimulatorHIDEvent.tapAt(x: 12, y: 34, duration: 0.5)
        == .composite([
          .touch(direction: .down, x: 12, y: 34),
          .delay(0.5),
          .touch(direction: .up, x: 12, y: 34),
        ]))
  }

  // MARK: - Button / Keyboard

  @Test
  func shortButtonPressLowersToDownUp() {
    #expect(
      SimulatorHIDEvent.shortButtonPress(.homeButton)
        == .composite([
          .button(direction: .down, button: .homeButton),
          .button(direction: .up, button: .homeButton),
        ]))
  }

  @Test
  func shortKeyPressLowersToDownUp() {
    #expect(
      SimulatorHIDEvent.shortKeyPress(0x04)
        == .composite([
          .keyboard(direction: .down, keyCode: 0x04),
          .keyboard(direction: .up, keyCode: 0x04),
        ]))
  }

  @Test
  func shortKeyPressSequencePressesEachKeyInOrder() {
    #expect(
      SimulatorHIDEvent.shortKeyPressSequence([0x04, 0x05, 0x06])
        == .composite([
          .keyboard(direction: .down, keyCode: 0x04),
          .keyboard(direction: .up, keyCode: 0x04),
          .keyboard(direction: .down, keyCode: 0x05),
          .keyboard(direction: .up, keyCode: 0x05),
          .keyboard(direction: .down, keyCode: 0x06),
          .keyboard(direction: .up, keyCode: 0x06),
        ]))
  }

  @Test
  func shortKeyPressSequenceEmptyIsEmptyComposite() {
    #expect(SimulatorHIDEvent.shortKeyPressSequence([]) == .composite([]))
  }

  // MARK: - Swipe

  // A vertical swipe of distance 100 with delta 10 -> 10 steps. The factory emits (steps + 1)
  // interpolated touch-downs, a duplicated final touch-down (the anti-inertial-scroll guard), and a
  // terminating touch-up; a delay follows every touch-down except the final up.
  @Test
  func swipeInterpolatesDownsThenLiftsUp() throws {
    let swipe = SimulatorHIDEvent.swipe(100, yStart: 100, xEnd: 100, yEnd: 200, delta: 10, duration: 0.3)
    let touches = try touches(swipe)

    // (steps + 1) interpolated downs + 1 duplicated final down + 1 up.
    #expect(touches.count == 13, "11 interpolated downs + 1 duplicate final down + 1 up")
    #expect(touches.filter { $0.0 == .down }.count == 12)
    #expect(touches.filter { $0.0 == .up }.count == 1)
    // One delay per down (none after the final up).
    #expect(try delayCount(swipe) == 12, "a delay follows each of the 12 downs")

    // Starts at the origin, ends lifting at the destination.
    let first = try #require(touches.first)
    #expect(first.0 == .down)
    #expect(abs(first.1 - 100) <= 1e-9)
    #expect(abs(first.2 - 100) <= 1e-9)
    let last = try #require(touches.last)
    #expect(last.0 == .up)
    #expect(abs(last.1 - 100) <= 1e-9)
    #expect(abs(last.2 - 200) <= 1e-9)

    // Interpolated y-coordinates are monotonically non-decreasing 100 -> 200; x is constant.
    let downYs = touches.filter { $0.0 == .down }.map(\.2)
    let firstY = try #require(downYs.first)
    let lastY = try #require(downYs.last)
    #expect(abs(firstY - 100) <= 1e-9)
    #expect(abs(lastY - 200) <= 1e-9, "duplicated final down sits at the destination")
    #expect(downYs == downYs.sorted(), "monotonic progression toward the destination")
    #expect(touches.allSatisfy { abs($0.1 - 100) < 1e-9 }, "constant x for a vertical swipe")
  }

  @Test
  func swipeNonPositiveDeltaUsesDefault() throws {
    // delta <= 0 falls back to defaultSwipeDelta (10), so distance 100 still yields 10 steps.
    let withZero = SimulatorHIDEvent.swipe(0, yStart: 0, xEnd: 0, yEnd: 100, delta: 0, duration: 0.3)
    let withDefault = SimulatorHIDEvent.swipe(0, yStart: 0, xEnd: 0, yEnd: 100, delta: SimulatorHIDEvent.defaultSwipeDelta, duration: 0.3)
    #expect(try touches(withZero).count == touches(withDefault).count)
  }

  @Test
  func swipeClampsStepsToAtLeastOne() throws {
    // A sub-delta distance must not divide to zero steps; it degrades to a single interpolated down.
    let swipe = SimulatorHIDEvent.swipe(0, yStart: 0, xEnd: 1, yEnd: 0, delta: 10, duration: 0.1)
    // (1 + 1) interpolated downs + 1 duplicate final down + 1 up.
    #expect(try touches(swipe).filter { $0.0 == .down }.count == 3)
    #expect(try touches(swipe).filter { $0.0 == .up }.count == 1)
  }

  // Without deceleration the swipe is the original one, event for event: every touch-down is followed by
  // `duration / (steps + 2)`, the final touch-down is repeated, and the contact lifts at the end point.
  @Test
  func swipeWithoutDecelerationKeepsTheOriginalEvents() throws {
    let swipe = SimulatorHIDEvent.swipe(0, yStart: 0, xEnd: 0, yEnd: 30, delta: 10, duration: 0.5, decelerationDuration: 0)
    let events = try #require(swipe.subEvents)
    #expect(events.count == 11)
    for (index, y) in [0.0, 10.0, 20.0, 30.0, 30.0].enumerated() {
      guard case let .touch(direction, x, actualY, _) = events[index * 2] else {
        Issue.record("event \(index * 2) should be a touch: \(events[index * 2])")
        continue
      }
      #expect(direction == .down)
      #expect(x == 0)
      #expect(abs(actualY - y) <= 1e-9, "touch \(index) should be at y \(y), got \(actualY)")
      guard case let .delay(seconds) = events[index * 2 + 1] else {
        Issue.record("event \(index * 2 + 1) should be a delay: \(events[index * 2 + 1])")
        continue
      }
      #expect(abs(seconds - 0.1) <= 1e-12)
    }
    guard case let .touch(direction, x, y, _) = events[10] else {
      Issue.record("the last event should be a touch: \(events[10])")
      return
    }
    #expect(direction == .up)
    #expect(x == 0)
    #expect(y == 30)
  }

  // A decelerating swipe drops the repeated final touch-down: a touch per sample, a delay between
  // consecutive samples, then the lift.
  @Test
  func deceleratingSwipeSpacesItsSamplesEvenly() throws {
    let swipe = SimulatorHIDEvent.swipe(100, yStart: 100, xEnd: 100, yEnd: 200, delta: 10, duration: 0.3, decelerationDuration: SimulatorHIDEvent.swipeDecelerationDuration)
    let touches = try touches(swipe)
    #expect(touches.filter { $0.0 == .down }.count == 11)
    #expect(touches.filter { $0.0 == .up }.count == 1)
    #expect(try delayCount(swipe) == 10)
    #expect(touches.last?.0 == .up)
  }

  // The guest flings a scroll view when a contact lifts faster than about 250 points per second,
  // measured over the last samples that moved. A 200-point swipe over 0.3 seconds travels at more than
  // twice that, so it has to have slowed to rest by the time it lifts.
  @Test
  func swipeSlowsToRestBeforeLifting() throws {
    let event = SimulatorHIDEvent.swipe(207, yStart: 650, xEnd: 207, yEnd: 450, delta: 10, duration: 0.3, decelerationDuration: SimulatorHIDEvent.swipeDecelerationDuration)
    let (distances, delay) = try steps(event)
    let finalSteps = Int((0.05 / delay).rounded(.up))
    let finalSpeed = distances.suffix(finalSteps).reduce(0, +) / (Double(finalSteps) * delay)
    #expect(finalSpeed < 250, "the last 50 ms move at \(finalSpeed) points per second")
    let cruisingSpeed = try #require(distances.first) / delay
    #expect(cruisingSpeed > 600, "the swipe should still travel quickly before it slows, got \(cruisingSpeed)")
  }

  // Slowing down must not overshoot: the contact only ever moves towards the end point, and the samples
  // span the whole duration the caller asked for.
  @Test
  func swipeTravelsMonotonicallyToTheEndPointOverItsDuration() throws {
    let event = SimulatorHIDEvent.swipe(0, yStart: 0, xEnd: 0, yEnd: 200, delta: 10, duration: 0.3, decelerationDuration: SimulatorHIDEvent.swipeDecelerationDuration)
    let ys = try touches(event).map(\.2)
    #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 <= $1 }, "positions should never move backwards: \(ys)")
    #expect(ys.first == 0)
    #expect(abs(try #require(ys.last) - 200) <= 1e-9)
    let (distances, delay) = try steps(event)
    #expect(abs(Double(distances.count) * delay - 0.3) <= 1e-9)
  }

  // With no time to spread the samples over there is nothing to slow down in, so a zero-duration
  // decelerating swipe still interpolates evenly and produces finite coordinates.
  @Test
  func zeroDurationDeceleratingSwipeInterpolatesEvenly() throws {
    let event = SimulatorHIDEvent.swipe(0, yStart: 0, xEnd: 0, yEnd: 100, delta: 10, duration: 0, decelerationDuration: SimulatorHIDEvent.swipeDecelerationDuration)
    let ys = try touches(event).filter { $0.0 == .down }.map(\.2)
    #expect(ys == stride(from: 0.0, through: 100.0, by: 10.0).map { $0 })
  }

  @Test
  func swipeDecelerationIsOffUnlessTheEnvironmentTurnsItOn() {
    #expect(!SimulatorHIDEvent.isSwipeDecelerationEnabled(environmentValue: nil))
    for off in ["", "0", "false", "off", "slow"] {
      #expect(!SimulatorHIDEvent.isSwipeDecelerationEnabled(environmentValue: off), "\(off)")
    }
    for on in ["1", "true", "YES", "On"] {
      #expect(SimulatorHIDEvent.isSwipeDecelerationEnabled(environmentValue: on), "\(on)")
    }
  }

  // MARK: - Pinch

  // A pinch-out from radius 50 to 100 (scale 2) with delta 10 -> 5 steps. Two fingers stay symmetric
  // about the center on the horizontal axis; the radius grows from start to end; the gesture is a
  // sequence of two-finger downs (initial + steps + duplicated final) terminated by a two-finger up.
  @Test
  func pinchOutIsSymmetricAndGrowsRadius() throws {
    let center = CGPoint(x: 200, y: 200)
    let pinch = SimulatorHIDEvent.pinchAt(x: center.x, y: center.y, scale: 2, duration: 0.3, radius: 50)
    let events = try twoFingerTouches(pinch)

    // initial down + 5 interpolated downs + 1 duplicated final down + 1 up.
    #expect(events.count == 8)
    #expect(events.map(\.0) == [.down, .down, .down, .down, .down, .down, .down, .up])
    #expect(try delayCount(pinch) == 7, "a delay follows every down")

    // Fingers are always symmetric about the center on the horizontal axis (y == centerY).
    for (_, f1, f2) in events {
      #expect(abs(f1.x + f2.x - 2 * center.x) <= 1e-9, "symmetric about centerX")
      #expect(abs(f1.y - center.y) <= 1e-9)
      #expect(abs(f2.y - center.y) <= 1e-9)
      #expect(f1.x < f2.x, "finger1 is the left contact")
    }

    // Radius (half the finger separation) grows from the start radius to the end radius.
    let startRadius = (events.first!.2.x - center.x)
    let endRadius = (events.last!.2.x - center.x)
    #expect(abs(startRadius - 50) <= 1e-9)
    #expect(abs(endRadius - 100) <= 1e-9)
  }

  @Test
  func pinchInShrinksRadius() throws {
    let pinch = SimulatorHIDEvent.pinchAt(x: 200, y: 200, scale: 0.5, duration: 0.3, radius: 100)
    let events = try twoFingerTouches(pinch)
    let startRadius = events.first!.2.x - 200
    let endRadius = events.last!.2.x - 200
    #expect(abs(startRadius - 100) <= 1e-9)
    #expect(abs(endRadius - 50) <= 1e-9, "pinch-in ends at the smaller radius")
  }

  @Test
  func pinchClampsStepsToAtLeastTwo() throws {
    // scale 1 -> zero finger travel -> steps would divide to 0; the factory clamps to 2 interpolated
    // moves so the gesture is still a well-formed multi-sample pinch.
    let pinch = SimulatorHIDEvent.pinchAt(x: 200, y: 200, scale: 1, duration: 0.3, radius: 50)
    // initial down + 2 interpolated downs + 1 duplicated final down + 1 up.
    #expect(try twoFingerTouches(pinch).count == 5)
  }

  // MARK: - Description rendering

  @Test
  func touchDescriptionRendersDirectionAndCoordinates() {
    #expect(
      SimulatorHIDEvent.touch(direction: .down, x: 10.5, y: 20.0).logDescription(.detailed) == "Touch down at (10.5,20.0)")
    // Negative coordinates arrive unvalidated from the wire (off-screen
    // swipe endpoints); rendering them must not trap.
    #expect(
      SimulatorHIDEvent.touch(direction: .up, x: -5.0, y: -0.5).logDescription(.detailed) == "Touch up at (-5.0,-0.5)")
  }

  @Test
  func twoFingerTouchDescriptionRendersBothFingersVerbatim() {
    #expect(
      SimulatorHIDEvent.twoFingerTouch(
        direction: .up,
        finger1: CGPoint(x: 10.5, y: 20.0),
        finger2: CGPoint(x: -30.0, y: 40.0)
      ).logDescription(.detailed) == "TwoFingerTouch up at (10.5,20.0) (-30.0,40.0)")
  }

  @Test
  func keyboardDescriptionRendersKeyCodeAndDirection() {
    #expect(
      SimulatorHIDEvent.keyboard(direction: .down, keyCode: 40).logDescription(.detailed) == "Keyboard Code=40 down")
  }

  @Test
  func redactedDescriptionsHideThePayload() {
    #expect(
      SimulatorHIDEvent.touch(direction: .down, x: 10.0, y: 20.0).logDescription(.redacted) == "Touch <hidden>")
    #expect(
      SimulatorHIDEvent.keyboard(direction: .down, keyCode: 40).logDescription(.redacted) == "Key <hidden>")
  }

  @Test
  func descriptionIsRedacted() {
    #expect(SimulatorHIDEvent.touch(direction: .down, x: 10.0, y: 20.0).description == "Touch <hidden>")
  }

  @Test
  func clampedDeliveryRendersBothEventsAtTheSameLevel() {
    let delivery = SimulatorHIDDelivery.clamped(
      requested: .touch(direction: .down, x: -1, y: 30),
      delivered: .touch(direction: .down, x: 0, y: 30),
      bounds: CGSize(width: 200, height: 300))
    #expect(
      delivery.logDescription(.detailed) == "Clamped Touch down at (-1.0,30.0) to Touch down at (0.0,30.0) within the display's point bounds (200.0 x 300.0)")
    #expect(
      delivery.logDescription(.redacted) == "Clamped Touch <hidden> to Touch <hidden> within the display's point bounds (200.0 x 300.0)")
  }

  @Test
  func compositeDescriptionRendersChildrenAtTheSameLevel() {
    let event = SimulatorHIDEvent.composite([.touch(direction: .down, x: 1, y: 2), .delay(0.5)])
    #expect(event.logDescription(.detailed) == "Composite [Touch down at (1.0,2.0), Delay for 0.5]")
    #expect(event.logDescription(.redacted) == "Composite [Touch <hidden>, Delay for 0.5]")
  }
}
