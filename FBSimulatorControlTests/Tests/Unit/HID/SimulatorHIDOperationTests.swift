/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorControl
import Foundation
import XCTest

final class SimulatorHIDOperationTests: XCTestCase {
  func testNestedGestureUsesOneDisplayBindingAndDrainsOnce() async throws {
    let recorder = Recorder()
    var operation = Self.makeOperation(recorder)
    let deliveries = try await operation.send(.composite([.composite([.tapAt(x: 20, y: 30)])]))
    try await operation.finish(flushing: true)
    XCTAssertEqual(deliveries, [.unchanged(.touch(direction: .down, x: 20, y: 30)), .unchanged(.touch(direction: .up, x: 20, y: 30))])
    let events = await recorder.events
    XCTAssertEqual(events.map(\.0), [.touch(direction: .down, x: 20, y: 30), .touch(direction: .up, x: 20, y: 30)])
    XCTAssertEqual(events.compactMap(\.1), [display(), display()])
    let flushes = await recorder.flushes
    XCTAssertEqual(flushes, 1)
  }

  func testFallbackDeliversEventsWithoutADisplay() async throws {
    let recorder = Recorder()
    var operation = SimulatorHIDOperation(
      displays: DisplayCommandsDouble([.success(.failed(.unsupported("displayinfo")))]),
      sink: recorder)
    _ = try await operation.send(.tapAt(x: 20, y: 30))
    try await operation.finish(flushing: false)
    let events = await recorder.events
    XCTAssertEqual(events.map(\.0), [.touch(direction: .down, x: 20, y: 30), .touch(direction: .up, x: 20, y: 30)])
    XCTAssertEqual(events.compactMap(\.1), [])
  }

  func testSeveralActiveDisplaysFailWithoutDelivering() async throws {
    let recorder = Recorder()
    var operation = SimulatorHIDOperation(
      displays: DisplayCommandsDouble([.success(.displays([screen("cover"), screen("inner")]))]),
      sink: recorder)
    let sent: Result<Void, any Error>
    do {
      _ = try await operation.send(.tapAt(x: 20, y: 30))
      try await operation.finish(flushing: false)
      sent = .success(())
    } catch {
      sent = .failure(error)
    }
    guard case .failure(SimulatorDisplayError.ambiguousActiveDisplays) = sent else { return XCTFail("\(sent)") }
    let events = await recorder.events
    XCTAssertEqual(events.count, 0)
  }

  func testNonFiniteTouchWithoutADisplay() async throws {
    let recorder = Recorder()
    var operation = SimulatorHIDOperation(
      displays: DisplayCommandsDouble([.success(.failed(.unsupported("displayinfo")))]),
      sink: recorder)
    do {
      _ = try await operation.send(.tapAt(x: .nan, y: 30))
      XCTFail("expected invalid coordinates")
    } catch {
      guard case let SimulatorDisplayInteractionError.nonFinitePoint(point) = error else { return XCTFail("unexpected error: \(error)") }
      XCTAssertTrue(point.x.isNaN)
      XCTAssertEqual(point.y, 30)
      XCTAssertEqual(error.localizedDescription, "Touch point (nan, 30.0) is not a real position (x is NaN)")
      await Self.assertCleanup(operation)
    }
    let events = await recorder.events
    XCTAssertTrue(events.isEmpty)
  }

  func testDisplayTransitionReleasesOnOriginalTargetWithoutSendingToNewTarget() async throws {
    let recorder = Recorder()
    let observation = SimulatorHIDDisplayObservation()
    var operation = Self.makeOperation(recorder, observation: observation)
    _ = try await operation.send(.touch(direction: .down, x: 20, y: 30))
    observation.record(.success(display("cover", target: 9)), matching: display())
    observation.record(.success(display()), matching: display())
    do {
      _ = try await operation.send(.touch(direction: .up, x: 20, y: 30))
      XCTFail("expected a changed-display error")
    } catch {
      guard case SimulatorDisplayError.changed = error else { return XCTFail("unexpected error: \(error)") }
      await Self.assertCleanup(operation)
    }
    let events = await recorder.events
    XCTAssertEqual(events.map(\.0), [.touch(direction: .down, x: 20, y: 30), .touch(direction: .up, x: 20, y: 30)])
    XCTAssertEqual(events.compactMap(\.1), [display(), display()])
  }

  func testDisplayTransitionObservedMidGestureFailsAsAChangedDisplay() async throws {
    let recorder = Recorder()
    let observation = SimulatorHIDDisplayObservation()
    var operation = Self.makeOperation(recorder, observation: observation)
    _ = try await operation.send(.touch(direction: .down, x: 20, y: 30))
    observation.record(.failure(SimulatorDisplayError.transitioning), matching: display())
    do {
      _ = try await operation.send(.touch(direction: .up, x: 20, y: 30))
      XCTFail("expected the gesture to fail")
    } catch {
      guard case SimulatorDisplayError.changed = error else { return XCTFail("unexpected error: \(error)") }
      await Self.assertCleanup(operation)
    }
  }

  func testOffScreenMoveMidGesture() async throws {
    let recorder = Recorder()
    var operation = Self.makeOperation(recorder)
    _ = try await operation.send(.touch(direction: .down, x: 20, y: 30))
    let deliveries = try await operation.send(.touch(direction: .down, x: -1, y: 30))
    await Self.assertCleanup(operation)
    let events = await recorder.events
    XCTAssertEqual(
      events.map(\.0),
      [.touch(direction: .down, x: 20, y: 30), .touch(direction: .down, x: 0, y: 30), .touch(direction: .up, x: 0, y: 30)])
    XCTAssertEqual(
      deliveries,
      [.clamped(requested: .touch(direction: .down, x: -1, y: 30), delivered: .touch(direction: .down, x: 0, y: 30), bounds: CGSize(width: 200, height: 300))])
  }

  func testOffScreenTwoFingerTouchOnRotatedDisplay() async throws {
    let recorder = Recorder()
    await recorder.setDisplay(screen(rotation: .clockwise))
    var operation = Self.makeOperation(recorder)
    let first = CGPoint(x: 20, y: 30)
    let second = CGPoint(x: 20, y: 250)
    let down = try await operation.send(.twoFingerTouch(direction: .down, finger1: first, finger2: second))
    let up = try await operation.send(.twoFingerTouch(direction: .up, finger1: first, finger2: second))
    try await operation.finish(flushing: true)
    let clamped = CGPoint(x: 20, y: 200)
    let events = await recorder.events
    XCTAssertEqual(
      events.map(\.0),
      [
        .twoFingerTouch(direction: .down, finger1: first, finger2: clamped),
        .twoFingerTouch(direction: .up, finger1: first, finger2: clamped),
      ])
    let bounds = CGSize(width: 300, height: 200)
    XCTAssertEqual(
      down + up,
      [
        .clamped(
          requested: .twoFingerTouch(direction: .down, finger1: first, finger2: second),
          delivered: .twoFingerTouch(direction: .down, finger1: first, finger2: clamped), bounds: bounds),
        .clamped(
          requested: .twoFingerTouch(direction: .up, finger1: first, finger2: second),
          delivered: .twoFingerTouch(direction: .up, finger1: first, finger2: clamped), bounds: bounds),
      ])
  }

  func testNonFiniteTouchFailsWithoutDelivering() async throws {
    let recorder = Recorder()
    var operation = Self.makeOperation(recorder)
    do {
      _ = try await operation.send(.tapAt(x: .nan, y: 30))
      XCTFail("expected invalid coordinates")
    } catch {
      guard case let SimulatorDisplayInteractionError.nonFinitePoint(point) = error else { return XCTFail("unexpected error: \(error)") }
      XCTAssertTrue(point.x.isNaN)
      XCTAssertEqual(point.y, 30)
      XCTAssertEqual(error.localizedDescription, "Touch point (nan, 30.0) is not a real position (x is NaN)")
      await Self.assertCleanup(operation)
    }
    let events = await recorder.events
    XCTAssertTrue(events.isEmpty)
  }

  func testFinalReadDetectsRotationAfterLastTouch() async throws {
    let recorder = Recorder()
    var operation = Self.makeOperation(recorder)
    _ = try await operation.send(.tapAt(x: 20, y: 30))
    await recorder.setDisplay(screen(rotation: .clockwise))
    do {
      try await operation.finish(flushing: true)
      XCTFail("expected the final display check to fail")
    } catch {
      guard case SimulatorDisplayError.changed = error else { return XCTFail("unexpected error: \(error)") }
    }
  }

  func testCancellationReleasesBothFingersAndDrainsOutsideCancelledTask() async throws {
    let recorder = Recorder()
    let entered = AsyncEvent<Void>()
    let first = CGPoint(x: 20, y: 30)
    let second = CGPoint(x: 50, y: 60)
    let task = Task {
      var operation = Self.makeOperation(recorder)
      do {
        _ = try await operation.send(.twoFingerTouch(direction: .down, finger1: first, finger2: second))
        entered.happen()
        try await Task.sleep(nanoseconds: 60_000_000_000)
      } catch {
        await Self.assertCleanup(operation)
        throw error
      }
    }
    try? await entered.waitIgnoringCancellation()
    task.cancel()
    do {
      try await task.value
      XCTFail("expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    let events = await recorder.events
    XCTAssertEqual(
      events.map(\.0),
      [
        .twoFingerTouch(direction: .down, finger1: first, finger2: second),
        .twoFingerTouch(direction: .up, finger1: first, finger2: second),
      ])
    let cancelled = await recorder.cancelledDeliveries
    let flushes = await recorder.flushes
    XCTAssertEqual(cancelled, 0)
    XCTAssertEqual(flushes, 1)
  }

  func testCancellationDuringDisplayLookupDoesNotWrite() async throws {
    let recorder = Recorder()
    let entered = AsyncEvent<Void>()
    let release = AsyncEvent<Void>()
    await recorder.block(after: 0, until: release, entered: entered)
    let task = Task {
      var operation = Self.makeOperation(recorder)
      do {
        _ = try await operation.send(.tapAt(x: 20, y: 30))
      } catch {
        await Self.assertCleanup(operation)
        throw error
      }
    }
    try? await entered.waitIgnoringCancellation()
    task.cancel()
    release.happen()
    do {
      try await task.value
      XCTFail("expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    let events = await recorder.events
    XCTAssertTrue(events.isEmpty)
  }

  func testSlowDisplayObservationDoesNotDelayTouchSamples() async throws {
    let recorder = Recorder()
    let release = AsyncEvent<Void>()
    await recorder.block(after: 1, until: release)
    recorder.identities.remember([SimulatorTouchscreen(displayUniqueID: "inner", digitizerTarget: 7)])
    let sent = expectation(description: "touch samples sent while observation is blocked")
    let task = Task {
      var operation = Self.makeOperation(recorder)
      _ = try await operation.send(.tapAt(x: 20, y: 30))
      sent.fulfill()
      try await operation.finish(flushing: true)
    }
    await fulfillment(of: [sent], timeout: 2)
    release.happen()
    try await task.value
    let events = await recorder.events
    XCTAssertEqual(events.count, 2)
  }

  func testLeaseExcludesConcurrentOperationAndCancelledWaiterDoesNotBlockNext() async throws {
    let lease = SimulatorHIDOperationLease()
    let entered = AsyncEvent<Void>()
    let release = AsyncEvent<Void>()
    let waiting = AsyncEvent<Void>()
    let first = Task {
      try await lease.withLease {
        entered.happen()
        try? await release.waitIgnoringCancellation()
      }
    }
    try? await entered.waitIgnoringCancellation()
    let cancelled = Task {
      waiting.happen()
      try await lease.withLease { XCTFail("cancelled waiter must not acquire the lease") }
    }
    try? await waiting.waitIgnoringCancellation()
    cancelled.cancel()
    do {
      try await cancelled.value
      XCTFail("expected cancellation while waiting")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    release.happen()
    try await first.value
    let value = try await lease.withLease { 42 }
    XCTAssertEqual(value, 42)
  }

  func testPinnedGestureBindsEveryEventToTheConfirmedDisplay() async throws {
    let recorder = Recorder()
    var operation = Self.makeOperation(recorder, binding: .display(uniqueID: "inner"))
    _ = try await operation.send(.touch(direction: .down, x: 20, y: 30))
    _ = try await operation.send(.touch(direction: .down, x: 25, y: 35))
    _ = try await operation.send(.touch(direction: .up, x: 25, y: 35))
    try await operation.finish(flushing: true)
    let events = await recorder.events
    XCTAssertEqual(events.compactMap(\.1), [display(), display(), display()])
  }

  func testPinnedGestureAcceptsMatchingSoleIdentifiedDisplay() async throws {
    let recorder = Recorder()
    let displays = DisplayCommandsDouble(.sole(.identified(screen())))
    var operation = SimulatorHIDOperation(
      displays: displays,
      binding: .display(uniqueID: "inner"),
      sink: recorder)

    _ = try await operation.send(.tapAt(x: 20, y: 30))
    try await operation.finish(flushing: true)

    let events = await recorder.events
    XCTAssertEqual(events.map(\.0), [.touch(direction: .down, x: 20, y: 30), .touch(direction: .up, x: 20, y: 30)])
    XCTAssertEqual(events.compactMap(\.1), [.sole(.identified(screen())), .sole(.identified(screen()))])
  }

  func testPinnedGestureRefusesMismatchedSoleIdentifiedDisplay() async throws {
    let recorder = Recorder()
    var operation = SimulatorHIDOperation(
      displays: DisplayCommandsDouble(.sole(.identified(screen("cover")))),
      binding: .display(uniqueID: "inner"),
      sink: recorder)

    do {
      _ = try await operation.send(.touch(direction: .down, x: 20, y: 30))
      XCTFail("expected the pin to refuse the sole display")
    } catch {
      guard case let SimulatorDisplayInteractionError.inactiveDisplay(identity) = error, identity == "inner" else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testPinnedGestureRefusesLegacySoleDisplayWithoutAnIdentity() async throws {
    let recorder = Recorder()
    var operation = SimulatorHIDOperation(
      displays: DisplayCommandsDouble(.sole(.legacy(screen().geometry))),
      binding: .display(uniqueID: "inner"),
      sink: recorder)

    do {
      _ = try await operation.send(.touch(direction: .down, x: 20, y: 30))
      XCTFail("expected an unidentified sole display to refuse the pin")
    } catch {
      guard case let SimulatorDisplayInteractionError.inactiveDisplay(identity) = error, identity == "inner" else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testPinnedGestureIsRefusedWhenAnotherDisplayIsActive() async throws {
    let recorder = Recorder()
    var operation = Self.makeOperation(recorder, binding: .display(uniqueID: "cover"))
    do {
      _ = try await operation.send(.touch(direction: .down, x: 20, y: 30))
      XCTFail("expected the pin to refuse the active display")
    } catch {
      guard case let SimulatorDisplayInteractionError.inactiveDisplay(identity) = error, identity == "cover" else {
        return XCTFail("unexpected error: \(error)")
      }
      _ = await operation.cleanup()
    }
    let events = await recorder.events
    XCTAssertTrue(events.isEmpty)
  }

  func testAbandonedPinnedGestureReleasesOnTheDisplayItOpenedOn() async throws {
    let recorder = Recorder()
    var operation = Self.makeOperation(recorder, binding: .display(uniqueID: "inner"))
    _ = try await operation.send(.touch(direction: .down, x: 20, y: 30))
    await recorder.setDisplay(screen("cover"))
    _ = await operation.cleanup()
    let events = await recorder.events
    XCTAssertEqual(events.map(\.0), [.touch(direction: .down, x: 20, y: 30), .touch(direction: .up, x: 20, y: 30)])
    XCTAssertEqual(events.compactMap(\.1), [display(), display()])
  }

  func testConfigurationBoundGestureDeliversWhileItsGenerationIsCurrent() async throws {
    let recorder = Recorder()
    let configuration = try recorder.configurationTracker.observe(.reporting(.selected(screen())))
    var operation = Self.makeOperation(recorder, binding: .configuration(generation: configuration.generation))
    _ = try await operation.send(.tapAt(x: 20, y: 30))
    try await operation.finish(flushing: true)
    let events = await recorder.events
    XCTAssertEqual(events.compactMap(\.1), [display(), display()])
  }

  func testConfigurationBoundGestureIsRefusedOnceTheGenerationMovesOn() async throws {
    let recorder = Recorder()
    let stale = try recorder.configurationTracker.observe(.reporting(.selected(screen(rotation: .clockwise))))
    var operation = Self.makeOperation(recorder, binding: .configuration(generation: stale.generation))
    do {
      _ = try await operation.send(.touch(direction: .down, x: 20, y: 30))
      XCTFail("expected a stale configuration")
    } catch {
      guard case SimulatorDisplayError.changed = error else { return XCTFail("unexpected error: \(error)") }
      await Self.assertCleanup(operation)
    }
    let events = await recorder.events
    XCTAssertTrue(events.isEmpty)
  }

  func testGenerationChangeSeenByAnotherReaderFailsTheGestureAndReleasesOnTheOriginalDisplay() async throws {
    let recorder = Recorder()
    var operation = Self.makeOperation(recorder)
    _ = try await operation.send(.touch(direction: .down, x: 20, y: 30))
    _ = try recorder.configurationTracker.observe(.reporting(.selected(screen(rotation: .clockwise))))
    _ = try recorder.configurationTracker.observe(.reporting(.selected(screen())))
    do {
      try await operation.finish(flushing: true)
      XCTFail("expected a changed display")
    } catch {
      guard case SimulatorDisplayError.changed = error else { return XCTFail("unexpected error: \(error)") }
      await Self.assertCleanup(operation)
    }
    let events = await recorder.events
    XCTAssertEqual(events.map(\.0), [.touch(direction: .down, x: 20, y: 30), .touch(direction: .up, x: 20, y: 30)])
    XCTAssertEqual(events.compactMap(\.1), [display(), display()])
  }

  private static func makeOperation(
    _ recorder: Recorder,
    observation: SimulatorHIDDisplayObservation = SimulatorHIDDisplayObservation(),
    binding: DisplaySelection = .active
  ) -> SimulatorHIDOperation {
    SimulatorHIDOperation(
      displays: recorder,
      binding: binding,
      sink: recorder,
      observation: observation)
  }

  private static func assertCleanup(_ operation: SimulatorHIDOperation) async {
    let failures = await operation.cleanup()
    XCTAssertTrue(failures.isEmpty, "cleanup failed: \(failures)")
  }

  private func display(_ identity: String = "inner", target: UInt32 = 7, rotation: SimulatorDisplayRotation = .upright) -> SimulatorHIDDisplay {
    .selected(screen(identity, rotation: rotation), id: target)
  }

  private func screen(_ identity: String = "inner", rotation: SimulatorDisplayRotation = .upright) -> SimulatorDisplay {
    Self.makeScreen(identity, rotation: rotation)
  }

  private static func makeScreen(_ identity: String = "inner", rotation: SimulatorDisplayRotation = .upright) -> SimulatorDisplay {
    SimulatorDisplay(
      uniqueID: identity, name: identity, activity: .active, isPrimary: true, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: 600, height: 900), scale: 3, rotation: rotation)
  }

  /// One of several displays, reached through digitizer target 7, and the sink recording what reaches it. Reads past `block(after:)` wait on the gate.
  private actor Recorder: DisplayCommands, SimulatorHIDOperationSink {
    nonisolated let identities = DisplayIdentityCache()
    nonisolated let configurationTracker = DisplayConfigurationTracker()
    var currentDisplay: SimulatorDisplay = SimulatorHIDOperationTests.makeScreen()
    var events: [(SimulatorHIDEvent, SimulatorHIDDisplay?)] = []
    var flushes = 0
    var cancelledDeliveries = 0
    private var reads = 0
    private var blocking: (after: Int, gate: AsyncEvent<Void>, entered: AsyncEvent<Void>?)?

    func block(after reads: Int, until gate: AsyncEvent<Void>, entered: AsyncEvent<Void>? = nil) {
      blocking = (reads, gate, entered)
    }

    func report() async throws -> SimulatorDisplayReport {
      reads += 1
      if let blocking, reads > blocking.after {
        blocking.entered?.happen()
        try? await blocking.gate.waitIgnoringCancellation()
      }
      return .reporting(.selected(currentDisplay))
    }

    func touchscreens() -> [SimulatorTouchscreen] {
      [SimulatorTouchscreen(displayUniqueID: currentDisplay.uniqueID, digitizerTarget: 7)]
    }

    func setDisplay(_ display: SimulatorDisplay) { currentDisplay = display }
    func deliver(_ event: SimulatorHIDEvent, display: SimulatorHIDDisplay?) {
      events.append((event, display))
      if Task.isCancelled { cancelledDeliveries += 1 }
    }
    func flush() { flushes += 1 }
  }
}
