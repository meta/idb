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
    #expect(sequence.contacts[0].positions.count == 2)
    #expect(sequence.contacts[0].positions[1].point.x == 3)
    #expect(sequence.contacts[0].positions[1].point.y == 4)
    #expect(sequence.contacts[0].positions[1].delay == 0.2)
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
    #expect(sequence.contacts[0].positions.map { $0.point.x } == [10, 20, 30, 30])
    #expect(sequence.contacts[0].positions.allSatisfy { $0.delay == 0.1 })
    #expect(sequence.duration == 0.4)
  }

  @Test func malformedAndUnsupportedRecipesNeverProduceInput() async {
    let down = touch(.down, 1, 2)
    let up = touch(.up, 1, 2)
    let invalid: [[Idb_HIDEvent]] = [
      [], [down], [up, down], [down, touch(.down, 3, 4), up], [down, up, up, down, up],
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

  @Test(arguments: [2, 3, 64, 128])
  func multipleTapsStayInOneBoundedRecipe(count: Int) async throws {
    let events = Array(repeating: [touch(.down, 10, 20), touch(.up, 10, 20)], count: count).flatMap { $0 }
    let request = try await DeviceHIDRequest.read(from: stream(events))
    guard case let .touch(sequence) = request else {
      Issue.record("Multiple taps did not compile as one recipe")
      return
    }
    #expect(sequence.contacts.count == count)
    #expect(sequence.contacts.allSatisfy { $0.positions.count == 1 && $0.positions[0].point.x == 10 && $0.positions[0].point.y == 20 })
  }

  @Test func separatesHoldsFromInterTapPauses() async throws {
    let request = try await DeviceHIDRequest.read(
      from: stream([
        touch(.down, 10, 20), delay(0.1), touch(.up, 10, 20), delay(0.2),
        touch(.down, 10, 20), delay(0.3), touch(.up, 10, 20),
      ]))
    guard case let .touch(sequence) = request else {
      Issue.record("Missing double-tap recipe")
      return
    }
    #expect(sequence.contacts.count == 2)
    #expect(sequence.contacts[0].positions[0].delay == 0.1)
    #expect(sequence.contacts[0].pause == 0.2)
    #expect(sequence.contacts[1].positions[0].delay == 0.3)
    #expect(sequence.contacts[1].pause == 0)
    #expect(abs(sequence.duration - 0.6) < 1e-12)
  }

  @Test func downAfterUpStartsANewContactButRepeatedDownStillMoves() async throws {
    let request = try await DeviceHIDRequest.read(
      from: stream([
        touch(.down, 1, 2), touch(.down, 3, 4), touch(.up, 3, 4), delay(0.1),
        touch(.down, 5, 6), touch(.down, 7, 8), touch(.up, 7, 8),
      ]))
    guard case let .touch(sequence) = request else {
      Issue.record("Missing sequential contact recipe")
      return
    }
    #expect(sequence.contacts.map { $0.positions.map { $0.point.x } } == [[1, 3], [5, 7]])
    #expect(sequence.contacts[0].pause == 0.1)
  }

  @Test func invalidSuffixAndAggregateBoundsRejectTheEntireRequest() async {
    let down = touch(.down, 1, 2)
    let up = touch(.up, 1, 2)
    let invalid: [[Idb_HIDEvent]] = [
      [down, up, down], [down, up, down, touch(.up, 3, 4)],
      [down, up, delay(.nan), down, up], [down, up, delay(-1), down, up],
      [down, up, delay(.infinity), down, up], [down, up, down, up, delay(0)],
      [down, delay(2), up, delay(1), down, delay(2), up],
      [down, up, touch(.down, -.infinity, 2), touch(.up, -.infinity, 2)],
      [down, up, Idb_HIDEvent.with { $0.press.action.touch = .init() }],
      [down, up, Idb_HIDEvent.with { $0.press.action.button.button = .home }, up],
      [
        down, up,
        Idb_HIDEvent.with {
          $0.swipe.start.x = 1
          $0.swipe.end.x = 2
        },
      ],
      Array(repeating: [down, up], count: 129).flatMap { $0 },
    ]
    for events in invalid {
      await #expect(throws: RPCError.self) { try await DeviceHIDRequest.read(from: stream(events)) }
    }
  }

  @Test(arguments: [2, 128])
  func failingEOFAfterAllContactsCannotReturnAPrefix(count: Int) async {
    let requests = AsyncThrowingStream<Idb_HIDEvent, any Error> { continuation in
      for _ in 0..<count {
        continuation.yield(touch(.down, 1, 2))
        continuation.yield(touch(.up, 1, 2))
      }
      continuation.finish(throwing: StreamFailure.failed)
    }
    await #expect(throws: StreamFailure.self) { try await DeviceHIDRequest.read(from: requests) }
  }

  @Test func cancellationAtSuccessfulEOFRejectsAllContacts() async {
    let events = [touch(.down, 1, 2), touch(.up, 1, 2), touch(.down, 1, 2), touch(.up, 1, 2)]
    let task = Task { try await DeviceHIDRequest.read(from: CancelAtEOF(events: events)) }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  private struct CancelAtEOF: AsyncSequence {
    typealias Element = Idb_HIDEvent
    let events: [Idb_HIDEvent]

    struct AsyncIterator: AsyncIteratorProtocol {
      var events: IndexingIterator<[Idb_HIDEvent]>
      mutating func next() async -> Idb_HIDEvent? {
        if let event = events.next() { return event }
        withUnsafeCurrentTask { $0?.cancel() }
        return nil
      }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(events: events.makeIterator()) }
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
