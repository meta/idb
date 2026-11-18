/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import GRPCCore
import IDBGRPCSwift
import Testing

@Suite
struct DeviceTapRequestTests {
  @Test(arguments: [nil, 0.0, 0.15] as [Double?])
  func preservesPointsAndOptionalDuration(duration: Double?) async throws {
    var events = [touch(.down, x: 100, y: 200)]
    if let duration {
      events.append(delay(duration))
    }
    events.append(touch(.up, x: 100, y: 200))
    let tap = try await DeviceTapRequest.read(from: stream(events))
    #expect(tap.x == 100)
    #expect(tap.y == 200)
    #expect(tap.duration == duration)
  }

  @Test
  func rejectsIncompleteOrUnsupportedStreams() async {
    let down = touch(.down, x: 100, y: 200)
    let up = touch(.up, x: 100, y: 200)
    let button = Idb_HIDEvent.with { $0.press.action.button.button = .home }
    let swipe = Idb_HIDEvent.with { $0.swipe.start.x = .nan }
    let missingPoint = Idb_HIDEvent.with {
      $0.press.direction = .down
      $0.press.action.touch = .init()
    }
    for events in [
      [], [down], [up, down], [down, down],
      [down, touch(.up, x: 101, y: 200)],
      [delay(0.15), down, up], [down, delay(0.15), delay(0.15), up],
      [down, up, delay(0.15)], [down, up, down, up],
      [button], [swipe], [missingPoint, up], [Idb_HIDEvent()],
    ] {
      await #expect(throws: RPCError.self) {
        try await DeviceTapRequest.read(from: stream(events))
      }
    }
  }

  @Test(arguments: [-1.0, Double.nan, Double.infinity, -Double.infinity])
  func rejectsInvalidCoordinates(value: Double) async {
    for (x, y) in [(value, 0.0), (0.0, value)] {
      await #expect(throws: RPCError.self) {
        try await DeviceTapRequest.read(from: stream([touch(.down, x: x, y: y), touch(.up, x: x, y: y)]))
      }
    }
  }

  @Test(arguments: [-1.0, Double.nan, Double.infinity, -Double.infinity])
  func rejectsInvalidDuration(value: Double) async {
    await #expect(throws: RPCError.self) {
      try await DeviceTapRequest.read(from: stream([touch(.down, x: 0, y: 0), delay(value), touch(.up, x: 0, y: 0)]))
    }
  }

  @Test
  func requiresSuccessfulEndOfStream() async {
    let requests = AsyncThrowingStream<Idb_HIDEvent, any Error> { continuation in
      continuation.yield(touch(.down, x: 0, y: 0))
      continuation.yield(touch(.up, x: 0, y: 0))
      continuation.finish(throwing: StreamFailure.failed)
    }
    await #expect(throws: StreamFailure.self) {
      try await DeviceTapRequest.read(from: requests)
    }
  }

  @Test(arguments: [false, true])
  func waitsForEOFWithoutAdmittingCancelledInput(cancel: Bool) async throws {
    let (requests, continuation) = AsyncStream<Idb_HIDEvent>.makeStream()
    let (waiting, waitingContinuation) = AsyncStream<Void>.makeStream()
    let admission = Admission()
    let observed = ObservedStream(base: requests, onEOFWait: { waitingContinuation.yield(()) })
    let task = Task {
      defer { waitingContinuation.finish() }
      let tap = try await DeviceTapRequest.read(from: observed)
      await admission.mark()
      return tap
    }
    continuation.yield(touch(.down, x: 0, y: 0))
    continuation.yield(touch(.up, x: 0, y: 0))
    var waitingIterator = waiting.makeAsyncIterator()
    guard await waitingIterator.next() != nil else {
      task.cancel()
      continuation.finish()
      let result = await task.result
      Issue.record("Parser completed without requesting EOF: \(result)")
      return
    }
    #expect(await admission.admitted == false)
    if cancel { task.cancel() }
    continuation.finish()
    waitingContinuation.finish()
    if cancel {
      await #expect(throws: CancellationError.self) { try await task.value }
      #expect(await admission.admitted == false)
    } else {
      _ = try await task.value
      #expect(await admission.admitted)
    }
  }

  @Test
  func cancellationBeforeReadingCannotAdmitATap() async {
    let requests = stream([touch(.down, x: 0, y: 0), touch(.up, x: 0, y: 0)])
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await DeviceTapRequest.read(from: requests)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  private actor Admission {
    var admitted = false
    func mark() { admitted = true }
  }

  private struct ObservedStream: AsyncSequence, Sendable {
    typealias Element = Idb_HIDEvent
    let base: AsyncStream<Idb_HIDEvent>
    let onEOFWait: @Sendable () -> Void

    func makeAsyncIterator() -> Iterator {
      Iterator(base: base.makeAsyncIterator(), onEOFWait: onEOFWait)
    }

    struct Iterator: AsyncIteratorProtocol {
      var base: AsyncStream<Idb_HIDEvent>.Iterator
      let onEOFWait: @Sendable () -> Void
      var readCount = 0

      mutating func next() async -> Idb_HIDEvent? {
        if readCount == 2 { onEOFWait() }
        readCount += 1
        return await base.next()
      }
    }
  }

  private enum StreamFailure: Error { case failed }

  private func touch(_ direction: Idb_HIDEvent.HIDDirection, x: Double, y: Double) -> Idb_HIDEvent {
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
      for event in events {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }
}
