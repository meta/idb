/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Dispatch
import Foundation
internal import IDBConcurrency

typealias DeviceHIDCancellation = @Sendable () throws -> Void

enum DeviceHIDContactPhase: Sendable {
  case start
  case position
  case end
}

struct DeviceHIDAssertion: Sendable {
  let identifier: UUID
  let release: @Sendable () throws -> Void
  let observe: @Sendable (@escaping @Sendable () -> Void) throws -> Void
}

struct DeviceHIDOutcome: Sendable {
  let error: (any Error)?
  let uncertain: Bool
  var uncertaintyCause: DeviceHIDError?
  var inputAdmitted = false

  func get() throws {
    if uncertain {
      throw DeviceHIDError.liveUncertain(cause: error ?? DeviceHIDError.unexpectedCompletion, uncertainty: uncertaintyCause)
    }
    if let error {
      if inputAdmitted { throw DeviceHIDError.inputMayHaveApplied(cause: error) }
      throw error
    }
  }
}

/// One assertion and one bounded plan or live contact. Native work never runs under the state mutex.
final class DeviceHIDOperation: Sendable {
  private struct Lease {
    let assertion: DeviceHIDAssertion
    var releaseClaimed = false
    var releaseReturned = false
  }

  private enum PendingOperation {
    case acquisition
    case factory
    case display
  }

  private struct Cancellation {
    let operation: PendingOperation
    let call: DeviceHIDCancellation
    var claimed = false
    var returned = false
  }

  private enum InputCall: String {
    case start
    case position
    case end
    case barrier
  }

  enum Mode: Sendable {
    case bounded(DeviceHIDPreparedInput)
    case live(DeviceHIDLivePreparation)
  }

  private struct LiveInput {
    let call: InputCall
    let point: CGPoint
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var live = false
    var liveReady = false
    var liveReadyWaiter: CheckedContinuation<Void, any Error>?
    var liveInput: LiveInput?
    var nativeUntil: ContinuousClock.Instant?
    var uncertaintyCause: DeviceHIDError?
    var continuation: CheckedContinuation<DeviceHIDOutcome, Never>?
    var retirementUntil: ContinuousClock.Instant?
    var lifetime: DeviceHIDOperation?
    var running = false
    var finishing = false
    var finished = false
    // Only value-type DeviceHIDError or CancellationError; summarize foreign errors before locking.
    var error: (any Error)?
    var uncertain = false
    var cleanupFailures: [any Error] = []
    var needsBarrier = false
    var acquisitionStarted = false
    var acquisitionInvoking = false
    var acquisitionCompleted = false
    var assertions: [UUID: Lease] = [:]
    var primaryAssertion: UUID?
    var observationStarted = false
    var observationPending = false
    var observationReturned = false
    var factoryStarted = false
    var factoryInvoking = false
    var factoryCompleted = false
    var factoryReady = false
    var displayStarted = false
    var displayInvoking = false
    var displayCompleted = false
    var displayBaseline: DeviceHIDDisplaySnapshot?
    var displayStopRequested = false
    var cancellations: [Cancellation] = []
    var contactIndex = 0
    var anyStartAdmitted = false
    var startScheduled = false
    var startAdmitted = false
    var startReturned = false
    var holdUntil: ContinuousClock.Instant?
    var positionIndex = 0
    var positionScheduled = false
    var lastAdmittedContact: DeviceHIDContact?
    var endScheduled = false
    var endClaimed = false
    var endReturned = false
    var endSucceeded = false
    var barrierScheduled = false
    var barrierReturned = false
    var inputInFlight: InputCall?
    var discardClaimed = false
    var discardReturned = false

    mutating func nextContact() {
      contactIndex += 1
      startScheduled = false
      startAdmitted = false
      startReturned = false
      holdUntil = nil
      positionIndex = 0
      positionScheduled = false
      lastAdmittedContact = nil
      endScheduled = false
      endClaimed = false
      endReturned = false
      endSucceeded = false
    }

    mutating func fail(_ error: any Error, uncertain: Bool, cleanup: Bool = false) -> (Bool, Bool) {
      let newlyUncertain = uncertain && !self.uncertain
      self.uncertain = self.uncertain || uncertain
      if uncertain, uncertaintyCause == nil { uncertaintyCause = error as? DeviceHIDError }
      guard !finished, !finishing || uncertain else { return (false, newlyUncertain) }
      let first = self.error == nil
      if first {
        self.error = error
      } else if cleanup {
        cleanupFailures.append(error)
      }
      return (first, newlyUncertain)
    }

    func activeDeadline(_ setupDeadline: ContinuousClock.Instant) -> ContinuousClock.Instant? {
      live && liveReady ? nativeUntil : setupDeadline
    }

    mutating func reconcile(deadline: ContinuousClock.Instant, now: ContinuousClock.Instant) -> Bool {
      guard !finished, error == nil, let active = activeDeadline(deadline), now >= active else { return false }
      error = DeviceHIDError.deadlineExceeded
      return true
    }

    mutating func publication() -> Publication? {
      guard let continuation else { return nil }
      let error = error.map { cause -> any Error in
        cleanupFailures.isEmpty ? cause : DeviceHIDError.cleanupFailed(cause: cause, failures: cleanupFailures)
      }
      let result = Publication(
        continuation: continuation,
        outcome: DeviceHIDOutcome(error: error, uncertain: uncertain, uncertaintyCause: uncertaintyCause, inputAdmitted: anyStartAdmitted),
        ready: liveReadyWaiter, input: liveInput)
      self.continuation = nil
      liveReadyWaiter = nil
      liveInput = nil
      return result
    }

    var pending: Bool {
      acquisitionInvoking || (acquisitionStarted && !acquisitionCompleted)
        || observationPending || factoryInvoking || (factoryStarted && !factoryCompleted)
        || displayInvoking || (displayStarted && !displayCompleted)
        || inputInFlight != nil || cancellations.contains { $0.claimed && !$0.returned }
    }
  }

  private enum Action {
    case acquire
    case observe(DeviceHIDAssertion)
    case display
    case factory
    case input(InputCall)
    case cancel(Int)
    case release(DeviceHIDAssertion)
    case discard
    case deadline
    case ready(CheckedContinuation<Void, any Error>)
    case retirementDeadline
    case publish(Publication)
    case finish(Atomic<[Cancellation]>)
  }

  private struct Publication {
    let continuation: CheckedContinuation<DeviceHIDOutcome, Never>
    let outcome: DeviceHIDOutcome
    let ready: CheckedContinuation<Void, any Error>?
    let input: LiveInput?
  }

  private let transport: DeviceHIDTransport
  private let live: DeviceHIDLivePreparation?
  private let expectedDisplay: DeviceHIDDisplaySnapshot?
  private let contacts: [DeviceHIDContactPlan]
  private let totalDuration: TimeInterval
  private let deadline: ContinuousClock.Instant
  private let cleanupReserve: TimeInterval
  private let retirementSeconds: TimeInterval
  private let retired: @Sendable () -> Void
  private let callSeconds: TimeInterval
  private let clock: @Sendable () -> ContinuousClock.Instant
  private let quarantine: @Sendable () -> Void
  private let state: Atomic<State>
  private let transportQueue = DispatchQueue(label: "com.facebook.idb.device-hid.transport")
  private let cleanupQueue = DispatchQueue(label: "com.facebook.idb.device-hid.cleanup", attributes: .concurrent)
  private let cancellationQueue = DispatchQueue(label: "com.facebook.idb.device-hid.cancel", attributes: .concurrent)
  private let operationTimer: any DispatchSourceTimer

  convenience init(transport: DeviceHIDTransport, input: DeviceHIDPreparedInput, operationSeconds: TimeInterval = 10, cleanupReserve: TimeInterval = 5, retirementSeconds: TimeInterval = 5, timerQueue: DispatchQueue = .global(), retired: @escaping @Sendable () -> Void = {}, quarantine: @escaping @Sendable () -> Void) {
    self.init(transport: transport, mode: .bounded(input), operationSeconds: operationSeconds, cleanupReserve: cleanupReserve, retirementSeconds: retirementSeconds, timerQueue: timerQueue, retired: retired, quarantine: quarantine)
  }

  init(transport: DeviceHIDTransport, mode: Mode, operationSeconds: TimeInterval = 10, cleanupReserve: TimeInterval = 5, retirementSeconds: TimeInterval = 5, timerQueue: DispatchQueue = .global(), clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, retired: @escaping @Sendable () -> Void = {}, quarantine: @escaping @Sendable () -> Void) {
    self.transport = transport
    self.retirementSeconds = retirementSeconds
    self.retired = retired
    self.clock = clock
    callSeconds = operationSeconds
    let live: DeviceHIDLivePreparation?
    let contacts: [DeviceHIDContactPlan]
    switch mode {
    case .live(let prepared):
      live = prepared
      expectedDisplay = prepared.displaySnapshot
      contacts = []
    case .bounded(let input):
      live = nil
      let first = DeviceHIDContactPlan(contact: input.contact, duration: input.duration ?? 0, positions: input.positions)
      switch input {
      case .touch(let touch):
        expectedDisplay = touch.start.displaySnapshot
        contacts = [DeviceHIDContactPlan(contact: first.contact, duration: first.duration, positions: first.positions, pause: touch.pause)] + touch.subsequent
      case .button:
        expectedDisplay = nil
        contacts = [first]
      }
    }
    self.live = live
    self.contacts = contacts
    state = Atomic(wrappedValue: State(live: live != nil))
    totalDuration = contacts.reduce(0) { $0 + $1.totalDuration }
    deadline = clock().advanced(by: .seconds(operationSeconds))
    self.cleanupReserve = cleanupReserve
    self.quarantine = quarantine
    operationTimer = DispatchSource.makeTimerSource(queue: timerQueue)
    operationTimer.setEventHandler { [weak self] in self?.advance() }
    operationTimer.schedule(deadline: .now() + operationSeconds)
    operationTimer.resume()
  }

  deinit {
    operationTimer.cancel()
  }

  static func validate(point: CGPoint, duration: TimeInterval?, secondPoint: CGPoint? = nil) throws {
    guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.x < 1, point.y >= 0, point.y < 1 else {
      throw DeviceHIDError.preparationFailed("The normalized point must be finite and inside the display")
    }
    if let duration, !duration.isFinite || duration < 0 {
      throw DeviceHIDError.preparationFailed("The hold duration must be finite and nonnegative")
    }
    if let secondPoint {
      try validate(point: secondPoint, duration: nil)
      guard secondPoint != point else { throw DeviceHIDError.preparationFailed("Two-finger points must be distinct") }
    }
  }

  func run() async -> DeviceHIDOutcome {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let installed = state.sync { state in
          guard !state.running else { return false }
          state.running = true
          state.lifetime = self
          state.continuation = continuation
          return true
        }
        guard installed else {
          continuation.resume(returning: DeviceHIDOutcome(error: DeviceHIDError.unexpectedCompletion, uncertain: true))
          return
        }
        do {
          guard
            live != nil
              || (contacts.reduce(0, { $0 + $1.positions.count + 2 }) <= DeviceHIDTouchSequence.maximumEvents
                && totalDuration.isFinite && contacts.last?.pause == 0)
          else { throw DeviceHIDError.preparationFailed("The contact plan exceeds its count or duration bound") }
          for plan in contacts {
            guard plan.pause.isFinite, plan.pause >= 0 else { throw DeviceHIDError.preparationFailed("Contact pauses must be finite and nonnegative") }
            switch plan.contact {
            case let .touch(point, secondPoint):
              try Self.validate(point: point, duration: plan.duration, secondPoint: secondPoint)
              guard plan.positions.allSatisfy({ ($0.secondPoint == nil) == (secondPoint == nil) }) else {
                throw DeviceHIDError.preparationFailed("A contact cannot change between one and two fingers")
              }
            case .button:
              guard contacts.count == 1, plan.positions.isEmpty, plan.duration.isFinite, plan.duration >= 0 else {
                throw DeviceHIDError.preparationFailed("A button plan must contain one bounded press")
              }
            }
            for position in plan.positions { try Self.validate(point: position.point, duration: position.delay, secondPoint: position.secondPoint) }
          }
          if Task.isCancelled { cancel() }
          advance()
        } catch {
          stop(error)
        }
      }
    } onCancel: {
      self.cancel()
    }
  }

  func waitUntilReady() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result: Result<Void, any Error>? = state.sync { state in
          guard state.live, state.liveReadyWaiter == nil else { return .failure(DeviceHIDError.unexpectedCompletion) }
          if let error = state.error { return .failure(error) }
          guard !state.finishing, !state.finished else { return .failure(CancellationError()) }
          if state.liveReady { return .success(()) }
          state.liveReadyWaiter = continuation
          return nil
        }
        if let result { continuation.resume(with: result) }
      }
    } onCancel: {
      self.cancel()
    }
  }

  func sendLive(_ event: DeviceHIDLiveEvent) async throws {
    guard let live else { throw DeviceHIDError.unexpectedCompletion }
    let call: InputCall
    let point: CGPoint
    switch event {
    case let .down(x, y): (call, point) = (.start, CGPoint(x: x, y: y))
    case let .move(x, y): (call, point) = (.position, CGPoint(x: x, y: y))
    case let .up(x, y): (call, point) = (.end, CGPoint(x: x, y: y))
    }
    let normalized = try live.normalize(point)
    try Self.validate(point: normalized, duration: nil)
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        let error: (any Error)? = state.sync { state in
          if let error = state.error { return error }
          guard state.liveReady, !state.finishing, !state.finished else { return DeviceHIDError.unexpectedCompletion }
          guard state.liveInput == nil, state.inputInFlight == nil else { return DeviceHIDError.busy }
          switch call {
          case .start:
            guard !state.startScheduled else { return DeviceHIDError.liveProtocol("One DOWN is allowed per live contact") }
          case .position:
            guard state.startReturned, !state.endScheduled else { return DeviceHIDError.liveProtocol("MOVE requires an active contact") }
          case .end:
            guard state.startReturned, !state.endScheduled,
              case .touch(let last, nil)? = state.lastAdmittedContact, last == normalized
            else { return DeviceHIDError.liveProtocol("UP must match the last admitted point") }
          case .barrier: return DeviceHIDError.unexpectedCompletion
          }
          state.liveInput = LiveInput(call: call, point: normalized, continuation: continuation)
          state.nativeUntil = self.clock().advanced(by: .seconds(callSeconds))
          return nil
        }
        if let error { continuation.resume(throwing: error) }
        advance()
      }
    } onCancel: {
      self.cancel()
    }
  }

  func cancel() { stop(CancellationError()) }

  func stop(_ error: any Error, uncertain: Bool = false, cleanup: Bool = false) {
    let summary: any Error = error is CancellationError ? CancellationError() : DeviceHIDError.native(error, operation: "operation")
    let changes = withExtendedLifetime(error) {
      state.sync { $0.fail(summary, uncertain: uncertain, cleanup: cleanup) }
    }
    if changes.1 { quarantine() }
    if changes.0 { operationTimer.cancel() }
    advance()
  }

  private func scheduleWatchdog() {
    state.sync { state in
      guard state.live, state.running, !state.finished, state.error == nil else { return }
      guard !state.finishing, let until = state.activeDeadline(deadline) else {
        operationTimer.schedule(deadline: .distantFuture)
        return
      }
      let remaining = self.clock().duration(to: until).components
      let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
      operationTimer.schedule(deadline: .now() + max(0, seconds))
    }
  }

  func advance() {
    let actions = state.sync { state -> [Action] in
      guard state.running, !state.finished else { return [] }
      var actions: [Action] = []
      if let until = state.retirementUntil, self.clock() >= until, state.continuation != nil {
        _ = state.fail(DeviceHIDError.deadlineExceeded, uncertain: true)
        if let publication = state.publication() { actions.append(.publish(publication)) }
      }
      guard !state.finishing else { return actions }
      if state.reconcile(deadline: deadline, now: self.clock()) { actions.append(.deadline) }
      let stopped = state.error != nil
      if !stopped, !state.acquisitionStarted {
        state.acquisitionStarted = true
        state.acquisitionInvoking = true
        actions.append(.acquire)
      }
      if !stopped, let id = state.primaryAssertion, let lease = state.assertions[id], !state.observationStarted {
        state.observationStarted = true
        state.observationPending = true
        actions.append(.observe(lease.assertion))
      }
      if !stopped, state.observationReturned, !state.acquisitionInvoking {
        if expectedDisplay != nil, !state.displayStarted {
          state.displayStarted = true
          state.displayInvoking = true
          actions.append(.display)
        }
        if expectedDisplay == nil || state.displayBaseline != nil, !state.displayInvoking, !state.factoryStarted {
          state.factoryStarted = true
          state.factoryInvoking = true
          actions.append(.factory)
        }
      }
      if !stopped, !state.live, state.endSucceeded, state.inputInFlight == nil,
        state.contactIndex + 1 < contacts.count, state.holdUntil.map({ self.clock() >= $0 }) == true
      {
        state.nextContact()
      }
      if !stopped, state.live, state.factoryReady, !state.factoryInvoking, !state.liveReady {
        state.liveReady = true
        if let waiter = state.liveReadyWaiter {
          state.liveReadyWaiter = nil
          actions.append(.ready(waiter))
        }
      }
      if !stopped, state.factoryReady, !state.factoryInvoking, !state.startScheduled,
        !state.live || state.liveInput?.call == .start
      {
        state.startScheduled = true
        actions.append(.input(.start))
      }
      if state.startReturned, state.inputInFlight == nil, !state.endScheduled {
        if stopped {
          state.endScheduled = true
          actions.append(.input(.end))
        } else if state.live {
          if state.liveInput?.call == .position, !state.positionScheduled {
            state.positionScheduled = true
            actions.append(.input(.position))
          } else if state.liveInput?.call == .end {
            state.endScheduled = true
            actions.append(.input(.end))
          }
        } else if state.holdUntil.map({ self.clock() >= $0 }) == true {
          if state.positionIndex < contacts[state.contactIndex].positions.count {
            if !state.positionScheduled {
              state.positionScheduled = true
              actions.append(.input(.position))
            }
          } else {
            state.endScheduled = true
            actions.append(.input(.end))
          }
        }
      }
      let contactEnded = !state.startAdmitted || state.endReturned
      if state.needsBarrier, state.inputInFlight == nil, !state.barrierScheduled,
        stopped ? contactEnded : (state.endReturned && (state.live || state.contactIndex == contacts.count - 1))
      {
        state.barrierScheduled = true
        actions.append(.input(.barrier))
      }
      if state.displayStarted, stopped || state.barrierReturned { state.displayStopRequested = true }
      for index in state.cancellations.indices {
        let pending: Bool
        switch state.cancellations[index].operation {
        case .acquisition: pending = stopped && (state.acquisitionInvoking || !state.acquisitionCompleted)
        case .factory: pending = stopped && (state.factoryInvoking || !state.factoryCompleted)
        case .display: pending = state.displayStopRequested && !state.displayCompleted
        }
        if pending, !state.cancellations[index].claimed {
          state.cancellations[index].claimed = true
          actions.append(.cancel(index))
        }
      }
      let terminating = stopped || (state.endScheduled && (state.live || state.contactIndex == contacts.count - 1))
      if terminating, state.retirementUntil == nil {
        state.retirementUntil = self.clock().advanced(by: .seconds(retirementSeconds))
        actions.append(.retirementDeadline)
      }
      let inputDrained = contactEnded && !state.needsBarrier
      let releaseEligible = !state.pending && (stopped ? inputDrained : state.barrierReturned)
      if releaseEligible {
        for id in Array(state.assertions.keys) {
          if var lease = state.assertions[id], !lease.releaseClaimed {
            lease.releaseClaimed = true
            state.assertions[id] = lease
            actions.append(.release(lease.assertion))
          }
        }
        if !state.discardClaimed {
          state.discardClaimed = true
          actions.append(.discard)
        }
      }
      let cleanupReturned = state.discardReturned && state.assertions.values.allSatisfy(\.releaseReturned)
      if releaseEligible && cleanupReturned {
        state.finishing = true
        let retired = Atomic(wrappedValue: state.cancellations)
        state.cancellations = []
        actions.append(.finish(retired))
      }
      return actions
    }
    scheduleWatchdog()
    for action in actions { perform(action) }
  }

  private func perform(_ action: Action) {
    switch action {
    case .acquire:
      transportQueue.async { self.acquire() }
    case .observe(let assertion):
      transportQueue.async { self.observe(assertion) }
    case .display:
      transportQueue.async { self.observeDisplays() }
    case .factory:
      transportQueue.async { self.makeCapability() }
    case .input(let call):
      transportQueue.async { self.input(call) }
    case .cancel(let index):
      cancellationQueue.async {
        self.requestCancellation(index)
        self.state.sync { state in
          if state.cancellations.indices.contains(index) { state.cancellations[index].returned = true }
        }
        self.advance()
      }
    case .release(let assertion):
      cleanupQueue.async {
        do { try assertion.release() } catch { self.stop(DeviceHIDError.native(error, operation: "assertion release"), uncertain: true, cleanup: true) }
        self.state.sync { $0.assertions[assertion.identifier]?.releaseReturned = true }
        self.advance()
      }
    case .discard:
      cleanupQueue.async {
        self.transport.discard()
        self.state.sync { $0.discardReturned = true }
        self.advance()
      }
    case .deadline:
      operationTimer.cancel()
    case .ready(let continuation):
      continuation.resume()
    case .retirementDeadline:
      cleanupQueue.asyncAfter(deadline: .now() + retirementSeconds) { [weak self] in self?.advance() }
    case .publish(let publication):
      publish(publication)
    case .finish(let captures):
      cleanupQueue.async {
        self.releaseCaptures(captures)
        let (publication, lifetime, uncertain) = self.state.sync { state in
          _ = state.reconcile(deadline: self.deadline, now: self.clock())
          if let until = state.retirementUntil, self.clock() >= until {
            _ = state.fail(DeviceHIDError.deadlineExceeded, uncertain: true)
          }
          state.finished = true
          let lifetime = state.lifetime
          state.lifetime = nil
          return (state.publication(), lifetime, state.uncertain)
        }
        if uncertain { self.quarantine() }
        self.retired()
        self.operationTimer.cancel()
        if let publication { self.publish(publication) }
        withExtendedLifetime(lifetime) {}
      }
    }
  }

  private func requestCancellation(_ index: Int) {
    let cancel = state.sync { state in state.cancellations.indices.contains(index) ? state.cancellations[index].call : nil }
    guard let cancel else {
      stop(DeviceHIDError.unexpectedCompletion, uncertain: true)
      return
    }
    do { try cancel() } catch { stop(DeviceHIDError.native(error, operation: "cancellation request"), uncertain: true, cleanup: true) }
  }

  private func releaseCaptures(_ captures: Atomic<[Cancellation]>) {
    let values = captures.sync { values in
      let removed = values
      values = []
      return removed
    }
    withExtendedLifetime(values) {}
  }

  private func publish(_ publication: Publication) {
    let outcome = publication.outcome
    if outcome.uncertain { quarantine() }
    operationTimer.cancel()
    publication.ready?.resume(throwing: outcome.error ?? DeviceHIDError.unexpectedCompletion)
    if let input = publication.input {
      if let error = outcome.error { input.continuation.resume(throwing: error) } else if input.call == .end { input.continuation.resume() } else { input.continuation.resume(throwing: DeviceHIDError.unexpectedCompletion) }
    }
    publication.continuation.resume(returning: outcome)
  }

  private func acquire() {
    guard state.sync(execute: { !$0.finishing && !$0.finished && $0.error == nil && self.clock() < deadline }) else {
      state.sync {
        $0.acquisitionInvoking = false
        $0.acquisitionCompleted = true
      }
      advance()
      return
    }
    do {
      let cancel = try transport.acquire { self.acquired($0) }
      install(cancel, for: .acquisition)
    } catch {
      state.sync { $0.acquisitionCompleted = true }
      stop(DeviceHIDError.native(error, operation: "assertion acquisition"))
    }
    state.sync { $0.acquisitionInvoking = false }
    advance()
  }

  private func acquired(_ result: Result<DeviceHIDAssertion, any Error>) {
    let result = result.mapError { DeviceHIDError.native($0, operation: "assertion acquisition") }
    let changes = withExtendedLifetime(result) {
      state.sync { state -> (Bool, Bool) in
        let first = !state.acquisitionCompleted
        state.acquisitionCompleted = true
        if case .success(let assertion) = result, state.assertions[assertion.identifier] == nil {
          state.assertions[assertion.identifier] = Lease(assertion: assertion)
          if first { state.primaryAssertion = assertion.identifier }
        }
        if !first {
          return state.fail(DeviceHIDError.unexpectedCompletion, uncertain: true)
        }
        if case .failure(let error) = result {
          return state.fail(error, uncertain: false)
        }
        return (false, false)
      }
    }
    if changes.1 { quarantine() }
    if changes.0 { operationTimer.cancel() }
    releaseLateAssertions()
    advance()
  }

  private func releaseLateAssertions() {
    let leases = state.sync { state -> [DeviceHIDAssertion] in
      guard state.finishing || state.finished else { return [] }
      let identifiers = Array(state.assertions.keys)
      return identifiers.compactMap { id in
        guard var lease = state.assertions[id], !lease.releaseClaimed else { return nil }
        lease.releaseClaimed = true
        state.assertions[id] = lease
        return lease.assertion
      }
    }
    for lease in leases { perform(.release(lease)) }
  }

  private func observe(_ assertion: DeviceHIDAssertion) {
    do {
      if state.sync(execute: { !$0.finishing && !$0.finished && $0.error == nil && self.clock() < deadline }) {
        let id = assertion.identifier
        try assertion.observe { [weak self] in self?.invalidated(id) }
      }
      state.sync {
        $0.observationReturned = true
        $0.observationPending = false
      }
    } catch {
      state.sync { $0.observationPending = false }
      stop(DeviceHIDError.native(error, operation: "assertion observation"))
    }
    advance()
  }

  private func invalidated(_ id: UUID) {
    let changes = state.sync { state -> (Bool, Bool) in
      guard !state.finished, state.assertions[id]?.releaseClaimed == false else { return (false, false) }
      return state.fail(DeviceHIDError.assertionInvalidated, uncertain: state.anyStartAdmitted)
    }
    if changes.1 { quarantine() }
    if changes.0 { operationTimer.cancel() }
    advance()
  }

  private func observeDisplays() {
    guard state.sync(execute: { !$0.finishing && !$0.finished && $0.error == nil && self.clock() < deadline }) else {
      state.sync {
        $0.displayInvoking = false
        $0.displayCompleted = true
      }
      advance()
      return
    }
    do {
      let cancel = try transport.observeDisplays({ self.receivedDisplay($0) }, { self.completedDisplays($0) })
      install(cancel, for: .display)
    } catch {
      state.sync { $0.displayCompleted = true }
      stop(DeviceHIDError.native(error, operation: "display observation startup"))
    }
    state.sync { $0.displayInvoking = false }
    advance()
  }

  private func receivedDisplay(_ snapshot: DeviceHIDDisplaySnapshot) {
    guard let expectedDisplay else { return }
    while true {
      let baseline = state.sync { $0.displayBaseline }
      let failure: (before: DeviceHIDError, after: DeviceHIDError)?
      do {
        if let baseline {
          try snapshot.validate(against: baseline)
        } else {
          try snapshot.validatePreparation(against: expectedDisplay)
        }
        failure = nil
      } catch {
        let error = DeviceHIDError.native(error, operation: "display observation")
        failure = (error, DeviceHIDError.observationAfterInput(error))
      }
      let changes = state.sync { state -> (retry: Bool, cancelTimer: Bool) in
        guard !state.finishing, !state.finished, !state.displayCompleted, !state.displayStopRequested else { return (false, false) }
        let expired = state.reconcile(deadline: deadline, now: self.clock())
        guard state.error == nil else { return (false, expired) }
        // The baseline can only transition from nil to one immutable full frame.
        if baseline == nil, state.displayBaseline != nil { return (true, false) }
        if let failure {
          return (false, state.fail(state.anyStartAdmitted ? failure.after : failure.before, uncertain: false).0)
        }
        if state.displayBaseline == nil { state.displayBaseline = snapshot }
        return (false, false)
      }
      if changes.retry { continue }
      if changes.cancelTimer { operationTimer.cancel() }
      break
    }
    advance()
  }

  private func completedDisplays(_ result: Result<Void, any Error>) {
    let failure: (any Error)?
    switch result {
    case .success: failure = nil
    case .failure(let error):
      failure = error is CancellationError ? CancellationError() : DeviceHIDError.native(error, operation: "display observation")
    }
    let beforeInput = failure ?? DeviceHIDError.preparationFailed("The selected-device display stream ended")
    let afterInput = DeviceHIDError.observationAfterInput(beforeInput)
    let changes = withExtendedLifetime(result) {
      state.sync { state -> (Bool, Bool) in
        guard !state.displayCompleted else { return state.fail(DeviceHIDError.unexpectedCompletion, uncertain: true) }
        state.displayCompleted = true
        if state.displayStopRequested {
          guard let failure, !(failure is CancellationError) else { return (false, false) }
          return state.fail(state.anyStartAdmitted ? afterInput : failure, uncertain: false, cleanup: true)
        }
        return state.fail(state.anyStartAdmitted ? afterInput : beforeInput, uncertain: false)
      }
    }
    if changes.1 { quarantine() }
    if changes.0 { operationTimer.cancel() }
    advance()
  }

  private func makeCapability() {
    guard state.sync(execute: { !$0.finishing && !$0.finished && $0.error == nil && self.clock() < deadline }) else {
      state.sync {
        $0.factoryInvoking = false
        $0.factoryCompleted = true
      }
      advance()
      return
    }
    do {
      let cancel = try transport.makeCapability { result in
        let result = result.mapError { DeviceHIDError.native($0, operation: "HID capability construction") }
        let changes = withExtendedLifetime(result) {
          self.state.sync { state -> (Bool, Bool) in
            let first = !state.factoryCompleted
            state.factoryCompleted = true
            if !first {
              return state.fail(DeviceHIDError.unexpectedCompletion, uncertain: true)
            }
            switch result {
            case .success:
              state.factoryReady = true
              return (false, false)
            case .failure(let error):
              return state.fail(error, uncertain: false)
            }
          }
        }
        if changes.1 { self.quarantine() }
        if changes.0 { self.operationTimer.cancel() }
        self.advance()
      }
      install(cancel, for: .factory)
    } catch {
      state.sync { $0.factoryCompleted = true }
      stop(DeviceHIDError.native(error, operation: "HID capability construction"))
    }
    state.sync { $0.factoryInvoking = false }
    advance()
  }

  private func install(_ cancellation: @escaping DeviceHIDCancellation, for operation: PendingOperation) {
    let late = state.sync { state -> Bool in
      guard !state.finishing, !state.finished else { return true }
      state.cancellations.append(Cancellation(operation: operation, call: cancellation))
      return false
    }
    if late {
      cancellationQueue.async {
        do { try cancellation() } catch { self.stop(DeviceHIDError.native(error, operation: "late cancellation request"), uncertain: true, cleanup: true) }
      }
    }
    advance()
  }

  private func input(_ call: InputCall) {
    var refusal: (any Error)?
    var clockExpired = false
    var inputContact: DeviceHIDContact?
    var hold: TimeInterval = 0
    let admitted = state.sync { state -> Bool in
      clockExpired = state.reconcile(deadline: deadline, now: self.clock())
      guard !state.finishing, !state.finished, state.inputInFlight == nil else { return false }
      let now = self.clock()
      let plan = contacts.indices.contains(state.contactIndex) ? contacts[state.contactIndex] : nil
      switch call {
      case .start:
        guard state.error == nil else { return false }
        if state.live {
          guard let input = state.liveInput, input.call == .start else { return false }
          inputContact = .touch(input.point, secondPoint: nil)
        } else {
          let remaining = now.duration(to: deadline).components
          let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
          let remainingDuration = contacts[state.contactIndex...].reduce(0) { $0 + $1.totalDuration }
          guard let plan, remainingDuration < seconds - cleanupReserve else {
            refusal =
              state.anyStartAdmitted
              ? DeviceHIDError.deadlineExceeded
              : DeviceHIDError.preparationFailed("Insufficient input budget: \(seconds)s remaining, \(remainingDuration)s hold, \(cleanupReserve)s reserved for contact cleanup")
            return false
          }
          inputContact = plan.contact
          hold = plan.duration
        }
        state.anyStartAdmitted = true
        state.startAdmitted = true
        state.lastAdmittedContact = inputContact
      case .position:
        state.positionScheduled = false
        guard state.error == nil, state.startReturned, !state.endScheduled else { return false }
        if state.live {
          guard let input = state.liveInput, input.call == .position else { return false }
          inputContact = .touch(input.point, secondPoint: nil)
        } else {
          guard let plan, plan.positions.indices.contains(state.positionIndex) else { return false }
          let position = plan.positions[state.positionIndex]
          inputContact = .touch(position.point, secondPoint: position.secondPoint)
          hold = position.delay
        }
        state.lastAdmittedContact = inputContact
      case .end:
        guard state.startAdmitted, state.startReturned, !state.endClaimed else { return false }
        state.endClaimed = true
        inputContact = state.lastAdmittedContact
        hold = plan?.pause ?? 0
      case .barrier:
        guard state.needsBarrier, !state.startAdmitted || state.endReturned else { return false }
      }
      if call != .barrier { state.needsBarrier = true }
      state.inputInFlight = call
      if state.live, state.nativeUntil == nil { state.nativeUntil = now.advanced(by: .seconds(callSeconds)) }
      return true
    }
    if clockExpired { operationTimer.cancel() }
    if let refusal { stop(refusal) }
    guard admitted else {
      advance()
      return
    }
    scheduleWatchdog()
    var failure: (any Error)?
    do {
      switch call {
      case .start, .position, .end:
        guard let inputContact else { throw DeviceHIDError.unexpectedCompletion }
        let phase: DeviceHIDContactPhase
        switch call {
        case .start: phase = .start
        case .position: phase = .position
        case .end, .barrier: phase = .end
        }
        try transport.send(phase, inputContact)
      case .barrier: try transport.barrier()
      }
    } catch { failure = error }
    let summary = failure.map { DeviceHIDError.native($0, operation: call.rawValue) }
    var reply: (CheckedContinuation<Void, any Error>, Result<Void, any Error>)?
    let changes = withExtendedLifetime(failure) {
      state.sync { state -> (Bool, Bool) in
        var changes = (state.reconcile(deadline: deadline, now: self.clock()), false)
        state.inputInFlight = nil
        switch call {
        case .start:
          state.startReturned = true
          state.holdUntil = self.clock().advanced(by: .seconds(hold))
        case .position:
          if !state.live { state.positionIndex += 1 }
          state.holdUntil = self.clock().advanced(by: .seconds(hold))
        case .end:
          state.endReturned = true
          state.endSucceeded = summary == nil
          state.holdUntil = self.clock().advanced(by: .seconds(hold))
        case .barrier:
          state.barrierReturned = true
          state.needsBarrier = false
        }
        if let summary {
          let failure = state.fail(summary, uncertain: true, cleanup: true)
          changes = (changes.0 || failure.0, changes.1 || failure.1)
        }
        state.nativeUntil = nil
        if let input = state.liveInput, input.call == call, call != .end {
          state.liveInput = nil
          reply = (input.continuation, state.error.map { .failure($0) } ?? .success(()))
        }
        return changes
      }
    }
    if changes.1 { quarantine() }
    if changes.0 { operationTimer.cancel() }
    if let (continuation, result) = reply { continuation.resume(with: result) }
    if hold > 0 {
      cleanupQueue.asyncAfter(deadline: .now() + hold) { [weak self] in self?.advance() }
    }
    advance()
  }
}
