/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Dispatch
@testable import FBDeviceHID
import Foundation
import IDBConcurrency
import Testing

// MARK: - Touch test adapter

extension DeviceHIDOperation {
  convenience init(transport: DeviceHIDTransport, prepared: DeviceHIDPreparedTap, positions: [DeviceHIDPosition] = [], operationSeconds: TimeInterval = 10, cleanupReserve: TimeInterval = 5, timerQueue: DispatchQueue = .global(), quarantine: @escaping @Sendable () -> Void) {
    self.init(transport: transport, input: .touch(DeviceHIDPreparedTouch(start: prepared, positions: positions)), operationSeconds: operationSeconds, cleanupReserve: cleanupReserve, timerQueue: timerQueue, quarantine: quarantine)
  }
}

enum DeviceHIDTestError: Error { case nativeFailure }

final class DeviceHIDTestLifetime: Sendable {
  private let onRelease: @Sendable () -> Void
  init(_ onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
  deinit { onRelease() }
}

struct DeviceHIDReentrantError: LocalizedError, Sendable {
  let describe: @Sendable () -> Void
  var errorDescription: String? {
    describe()
    return "reentrant native failure"
  }
}

final class DeviceHIDFixture: Sendable {
  struct State {
    var points: [CGPoint] = []
    var buttons: [DeviceHIDButton] = []
    var acquisition: (@Sendable (Result<DeviceHIDAssertion, any Error>) -> Void)?
    var factory: (@Sendable (Result<Void, any Error>) -> Void)?
    var invalidated: (@Sendable () -> Void)?
    var quarantined = false
  }

  let state = Atomic(wrappedValue: State())
  let events = DeviceHIDTestRecorder()
  let block: String?
  let fail: String?
  let lateAcquisition: Bool
  let retainAcquisition: Bool
  let lateFactory: Bool
  let gate = DeviceHIDTestGate()
  let identifier = UUID()

  init(block: String? = nil, fail: String? = nil, lateAcquisition: Bool = false, retainAcquisition: Bool = false, lateFactory: Bool = false) {
    self.block = block
    self.fail = fail
    self.lateAcquisition = lateAcquisition
    self.retainAcquisition = retainAcquisition
    self.lateFactory = lateFactory
  }

  private func call(_ name: String) throws {
    events.record(name)
    if block == name { gate.wait() }
    if fail == name { throw DeviceHIDTestError.nativeFailure }
    events.record(name + "Returned")
  }

  var assertion: DeviceHIDAssertion {
    DeviceHIDAssertion(
      identifier: identifier,
      release: { try self.call("release") },
      observe: { invalidated in
        try self.call("observe")
        self.state.sync { $0.invalidated = invalidated }
      })
  }

  var transport: DeviceHIDTransport {
    let lifetime = DeviceHIDTestLifetime { self.events.record("transportRetired") }
    return DeviceHIDTransport(
      acquire: { completion in
        try self.call("acquire")
        if self.lateAcquisition || self.retainAcquisition {
          self.state.sync { $0.acquisition = completion }
        }
        if self.lateAcquisition {
          self.events.record("acquisitionPending")
        } else {
          completion(.success(self.assertion))
        }
        return { try self.call("cancelAcquisition") }
      },
      makeCapability: { completion in
        try self.call("factory")
        if self.lateFactory {
          self.state.sync { $0.factory = completion }
          self.events.record("factoryPending")
        } else {
          completion(.success(()))
        }
        return { try self.call("cancelFactory") }
      },
      send: { phase, contact in
        defer { withExtendedLifetime(lifetime) {} }
        self.state.sync { state in
          switch contact {
          case let .touch(point): state.points.append(point)
          case let .button(button): state.buttons.append(button)
          }
        }
        switch phase {
        case .start: try self.call("start")
        case .position: try self.call("position")
        case .end: try self.call("end")
        }
      },
      barrier: { try self.call("barrier") },
      discard: { self.events.record("discard") })
  }

  static func prepared(duration: TimeInterval? = nil, point: CGPoint = CGPoint(x: 0.25, y: 0.5)) -> DeviceHIDPreparedTap {
    DeviceHIDPreparedTap(deviceIdentifier: UUID(), point: point, duration: duration)
  }

  func operation(duration: TimeInterval? = nil, operationSeconds: TimeInterval = 2, cleanupReserve: TimeInterval = 0.1) -> DeviceHIDOperation {
    DeviceHIDOperation(
      transport: transport,
      prepared: Self.prepared(duration: duration),
      operationSeconds: operationSeconds,
      cleanupReserve: cleanupReserve,
      quarantine: { self.state.sync { $0.quarantined = true } })
  }

  func completeAcquisition() {
    let completion = state.sync { state in
      let completion = state.acquisition
      state.acquisition = nil
      return completion
    }
    completion?(.success(assertion))
  }

  func completeFactory() {
    let completion = state.sync { state in
      let completion = state.factory
      state.factory = nil
      return completion
    }
    completion?(.success(()))
  }
}

@Suite("Physical HID operation")
struct DeviceHIDOperationTests {
  @Test(arguments: [nil, 0, 0.02] as [TimeInterval?])
  func sendsOneFixedContactAndReleasesItsAssertion(_ duration: TimeInterval?) async throws {
    let fixture = DeviceHIDFixture()
    let outcome = await fixture.operation(duration: duration).run()
    #expect(outcome.error == nil)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("acquire") == 1)
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
    #expect(fixture.events.count("discard") == 1)
    let points = fixture.state.sync { $0.points }
    #expect(points == [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.25, y: 0.5)])
    let start = try #require(fixture.events.time("startReturned"))
    let end = try #require(fixture.events.time("end"))
    #expect(start.duration(to: end) >= .seconds(duration ?? 0))
    let barrier = try #require(fixture.events.time("barrierReturned"))
    let released = try #require(fixture.events.time("release"))
    #expect(barrier <= released)
  }

  @Test func cancellationBeforeRunEmitsNothing() async {
    let fixture = DeviceHIDFixture()
    let operation = fixture.operation()
    operation.cancel()
    let outcome = await operation.run()
    #expect(outcome.error is CancellationError)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("acquire") == 0)
    #expect(fixture.events.count("start") == 0)
  }

  @Test(arguments: [CGPoint(x: -0.1, y: 0.5), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: .nan)])
  func invalidNormalizedPointNeverAcquiresAnAssertion(_ point: CGPoint) async {
    let fixture = DeviceHIDFixture()
    let operation = DeviceHIDOperation(
      transport: fixture.transport,
      prepared: DeviceHIDFixture.prepared(point: point),
      quarantine: {})
    let outcome = await operation.run()
    #expect(outcome.error is DeviceHIDError)
    #expect(fixture.events.count("acquire") == 0)
    #expect(fixture.events.count("start") == 0)
  }

  @Test func preparedMetadataHasNoAgeExpiry() async throws {
    let fixture = DeviceHIDFixture()
    let prepared = DeviceHIDFixture.prepared()
    let aged = ContinuousClock.now.advanced(by: .milliseconds(5100))
    fixture.events.onDeadline(aged, signal: "preparedAged") {}
    try await fixture.events.waitFor("preparedAged", timeout: 8)
    let operation = DeviceHIDOperation(transport: fixture.transport, prepared: prepared, quarantine: {})
    let outcome = await operation.run()
    #expect(outcome.error == nil)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
  }

  @Test func rejectsHoldBeyondTheBudgetWithoutOverflow() async {
    let fixture = DeviceHIDFixture()
    let outcome = await fixture.operation(duration: .greatestFiniteMagnitude).run()
    #expect(outcome.error is DeviceHIDError)
    #expect(fixture.events.count("start") == 0)
    #expect(fixture.events.count("releaseReturned") == 1)
  }

  @Test func rejectsHoldThatWouldConsumeTheCleanupReserve() async throws {
    let fixture = DeviceHIDFixture()
    let outcome = await fixture.operation(duration: 6, operationSeconds: 10, cleanupReserve: 5).run()
    let error = try #require(outcome.error as? DeviceHIDError)
    guard case .preparationFailed(let message) = error else {
      Issue.record("A hold that exceeds the admission budget failed for another reason: \(error)")
      return
    }
    #expect(message.contains("reserved for contact cleanup"))
    #expect(message.contains("6.0s hold"))
    #expect(message.contains("5.0s reserved"))
    #expect(!outcome.uncertain)
    #expect(!fixture.state.sync { $0.quarantined })
    #expect(fixture.events.count("acquire") == 1)
    #expect(fixture.events.count("factory") == 1)
    #expect(fixture.events.count("start") == 0)
    #expect(fixture.events.count("end") == 0)
    #expect(fixture.events.count("barrier") == 0)
    #expect(fixture.events.count("release") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
    #expect(fixture.events.count("discard") == 1)
  }

  @Test(arguments: ["acquire", "observe", "factory"])
  func preContactFailuresEmitNothing(_ phase: String) async {
    let fixture = DeviceHIDFixture(fail: phase)
    let outcome = await fixture.operation().run()
    #expect(outcome.error != nil)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("start") == 0)
    #expect(fixture.events.count("end") == 0)
    #expect(fixture.events.count("releaseReturned") == (phase == "acquire" ? 0 : 1))
  }

  @Test func throwingStartStillGetsOnlyOneMatchingEnd() async {
    let fixture = DeviceHIDFixture(fail: "start")
    let outcome = await fixture.operation().run()
    #expect(outcome.error != nil)
    #expect(outcome.uncertain)
    #expect(fixture.state.sync { $0.quarantined })
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
  }

  @Test func throwingEndIsNotRetriedButStillDrainsTheTransport() async {
    let fixture = DeviceHIDFixture(fail: "end")
    let outcome = await fixture.operation().run()
    #expect(outcome.error != nil)
    #expect(outcome.uncertain)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
  }

  @Test(arguments: ["start", "position", "end", "barrier"])
  func cancellationJoinsBlockedNativeInput(_ phase: String) async throws {
    let fixture = DeviceHIDFixture(block: phase)
    let outcome = try await cancelThenJoinBlockedInput(fixture, phase: phase)
    try await fixture.events.waitFor("transportRetired")
    #expect(outcome.error is CancellationError)
    #expect(!outcome.uncertain)
    #expect(!fixture.state.sync { $0.quarantined })
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
    let nativeReturned = try #require(fixture.events.time(phase + "Returned"))
    let released = try #require(fixture.events.time("release"))
    let releaseReturned = try #require(fixture.events.time("releaseReturned"))
    let callerFinished = try #require(fixture.events.time("callerFinished"))
    #expect(nativeReturned <= released)
    #expect(releaseReturned <= callerFinished)
  }

  private func cancelThenJoinBlockedInput(_ fixture: DeviceHIDFixture, phase: String) async throws -> DeviceHIDOutcome {
    defer { fixture.gate.open() }
    let operation = DeviceHIDOperation(
      transport: fixture.transport, prepared: DeviceHIDFixture.prepared(),
      positions: [DeviceHIDPosition(point: CGPoint(x: 0.5, y: 0.5), delay: 0)],
      operationSeconds: 3, cleanupReserve: 0,
      quarantine: { fixture.state.sync { $0.quarantined = true } })
    let task = Task { await operation.run() }
    try await fixture.events.waitFor(phase)
    operation.cancel()
    fixture.gate.open()
    let outcome = await task.value
    fixture.events.record("callerFinished")
    return outcome
  }

  @Test(arguments: ["acquisition", "factory"])
  func cancelledPreparationRetiresWithoutQuarantine(_ phase: String) async throws {
    let fixture = DeviceHIDFixture(lateAcquisition: phase == "acquisition", lateFactory: phase == "factory")
    let outcome = try await cancelThenJoinPreparation(fixture, phase: phase)
    try await fixture.events.waitFor("transportRetired")
    #expect(outcome.error is CancellationError)
    #expect(!outcome.uncertain)
    #expect(!fixture.state.sync { $0.quarantined })
    #expect(fixture.events.count("start") == 0)
    #expect(fixture.events.count("releaseReturned") == 1)
    #expect(fixture.events.count("discard") == 1)
  }

  private func cancelThenJoinPreparation(_ fixture: DeviceHIDFixture, phase: String) async throws -> DeviceHIDOutcome {
    let operation = fixture.operation(cleanupReserve: 0)
    let task = Task { await operation.run() }
    try await fixture.events.waitFor(phase + "Pending")
    operation.cancel()
    if phase == "acquisition" { fixture.completeAcquisition() } else { fixture.completeFactory() }
    return await task.value
  }

  @Test func cancellationAndInvalidationClaimOnlyOneEnd() async throws {
    let fixture = DeviceHIDFixture()
    let operation = fixture.operation(duration: 1)
    let task = Task { await operation.run() }
    try await fixture.events.waitFor("startReturned")
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 { group.addTask { operation.cancel() } }
      group.addTask { fixture.state.sync { $0.invalidated }?() }
    }
    let outcome = await task.value
    #expect(outcome.error != nil)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
  }

  @Test(arguments: ["acquisition", "factory"])
  func timedOutPreparationRetiresWithoutQuarantine(_ phase: String) async throws {
    let fixture = DeviceHIDFixture(lateAcquisition: phase == "acquisition", lateFactory: phase == "factory")
    let outcome = try await completeLateCallback(fixture, phase: phase)
    try await fixture.events.waitFor("transportRetired")
    let error = try #require(outcome.error as? DeviceHIDError)
    guard case .deadlineExceeded = error else {
      Issue.record("A late clean callback lost the deadline error: \(error)")
      return
    }
    #expect(!outcome.uncertain)
    #expect(!fixture.state.sync { $0.quarantined })
    #expect(fixture.events.count("start") == 0)
    #expect(fixture.events.count("releaseReturned") == 1)
    #expect(fixture.events.count("release") == 1)
    #expect(fixture.events.count("discard") == 1)
    #expect(try #require(fixture.events.time("lateCallback")) <= #require(fixture.events.time("release")))
  }

  private func completeLateCallback(_ fixture: DeviceHIDFixture, phase: String) async throws -> DeviceHIDOutcome {
    let operation = fixture.operation(operationSeconds: 1, cleanupReserve: 0)
    let task = Task { await operation.run() }
    try await fixture.events.waitFor(phase + "Pending")
    fixture.events.onDeadline(.now.advanced(by: .milliseconds(1200)), signal: "lateCallback") {
      if phase == "acquisition" { fixture.completeAcquisition() } else { fixture.completeFactory() }
    }
    return await task.value
  }

  @Test(arguments: ["observe", "release", "cancelFactory"])
  func cancellationJoinsBlockedCleanup(_ phase: String) async throws {
    let fixture = DeviceHIDFixture(block: phase, lateFactory: phase == "cancelFactory")
    let outcome = try await completeBlockedCleanup(fixture, phase: phase)
    try await fixture.events.waitFor("transportRetired")
    #expect(outcome.error is CancellationError)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("end") <= 1)
    #expect(fixture.events.count("releaseReturned") == 1)
    #expect(fixture.events.count("release") == 1)
    #expect(try #require(fixture.events.time(phase + "Returned")) <= #require(fixture.events.time("callerFinished")))
  }

  private func completeBlockedCleanup(_ fixture: DeviceHIDFixture, phase: String) async throws -> DeviceHIDOutcome {
    defer { fixture.gate.open() }
    let operation = fixture.operation(cleanupReserve: 0)
    let task = Task { await operation.run() }
    if phase == "cancelFactory" {
      try await fixture.events.waitFor("factoryPending")
      operation.cancel()
    }
    try await fixture.events.waitFor(phase)
    operation.cancel()
    if phase != "release" { #expect(fixture.events.count("release") == 0) }
    fixture.gate.open()
    if phase == "cancelFactory" { fixture.completeFactory() }
    let outcome = await task.value
    fixture.events.record("callerFinished")
    return outcome
  }

  @Test(arguments: ["barrier", "release", "cancelFactory"])
  func cleanupErrorsQuarantineTheCommand(_ phase: String) async throws {
    let fixture = DeviceHIDFixture(fail: phase, lateFactory: phase == "cancelFactory")
    let operation = fixture.operation()
    let task = Task { await operation.run() }
    if phase == "cancelFactory" {
      try await fixture.events.waitFor("factoryPending")
      operation.cancel()
      fixture.completeFactory()
    }
    let outcome = await task.value
    #expect(outcome.error != nil)
    #expect(outcome.uncertain)
    #expect(fixture.state.sync { $0.quarantined })
  }

  @Test(arguments: [false, true])
  func cleanupFailuresPreserveTheOriginalCause(_ cancelFirst: Bool) async throws {
    let fixture = DeviceHIDFixture(block: "start", fail: "release")
    defer { fixture.gate.open() }
    let base = fixture.transport
    let transport = DeviceHIDTransport(
      acquire: base.acquire, makeCapability: base.makeCapability,
      send: { phase, contact in
        try base.send(phase, contact)
        if case .end = phase { throw DeviceHIDTestError.nativeFailure }
      },
      barrier: {
        try base.barrier()
        throw DeviceHIDTestError.nativeFailure
      },
      discard: base.discard)
    let operation = DeviceHIDOperation(
      transport: transport, prepared: DeviceHIDFixture.prepared(),
      quarantine: { fixture.state.sync { $0.quarantined = true } })
    let task = Task { await operation.run() }
    try await fixture.events.waitFor("start")
    if cancelFirst { operation.cancel() }
    fixture.gate.open()
    let outcome = await task.value
    let error = try #require(outcome.error as? DeviceHIDError)
    guard case .cleanupFailed(let cause, let failures) = error else {
      Issue.record("Multiple failures did not retain their original cause: \(error)")
      return
    }
    if cancelFirst {
      #expect(cause is CancellationError)
    } else if case DeviceHIDError.nativeFailure(let operation, _, _, _) = cause {
      #expect(operation == "end")
    } else {
      Issue.record("The original native end failure was replaced: \(cause)")
    }
    let operations = failures.compactMap { error -> String? in
      if case DeviceHIDError.nativeFailure(let operation, _, _, _) = error { return operation }
      return nil
    }
    #expect(operations.sorted() == (cancelFirst ? ["assertion release", "barrier", "end"] : ["assertion release", "barrier"]))
    #expect(failures.count == operations.count)
    #expect(outcome.uncertain)
    #expect(fixture.state.sync { $0.quarantined })
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("release") == 1)
    #expect(fixture.events.count("discard") == 1)
  }

  @Test(arguments: ["acquire", "factory", "start"])
  func errorDescriptionsMayReenterCancellation(_ phase: String) async {
    let fixture = DeviceHIDFixture()
    let base = fixture.transport
    let active = Atomic<DeviceHIDOperation?>(wrappedValue: nil)
    let error = DeviceHIDReentrantError {
      fixture.events.record("description")
      active.wrappedValue?.cancel()
    }
    let transport = DeviceHIDTransport(
      acquire: { completion in
        if phase == "acquire" {
          completion(.failure(error))
          return {}
        }
        return try base.acquire(completion)
      },
      makeCapability: { completion in
        if phase == "factory" {
          completion(.failure(error))
          return {}
        }
        return try base.makeCapability(completion)
      },
      send: { contact, point in
        try base.send(contact, point)
        if phase == "start", case .start = contact { throw error }
      },
      barrier: base.barrier,
      discard: base.discard)
    let operation = DeviceHIDOperation(transport: transport, prepared: DeviceHIDFixture.prepared(), quarantine: {})
    active.set(operation)
    defer { active.set(nil) }
    let outcome = await operation.run()
    #expect(outcome.error != nil)
    #expect(fixture.events.count("description") > 0)
    #expect(fixture.events.count("releaseReturned") == (phase == "acquire" ? 0 : 1))
    #expect(fixture.events.count("end") == (phase == "start" ? 1 : 0))
  }

  @Test func retiringCancellationCapturesMayReenterTheOperation() async throws {
    let fixture = DeviceHIDFixture()
    let base = fixture.transport
    let active = Atomic<DeviceHIDOperation?>(wrappedValue: nil)
    let transport = DeviceHIDTransport(
      acquire: { completion in
        let cancel = try base.acquire(completion)
        let lifetime = DeviceHIDTestLifetime {
          active.wrappedValue?.cancel()
          fixture.events.record("captureRetired")
        }
        return { try withExtendedLifetime(lifetime) { try cancel() } }
      },
      makeCapability: base.makeCapability,
      send: base.send,
      barrier: base.barrier,
      discard: base.discard)
    let operation = DeviceHIDOperation(transport: transport, prepared: DeviceHIDFixture.prepared(), quarantine: {})
    active.set(operation)
    defer { active.set(nil) }
    let outcome = await operation.run()
    try await fixture.events.waitFor("captureRetired")
    #expect(outcome.error == nil)
    #expect(fixture.events.count("captureRetired") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
  }

  @Test func uncertainPublicationWaitsForQuarantineEvenWhenTheFirstCallbackIsPaused() async throws {
    let fixture = DeviceHIDFixture(fail: "end")
    let result = try await finishWhileFirstQuarantineIsPaused(fixture)
    try await fixture.events.waitFor("transportRetired")
    #expect(result.outcome.uncertain)
    #expect(result.latchedBeforeReturn)
    #expect(fixture.events.count("quarantineLatched") >= 1)
    #expect(fixture.events.count("releaseReturned") == 1)
  }

  private func finishWhileFirstQuarantineIsPaused(_ fixture: DeviceHIDFixture) async throws -> (outcome: DeviceHIDOutcome, latchedBeforeReturn: Bool) {
    let firstCallback = DeviceHIDTestGate()
    defer { firstCallback.open() }
    let callbacks = Atomic(wrappedValue: 0)
    let operation = DeviceHIDOperation(
      transport: fixture.transport,
      prepared: DeviceHIDFixture.prepared(),
      quarantine: {
        let index = callbacks.sync { count in
          count += 1
          return count
        }
        if index == 1 {
          fixture.events.record("firstQuarantinePaused")
          firstCallback.wait()
        } else {
          fixture.state.sync { $0.quarantined = true }
          fixture.events.record("quarantineLatched")
        }
      })
    let task = Task { await operation.run() }
    try await fixture.events.waitFor("firstQuarantinePaused")
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("endReturned") == 0)
    operation.cancel()
    firstCallback.open()
    let outcome = await task.value
    let latched = fixture.state.sync { $0.quarantined }
    return (outcome, latched)
  }

  @Test(arguments: ["acquire", "observe", "factory", "start", "position", "end", "barrier", "release"])
  func lateReturnsFailEvenWhenTimersCannotRun(_ phase: String) async throws {
    let fixture = DeviceHIDFixture(block: phase)
    let outcome = try await completePastDeadline(fixture, phase: phase)
    try await fixture.events.waitFor("transportRetired")
    let error = try #require(outcome.error as? DeviceHIDError)
    guard case .deadlineExceeded = error else {
      Issue.record("A clean late return lost the deadline error: \(error)")
      return
    }
    #expect(!outcome.uncertain)
    #expect(!fixture.state.sync { $0.quarantined })
    #expect(fixture.events.count("releaseReturned") == 1)
    if phase == "acquire" || phase == "observe" {
      #expect(fixture.events.count("factory") == 0)
    }
    if phase == "acquire" || phase == "observe" || phase == "factory" {
      #expect(fixture.events.count("start") == 0)
    } else {
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
    }
  }

  private func completePastDeadline(_ fixture: DeviceHIDFixture, phase: String) async throws -> DeviceHIDOutcome {
    let timers = DispatchQueue(label: "device-hid-test.operation-timers")
    timers.suspend()
    defer {
      timers.resume()
      fixture.gate.open()
    }
    let operation = DeviceHIDOperation(
      transport: fixture.transport,
      prepared: DeviceHIDFixture.prepared(),
      positions: phase == "position" ? [DeviceHIDPosition(point: CGPoint(x: 0.5, y: 0.5), delay: 0)] : [],
      operationSeconds: 1,
      cleanupReserve: 0.1,
      timerQueue: timers,
      quarantine: { fixture.state.sync { $0.quarantined = true } })
    let task = Task { await operation.run() }
    try await fixture.events.waitFor(phase)
    let entered = try #require(fixture.events.time(phase))
    let expires = entered.advanced(by: .milliseconds(1200))
    fixture.events.onDeadline(expires, signal: "operationDeadline") { fixture.gate.open() }
    let outcome = await task.value
    let observed = try #require(fixture.events.time("operationDeadline"))
    #expect(observed >= expires)
    return outcome
  }
}
