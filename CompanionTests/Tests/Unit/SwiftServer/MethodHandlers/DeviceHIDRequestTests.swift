/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@testable import FBDeviceHID
import GRPCCore
import IDBGRPCSwift
import Testing

@Suite("Physical HID recipe parsing")
struct DeviceHIDRequestTests {
  @Test func retainsTheLegacyTapRoute() async throws {
    let request = try await DeviceHIDRequest.read(from: stream([touch(.down, 1, 2), delay(0.15), touch(.up, 1, 2)]))
    guard case let .tap(tap) = request else {
      Issue.record("Tap did not use the legacy parser")
      return
    }
    #expect(tap.x == 1)
    #expect(tap.duration == 0.15)
  }

  @Test func repeatedDownMeansMoveWithinOneCompleteContact() async throws {
    let request = try await DeviceHIDRequest.read(from: stream([touch(.down, 1, 2), delay(0.1), touch(.down, 3, 4), delay(0.2), touch(.up, 3, 4)]))
    guard case let .touch(sequence) = request else {
      Issue.record("Missing touch recipe")
      return
    }
    #expect(sequence.positions.count == 2)
    #expect(sequence.positions[1].point.x == 3)
    #expect(sequence.positions[1].point.y == 4)
    #expect(sequence.positions[1].delay == 0.2)
  }

  @Test func swipeMatchesTheConstantSpeedSimulatorRecipe() async throws {
    let swipe = Idb_HIDEvent.with {
      $0.swipe.start.x = 10
      $0.swipe.start.y = 20
      $0.swipe.end.x = 30
      $0.swipe.end.y = 20
      $0.swipe.delta = 10
      $0.swipe.duration = 0.4
    }
    let request = try await DeviceHIDRequest.read(from: stream([swipe]))
    guard case let .touch(sequence) = request else {
      Issue.record("Missing swipe recipe")
      return
    }
    #expect(sequence.positions.map { $0.point.x } == [10, 20, 30, 30])
    #expect(sequence.positions.allSatisfy { $0.delay == 0.1 })
    #expect(sequence.duration == 0.4)
  }

  @Test func malformedAndUnsupportedRecipesNeverProduceInput() async {
    let down = touch(.down, 1, 2)
    let up = touch(.up, 1, 2)
    let invalid: [[Idb_HIDEvent]] = [
      [], [down], [up, down], [down, touch(.down, 3, 4), up], [down, up, down, up],
      [down, delay(.nan), touch(.down, 3, 4), touch(.up, 3, 4)],
      [down, delay(5), touch(.down, 3, 4), touch(.up, 3, 4)],
      [Idb_HIDEvent.with { $0.press.action.button.button = .home }],
      [Idb_HIDEvent.with { $0.press.action.key.keycode = 4 }],
      [Idb_HIDEvent.with { $0.shake = .init() }],
      [Idb_HIDEvent.with { $0.pinch.scale = 2 }],
      [Idb_HIDEvent.with { $0.press.direction = .UNRECOGNIZED(99) }],
      Array(repeating: down, count: 257),
    ]
    for events in invalid {
      await #expect(throws: RPCError.self) { try await DeviceHIDRequest.read(from: stream(events)) }
    }
  }

  @Test func oversizedAndNonfiniteSwipesAreRejectedBeforeIntegerConversion() async {
    for value in [Double.infinity, Double.nan, Double.greatestFiniteMagnitude, 100_000] {
      let swipe = Idb_HIDEvent.with {
        $0.swipe.start = .init()
        $0.swipe.end.x = value
        $0.swipe.end.y = 1
        $0.swipe.delta = 1
      }
      await #expect(throws: RPCError.self) { try await DeviceHIDRequest.read(from: stream([swipe])) }
    }
  }

  @Test func failingEOFRejectsACompleteGesture() async {
    let requests = AsyncThrowingStream<Idb_HIDEvent, any Error> { continuation in
      continuation.yield(touch(.down, 1, 2))
      continuation.yield(touch(.down, 3, 4))
      continuation.yield(touch(.up, 3, 4))
      continuation.finish(throwing: StreamFailure.failed)
    }
    await #expect(throws: StreamFailure.self) { try await DeviceHIDRequest.read(from: requests) }
  }

  @Test func cancellationBeforeReadingDoesNotCompileARecipe() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await DeviceHIDRequest.read(from: stream([touch(.down, 1, 2), touch(.down, 3, 4), touch(.up, 3, 4)]))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  private enum StreamFailure: Error { case failed }

  private func touch(_ direction: Idb_HIDEvent.HIDDirection, _ x: Double, _ y: Double) -> Idb_HIDEvent {
    Idb_HIDEvent.with {
      $0.press.direction = direction
      $0.press.action.touch.point.x = x
      $0.press.action.touch.point.y = y
    }
  }

  private func delay(_ duration: Double) -> Idb_HIDEvent {
    Idb_HIDEvent.with { $0.delay.duration = duration }
  }

  private func stream(_ events: [Idb_HIDEvent]) -> AsyncStream<Idb_HIDEvent> {
    AsyncStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }
}
