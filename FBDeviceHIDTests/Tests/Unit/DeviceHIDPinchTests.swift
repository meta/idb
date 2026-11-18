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

@Suite("Bounded fixed two-finger input")
struct DeviceHIDPinchTests {
  @Test func matchesTheSymmetricSimulatorPinchRecipe() throws {
    let sequence = try DeviceHIDTouchSequence.pinch(x: 200, y: 200, scale: 2, duration: 0.3, radius: 50)
    #expect(sequence.contacts.count == 1)
    let positions = sequence.contacts[0].positions
    #expect(positions.map { $0.point.x } == [150, 140, 130, 120, 110, 100, 100])
    #expect(positions.map { $0.secondPoint?.x } == [250, 260, 270, 280, 290, 300, 300])
    #expect(positions.allSatisfy { $0.point.y == 200 && $0.secondPoint?.y == 200 })
    #expect(positions.allSatisfy { $0.delay == 0.3 / 7 })
    #expect(sequence.duration == 0.3)
  }

  @Test(arguments: [0.5, 1.0])
  func pinchInAndStationaryPinchKeepTwoFingers(scale: Double) throws {
    let sequence = try DeviceHIDTouchSequence.pinch(x: 200, y: 200, scale: scale, radius: 50)
    let positions = sequence.contacts[0].positions
    #expect(positions.count == 4)
    #expect(positions.first?.point.x == 150)
    let last = try #require(positions.last)
    let second = try #require(last.secondPoint)
    #expect(abs(Double(last.point.x) - (200 - 50 * scale)) < 1e-12)
    #expect(abs(Double(second.x) - (200 + 50 * scale)) < 1e-12)
    #expect(positions.allSatisfy { $0.secondPoint != nil })
  }

  @Test func rejectsUnsafeGeometryAndUnboundedRecipesBeforeSampling() throws {
    let invalid: [(Double, Double, Double, Double, Double)] = [
      (.nan, 200, 2, 0.5, 50), (200, .infinity, 2, 0.5, 50), (-1, 200, 2, 0.5, 50),
      (200, 200, 0, 0.5, 50), (200, 200, -1, 0.5, 50), (200, 200, .nan, 0.5, 50),
      (200, 200, .infinity, 0.5, 50), (200, 200, 2, -1, 50), (200, 200, 2, 5, 50),
      (200, 200, 2, .nan, 50), (200, 200, 2, .infinity, 50), (200, 200, 2, 0.5, 0),
      (200, 200, 2, 0.5, -1), (200, 200, 2, 0.5, .nan),
      (200, 200, 2, 0.5, .greatestFiniteMagnitude), (1, 200, 2, 0.5, 50),
      (1e20, 200, 1, 0.5, 1), (200, 200, .leastNonzeroMagnitude, 0.5, .leastNonzeroMagnitude),
    ]
    for (x, y, scale, duration, radius) in invalid {
      #expect(throws: DeviceHIDError.self) { try DeviceHIDTouchSequence.pinch(x: x, y: y, scale: scale, duration: duration, radius: radius) }
    }
    let boundary = try DeviceHIDTouchSequence.pinch(x: 1500, y: 200, scale: 13.5, duration: 0, radius: 100)
    #expect(boundary.contacts[0].positions.count * 2 + 1 == 255)
    #expect(throws: DeviceHIDError.self) { try DeviceHIDTouchSequence.pinch(x: 1500, y: 200, scale: 13.6, radius: 100) }
  }

  @Test func sendsAndLiftsBothLastPoints() async {
    let fixture = DeviceHIDFixture()
    let outcome = await operation(fixture).run()
    #expect(outcome.error == nil)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("acquire") == 1)
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("position") == 2)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("release") == 1)
    #expect(fixture.state.sync { $0.points.map(\.x) } == [0.25, 0.3, 0.4, 0.4])
    #expect(fixture.state.sync { $0.secondPoints.map { $0?.x } } == [0.75, 0.7, 0.6, 0.6])
  }

  @Test(arguments: ["start", "position", "end", "barrier"])
  func aNativeFailureQuarantinesWithoutRetryingEitherFinger(failure: String) async {
    let fixture = DeviceHIDFixture(fail: failure)
    let outcome = await operation(fixture).run()
    #expect(outcome.error != nil)
    #expect(outcome.uncertain)
    #expect(fixture.state.sync { $0.quarantined })
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("release") == 1)
    let expectedFirst: [CGFloat] = failure == "start" ? [0.25, 0.25] : (failure == "position" ? [0.25, 0.3, 0.3] : [0.25, 0.3, 0.4, 0.4])
    let expectedSecond: [CGFloat?] = failure == "start" ? [0.75, 0.75] : (failure == "position" ? [0.75, 0.7, 0.7] : [0.75, 0.7, 0.6, 0.6])
    #expect(fixture.state.sync { $0.points.map(\.x) } == expectedFirst)
    #expect(fixture.state.sync { $0.secondPoints.map { $0?.x } } == expectedSecond)
  }

  @Test(arguments: ["start", "position", "end"])
  func cancellationCannotReleaseWhileAPairedSendIsInFlight(block: String) async throws {
    let fixture = DeviceHIDFixture(block: block)
    defer { fixture.gate.open() }
    let operation = operation(fixture)
    let task = Task { await operation.run() }
    try await fixture.events.waitFor(block)
    operation.cancel()
    #expect(fixture.events.count("end") == (block == "end" ? 1 : 0))
    fixture.gate.open()
    let outcome = await task.value
    #expect(outcome.error is CancellationError)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("release") == 1)
    let expectedFirst: CGFloat = block == "start" ? 0.25 : (block == "position" ? 0.3 : 0.4)
    let expectedSecond: CGFloat = block == "start" ? 0.75 : (block == "position" ? 0.7 : 0.6)
    #expect(fixture.state.sync { $0.points.last?.x } == expectedFirst)
    #expect(fixture.state.sync { $0.secondPoints.last.flatMap { $0?.x } } == expectedSecond)
  }

  @Test func invalidationStillJoinsThePairedRelease() async throws {
    let fixture = DeviceHIDFixture(block: "position")
    let outcome = try await drain(fixture)
    try await fixture.events.waitFor("transportRetired")
    #expect(outcome.uncertain)
    #expect(fixture.state.sync { $0.quarantined })
    #expect(fixture.events.count("position") == 1)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("release") == 1)
    #expect(fixture.state.sync { $0.points.last?.x } == 0.3)
    #expect(fixture.state.sync { $0.secondPoints.last.flatMap { $0?.x } } == 0.7)
  }

  private func drain(_ fixture: DeviceHIDFixture) async throws -> DeviceHIDOutcome {
    defer { fixture.gate.open() }
    let operation = operation(fixture, cleanupReserve: 0.05)
    let task = Task { await operation.run() }
    try await fixture.events.waitFor("position")
    operation.cancel()
    fixture.state.sync { $0.invalidated }?()
    #expect(fixture.events.count("end") == 0)
    #expect(fixture.events.count("release") == 0)
    fixture.gate.open()
    return await task.value
  }

  @Test func fingerCountAndEverySecondPointAreValidatedBeforeAcquisition() async {
    for (initialSecond, laterSecond) in [
      (CGPoint(x: 0.75, y: 0.5), nil),
      (nil, CGPoint(x: 0.7, y: 0.5)),
      (CGPoint(x: 0.75, y: 0.5), CGPoint(x: 1, y: 0.5)),
      (CGPoint(x: 0.75, y: 0.5), CGPoint(x: 0.3, y: 0.5)),
      (CGPoint(x: 0.75, y: 0.5), CGPoint(x: .nan, y: 0.5)),
    ] as [(CGPoint?, CGPoint?)] {
      let fixture = DeviceHIDFixture()
      var start = DeviceHIDFixture.prepared()
      start.secondPoint = initialSecond
      let prepared = DeviceHIDPreparedTouch(start: start, positions: [DeviceHIDPosition(point: CGPoint(x: 0.3, y: 0.5), delay: 0, secondPoint: laterSecond)])
      let outcome = await DeviceHIDOperation(transport: fixture.transport, input: .touch(prepared), quarantine: {}).run()
      #expect(outcome.error != nil)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("acquire") == 0)
    }
  }

  @Test func pairedSamplesShareTheExistingCleanupReserve() async {
    let fixture = DeviceHIDFixture()
    let outcome = await operation(fixture, hold: 0.4, operationSeconds: 0.5, cleanupReserve: 0.2).run()
    #expect(outcome.error != nil)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("start") == 0)
    #expect(fixture.events.count("release") == 1)
  }

  private func operation(_ fixture: DeviceHIDFixture, hold: TimeInterval = 0, operationSeconds: TimeInterval = 3, cleanupReserve: TimeInterval = 1) -> DeviceHIDOperation {
    var start = DeviceHIDFixture.prepared(duration: hold)
    start.secondPoint = CGPoint(x: 0.75, y: 0.5)
    let prepared = DeviceHIDPreparedTouch(
      start: start,
      positions: [
        DeviceHIDPosition(point: CGPoint(x: 0.3, y: 0.5), delay: 0, secondPoint: CGPoint(x: 0.7, y: 0.5)),
        DeviceHIDPosition(point: CGPoint(x: 0.4, y: 0.5), delay: 0, secondPoint: CGPoint(x: 0.6, y: 0.5)),
      ])
    return DeviceHIDOperation(transport: fixture.transport, input: .touch(prepared), operationSeconds: operationSeconds, cleanupReserve: cleanupReserve, quarantine: { fixture.state.sync { $0.quarantined = true } })
  }
}
