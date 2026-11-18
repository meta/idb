/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBDeviceControl
@testable import FBDeviceHID
import Foundation
import Testing

@Suite("Bounded sequential physical contacts")
struct DeviceHIDMultiTouchTests {
  @Test func compilesContactBoundariesAndPauses() throws {
    let sequence = try DeviceHIDTouchSequence([
      .down(x: 10, y: 20), .delay(0.1), .move(x: 30, y: 40), .delay(0.2), .up(x: 30, y: 40),
      .delay(0.3), .delay(0.1), .down(x: 50, y: 60), .delay(0.2), .up(x: 50, y: 60),
    ])
    #expect(sequence.contacts.count == 2)
    #expect(sequence.contacts[0].positions.map(\.point) == [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)])
    #expect(sequence.contacts[0].pause == 0.4)
    #expect(sequence.contacts[1].positions[0].delay == 0.2)
    #expect(sequence.contacts[1].pause == 0)
    #expect(abs(sequence.duration - 0.9) < 1e-12)
  }

  @Test func validatesTheWholeRecipeNotEachContactSeparately() throws {
    let down = DeviceHIDTouchEvent.down(x: 1, y: 2)
    let up = DeviceHIDTouchEvent.up(x: 1, y: 2)
    let invalid: [[DeviceHIDTouchEvent]] = [
      [down], [up], [.move(x: 1, y: 2), up], [down, down, up],
      [down, .up(x: 2, y: 2)], [.delay(.nan), down, up], [.delay(-1), down, up],
      [.delay(.infinity), down, up], [.delay(5), down, up],
      [down, .move(x: -1, y: 2), .up(x: -1, y: 2)], [down, up, .delay(0)],
    ]
    for tail in invalid {
      #expect(throws: DeviceHIDError.self) { try DeviceHIDTouchSequence([down, up] + tail) }
    }
    #expect(throws: DeviceHIDError.self) {
      try DeviceHIDTouchSequence([down, .delay(2), up, .delay(1), down, .delay(2), up])
    }
    let boundary = Array(repeating: [down, up], count: 128).flatMap { $0 }
    #expect(try DeviceHIDTouchSequence(boundary).contacts.count == 128)
    #expect(throws: DeviceHIDError.self) { try DeviceHIDTouchSequence(boundary + [down, up]) }
  }

  @Test func oneOwnerOrdersAllContactsAndOneFinalBarrier() async throws {
    let fixture = DeviceHIDFixture()
    let outcome = await operation(fixture, pause: 0.02).run()
    #expect(outcome.error == nil)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("acquire") == 1)
    #expect(fixture.events.count("factory") == 1)
    #expect(fixture.events.count("start") == 3)
    #expect(fixture.events.count("position") == 3)
    #expect(fixture.events.count("end") == 3)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("release") == 1)
    #expect(fixture.events.count("discard") == 1)
    #expect(fixture.state.sync { $0.points.map(\.x) } == [0.25, 0.3, 0.3, 0.5, 0.6, 0.6, 0.75, 0.8, 0.8])
    let end = try #require(fixture.events.time("end1Returned"))
    let second = try #require(fixture.events.time("start2"))
    #expect(end.duration(to: second) >= .seconds(0.02))
    #expect(try #require(fixture.events.time("end2Returned")) <= #require(fixture.events.time("start3")))
    #expect(try #require(fixture.events.time("end3Returned")) <= #require(fixture.events.time("barrier")))
  }

  @Test(arguments: ["start1", "position1", "end1", "start2", "position2", "end2", "barrier"])
  func nativeFailureStopsWithoutReplayingOrLiftingEarlierContacts(failure: String) async {
    let fixture = DeviceHIDFixture(fail: failure)
    let outcome = await operation(fixture).run()
    let started = failure == "barrier" ? 3 : (failure.hasSuffix("1") ? 1 : 2)
    #expect(outcome.error != nil)
    #expect(outcome.uncertain)
    #expect(fixture.state.sync { $0.quarantined })
    #expect(fixture.events.count("start") == started)
    #expect(fixture.events.count("end") == started)
    #expect(fixture.events.count("release") == 1)
    let expected: [CGFloat]
    switch failure {
    case "start1": expected = [0.25, 0.25]
    case "position1", "end1": expected = [0.25, 0.3, 0.3]
    case "start2": expected = [0.25, 0.3, 0.3, 0.5, 0.5]
    case "position2", "end2": expected = [0.25, 0.3, 0.3, 0.5, 0.6, 0.6]
    default: expected = [0.25, 0.3, 0.3, 0.5, 0.6, 0.6, 0.75, 0.8, 0.8]
    }
    #expect(fixture.state.sync { $0.points.map(\.x) } == expected)
  }

  @Test(arguments: ["start2", "position2", "end1", "end2"])
  func cancellationWaitsForTheOwnedSendAndStopsFutureContacts(block: String) async throws {
    let fixture = DeviceHIDFixture(block: block)
    defer { fixture.gate.open() }
    let operation = operation(fixture)
    let task = Task { await operation.run() }
    try await fixture.events.waitFor(block)
    operation.cancel()
    #expect(fixture.events.count("start3") == 0)
    let ends = fixture.events.count("end")
    #expect(ends == (block == "end1" ? 1 : (block == "end2" ? 2 : 1)))
    fixture.gate.open()
    let outcome = await task.value
    #expect(outcome.error is CancellationError)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("start") == (block == "end1" ? 1 : 2))
    #expect(fixture.events.count("end") == fixture.events.count("start"))
    #expect(fixture.events.count("release") == 1)
    #expect(fixture.events.count("barrier") == 1)
    let points = fixture.state.sync { $0.points.map(\.x) }
    #expect(points.last == (block == "start2" ? 0.5 : (block == "end1" ? 0.3 : 0.6)))
  }

  @Test func invalidationJoinsBlockedEndWithoutStartingTheNextContact() async throws {
    let fixture = DeviceHIDFixture(block: "end1")
    let outcome = try await drainBlockedEnd(fixture)
    try await fixture.events.waitFor("transportRetired")
    #expect(outcome.uncertain)
    #expect(fixture.state.sync { $0.quarantined })
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("release") == 1)
  }

  private func drainBlockedEnd(_ fixture: DeviceHIDFixture) async throws -> DeviceHIDOutcome {
    defer { fixture.gate.open() }
    let operation = operation(fixture, operationSeconds: 2, cleanupReserve: 0.05)
    let task = Task { await operation.run() }
    try await fixture.events.waitFor("end1")
    operation.cancel()
    fixture.state.sync { $0.invalidated }?()
    #expect(fixture.events.count("release") == 0)
    fixture.gate.open()
    return await task.value
  }

  @Test func holdsAndPausesShareTheFirstAdmissionBudget() async {
    let fixture = DeviceHIDFixture()
    let outcome = await operation(fixture, pause: 0.2, secondHold: 0.2, operationSeconds: 0.5, cleanupReserve: 0.2).run()
    #expect(outcome.error != nil)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("start") == 0)
    #expect(fixture.events.count("release") == 1)
  }

  @Test func laterBudgetRefusalDrainsEarlierContactsWithoutClaimingPreparationFailed() async throws {
    let fixture = DeviceHIDFixture(block: "end1")
    defer { fixture.gate.open() }
    let until = ContinuousClock.now.advanced(by: .seconds(0.2))
    let operation = operation(fixture, secondHold: 0.2, operationSeconds: 0.5, cleanupReserve: 0.2)
    let task = Task { await operation.run() }
    try await fixture.events.waitFor("end1")
    fixture.events.onDeadline(until.advanced(by: .milliseconds(20)), signal: "boundary") { fixture.gate.open() }
    let outcome = await task.value
    let error = try #require(outcome.error as? DeviceHIDError)
    guard case .deadlineExceeded = error else {
      Issue.record("A partially executed recipe must report its operation deadline, not pre-input preparation failure")
      return
    }
    #expect(!outcome.uncertain)
    #expect { try outcome.get() } throws: { error in
      guard case DeviceHIDError.inputMayHaveApplied(let cause) = error,
        case DeviceHIDError.deadlineExceeded = cause
      else { return false }
      return true
    }
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("release") == 1)
    #expect(try #require(fixture.events.time("end1Returned")) <= #require(fixture.events.time("barrier")))
    #expect(try #require(fixture.events.time("barrierReturned")) <= #require(fixture.events.time("release")))
  }

  @Test func invalidLaterPayloadsFailBeforeAnyNativeCall() async {
    for plan in [
      DeviceHIDContactPlan(contact: .touch(CGPoint(x: 1, y: 0.5)), duration: 0, positions: []),
      DeviceHIDContactPlan(contact: .touch(CGPoint(x: 0.5, y: 0.5)), duration: .nan, positions: []),
      DeviceHIDContactPlan(contact: .button(.home), duration: 0, positions: []),
      DeviceHIDContactPlan(contact: .touch(CGPoint(x: 0.5, y: 0.5)), duration: 0, positions: [], pause: -1),
    ] {
      let fixture = DeviceHIDFixture()
      let prepared = DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(), positions: [], subsequent: [plan])
      let outcome = await DeviceHIDOperation(transport: fixture.transport, input: .touch(prepared), quarantine: {}).run()
      #expect(outcome.error != nil)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("acquire") == 0)
    }
  }

  @Test func theWholeRecipeSharesCommandAdmissionAndQuarantine() async throws {
    let fixture = DeviceHIDFixture(block: "start2", fail: "end2")
    defer { fixture.gate.open() }
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let prepared = prepared()
    let commands = DeviceHIDCommands(
      device: device,
      checkRuntime: {}, makeTransport: { _ in fixture.transport }, prepareTouch: { _, _ in prepared },
      prepareButton: { _, _, _ in throw DeviceHIDTestError.nativeFailure })
    let sequence = try DeviceHIDTouchSequence([.down(x: 1, y: 2), .up(x: 1, y: 2), .down(x: 1, y: 2), .up(x: 1, y: 2)])
    let task = Task { try await commands.touch(sequence) }
    try await fixture.events.waitFor("start2")
    await #expect { try await commands.touch(.tap(x: 1, y: 2, duration: nil)) } throws: { error in
      if case DeviceHIDError.busy = error { return true }
      return false
    }
    await #expect { try await commands.button(.home) } throws: { error in
      if case DeviceHIDError.busy = error { return true }
      return false
    }
    fixture.gate.open()
    await #expect(throws: (any Error).self) { try await task.value }
    await #expect { try await commands.touch(sequence) } throws: { error in
      if case DeviceHIDError.uncertainState = error { return true }
      return false
    }
    #expect(fixture.events.count("acquire") == 1)
    #expect(fixture.events.count("start") == 2)
    withExtendedLifetime(device) {}
  }

  private func prepared(pause: TimeInterval = 0, secondHold: TimeInterval = 0) -> DeviceHIDPreparedTouch {
    DeviceHIDPreparedTouch(
      start: DeviceHIDFixture.prepared(),
      positions: [DeviceHIDPosition(point: CGPoint(x: 0.3, y: 0.5), delay: 0)], pause: pause,
      subsequent: [
        DeviceHIDContactPlan(contact: .touch(CGPoint(x: 0.5, y: 0.5)), duration: secondHold, positions: [DeviceHIDPosition(point: CGPoint(x: 0.6, y: 0.5), delay: 0)]),
        DeviceHIDContactPlan(contact: .touch(CGPoint(x: 0.75, y: 0.5)), duration: 0, positions: [DeviceHIDPosition(point: CGPoint(x: 0.8, y: 0.5), delay: 0)]),
      ])
  }

  private func operation(_ fixture: DeviceHIDFixture, pause: TimeInterval = 0, secondHold: TimeInterval = 0, operationSeconds: TimeInterval = 10, cleanupReserve: TimeInterval = 5) -> DeviceHIDOperation {
    DeviceHIDOperation(
      transport: fixture.transport, input: .touch(prepared(pause: pause, secondHold: secondHold)),
      operationSeconds: operationSeconds, cleanupReserve: cleanupReserve,
      quarantine: { fixture.state.sync { $0.quarantined = true } })
  }
}
