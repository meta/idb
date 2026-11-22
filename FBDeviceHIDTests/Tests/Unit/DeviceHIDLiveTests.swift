/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Dispatch
import FBDeviceControl
@testable import FBDeviceHID
import Foundation
import IDBConcurrency
import Testing

// MARK: - Shared live-operation test fixtures

final class LiveHIDClock: Sendable {
  private let value = Atomic(wrappedValue: ContinuousClock.now)
  func now() -> ContinuousClock.Instant { value.wrappedValue }
  func advance(_ seconds: Double) { value.sync { $0 = $0.advanced(by: .seconds(seconds)) } }
}

final class LiveHIDFixture: Sendable {
  private struct Observation {
    var receive: (@Sendable (DeviceHIDDisplaySnapshot) -> Void)?
    var completion: (@Sendable (Result<Void, any Error>) -> Void)?
    var completed = false
  }

  let native: DeviceHIDFixture
  let clock = LiveHIDClock()
  private let observation = Atomic(wrappedValue: Observation())
  private let tasks = Atomic(wrappedValue: [Task<Void, any Error>]())
  private let completions = DispatchGroup()
  private let retiring = Atomic(wrappedValue: false)
  let onCancellationRetirement = Atomic<(@Sendable () -> Void)?>(wrappedValue: nil)
  private let gates: [String: DeviceHIDTestGate]
  private let initial: DeviceHIDDisplaySnapshot?
  private let completeOnCancel: Bool
  private let completionResult: Result<Void, any Error>
  private let cancellationFailure: (any Error)?
  private let failures: [String: any Error]

  var events: DeviceHIDTestRecorder { native.events }

  init(
    native: DeviceHIDFixture = DeviceHIDFixture(),
    initial: DeviceHIDDisplaySnapshot? = DeviceHIDFixture.displaySnapshot,
    held: Set<String> = [], completeOnCancel: Bool = true,
    completionResult: Result<Void, any Error> = .success(()),
    cancellationFailure: (any Error)? = nil, failures: [String: any Error] = [:]
  ) {
    self.native = native
    self.initial = initial
    self.completeOnCancel = completeOnCancel
    self.completionResult = completionResult
    self.cancellationFailure = cancellationFailure
    self.failures = failures
    gates = Dictionary(uniqueKeysWithValues: held.map { ($0, DeviceHIDTestGate()) })
  }

  private func pass(_ stage: String) {
    events.record("gate.\(stage)")
    gates[stage]?.wait()
    events.record("gateReturned.\(stage)")
  }

  func open(_ stage: String) { gates[stage]?.open() }

  var transport: DeviceHIDTransport {
    let base = native.transport
    return DeviceHIDTransport(
      acquire: { completion in
        let cancel = try base.acquire { result in
          completion(
            result.map { assertion in
              DeviceHIDAssertion(
                identifier: assertion.identifier,
                release: {
                  self.pass("release")
                  try assertion.release()
                }, observe: assertion.observe)
            })
        }
        if self.retiring.wrappedValue, self.native.lateAcquisition { self.native.completeAcquisition() }
        return {
          try cancel()
          self.pass("acquisitionCancelReturn")
        }
      },
      makeCapability: { completion in
        let cancel = try base.makeCapability(completion)
        if self.retiring.wrappedValue, self.native.lateFactory { self.native.completeFactory() }
        return {
          try cancel()
          self.pass("factoryCancelReturn")
        }
      },
      observeDisplays: { receive, completion in
        let completed = self.observation.sync { state in
          guard !state.completed else { return true }
          state.receive = receive
          state.completion = completion
          return false
        }
        self.events.record("displayStarted")
        if completed {
          self.events.record("consumerReturned")
          completion(.success(()))
        } else if let initial = self.initial {
          self.emit(initial)
        }
        self.pass("displayStartup")
        self.events.record("displayStartupReturned")
        let lifetime = DeviceHIDTestLifetime {
          self.onCancellationRetirement.wrappedValue?()
          self.events.record("displayCancellationRetired")
        }
        return {
          defer { withExtendedLifetime(lifetime) {} }
          self.events.record("displayCancel")
          if self.completeOnCancel { self.finish(self.completionResult) }
          self.pass("displayCancelReturn")
          self.events.record("displayCancelReturned")
          if let failure = self.cancellationFailure { throw failure }
        }
      },
      send: { phase, contact in
        let stage: String
        switch phase {
        case .start: stage = "start"
        case .position: stage = "position"
        case .end: stage = "end"
        }
        self.pass(stage)
        try base.send(phase, contact)
        if let failure = self.failures[stage] { throw failure }
      },
      barrier: {
        self.pass("barrier")
        try base.barrier()
        if let failure = self.failures["barrier"] { throw failure }
      },
      discard: {
        self.pass("discard")
        base.discard()
      })
  }

  func emit(_ snapshot: DeviceHIDDisplaySnapshot) {
    observation.sync { $0.receive }?(snapshot)
    events.record("displayFrameReturned")
  }

  func finish(_ result: Result<Void, any Error> = .success(())) {
    let callback = observation.sync { state in
      guard !state.completed else { return Optional<@Sendable (Result<Void, any Error>) -> Void>.none }
      state.completed = true
      let callback = state.completion
      state.receive = nil
      state.completion = nil
      return callback
    }
    guard let callback else { return }
    completions.enter()
    DispatchQueue.global().async {
      self.pass("displayCompletion")
      self.events.record("consumerReturned")
      callback(result)
      self.events.record("completionCallbackReturned")
      self.completions.leave()
    }
  }

  func preparation(
    snapshot: DeviceHIDDisplaySnapshot = DeviceHIDFixture.displaySnapshot,
    normalize: @escaping @Sendable (CGPoint) throws -> CGPoint = { $0 }
  ) -> DeviceHIDLivePreparation {
    DeviceHIDLivePreparation(deviceIdentifier: native.identifier, displaySnapshot: snapshot, normalize: normalize)
  }

  func operation(prepared: DeviceHIDLivePreparation? = nil, timerQueue: DispatchQueue = .global(), retirementSeconds: TimeInterval = 5) -> DeviceHIDOperation {
    DeviceHIDOperation(
      transport: transport, mode: .live(prepared ?? preparation()), retirementSeconds: retirementSeconds, timerQueue: timerQueue,
      clock: { self.clock.now() }, quarantine: { self.native.state.sync { $0.quarantined = true } })
  }

  func task(_ label: String, _ body: @escaping @Sendable () async throws -> Void) -> Task<Void, any Error> {
    let task = Task {
      defer { self.events.record(label + "Returned") }
      try await body()
    }
    tasks.sync { $0.append(task) }
    return task
  }

  func unblock() {
    retiring.set(true)
    for gate in gates.values { gate.open() }
    native.gate.open()
    if native.lateAcquisition { native.completeAcquisition() }
    if native.lateFactory { native.completeFactory() }
    finish()
  }

  private func join() async {
    for task in tasks.wrappedValue { _ = await task.result }
    await withCheckedContinuation { continuation in
      completions.notify(queue: .global()) { continuation.resume() }
    }
  }

  func withOperation(
    _ operation: DeviceHIDOperation,
    _ body: (Task<DeviceHIDOutcome, Never>) async throws -> Void
  ) async throws {
    let run = Task {
      let outcome = await operation.run()
      self.events.record("operationReturned")
      return outcome
    }
    let result: Result<Void, any Error>
    do {
      try await body(run)
      result = .success(())
    } catch { result = .failure(error) }
    operation.cancel()
    unblock()
    _ = await run.value
    await join()
    try result.get()
  }

  func withTask(_ run: Task<Void, any Error>, _ body: () async throws -> Void) async throws {
    let result: Result<Void, any Error>
    do {
      try await body()
      result = .success(())
    } catch { result = .failure(error) }
    run.cancel()
    unblock()
    _ = await run.result
    await join()
    try result.get()
  }

  func race(_ actions: [@Sendable () -> Void]) async throws {
    let gate = DeviceHIDTestGate()
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "live-test.race", attributes: .concurrent)
    for (index, action) in actions.enumerated() {
      group.enter()
      queue.async {
        self.events.record("raceReady\(index)")
        gate.wait()
        action()
        group.leave()
      }
    }
    let result: Result<Void, any Error>
    do {
      for index in actions.indices { try await events.waitFor("raceReady\(index)") }
      result = .success(())
    } catch { result = .failure(error) }
    gate.open()
    await withCheckedContinuation { continuation in
      group.notify(queue: .global()) { continuation.resume() }
    }
    try result.get()
  }

  func expectRetired() async {
    await join()
    #expect(events.count("consumerReturned") == 1)
    #expect(events.count("releaseReturned") == 1)
    #expect(events.count("discard") == 1)
  }
}

struct LiveSamples: AsyncSequence, Sendable {
  let events: [DeviceHIDLiveEvent]
  let pulls = Atomic(wrappedValue: 0)
  struct Iterator: AsyncIteratorProtocol {
    let source: LiveSamples
    mutating func next() async -> DeviceHIDLiveEvent? {
      let index = source.pulls.sync { count in
        defer { count += 1 }
        return count
      }
      return source.events.indices.contains(index) ? source.events[index] : nil
    }
  }
  func makeAsyncIterator() -> Iterator { Iterator(source: self) }
}

struct ObservedLiveStream: AsyncSequence, Sendable {
  let stream: AsyncThrowingStream<DeviceHIDLiveEvent, any Error>
  let events: DeviceHIDTestRecorder
  let pulls = Atomic(wrappedValue: 0)

  struct Iterator: AsyncIteratorProtocol {
    var iterator: AsyncThrowingStream<DeviceHIDLiveEvent, any Error>.Iterator
    let source: ObservedLiveStream
    mutating func next() async throws -> DeviceHIDLiveEvent? {
      let count = source.pulls.sync { count in
        count += 1
        return count
      }
      source.events.record("sourcePull\(count)")
      return try await iterator.next()
    }
  }
  func makeAsyncIterator() -> Iterator { Iterator(iterator: stream.makeAsyncIterator(), source: self) }
}

// MARK: - Live credit and native joins

@Suite("Native live physical touch")
struct DeviceHIDLiveTests {
  @Test func healthyStationaryAndMovingContactsHaveNoAgeOrSampleCap() async throws {
    let fixture = LiveHIDFixture()
    let operation = fixture.operation()
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      #expect(fixture.events.count("start") == 0)
      try await operation.sendLive(.down(x: 0.1, y: 0.2))
      fixture.clock.advance(365 * 24 * 60 * 60)
      operation.advance()
      #expect(fixture.events.count("end") == 0)
      #expect(fixture.events.count("operationReturned") == 0)
      for index in 0..<600 {
        fixture.clock.advance(60)
        try await operation.sendLive(.move(x: index.isMultiple(of: 2) ? 0.4 : 0.6, y: 0.7))
      }
      try await operation.sendLive(.up(x: 0.6, y: 0.7))
      let outcome = await run.value
      #expect(outcome.error == nil)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("position") == 600)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(fixture.native.state.wrappedValue.secondPoints.allSatisfy { $0 == nil })
      await fixture.expectRetired()
    }
  }

  @Test func blockedMoveHasOneCreditAndJoinsAfterWatchdogExpiry() async throws {
    let fixture = LiveHIDFixture(held: ["position"])
    let operation = fixture.operation()
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 0.1, y: 0.2))
      let move = fixture.task("move") { try await operation.sendLive(.move(x: 0.4, y: 0.5)) }
      try await fixture.events.waitFor("gate.position")
      await #expect { try await operation.sendLive(.move(x: 0.8, y: 0.9)) } throws: { error in
        if case DeviceHIDError.busy = error { return true }
        return false
      }
      fixture.clock.advance(11)
      operation.advance()
      fixture.clock.advance(1)
      operation.advance()
      #expect(fixture.events.count("moveReturned") == 0)
      #expect(fixture.events.count("operationReturned") == 0)
      #expect(fixture.events.count("end") == 0)
      #expect(fixture.events.count("release") == 0)
      #expect(fixture.events.count("discard") == 0)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      fixture.open("position")
      await #expect(throws: DeviceHIDError.self) { try await move.value }
      let outcome = await run.value
      guard case .deadlineExceeded? = outcome.error as? DeviceHIDError else {
        Issue.record("Blocked MOVE lost its watchdog error")
        return
      }
      #expect(!outcome.uncertain)
      #expect(outcome.uncertaintyCause == nil)
      #expect(fixture.native.state.wrappedValue.points == [.init(x: 0.1, y: 0.2), .init(x: 0.4, y: 0.5), .init(x: 0.4, y: 0.5)])
      #expect(fixture.events.count("position") == 1)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      await fixture.expectRetired()
    }
  }

  @Test(arguments: ["start", "position", "end", "barrier"], [false, true])
  func overdueNativeCallsJoinWithinRetirementGrace(_ stage: String, _ timerFirst: Bool) async throws {
    let fixture = LiveHIDFixture(held: [stage])
    let operation = fixture.operation(retirementSeconds: 20)
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      if stage != "start" { try await operation.sendLive(.down(x: 0.1, y: 0.2)) }
      let event: DeviceHIDLiveEvent = stage == "start" ? .down(x: 0.1, y: 0.2) : (stage == "position" ? .move(x: 0.4, y: 0.5) : .up(x: 0.1, y: 0.2))
      let sample = fixture.task("sample") { try await operation.sendLive(event) }
      try await fixture.events.waitFor("gate.\(stage)")
      if timerFirst {
        fixture.clock.advance(11)
        operation.advance()
      }
      operation.cancel()
      fixture.clock.advance(1)
      operation.advance()
      #expect(fixture.events.count("sampleReturned") == 0)
      #expect(fixture.events.count("operationReturned") == 0)
      #expect(fixture.events.count("release") == 0)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      fixture.open(stage)
      _ = await sample.result
      let outcome = await run.value
      if timerFirst {
        guard case .deadlineExceeded? = outcome.error as? DeviceHIDError else {
          Issue.record("Watchdog did not remain primary")
          return
        }
      } else {
        #expect(outcome.error is CancellationError)
      }
      #expect(!outcome.uncertain)
      #expect(outcome.uncertaintyCause == nil)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(fixture.native.state.wrappedValue.points.last == (stage == "position" ? CGPoint(x: 0.4, y: 0.5) : CGPoint(x: 0.1, y: 0.2)))
      await fixture.expectRetired()
    }
  }

  @Test func lateNativeFailureIsDistinctFromWatchdogExpiry() async throws {
    let fixture = LiveHIDFixture(held: ["position"], failures: ["position": DeviceHIDTestError.nativeFailure])
    let operation = fixture.operation()
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 0.1, y: 0.2))
      let move = fixture.task("move") { try await operation.sendLive(.move(x: 0.4, y: 0.5)) }
      try await fixture.events.waitFor("gate.position")
      fixture.clock.advance(11)
      operation.advance()
      #expect(!fixture.native.state.wrappedValue.quarantined)
      fixture.open("position")
      _ = await move.result
      let outcome = await run.value
      guard case .cleanupFailed(let cause, let failures)? = outcome.error as? DeviceHIDError,
        case .deadlineExceeded? = cause as? DeviceHIDError
      else {
        Issue.record("Late native failure replaced the watchdog cause")
        return
      }
      #expect(failures.count == 1)
      #expect(outcome.uncertain)
      #expect(fixture.native.state.wrappedValue.quarantined)
      guard case .nativeFailure(let operation, _, _, _)? = outcome.uncertaintyCause else {
        Issue.record("Lost concrete native uncertainty")
        return
      }
      #expect(operation == "position")
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
    }
  }

  @Test(arguments: [false, true])
  func explicitUpWaitsForEveryRetirementScope(_ completionFirst: Bool) async throws {
    let fixture = LiveHIDFixture(held: ["displayCompletion", "displayCancelReturn", "release", "discard"])
    let operation = fixture.operation()
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 0.1, y: 0.2))
      let up = fixture.task("up") { try await operation.sendLive(.up(x: 0.1, y: 0.2)) }
      try await fixture.events.waitFor("gate.displayCompletion")
      try await fixture.events.waitFor("gate.displayCancelReturn")
      #expect(fixture.events.count("barrierReturned") == 1)
      fixture.clock.advance(1)
      operation.advance()
      #expect(fixture.events.count("upReturned") == 0)
      #expect(fixture.events.count("operationReturned") == 0)
      #expect(fixture.events.count("release") == 0)
      let first = completionFirst ? "displayCompletion" : "displayCancelReturn"
      let second = completionFirst ? "displayCancelReturn" : "displayCompletion"
      fixture.open(first)
      try await fixture.events.waitFor(completionFirst ? "consumerReturned" : "displayCancelReturned")
      #expect(fixture.events.count("upReturned") == 0)
      #expect(fixture.events.count("gate.release") == 0)
      fixture.open(second)
      try await fixture.events.waitFor("gate.release")
      try await fixture.events.waitFor("gate.discard")
      fixture.open("release")
      try await fixture.events.waitFor("releaseReturned")
      #expect(fixture.events.count("upReturned") == 0)
      #expect(fixture.events.count("operationReturned") == 0)
      fixture.open("discard")
      try await up.value
      let outcome = await run.value
      #expect(outcome.error == nil)
      #expect(!outcome.uncertain)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      await fixture.expectRetired()
    }
  }

  @Test func invalidationDuringNormalizationRejectsTheFuturePoint() async throws {
    let fixture = LiveHIDFixture()
    var changed = DeviceHIDFixture.displaySnapshot
    changed.displays[0].pointScale = 4
    let mismatch = changed
    let prepared = fixture.preparation { point in
      if point.x == 0.8 { fixture.emit(mismatch) }
      return point
    }
    let operation = fixture.operation(prepared: prepared)
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 0.2, y: 0.3))
      await #expect(throws: DeviceHIDError.self) { try await operation.sendLive(.move(x: 0.8, y: 0.9)) }
      let outcome = await run.value
      guard case .displayObservationFailed? = outcome.error as? DeviceHIDError else {
        Issue.record("Lost observation failure during normalization")
        return
      }
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("position") == 0)
      #expect(fixture.native.state.wrappedValue.points == [.init(x: 0.2, y: 0.3), .init(x: 0.2, y: 0.3)])
    }
  }

  @Test(arguments: [false, true])
  func observerLossDuringBlockedMoveLiftsOnlyAfterItReturns(_ failed: Bool) async throws {
    let fixture = LiveHIDFixture(held: ["position"])
    let operation = fixture.operation()
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 0.1, y: 0.2))
      let move = fixture.task("move") { try await operation.sendLive(.move(x: 0.4, y: 0.5)) }
      try await fixture.events.waitFor("gate.position")
      fixture.finish(failed ? .failure(DeviceHIDTestError.nativeFailure) : .success(()))
      try await fixture.events.waitFor("completionCallbackReturned")
      #expect(fixture.events.count("end") == 0)
      #expect(fixture.events.count("moveReturned") == 0)
      #expect(fixture.events.count("operationReturned") == 0)
      fixture.open("position")
      _ = await move.result
      let outcome = await run.value
      guard case .displayObservationFailed? = outcome.error as? DeviceHIDError else {
        Issue.record("Lost post-input stream failure")
        return
      }
      #expect(!outcome.uncertain)
      #expect(fixture.native.state.wrappedValue.points.last == CGPoint(x: 0.4, y: 0.5))
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      await fixture.expectRetired()
    }
  }

  @Test(arguments: ["acquisition", "factory"])
  func expiredSetupWaitsForLateCallbacksAndCancellationReturn(_ stage: String) async throws {
    let native = DeviceHIDFixture(lateAcquisition: stage == "acquisition", lateFactory: stage == "factory")
    let cancellation = stage == "acquisition" ? "acquisitionCancelReturn" : "factoryCancelReturn"
    let fixture = LiveHIDFixture(native: native, held: [cancellation])
    let operation = fixture.operation()
    try await fixture.withOperation(operation) { run in
      let ready = fixture.task("ready") { try await operation.waitUntilReady() }
      try await fixture.events.waitFor(stage == "acquisition" ? "acquisitionPending" : "factoryPending")
      fixture.clock.advance(16)
      operation.advance()
      try await fixture.events.waitFor("gate.\(cancellation)")
      #expect(fixture.events.count("operationReturned") == 0)
      if stage == "acquisition" { native.completeAcquisition() } else { native.completeFactory() }
      #expect(fixture.events.count("release") == 0)
      fixture.clock.advance(1)
      operation.advance()
      #expect(!native.state.wrappedValue.quarantined)
      fixture.open(cancellation)
      _ = await ready.result
      let outcome = await run.value
      guard case .deadlineExceeded? = outcome.error as? DeviceHIDError else {
        Issue.record("Late setup replaced its deadline")
        return
      }
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("start") == 0)
      #expect(fixture.events.count("releaseReturned") == 1)
      #expect(fixture.events.count("discard") == 1)
    }
  }

  @Test func invalidPhaseAndMismatchedUpNeverReachNativeInput() async throws {
    let fixture = LiveHIDFixture()
    let operation = fixture.operation()
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      await #expect { try await operation.sendLive(.move(x: 0.1, y: 0.2)) } throws: { error in
        if case DeviceHIDError.liveProtocol = error { return true }
        return false
      }
      try await operation.sendLive(.down(x: 0.1, y: 0.2))
      for event in [DeviceHIDLiveEvent.down(x: 0.1, y: 0.2), .up(x: 0.4, y: 0.5)] {
        await #expect { try await operation.sendLive(event) } throws: { error in
          if case DeviceHIDError.liveProtocol = error { return true }
          return false
        }
      }
      operation.cancel()
      #expect((await run.value).error is CancellationError)
      #expect(fixture.events.count("start") == 1)
      #expect(fixture.events.count("position") == 0)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.native.state.wrappedValue.points.last == CGPoint(x: 0.1, y: 0.2))
    }
  }

  @Test func observerFailureDescriptionCanReenterTheOperation() async throws {
    let fixture = LiveHIDFixture()
    let operation = fixture.operation()
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 0.1, y: 0.2))
      fixture.finish(
        .failure(
          DeviceHIDReentrantError(describe: {
            operation.advance()
            fixture.events.record("descriptionReentered")
          })))
      try await fixture.events.waitFor("descriptionReentered")
      let outcome = await run.value
      guard case .displayObservationFailed? = outcome.error as? DeviceHIDError else {
        Issue.record("Lost reentrant observer error")
        return
      }
      #expect(!outcome.uncertain)
      await fixture.expectRetired()
    }
  }

  @Test func retiredObserverCancellationCaptureCanReenterTheOperation() async throws {
    let fixture = LiveHIDFixture()
    let operation = fixture.operation()
    fixture.onCancellationRetirement.set { operation.advance() }
    defer { fixture.onCancellationRetirement.set(nil) }
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 0.1, y: 0.2))
      try await operation.sendLive(.up(x: 0.1, y: 0.2))
      #expect((await run.value).error == nil)
      try await fixture.events.waitFor("displayCancellationRetired")
      #expect(fixture.events.count("displayCancellationRetired") == 1)
    }
  }

  @Test func duplicateAssertionCallbackIsRealUncertainty() async throws {
    let native = DeviceHIDFixture(retainAcquisition: true)
    let fixture = LiveHIDFixture(native: native)
    let operation = fixture.operation()
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 0.1, y: 0.2))
      native.completeAcquisition()
      let outcome = await run.value
      guard case .unexpectedCompletion? = outcome.error as? DeviceHIDError,
        case .unexpectedCompletion? = outcome.uncertaintyCause
      else {
        Issue.record("Duplicate callback ambiguity was not preserved")
        return
      }
      #expect(outcome.uncertain)
      #expect(native.state.wrappedValue.quarantined)
      #expect(fixture.events.count("start") == 1)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      await fixture.expectRetired()
    }
  }

  @Test func assertionReleaseFailureIsTypedAndQuarantines() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let fixture = LiveHIDFixture(native: DeviceHIDFixture(fail: "release"))
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport },
      prepareButton: { _, _, _ in throw DeviceHIDError.unexpectedCompletion },
      prepareLive: { _ in fixture.preparation() })
    let source = LiveSamples(events: [.down(x: 0.1, y: 0.2), .up(x: 0.1, y: 0.2)])
    let run = fixture.task("public") { try await command.liveTouch(events: source) }
    try await fixture.withTask(run) {
      let error = await #expect(throws: DeviceHIDError.self) { try await run.value }
      guard case .liveUncertain(let cause, let uncertainty)? = error,
        case .nativeFailure(let primary, _, _, _)? = cause as? DeviceHIDError,
        case .nativeFailure(let uncertain, _, _, _)? = uncertainty as? DeviceHIDError
      else {
        Issue.record("Release failure was not a typed uncertain outcome")
        return
      }
      #expect(primary == "assertion release")
      #expect(uncertain == "assertion release")
      #expect(fixture.events.count("release") == 1)
      #expect(fixture.events.count("consumerReturned") == 1)
      #expect(fixture.events.count("discard") == 1)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      await #expect { try await command.button(.home) } throws: { error in
        if case DeviceHIDError.uncertainState = error { return true }
        return false
      }
    }
  }

  // MARK: - Public command/source ownership

  @Test(arguments: ["start", "position"])
  func sourceCreditWaitsForTheNativeCallToReturn(_ stage: String) async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let fixture = LiveHIDFixture(held: [stage])
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport },
      prepareLive: { _ in fixture.preparation() })
    let source = LiveSamples(events: [.down(x: 0.1, y: 0.2), .move(x: 0.4, y: 0.5), .up(x: 0.4, y: 0.5)])
    let run = fixture.task("public") { try await command.liveTouch(events: source) }
    try await fixture.withTask(run) {
      try await fixture.events.waitFor("gate.\(stage)")
      #expect(source.pulls.wrappedValue == (stage == "start" ? 1 : 2))
      #expect(fixture.events.count("publicReturned") == 0)
      #expect(fixture.events.count("end") == 0)
      fixture.open(stage)
      try await run.value
      #expect(source.pulls.wrappedValue == 3)
      #expect(fixture.native.state.wrappedValue.points == [.init(x: 0.1, y: 0.2), .init(x: 0.4, y: 0.5), .init(x: 0.4, y: 0.5)])
      await fixture.expectRetired()
    }
  }

  @Test(arguments: ["end", "barrier", "displayCompletion", "displayCancelReturn", "release", "discard"])
  func commandFinishesUpAfterCleanupWithoutPullingAgain(_ stage: String) async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let fixture = LiveHIDFixture(held: [stage])
    let prepared = fixture.preparation()
    let identifier = prepared.deviceIdentifier
    let udid = device.udid
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {},
      makeTransport: { selected in
        #expect(selected == identifier)
        return fixture.transport
      },
      prepareButton: { _, _, _ in throw DeviceHIDError.unexpectedCompletion },
      prepareLive: { selected in
        #expect(selected == udid)
        return prepared
      })
    let samples = LiveSamples(events: [.down(x: 0.1, y: 0.2), .move(x: 0.4, y: 0.5), .up(x: 0.4, y: 0.5)])
    let run = fixture.task("public") { try await command.liveTouch(events: samples) }
    try await fixture.withTask(run) {
      try await fixture.events.waitFor("gate.\(stage)")
      #expect(samples.pulls.wrappedValue == 3)
      #expect(fixture.events.count("publicReturned") == 0)
      await #expect { try await command.button(.home) } throws: { error in
        if case DeviceHIDError.busy = error { return true }
        return false
      }
      fixture.open(stage)
      try await run.value
      #expect(samples.pulls.wrappedValue == 3)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      await fixture.expectRetired()
    }
  }

  @Test func observerFailureCancelsIdleProducerAndAllowsCleanReuse() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let fixture = LiveHIDFixture()
    let recovery = LiveHIDFixture()
    let constructions = Atomic(wrappedValue: 0)
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {},
      makeTransport: { _ in
        let first = constructions.sync { count in
          count += 1
          return count == 1
        }
        return first ? fixture.transport : recovery.transport
      }, prepareButton: { _, _, _ in throw DeviceHIDError.unexpectedCompletion },
      prepareLive: { _ in fixture.preparation() })
    let (events, writer) = AsyncThrowingStream<DeviceHIDLiveEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    writer.onTermination = { _ in fixture.events.record("producerStopped") }
    let source = ObservedLiveStream(stream: events, events: fixture.events)
    defer {
      writer.finish()
      recovery.unblock()
    }
    let run = fixture.task("public") { try await command.liveTouch(events: source) }
    try await fixture.withTask(run) {
      writer.yield(.down(x: 0.1, y: 0.2))
      try await fixture.events.waitFor("sourcePull2")
      await #expect { try await command.button(.home) } throws: { error in
        if case DeviceHIDError.busy = error { return true }
        return false
      }
      fixture.finish()
      await #expect { try await run.value } throws: { error in
        if case DeviceHIDError.inputMayHaveApplied(let cause) = error,
          case DeviceHIDError.displayObservationFailed = cause
        {
          return true
        }
        return false
      }
      try await fixture.events.waitFor("producerStopped")
      #expect(!fixture.native.state.wrappedValue.quarantined)
      try await command.liveTouch(events: LiveSamples(events: [.down(x: 0.2, y: 0.3), .up(x: 0.2, y: 0.3)]))
      #expect(constructions.wrappedValue == 2)
      await recovery.expectRetired()
    }
  }

  @Test func cancellationThenCleanupFailurePreservesTheTypedTree() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let end = DeviceHIDError.nativeFailure(operation: "end", domain: "test", code: 1, message: "end failure")
    let barrier = DeviceHIDError.nativeFailure(operation: "barrier", domain: "test", code: 2, message: "barrier failure")
    let fixture = LiveHIDFixture(failures: ["end": end, "barrier": barrier])
    let command = DeviceHIDCommands(device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport }, prepareButton: { _, _, _ in throw DeviceHIDError.unexpectedCompletion }, prepareLive: { _ in fixture.preparation() })
    let (events, writer) = AsyncThrowingStream<DeviceHIDLiveEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    defer { writer.finish() }
    let run = fixture.task("public") { try await command.liveTouch(events: events) }
    try await fixture.withTask(run) {
      writer.yield(.down(x: 0.1, y: 0.2))
      try await fixture.events.waitFor("startReturned")
      run.cancel()
      let error = await #expect(throws: DeviceHIDError.self) { try await run.value }
      guard case .liveUncertain(let cause, let uncertainty)? = error,
        case .cleanupFailed(let primary, let failures)? = cause as? DeviceHIDError
      else {
        Issue.record("Cleanup tree was flattened or hidden by cancellation")
        return
      }
      #expect(primary is CancellationError)
      #expect(failures.count == 2)
      let operations = failures.compactMap { error -> String? in
        guard case .nativeFailure(let operation, _, _, _)? = error as? DeviceHIDError else { return nil }
        return operation
      }
      #expect(operations == ["end", "barrier"])
      guard case .nativeFailure(let operation, _, _, _)? = uncertainty as? DeviceHIDError else {
        Issue.record("Lost first native uncertainty")
        return
      }
      #expect(operation == "end")
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      await #expect { try await command.button(.home) } throws: { error in
        if case DeviceHIDError.uncertainState = error { return true }
        return false
      }
    }
  }

  @Test func cancellationThenAssertionInvalidationIsNotPlainCancellation() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let fixture = LiveHIDFixture(held: ["end"])
    let command = DeviceHIDCommands(device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport }, prepareButton: { _, _, _ in throw DeviceHIDError.unexpectedCompletion }, prepareLive: { _ in fixture.preparation() })
    let (events, writer) = AsyncThrowingStream<DeviceHIDLiveEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    defer { writer.finish() }
    let run = fixture.task("public") { try await command.liveTouch(events: events) }
    try await fixture.withTask(run) {
      writer.yield(.down(x: 0.1, y: 0.2))
      try await fixture.events.waitFor("startReturned")
      run.cancel()
      try await fixture.events.waitFor("gate.end")
      fixture.native.state.sync { $0.invalidated }?()
      fixture.open("end")
      let error = await #expect(throws: DeviceHIDError.self) { try await run.value }
      guard case .liveUncertain(let cause, let uncertainty)? = error else {
        Issue.record("Invalidation was hidden by cancellation")
        return
      }
      #expect(cause is CancellationError)
      guard case .assertionInvalidated? = uncertainty as? DeviceHIDError else {
        Issue.record("Lost assertion uncertainty")
        return
      }
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
    }
  }

  @Test func prematureEOFDrainsTheAdmittedContact() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let fixture = LiveHIDFixture()
    let command = DeviceHIDCommands(device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport }, prepareButton: { _, _, _ in throw DeviceHIDError.unexpectedCompletion }, prepareLive: { _ in fixture.preparation() })
    let samples = LiveSamples(events: [.down(x: 0.1, y: 0.2)])
    let run = fixture.task("public") { try await command.liveTouch(events: samples) }
    try await fixture.withTask(run) {
      await #expect { try await run.value } throws: { error in
        if case DeviceHIDError.inputMayHaveApplied(let cause) = error,
          case DeviceHIDError.liveProtocol = cause
        {
          return true
        }
        return false
      }
      #expect(samples.pulls.wrappedValue == 2)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      await fixture.expectRetired()
    }
  }

  @Test func producerFailureRemainsPrimaryThroughCleanup() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let primary = DeviceHIDTestError.nativeFailure
    let fixture = LiveHIDFixture(failures: ["end": DeviceHIDTestError.nativeFailure])
    let command = DeviceHIDCommands(device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport }, prepareButton: { _, _, _ in throw DeviceHIDError.unexpectedCompletion }, prepareLive: { _ in fixture.preparation() })
    let (events, writer) = AsyncThrowingStream<DeviceHIDLiveEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    defer { writer.finish() }
    let run = fixture.task("public") { try await command.liveTouch(events: events) }
    try await fixture.withTask(run) {
      writer.yield(.down(x: 0.1, y: 0.2))
      try await fixture.events.waitFor("startReturned")
      writer.finish(throwing: primary)
      let error = await #expect(throws: DeviceHIDError.self) { try await run.value }
      guard case .liveUncertain(let cause, _)? = error,
        case .cleanupFailed(let original, let failures)? = cause as? DeviceHIDError,
        case .nativeFailure(let primaryOperation, _, _, _)? = original as? DeviceHIDError
      else {
        Issue.record("Producer cause did not survive cleanup failure")
        return
      }
      #expect(primaryOperation == "operation")
      #expect(failures.count == 1)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
    }
  }

  @Test(arguments: [false, true])
  func observerCompletionAndCancellationFailureHaveDifferentUncertainty(_ cancellationThrows: Bool) async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let fixture = LiveHIDFixture(
      completionResult: cancellationThrows ? .success(()) : .failure(DeviceHIDTestError.nativeFailure),
      cancellationFailure: cancellationThrows ? DeviceHIDTestError.nativeFailure : nil)
    let recovery = LiveHIDFixture()
    let constructions = Atomic(wrappedValue: 0)
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {},
      makeTransport: { _ in
        let first = constructions.sync { count in
          count += 1
          return count == 1
        }
        return first ? fixture.transport : recovery.transport
      }, prepareButton: { _, _, _ in throw DeviceHIDError.unexpectedCompletion },
      prepareLive: { _ in fixture.preparation() })
    let samples = LiveSamples(events: [.down(x: 0.1, y: 0.2), .up(x: 0.1, y: 0.2)])
    let run = fixture.task("public") { try await command.liveTouch(events: samples) }
    try await fixture.withTask(run) {
      let error = await #expect(throws: DeviceHIDError.self) { try await run.value }
      if cancellationThrows {
        guard case .liveUncertain(_, let uncertainty)? = error,
          case .nativeFailure(let operation, _, _, _)? = uncertainty as? DeviceHIDError
        else {
          Issue.record("Throwing cancellation request lost its uncertainty")
          return
        }
        #expect(operation == "cancellation request")
        await #expect { try await command.button(.home) } throws: { error in
          if case DeviceHIDError.uncertainState = error { return true }
          return false
        }
      } else {
        guard case .inputMayHaveApplied(let cause)? = error, case DeviceHIDError.displayObservationFailed = cause else {
          Issue.record("Observer completion error lost its retry-unsafe cause")
          return
        }
        try await command.liveTouch(events: LiveSamples(events: samples.events))
        #expect(constructions.wrappedValue == 2)
        await recovery.expectRetired()
      }
      await fixture.expectRetired()
    }
  }

  @Test func heldLiveOperationDoesNotKeepItsDeviceAlive() async throws {
    var device = Optional(DeviceHIDRetentionTests.makeInertDevice())
    weak var weakDevice = device
    let fixture = LiveHIDFixture()
    let command = DeviceHIDCommands(device: try #require(device), checkRuntime: {}, makeTransport: { _ in fixture.transport }, prepareLive: { _ in fixture.preparation() })
    let (events, writer) = AsyncThrowingStream<DeviceHIDLiveEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    defer { writer.finish() }
    let run = fixture.task("public") { try await command.liveTouch(events: events) }
    try await fixture.withTask(run) {
      writer.yield(.down(x: 0.1, y: 0.2))
      try await fixture.events.waitFor("startReturned")
      device = nil
      #expect(weakDevice == nil)
      writer.yield(.up(x: 0.1, y: 0.2))
      try await run.value
    }
  }

  @Test func commandUsesOneSharedRuntimeCheckForEachMode() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let live = LiveHIDFixture()
    let bounded = LiveHIDFixture()
    let button = LiveHIDFixture()
    let calls = Atomic(wrappedValue: [String]())
    let count = Atomic(wrappedValue: 0)
    let command = DeviceHIDCommands(
      device: device, checkRuntime: { calls.sync { $0.append("runtime") } },
      makeTransport: { _ in
        calls.sync { $0.append("native") }
        let first = count.sync { value in
          value += 1
          return value == 1
        }
        return first ? live.transport : bounded.transport
      },
      prepareTouch: { _, _ in
        calls.sync { $0.append("prepare-bounded") }
        return DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(), positions: [])
      },
      prepareButton: { _, identity, duration in
        calls.sync { $0.append("prepare-button") }
        return DeviceHIDPreparedButton(deviceIdentifier: UUID(), button: identity, duration: duration)
      },
      makeButtonTransport: { _ in
        calls.sync { $0.append("button-native") }
        return button.transport
      },
      prepareLive: { _ in
        calls.sync { $0.append("prepare-live") }
        return live.preparation()
      })
    try await command.liveTouch(events: LiveSamples(events: [.down(x: 0.1, y: 0.2), .up(x: 0.1, y: 0.2)]))
    #expect(calls.wrappedValue == ["runtime", "prepare-live", "native"])
    calls.set([])
    try await command.touch(try .tap(x: 1, y: 2))
    #expect(calls.wrappedValue == ["prepare-bounded", "runtime", "native"])
    calls.set([])
    try await command.button(.home)
    #expect(calls.wrappedValue == ["prepare-button", "runtime", "button-native"])
    #expect(button.events.count("displayStarted") == 0)
    await live.expectRetired()
    await bounded.expectRetired()
  }

  @Test func cancelledPreparationDoesNotConstructTransportAndAllowsReuse() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let fixture = LiveHIDFixture()
    let recovery = LiveHIDFixture()
    let pending = Atomic<CheckedContinuation<Void, Never>?>(wrappedValue: nil)
    let preparations = Atomic(wrappedValue: 0)
    let constructions = Atomic(wrappedValue: 0)
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {},
      makeTransport: { _ in
        constructions.sync { $0 += 1 }
        return recovery.transport
      },
      prepareLive: { _ in
        let first = preparations.sync { count in
          count += 1
          return count == 1
        }
        if first {
          await withCheckedContinuation { continuation in
            pending.set(continuation)
            fixture.events.record("prepareStarted")
          }
        }
        return recovery.preparation()
      })
    let samples = LiveSamples(events: [.down(x: 0.1, y: 0.2), .up(x: 0.1, y: 0.2)])
    let run = fixture.task("public") { try await command.liveTouch(events: samples) }
    try await fixture.withTask(run) {
      defer {
        pending.sync { value in
          defer { value = nil }
          return value
        }?.resume()
      }
      try await fixture.events.waitFor("prepareStarted")
      run.cancel()
      #expect(constructions.wrappedValue == 0)
      pending.sync { value in
        defer { value = nil }
        return value
      }?.resume()
      await #expect(throws: CancellationError.self) { try await run.value }
      #expect(constructions.wrappedValue == 0)
      #expect(samples.pulls.wrappedValue == 0)
    }
    try await command.liveTouch(events: LiveSamples(events: samples.events))
    #expect(constructions.wrappedValue == 1)
    await recovery.expectRetired()
  }

  @Test func rejectedLiveRuntimeNeverPreparesOrPullsInput() async {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let calls = Atomic(wrappedValue: [String]())
    let fixture = LiveHIDFixture()
    let command = DeviceHIDCommands(
      device: device,
      checkRuntime: {
        calls.sync { $0.append("runtime") }
        throw DeviceHIDError.unsupportedRuntime("injected rejection")
      },
      makeTransport: { _ in
        calls.sync { $0.append("native") }
        return fixture.transport
      },
      prepareLive: { _ in
        calls.sync { $0.append("prepare") }
        return fixture.preparation()
      })
    let samples = LiveSamples(events: [.down(x: 0.1, y: 0.2)])
    await #expect(throws: DeviceHIDError.self) { try await command.liveTouch(events: samples) }
    #expect(samples.pulls.wrappedValue == 0)
    #expect(calls.wrappedValue == ["runtime"])
    #expect(fixture.events.count("displayStarted") == 0)
  }
}
