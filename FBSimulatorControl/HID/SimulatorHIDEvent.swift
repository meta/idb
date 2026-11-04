/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import Foundation

// MARK: - SimulatorHIDEvent

/// An input event that can be sent to a Simulator. A discriminated union of the primitive
/// payloads (touch, button, remote button, keyboard, two-finger touch, trackpad, Apple Watch button,
/// Digital Crown, delay) plus a `composite` of ordered events. Device actions such as rotation, lock
/// or shake are commands on the `Simulator`.
public indirect enum SimulatorHIDEvent: Equatable, Hashable, Sendable {

  /// The per-sample step, in points, a swipe is broken into when the caller does not choose one.
  public static let defaultSwipeDelta: Double = 10.0

  case touch(direction: SimulatorHIDDirection, x: Double, y: Double, edge: SimulatorHIDEdge)
  case button(direction: SimulatorHIDDirection, button: SimulatorHIDButton)
  case remoteButton(direction: SimulatorHIDDirection, button: SimulatorHIDRemoteButton)
  case keyboard(direction: SimulatorHIDDirection, keyCode: UInt32)
  case twoFingerTouch(direction: SimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint)
  case trackpad(phase: SimulatorTrackpadPhase, point: SimulatorTrackpadPoint)
  /// A press of a button only an Apple Watch has. Distinct from `.button`, whose `sideButton` is the
  /// Consumer Power usage.
  case watchButton(direction: SimulatorHIDDirection, button: SimulatorWatchButton)
  /// One sample of a Digital Crown rotation. `.down` carries a delta and begins or continues the
  /// turn; `.up` ends it, and its delta is ignored.
  case crown(direction: SimulatorHIDDirection, delta: Double)
  case delay(TimeInterval)
  case composite([SimulatorHIDEvent])

  /// For a `.composite` event, its ordered sub-events; otherwise `nil`.
  public var subEvents: [SimulatorHIDEvent]? {
    guard case let .composite(events) = self else {
      return nil
    }
    return events
  }

}

// MARK: - Delays

public extension SimulatorHIDEvent {

  /// Throws `SimulatorHIDError.invalidDelay` unless `seconds` is finite, non-negative and short
  /// enough for `.delay` to sleep for.
  static func validateDelay(_ seconds: TimeInterval) throws {
    guard seconds >= 0 else {
      throw SimulatorHIDError.invalidDelay(seconds)
    }
    _ = try delayNanoseconds(seconds)
  }
}

extension SimulatorHIDEvent {

  /// The nanoseconds `.delay(seconds)` sleeps for. A negative delay is no wait.
  static func delayNanoseconds(_ seconds: TimeInterval) throws -> UInt64 {
    let nanoseconds = max(0, seconds) * 1_000_000_000
    // `Double(UInt64.max)` rounds up to 2^64, so only a strictly smaller value converts.
    guard seconds.isFinite, nanoseconds < Double(UInt64.max) else {
      throw SimulatorHIDError.invalidDelay(seconds)
    }
    return UInt64(nanoseconds)
  }
}

// MARK: - Factories

public extension SimulatorHIDEvent {

  /// An ordinary touch, not originating at a screen edge — what almost every caller wants. Tagging a
  /// contact with an edge is what turns a swipe into a system gesture, so it has to be asked for
  /// explicitly via the `.touch` case.
  static func touch(direction: SimulatorHIDDirection, x: Double, y: Double) -> SimulatorHIDEvent {
    .touch(direction: direction, x: x, y: y, edge: .none)
  }

  static func tapAt(x: Double, y: Double) -> SimulatorHIDEvent {
    .composite([
      .touch(direction: .down, x: x, y: y),
      .touch(direction: .up, x: x, y: y),
    ])
  }

  static func tapAt(x: Double, y: Double, duration: Double) -> SimulatorHIDEvent {
    .composite([
      .touch(direction: .down, x: x, y: y),
      .delay(duration),
      .touch(direction: .up, x: x, y: y),
    ])
  }

  static func shortButtonPress(_ button: SimulatorHIDButton) -> SimulatorHIDEvent {
    .composite([
      .button(direction: .down, button: button),
      .button(direction: .up, button: button),
    ])
  }

  /// A short press of a button only an Apple Watch has: down then up, which is what the guest
  /// reads as a click rather than a hold.
  static func shortWatchButtonPress(_ button: SimulatorWatchButton) -> SimulatorHIDEvent {
    .composite([
      .watchButton(direction: .down, button: button),
      .watchButton(direction: .up, button: button),
    ])
  }

  static func shortKeyPress(_ keyCode: UInt32) -> SimulatorHIDEvent {
    .composite([
      .keyboard(direction: .down, keyCode: keyCode),
      .keyboard(direction: .up, keyCode: keyCode),
    ])
  }

  static func shortKeyPressSequence(_ sequence: [UInt32]) -> SimulatorHIDEvent {
    var events: [SimulatorHIDEvent] = []
    for keyCode in sequence {
      events.append(.keyboard(direction: .down, keyCode: keyCode))
      events.append(.keyboard(direction: .up, keyCode: keyCode))
    }
    return .composite(events)
  }

  /// A short press of a Siri Remote focus action for tvOS, left for the transport to encode.
  static func remoteButton(_ button: SimulatorHIDRemoteButton) -> SimulatorHIDEvent {
    .composite([
      .remoteButton(direction: .down, button: button),
      .remoteButton(direction: .up, button: button),
    ])
  }

  /// How long a crown rotation's samples are spread over, in seconds. The guest reads a turn from
  /// the rate the samples arrive at.
  static let defaultCrownDuration: Double = 0.15

  /// A complete Digital Crown rotation: its samples paced across `duration`, then the release that
  /// ends the gesture. Throws `SimulatorHIDError.invalidDelay` for a `duration` that
  /// `validateDelay(_:)` rejects.
  static func crownRotation(
    _ rotation: SimulatorCrownRotation, duration: Double = defaultCrownDuration
  ) throws -> SimulatorHIDEvent {
    try validateDelay(duration)
    let steps = rotation.steps
    let stepDelay = duration / Double(steps.count + 1)
    var events: [SimulatorHIDEvent] = []
    for step in steps {
      events.append(.crown(direction: .down, delta: step))
      events.append(.delay(stepDelay))
    }
    events.append(.crown(direction: .up, delta: 0))
    return .composite(events)
  }

  /// How long a swipe spends slowing from its travelling speed to rest before it lifts.
  ///
  /// The guest takes a contact's release velocity from the last samples that moved; samples that repeat
  /// a position carry no motion, so holding still before lifting does not slow it. A contact lifted
  /// while still moving faster than about 250 points per second makes a scroll view coast past the end
  /// point. Slowing to rest over this long keeps the release velocity below that on every runtime.
  static let swipeDecelerationDuration: Double = 0.15

  /// The `decelerationDuration` a swipe uses when its caller passes none. Slowing to rest is opt-in:
  /// it is `swipeDecelerationDuration` only while `IDB_SWIPE_DECELERATION` is `1`, `true`, `yes` or `on`
  /// in the process's environment, and zero otherwise, which keeps the original constant-speed swipe.
  static let defaultSwipeDecelerationDuration: Double =
    isSwipeDecelerationEnabled(environmentValue: ProcessInfo.processInfo.environment["IDB_SWIPE_DECELERATION"])
    ? swipeDecelerationDuration : 0

  static func isSwipeDecelerationEnabled(environmentValue value: String?) -> Bool {
    guard let value else {
      return false
    }
    return ["1", "true", "yes", "on"].contains(value.lowercased())
  }

  /// A swipe from `(xStart,yStart)` to `(xEnd,yEnd)`, one sample per `delta` points of travel.
  ///
  /// With a positive `decelerationDuration`, samples are evenly spaced in time across `duration`; the
  /// contact moves at constant speed, then slows to rest over the last `decelerationDuration` (all of
  /// `duration`, when that is shorter), so the content moves with the contact and stops where it stops.
  /// With zero, the swipe is the original constant-speed one, which lifts at full speed.
  ///
  /// `edge` tags every contact in the gesture, not just the first: the guest reads the edge flag off
  /// whichever contact it is inspecting, so a gesture that announced an edge only on touch-down would
  /// be read as an ordinary drag from its second sample onwards.
  static func swipe(
    _ xStart: Double, yStart: Double, xEnd: Double, yEnd: Double, delta: Double, duration: Double,
    edge: SimulatorHIDEdge = .none, decelerationDuration: Double = defaultSwipeDecelerationDuration
  ) -> SimulatorHIDEvent {
    var events: [SimulatorHIDEvent] = []
    let distance = sqrt(pow(yEnd - yStart, 2) + pow(xEnd - xStart, 2))
    var effectiveDelta = delta
    if effectiveDelta <= 0.0 {
      effectiveDelta = defaultSwipeDelta
    }
    let steps = max(1, Int(distance / effectiveDelta))
    guard decelerationDuration > 0 else {
      return constantSpeedSwipe(
        xStart, yStart: yStart, xEnd: xEnd, yEnd: yEnd, steps: steps, duration: duration, edge: edge)
    }
    let stepDelay = duration / Double(steps)
    let deceleration = duration > 0 ? min(max(0, decelerationDuration), duration) / duration : 0

    for i in 0...steps {
      let travelled = swipeTravelFraction(Double(i) / Double(steps), decelerationFraction: deceleration)
      events.append(
        .touch(
          direction: .down, x: xStart + (xEnd - xStart) * travelled, y: yStart + (yEnd - yStart) * travelled,
          edge: edge))
      if i < steps {
        events.append(.delay(stepDelay))
      }
    }
    events.append(.touch(direction: .up, x: xEnd, y: yEnd, edge: edge))

    return .composite(events)
  }

  private static func constantSpeedSwipe(
    _ xStart: Double, yStart: Double, xEnd: Double, yEnd: Double, steps: Int, duration: Double,
    edge: SimulatorHIDEdge
  ) -> SimulatorHIDEvent {
    var events: [SimulatorHIDEvent] = []

    let dx = (xEnd - xStart) / Double(steps)
    let dy = (yEnd - yStart) / Double(steps)

    let stepDelay = duration / Double(steps + 2)

    for i in 0...steps {
      events.append(.touch(direction: .down, x: xStart + dx * Double(i), y: yStart + dy * Double(i), edge: edge))
      events.append(.delay(stepDelay))
    }
    // Add an additional touch down event at the end of the swipe to avoid inertial scroll on arm simulators.
    events.append(
      .touch(direction: .down, x: xStart + dx * Double(steps), y: yStart + dy * Double(steps), edge: edge))
    events.append(.delay(stepDelay))

    events.append(.touch(direction: .up, x: xEnd, y: yEnd, edge: edge))

    return .composite(events)
  }

  /// The fraction of a swipe's travel covered `progress` of the way through its duration: constant speed,
  /// then a speed falling linearly to zero over the final `decelerationFraction` of the duration.
  private static func swipeTravelFraction(_ progress: Double, decelerationFraction: Double) -> Double {
    let cruise = 1 - decelerationFraction
    let speed = 1 / (cruise + decelerationFraction / 2)
    guard progress > cruise else {
      return speed * progress
    }
    let slowing = min(progress, 1) - cruise
    return speed * (cruise + slowing - slowing * slowing / (2 * decelerationFraction))
  }

  /// How far across the screen an edge swipe travels, as a fraction of the axis it moves along. Half
  /// the screen is comfortably past the thresholds the system gestures commit at, without running the
  /// contact into the opposite edge.
  static let edgeSwipeTravelFraction: Double = 0.5

  /// A swipe inwards from a screen edge — the gesture iOS reads as a system gesture rather than as
  /// content scrolling: up from the bottom for the home indicator, down from the top for Notification
  /// Centre, rightwards from the left edge for back.
  ///
  /// `screenSize` is in points. The gesture starts one point inside the edge rather than exactly on it,
  /// because the far edge of the screen is `size - 1` in a coordinate space that starts at zero, and
  /// travels `edgeSwipeTravelFraction` of the way across.
  ///
  /// It never slows to rest: the system gestures read the flick, and slowing to rest first can turn a
  /// swipe up from the bottom into the App Switcher instead of Home.
  ///
  /// `.none` is accepted and produces a stationary contact at the screen centre with no edge flag, so
  /// a caller threading an edge through from a CLI argument does not have to special-case it.
  static func edgeSwipe(
    _ edge: SimulatorHIDEdge, screenSize: CGSize, duration: Double, delta: Double = defaultSwipeDelta
  ) -> SimulatorHIDEvent {
    let width = Double(screenSize.width)
    let height = Double(screenSize.height)
    let midX = width / 2
    let midY = height / 2
    let travelX = width * edgeSwipeTravelFraction
    let travelY = height * edgeSwipeTravelFraction

    let start: CGPoint
    let end: CGPoint
    switch edge {
    case .top:
      start = CGPoint(x: midX, y: 1)
      end = CGPoint(x: midX, y: travelY)
    case .bottom:
      start = CGPoint(x: midX, y: height - 1)
      end = CGPoint(x: midX, y: height - travelY)
    case .left:
      start = CGPoint(x: 1, y: midY)
      end = CGPoint(x: travelX, y: midY)
    case .right:
      start = CGPoint(x: width - 1, y: midY)
      end = CGPoint(x: width - travelX, y: midY)
    case .none:
      start = CGPoint(x: midX, y: midY)
      end = CGPoint(x: midX, y: midY)
    }

    return swipe(
      Double(start.x), yStart: Double(start.y), xEnd: Double(end.x), yEnd: Double(end.y),
      delta: delta, duration: duration, edge: edge, decelerationDuration: 0)
  }

  /// A press-and-drag: hold at the source for `pressDuration`, travel over interpolated samples spread
  /// across `duration`, hold at the destination for `releaseDuration`, then lift. The initial hold is what
  /// starts an iOS drag session (it must clear the long-press threshold); `swipe` cannot express it.
  static func drag(
    _ xStart: Double, yStart: Double, xEnd: Double, yEnd: Double, delta: Double,
    pressDuration: Double, duration: Double, releaseDuration: Double
  ) -> SimulatorHIDEvent {
    let distance = sqrt(pow(yEnd - yStart, 2) + pow(xEnd - xStart, 2))
    var effectiveDelta = delta
    if effectiveDelta <= 0.0 {
      effectiveDelta = defaultSwipeDelta
    }
    let steps = max(1, Int(distance / effectiveDelta))

    let dx = (xEnd - xStart) / Double(steps)
    let dy = (yEnd - yStart) / Double(steps)
    let stepDelay = duration / Double(steps)

    var events: [SimulatorHIDEvent] = [
      .touch(direction: .down, x: xStart, y: yStart),
      .delay(pressDuration),
    ]
    for i in 1...steps {
      events.append(.touch(direction: .down, x: xStart + dx * Double(i), y: yStart + dy * Double(i)))
      events.append(.delay(stepDelay))
    }
    events.append(.delay(releaseDuration))
    events.append(.touch(direction: .up, x: xEnd, y: yEnd))

    return .composite(events)
  }

  /// A tvOS Siri Remote trackpad pan (unit-square points): began → changed×steps → ended, with small delays
  /// so the focus engine sees velocity. Indigo only. The `?? from` fallbacks are unreachable — interpolating
  /// two in-square points stays in the square.
  static func pan(
    from: SimulatorTrackpadPoint, to: SimulatorTrackpadPoint, steps: Int, duration: Double
  ) -> SimulatorHIDEvent {
    let n = max(1, steps)
    let stepDelay = duration / Double(n + 1)
    var events: [SimulatorHIDEvent] = [.trackpad(phase: .began, point: from)]
    for i in 1...n {
      let t = Double(i) / Double(n + 1)
      let sample =
        SimulatorTrackpadPoint(
          x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t
        ) ?? from
      events.append(.delay(stepDelay))
      events.append(.trackpad(phase: .changed, point: sample))
    }
    events.append(.delay(stepDelay))
    events.append(.trackpad(phase: .ended, point: to))
    return .composite(events)
  }

  static func pinchAt(
    x centerX: Double, y centerY: Double, scale: Double, duration: Double, radius: Double
  ) -> SimulatorHIDEvent {
    let startRadius = radius
    let endRadius = radius * scale
    let fingerDistance = abs(endRadius - startRadius)

    let delta = defaultSwipeDelta
    var steps = Int(fingerDistance / delta)
    if steps < 2 { steps = 2 }
    let stepDelay = duration / Double(steps + 2)

    var events: [SimulatorHIDEvent] = []

    let f1Start = CGPoint(x: centerX - startRadius, y: centerY)
    let f2Start = CGPoint(x: centerX + startRadius, y: centerY)
    events.append(.twoFingerTouch(direction: .down, finger1: f1Start, finger2: f2Start))
    events.append(.delay(stepDelay))

    let dr = (endRadius - startRadius) / Double(steps)
    for i in 1...steps {
      let r = startRadius + dr * Double(i)
      let f1 = CGPoint(x: centerX - r, y: centerY)
      let f2 = CGPoint(x: centerX + r, y: centerY)
      events.append(.twoFingerTouch(direction: .down, finger1: f1, finger2: f2))
      events.append(.delay(stepDelay))
    }

    // Duplicate final touch-down to avoid inertial scroll on arm simulators
    let f1End = CGPoint(x: centerX - endRadius, y: centerY)
    let f2End = CGPoint(x: centerX + endRadius, y: centerY)
    events.append(.twoFingerTouch(direction: .down, finger1: f1End, finger2: f2End))
    events.append(.delay(stepDelay))

    events.append(.twoFingerTouch(direction: .up, finger1: f1End, finger2: f2End))

    return .composite(events)
  }
}

// MARK: - CustomStringConvertible

/// How much of an event's payload log lines carry. Coordinates and key codes can reveal what is being typed or tapped.
public enum SimulatorHIDEventLogging: Sendable {
  case redacted
  case detailed
}

extension SimulatorHIDEvent: CustomStringConvertible {
  public var description: String {
    logDescription(.redacted)
  }

  public func logDescription(_ logging: SimulatorHIDEventLogging) -> String {
    let detailed = logging == .detailed
    switch self {
    case let .touch(direction, x, y, edge):
      guard detailed else { return "Touch <hidden>" }
      guard edge != .none else { return "Touch \(direction.name) at (\(x),\(y))" }
      return "Touch \(direction.name) at (\(x),\(y)) from the \(edge.name) edge"
    case let .button(direction, button):
      guard detailed else { return "Button <hidden>" }
      return "Button \(button.name) \(direction.name)"
    case let .remoteButton(direction, button):
      guard detailed else { return "Remote <hidden>" }
      return "Remote \(button.name) \(direction.name)"
    case let .keyboard(direction, keyCode):
      guard detailed else { return "Key <hidden>" }
      return "Keyboard Code=\(keyCode) \(direction.name)"
    case let .twoFingerTouch(direction, finger1, finger2):
      guard detailed else { return "TwoFingerTouch <hidden>" }
      return "TwoFingerTouch \(direction.name) at (\(finger1.x),\(finger1.y)) (\(finger2.x),\(finger2.y))"
    case let .trackpad(phase, point):
      guard detailed else { return "Trackpad <hidden>" }
      return "Trackpad \(phase.name) at (\(point.x),\(point.y))"
    case let .watchButton(direction, button):
      guard detailed else { return "WatchButton <hidden>" }
      return "WatchButton \(button.name) \(direction.name)"
    case let .crown(direction, delta):
      guard detailed else { return "Crown <hidden>" }
      guard direction == .down else { return "Crown release" }
      return "Crown rotate \(delta)"
    case let .delay(duration):
      return "Delay for \(duration)"
    case let .composite(events):
      return "Composite [\(events.map { $0.logDescription(logging) }.joined(separator: ", "))]"
    }
  }
}
