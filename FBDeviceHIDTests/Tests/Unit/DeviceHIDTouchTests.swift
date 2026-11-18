/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBDeviceHID
import Foundation
import Testing

@Suite("Bounded physical touch sequences")
struct DeviceHIDTouchTests {
  @Test func compilesExplicitPhasesAndAccumulatesHolds() throws {
    let sequence = try DeviceHIDTouchSequence([
      .down(x: 10, y: 20), .delay(0.1), .delay(0.2),
      .move(x: 30, y: 40), .delay(0.3), .move(x: 50, y: 60), .up(x: 50, y: 60),
    ])
    #expect(sequence.positions.map(\.point) == [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40), CGPoint(x: 50, y: 60)])
    #expect(abs(sequence.positions[0].delay - 0.3) < 1e-12)
    #expect(abs(sequence.duration - 0.6) < 1e-12)
  }

  @Test func rejectsIncompleteMultipleAndOversizedContacts() {
    let down = DeviceHIDTouchEvent.down(x: 1, y: 2)
    let up = DeviceHIDTouchEvent.up(x: 1, y: 2)
    let invalid: [[DeviceHIDTouchEvent]] = [
      [], [down], [up, down], [down, down, up], [down, .move(x: 2, y: 3)],
      [down, .move(x: 2, y: 3), up], [down, up, .delay(0)], [down, up, down, up],
      [down, .delay(5), up], [down, .delay(.nan), up], [down, .delay(-1), up],
      [down, .move(x: .infinity, y: 2), .up(x: .infinity, y: 2)],
      [down] + Array(repeating: .delay(0), count: 255) + [up],
    ]
    for events in invalid {
      #expect(throws: DeviceHIDError.self) { try DeviceHIDTouchSequence(events) }
    }
  }

  @Test func positionsAreSentInOrderAndEndMatchesTheLastPosition() async throws {
    let fixture = DeviceHIDFixture()
    let first = CGPoint(x: 0.25, y: 0.5)
    let middle = CGPoint(x: 0.5, y: 0.5)
    let last = CGPoint(x: 0.75, y: 0.5)
    let operation = DeviceHIDOperation(
      transport: fixture.transport, prepared: DeviceHIDFixture.prepared(duration: 0.01),
      positions: [DeviceHIDPosition(point: middle, delay: 0.01), DeviceHIDPosition(point: last, delay: 0.01)],
      quarantine: { fixture.state.sync { $0.quarantined = true } })
    let outcome = await operation.run()
    #expect(outcome.error == nil)
    #expect(!outcome.uncertain)
    #expect(fixture.state.sync { $0.points } == [first, middle, last, last])
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("position") == 2)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
    let start = try #require(fixture.events.time("startReturned"))
    let position = try #require(fixture.events.time("position"))
    #expect(start.duration(to: position) >= .seconds(0.01))
  }

  @Test func failedPositionEndsTheAttemptedPointWithoutRetry() async {
    let fixture = DeviceHIDFixture(fail: "position")
    let middle = CGPoint(x: 0.5, y: 0.5)
    let operation = DeviceHIDOperation(
      transport: fixture.transport, prepared: DeviceHIDFixture.prepared(),
      positions: [DeviceHIDPosition(point: middle, delay: 0), DeviceHIDPosition(point: CGPoint(x: 0.75, y: 0.5), delay: 0)],
      quarantine: { fixture.state.sync { $0.quarantined = true } })
    let outcome = await operation.run()
    #expect(outcome.uncertain)
    #expect(outcome.error != nil)
    #expect(fixture.state.sync { $0.quarantined })
    #expect(fixture.state.sync { $0.points } == [CGPoint(x: 0.25, y: 0.5), middle, middle])
    #expect(fixture.events.count("position") == 1)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
  }

  @Test func cancellationBeforeMoveReleasesCurrentNotFuturePoint() async throws {
    let fixture = DeviceHIDFixture()
    let operation = DeviceHIDOperation(
      transport: fixture.transport, prepared: DeviceHIDFixture.prepared(duration: 1),
      positions: [DeviceHIDPosition(point: CGPoint(x: 0.75, y: 0.5), delay: 0)], quarantine: {})
    let task = Task { await operation.run() }
    try await fixture.events.waitFor("startReturned")
    operation.cancel()
    let outcome = await task.value
    #expect(outcome.error is CancellationError)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("position") == 0)
    #expect(fixture.state.sync { $0.points } == [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.25, y: 0.5)])
    #expect(fixture.events.count("end") == 1)
  }

  @Test func initialAndFinalHoldsAreIndependent() async throws {
    let fixture = DeviceHIDFixture()
    let operation = DeviceHIDOperation(
      transport: fixture.transport, prepared: DeviceHIDFixture.prepared(duration: 0.02),
      positions: [DeviceHIDPosition(point: CGPoint(x: 0.5, y: 0.5), delay: 0.03)], quarantine: {})
    let outcome = await operation.run()
    #expect(outcome.error == nil)
    let startReturned = try #require(fixture.events.time("startReturned"))
    let position = try #require(fixture.events.time("position"))
    let positionReturned = try #require(fixture.events.time("positionReturned"))
    let end = try #require(fixture.events.time("end"))
    #expect(startReturned.duration(to: position) >= .seconds(0.02))
    #expect(positionReturned.duration(to: end) >= .seconds(0.03))
  }

  @Test func cancelledBlockedPositionOnlyEndsAfterReturn() async throws {
    let fixture = DeviceHIDFixture(block: "position")
    let outcome = try await finishBlockedPosition(fixture)
    try await fixture.events.waitFor("transportRetired")
    #expect(!outcome.uncertain)
    #expect(!fixture.state.sync { $0.quarantined })
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("position") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
    #expect(fixture.events.count("release") == 1)
    #expect(outcome.error is CancellationError)
    #expect(fixture.state.sync { $0.points } == [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5)])
  }

  private func finishBlockedPosition(_ fixture: DeviceHIDFixture) async throws -> DeviceHIDOutcome {
    defer { fixture.gate.open() }
    let operation = DeviceHIDOperation(
      transport: fixture.transport, prepared: DeviceHIDFixture.prepared(),
      positions: [DeviceHIDPosition(point: CGPoint(x: 0.5, y: 0.5), delay: 0), DeviceHIDPosition(point: CGPoint(x: 0.75, y: 0.5), delay: 0)],
      operationSeconds: 2, cleanupReserve: 0,
      quarantine: { fixture.state.sync { $0.quarantined = true } })
    let task = Task { await operation.run() }
    try await fixture.events.waitFor("position")
    operation.cancel()
    #expect(fixture.events.count("end") == 0)
    #expect(fixture.events.count("release") == 0)
    fixture.gate.open()
    return await task.value
  }

  @Test func allPointsAndCombinedHoldAreValidatedBeforeStart() async {
    for positions in [
      [DeviceHIDPosition(point: CGPoint(x: 1, y: 0.5), delay: 0)],
      [DeviceHIDPosition(point: CGPoint(x: 0.5, y: 0.5), delay: .nan)],
      [DeviceHIDPosition(point: CGPoint(x: 0.5, y: 0.5), delay: 4)],
    ] {
      let fixture = DeviceHIDFixture()
      let operation = DeviceHIDOperation(
        transport: fixture.transport, prepared: DeviceHIDFixture.prepared(duration: 1), positions: positions,
        operationSeconds: 10, cleanupReserve: 5, quarantine: {})
      let outcome = await operation.run()
      #expect(outcome.error != nil)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("start") == 0)
    }
  }
}
