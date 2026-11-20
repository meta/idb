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
  @Test(arguments: [nil, 0.0, 0.15] as [Double?])
  func singleTapUsesTheCommonTouchRecipe(duration: Double?) async throws {
    var events = [touch(.down, 1, 2)]
    if let duration { events.append(delay(duration)) }
    events.append(touch(.up, 1, 2))
    let request = try await DeviceHIDRequest.read(from: stream(events))
    guard case let .touch(sequence) = request else {
      Issue.record("Missing tap recipe")
      return
    }
    #expect(sequence.contacts.count == 1)
    #expect(sequence.contacts[0].positions.count == 1)
    #expect(sequence.contacts[0].positions[0].point.x == 1)
    #expect(sequence.contacts[0].positions[0].point.y == 2)
    #expect(sequence.duration == (duration ?? 0))
    #expect(sequence.contacts[0].positions[0].delay == (duration ?? 0))
  }

  @Test(arguments: [Idb_HIDEvent.HIDDirection.down, .up])
  func missingTouchPointIsAnInvalidArgument(direction: Idb_HIDEvent.HIDDirection) async {
    let malformed = Idb_HIDEvent.with {
      $0.press.direction = direction
      $0.press.action.touch = .init()
    }
    for events in [[malformed], [touch(.down, 1, 2), touch(.up, 1, 2), malformed]] {
      await #expect { try await DeviceHIDRequest.read(from: stream(events)) } throws: { error in
        (error as? RPCError)?.code == .invalidArgument
      }
    }
  }

  @Test func missingPressActionIsAnInvalidArgument() async {
    for event in [Idb_HIDEvent.with { $0.press = .init() }, Idb_HIDEvent.with { $0.press.action = .init() }] {
      await #expect { try await DeviceHIDRequest.read(from: stream([event])) } throws: { error in
        (error as? RPCError)?.code == .invalidArgument
      }
    }
  }

  @Test func unsupportedPhysicalHIDShapesKeepCompanionErrors() async {
    let unsupported = [
      Idb_HIDEvent.with { $0.press.action.key.keycode = 4 },
      Idb_HIDEvent.with { $0.orientation.orientation = .portrait },
      Idb_HIDEvent.with { $0.shake = .init() },
      Idb_HIDEvent.with { $0.hinge.angle = 90 },
      Idb_HIDEvent.with { $0.text.text = "azerty" },
    ]
    for event in unsupported {
      await #expect { try await DeviceHIDRequest.read(from: stream([event])) } throws: { error in
        (error as? RPCError)?.code == .unimplemented
      }
    }
    for button in [Idb_HIDEvent.HIDButtonType.applePay, .lock, .sideButton, .siri, .playPause, .eject] {
      let events = [Idb_HIDEvent.HIDDirection.down, .up].map { direction in
        Idb_HIDEvent.with {
          $0.press.direction = direction
          $0.press.action.button.button = button
        }
      }
      await #expect { try await DeviceHIDRequest.read(from: stream(events)) } throws: { error in
        (error as? RPCError)?.code == .unimplemented
      }
    }
  }

  @Test(arguments: [-1.0, Double.nan, Double.infinity, -Double.infinity])
  func rejectsInvalidTapCoordinates(value: Double) async {
    for (x, y) in [(value, 0.0), (0.0, value)] {
      await #expect { try await DeviceHIDRequest.read(from: stream([touch(.down, x, y), touch(.up, x, y)])) } throws: { error in
        (error as? RPCError)?.code == .invalidArgument
      }
    }
  }

  @Test(arguments: [-1.0, Double.nan, Double.infinity, -Double.infinity, 5.0, 10.0])
  func rejectsInvalidTapHolds(value: Double) async {
    await #expect { try await DeviceHIDRequest.read(from: stream([touch(.down, 0, 0), delay(value), touch(.up, 0, 0)])) } throws: { error in
      (error as? RPCError)?.code == .invalidArgument
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
      let request = try await DeviceHIDRequest.read(from: observed)
      await admission.mark()
      return request
    }
    continuation.yield(touch(.down, 0, 0))
    continuation.yield(touch(.up, 0, 0))
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

  @Test func repeatedDelaysAccumulateWithinATap() async throws {
    let request = try await DeviceHIDRequest.read(from: stream([touch(.down, 1, 2), delay(0.1), delay(0.2), touch(.up, 1, 2)]))
    guard case let .touch(sequence) = request else {
      Issue.record("Missing tap recipe")
      return
    }
    #expect(abs(sequence.duration - 0.3) < 1e-12)
    #expect(abs(sequence.contacts[0].positions[0].delay - 0.3) < 1e-12)
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

  @Test(arguments: [0.0, -1.0, 10.0])
  func swipeForwardsSamplingAndDefaultDelta(delta: Double) async throws {
    let swipe = Idb_HIDEvent.with {
      $0.swipe.start.x = 10
      $0.swipe.start.y = 20
      $0.swipe.end.x = 30
      $0.swipe.end.y = 20
      $0.swipe.delta = delta
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
      [], [down], [up, down], [down, down], [down, touch(.up, 3, 4)],
      [delay(0.1), down, up], [down, up, delay(0)],
      [Idb_HIDEvent()], [Idb_HIDEvent.with { $0.press.action.touch = .init() }, up],
      [down, touch(.down, 3, 4), up], [down, up, up, down, up],
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

  @Test func swipeRequiresBothWirePointsAndKeepsZeroDuration() async throws {
    for swipe in [
      Idb_HIDEvent.with { $0.swipe.start = .init() },
      Idb_HIDEvent.with { $0.swipe.end = .init() },
    ] {
      await #expect { try await DeviceHIDRequest.read(from: stream([swipe])) } throws: { error in
        (error as? RPCError)?.code == .invalidArgument
      }
    }
    let swipe = Idb_HIDEvent.with {
      $0.swipe.start = .init()
      $0.swipe.end = .init()
    }
    let request = try await DeviceHIDRequest.read(from: stream([swipe]))
    guard case let .touch(sequence) = request else {
      Issue.record("Missing stationary swipe recipe")
      return
    }
    #expect(sequence.contacts[0].positions.count == 3)
    #expect(sequence.contacts[0].positions.allSatisfy { $0.point.x == 0 && $0.point.y == 0 && $0.delay == 0 })
    #expect(sequence.duration == 0)
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

  @Test(arguments: [1, 2, 128])
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

  @Test(arguments: [1, 2])
  func cancellationAtSuccessfulEOFRejectsAllContacts(count: Int) async {
    let events = Array(repeating: [touch(.down, 1, 2), touch(.up, 1, 2)], count: count).flatMap { $0 }
    let task = Task { try await DeviceHIDRequest.read(from: CancelAtEOF(events: events)) }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func existingPinchMessageCompilesOnePairedRecipe() async throws {
    let request = try await DeviceHIDRequest.read(from: stream([pinch()]))
    guard case let .touch(sequence) = request else {
      Issue.record("Pinch did not compile as a bounded recipe")
      return
    }
    #expect(sequence.contacts.count == 1)
    let positions = sequence.contacts[0].positions
    #expect(positions.map { $0.point.x } == [150, 140, 130, 120, 110, 100, 100])
    #expect(positions.map { $0.secondPoint?.x } == [250, 260, 270, 280, 290, 300, 300])
    #expect(positions.allSatisfy { $0.delay == 0.4 / 7 })
  }

  @Test func zeroPinchScalarsRetainWireDefaults() async throws {
    let event = pinch(scale: 1, duration: 0, radius: 0)
    let request = try await DeviceHIDRequest.read(from: stream([event]))
    guard case let .touch(sequence) = request else {
      Issue.record("Missing defaulted pinch")
      return
    }
    #expect(sequence.duration == 0.5)
    let first = try #require(sequence.contacts[0].positions.first)
    let second = try #require(first.secondPoint)
    #expect(first.point.x == 100)
    #expect(second.x == 300)
    #expect(first.delay == 0.125)
    #expect(
      try HidMethodHandler.request(from: event)
        == .input(
          .pinchAt(x: 200, y: 200, scale: 1, duration: sequence.duration, radius: second.x - 200)))
  }

  @Test func malformedOrOversizedPinchIsRejectedBeforeInput() async {
    var nonFiniteCenter = pinch()
    nonFiniteCenter.pinch.center.x = .nan
    var negativeCenter = pinch()
    negativeCenter.pinch.center.y = -1
    let invalid = [
      Idb_HIDEvent.with { $0.pinch.scale = 2 }, nonFiniteCenter, negativeCenter,
      pinch(scale: 0), pinch(scale: -1), pinch(scale: .nan), pinch(scale: .infinity),
      pinch(scale: 1e20), pinch(duration: -1), pinch(duration: .nan), pinch(duration: .infinity), pinch(duration: 5),
      pinch(radius: -1), pinch(radius: .nan), pinch(radius: .infinity), pinch(radius: .greatestFiniteMagnitude),
    ]
    for event in invalid {
      await #expect { try await DeviceHIDRequest.read(from: stream([event])) } throws: { error in
        (error as? RPCError)?.code == .invalidArgument
      }
    }
  }

  @Test func pinchCannotBeMixedOrRepeatedInOneRequest() async {
    let event = pinch()
    for events in [
      [event, event], [event, delay(0)], [delay(0), event],
      [touch(.down, 1, 2), touch(.up, 1, 2), event],
      [event, touch(.down, 1, 2), touch(.up, 1, 2)],
    ] {
      await #expect { try await DeviceHIDRequest.read(from: stream(events)) } throws: { error in
        (error as? RPCError)?.code == .unimplemented
      }
    }
  }

  @Test func pinchMustReachSuccessfulUncancelledEOF() async {
    let requests = AsyncThrowingStream<Idb_HIDEvent, any Error> { continuation in
      continuation.yield(pinch())
      continuation.finish(throwing: StreamFailure.failed)
    }
    await #expect(throws: StreamFailure.self) { try await DeviceHIDRequest.read(from: requests) }
    let event = pinch()
    let task = Task { try await DeviceHIDRequest.read(from: CancelAtEOF(events: [event])) }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  private func pinch(scale: Double = 2, duration: Double = 0.4, radius: Double = 50) -> Idb_HIDEvent {
    Idb_HIDEvent.with {
      $0.pinch.center.x = 200
      $0.pinch.center.y = 200
      $0.pinch.scale = scale
      $0.pinch.duration = duration
      $0.pinch.radius = radius
    }
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
