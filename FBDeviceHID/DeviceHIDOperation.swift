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
}

/// One assertion and one fixed contact plan. Native work never runs under the state mutex.
final class DeviceHIDOperation: Sendable {
  private struct Lease {
    let assertion: DeviceHIDAssertion
    var releaseClaimed = false
    var releaseReturned = false
  }

  private enum PendingOperation {
    case acquisition
    case factory
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

  private struct State {
    var continuation: CheckedContinuation<DeviceHIDOutcome, Never>?
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
    var cancellations: [Cancellation] = []
    var startScheduled = false
    var startAdmitted = false
    var startReturned = false
    var holdUntil: ContinuousClock.Instant?
    var positionIndex = 0
    var positionScheduled = false
    var lastAdmittedPoint: CGPoint?
    var endScheduled = false
    var endClaimed = false
    var endReturned = false
    var endSucceeded = false
    var barrierScheduled = false
    var barrierReturned = false
    var inputInFlight: InputCall?
    var discardClaimed = false
    var discardReturned = false

    mutating func fail(_ error: any Error, uncertain: Bool, cleanup: Bool = false) -> (Bool, Bool) {
      let newlyUncertain = uncertain && !self.uncertain
      self.uncertain = self.uncertain || uncertain
      guard !finished else { return (false, newlyUncertain) }
      let first = self.error == nil
      if first {
        self.error = error
      } else if cleanup {
        cleanupFailures.append(error)
      }
      return (first, newlyUncertain)
    }

    mutating func reconcile(deadline: ContinuousClock.Instant) -> Bool {
      guard !finished, error == nil, ContinuousClock.now >= deadline else { return false }
      error = DeviceHIDError.deadlineExceeded
      return true
    }

    var pending: Bool {
      acquisitionInvoking || (acquisitionStarted && !acquisitionCompleted)
        || observationPending || factoryInvoking || (factoryStarted && !factoryCompleted)
        || inputInFlight != nil || cancellations.contains { $0.claimed && !$0.returned }
    }
  }

  private enum Action {
    case acquire
    case observe(DeviceHIDAssertion)
    case factory
    case input(InputCall)
    case cancel(Int, DeviceHIDCancellation)
    case release(DeviceHIDAssertion)
    case discard
    case deadline
    case finish(CheckedContinuation<DeviceHIDOutcome, Never>, Atomic<[Cancellation]>)
  }

  private let transport: DeviceDigitizerHIDTransport
  private let point: CGPoint
  private let duration: TimeInterval
  private let positions: [DeviceHIDPosition]
  private let totalDuration: TimeInterval
  private let deadline: ContinuousClock.Instant
  private let cleanupReserve: TimeInterval
  private let quarantine: @Sendable () -> Void
  private let state = Atomic(wrappedValue: State())
  private let transportQueue = DispatchQueue(label: "com.facebook.idb.device-hid.transport")
  private let cleanupQueue = DispatchQueue(label: "com.facebook.idb.device-hid.cleanup", attributes: .concurrent)
  private let cancellationQueue = DispatchQueue(label: "com.facebook.idb.device-hid.cancel", attributes: .concurrent)
  private let operationTimer: any DispatchSourceTimer

  init(transport: DeviceDigitizerHIDTransport, prepared: DeviceHIDPreparedTap, positions: [DeviceHIDPosition] = [], operationSeconds: TimeInterval = 10, cleanupReserve: TimeInterval = 5, timerQueue: DispatchQueue = .global(), quarantine: @escaping @Sendable () -> Void) {
    self.transport = transport
    point = prepared.point
    duration = prepared.duration ?? 0
    self.positions = positions
    totalDuration = positions.reduce(prepared.duration ?? 0) { $0 + $1.delay }
    deadline = ContinuousClock.now.advanced(by: .seconds(operationSeconds))
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

  static func validate(point: CGPoint, duration: TimeInterval?) throws {
    guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.x < 1, point.y >= 0, point.y < 1 else {
      throw DeviceHIDError.preparationFailed("The normalized point must be finite and inside the display")
    }
    if let duration, !duration.isFinite || duration < 0 {
      throw DeviceHIDError.preparationFailed("The hold duration must be finite and nonnegative")
    }
  }

  func run() async -> DeviceHIDOutcome {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let installed = state.sync { state in
          guard !state.running else { return false }
          state.running = true
          state.continuation = continuation
          return true
        }
        guard installed else {
          continuation.resume(returning: DeviceHIDOutcome(error: DeviceHIDError.unexpectedCompletion, uncertain: true))
          return
        }
        do {
          try Self.validate(point: point, duration: duration)
          guard positions.count < DeviceHIDTouchSequence.maximumEvents, totalDuration.isFinite else {
            throw DeviceHIDError.preparationFailed("The contact plan exceeds its count or duration bound")
          }
          for position in positions { try Self.validate(point: position.point, duration: position.delay) }
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

  func cancel() { stop(CancellationError()) }

  private func stop(_ error: any Error, uncertain: Bool = false, cleanup: Bool = false) {
    let summary: any Error = error is CancellationError ? CancellationError() : DeviceHIDError.native(error, operation: "operation")
    let changes = withExtendedLifetime(error) {
      state.sync { $0.fail(summary, uncertain: uncertain, cleanup: cleanup) }
    }
    if changes.1 { quarantine() }
    if changes.0 { operationTimer.cancel() }
    advance()
  }

  private func advance() {
    let actions = state.sync { state -> [Action] in
      guard state.running, !state.finishing, !state.finished else { return [] }
      var actions: [Action] = []
      if state.reconcile(deadline: deadline) { actions.append(.deadline) }
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
      if !stopped, state.observationReturned, !state.acquisitionInvoking, !state.factoryStarted {
        state.factoryStarted = true
        state.factoryInvoking = true
        actions.append(.factory)
      }
      if !stopped, state.factoryReady, !state.factoryInvoking, !state.startScheduled {
        state.startScheduled = true
        actions.append(.input(.start))
      }
      if state.startReturned, state.inputInFlight == nil, !state.endScheduled {
        if stopped {
          state.endScheduled = true
          actions.append(.input(.end))
        } else if state.holdUntil.map({ ContinuousClock.now >= $0 }) == true {
          if state.positionIndex < positions.count {
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
      if state.needsBarrier, state.inputInFlight == nil, !state.barrierScheduled, contactEnded {
        state.barrierScheduled = true
        actions.append(.input(.barrier))
      }
      if stopped {
        for index in state.cancellations.indices {
          let pending: Bool
          switch state.cancellations[index].operation {
          case .acquisition: pending = state.acquisitionInvoking || !state.acquisitionCompleted
          case .factory: pending = state.factoryInvoking || !state.factoryCompleted
          }
          if pending, !state.cancellations[index].claimed {
            state.cancellations[index].claimed = true
            actions.append(.cancel(index, state.cancellations[index].call))
          }
        }
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
      if releaseEligible && cleanupReturned, let continuation = state.continuation {
        state.finishing = true
        state.continuation = nil
        let retired = Atomic(wrappedValue: state.cancellations)
        state.cancellations = []
        actions.append(.finish(continuation, retired))
      }
      return actions
    }
    for action in actions { perform(action) }
  }

  private func perform(_ action: Action) {
    switch action {
    case .acquire:
      transportQueue.async { self.acquire() }
    case .observe(let assertion):
      transportQueue.async { self.observe(assertion) }
    case .factory:
      transportQueue.async { self.makeDigitizer() }
    case .input(let call):
      transportQueue.async { self.input(call) }
    case .cancel(let index, let cancel):
      cancellationQueue.async {
        do { try cancel() } catch { self.stop(DeviceHIDError.native(error, operation: "cancellation request"), uncertain: true, cleanup: true) }
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
    case .finish(let continuation, let retired):
      let outcome = state.sync { state in
        _ = state.reconcile(deadline: deadline)
        state.finished = true
        let error = state.error.map { cause -> any Error in
          state.cleanupFailures.isEmpty ? cause : DeviceHIDError.cleanupFailed(cause: cause, failures: state.cleanupFailures)
        }
        return DeviceHIDOutcome(error: error, uncertain: state.uncertain)
      }
      if outcome.uncertain { quarantine() }
      operationTimer.cancel()
      continuation.resume(returning: outcome)
      cleanupQueue.async {
        let values = retired.sync { values in
          let removed = values
          values = []
          return removed
        }
        withExtendedLifetime(values) {}
      }
    }
  }

  private func acquire() {
    guard state.sync(execute: { !$0.finishing && !$0.finished && $0.error == nil && ContinuousClock.now < deadline }) else {
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
      if state.sync(execute: { !$0.finishing && !$0.finished && $0.error == nil && ContinuousClock.now < deadline }) {
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
      return state.fail(DeviceHIDError.assertionInvalidated, uncertain: state.startAdmitted)
    }
    if changes.1 { quarantine() }
    if changes.0 { operationTimer.cancel() }
    advance()
  }

  private func makeDigitizer() {
    guard state.sync(execute: { !$0.finishing && !$0.finished && $0.error == nil && ContinuousClock.now < deadline }) else {
      state.sync {
        $0.factoryInvoking = false
        $0.factoryCompleted = true
      }
      advance()
      return
    }
    do {
      let cancel = try transport.makeDigitizer { result in
        let result = result.mapError { DeviceHIDError.native($0, operation: "digitizer construction") }
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
      stop(DeviceHIDError.native(error, operation: "digitizer construction"))
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
    var inputPoint = point
    var hold: TimeInterval = 0
    let admitted = state.sync { state -> Bool in
      clockExpired = state.reconcile(deadline: deadline)
      guard !state.finishing, !state.finished, state.inputInFlight == nil else { return false }
      let now = ContinuousClock.now
      switch call {
      case .start:
        guard state.error == nil else { return false }
        let remaining = now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard totalDuration < seconds - cleanupReserve else {
          refusal = DeviceHIDError.preparationFailed("Insufficient input budget: \(seconds)s remaining, \(totalDuration)s hold, \(cleanupReserve)s reserved for contact cleanup")
          return false
        }
        state.startAdmitted = true
        state.lastAdmittedPoint = point
        hold = duration
      case .position:
        state.positionScheduled = false
        guard state.error == nil, state.startReturned, !state.endScheduled, positions.indices.contains(state.positionIndex) else { return false }
        let position = positions[state.positionIndex]
        inputPoint = position.point
        hold = position.delay
        state.lastAdmittedPoint = inputPoint
      case .end:
        guard state.startAdmitted, state.startReturned, !state.endClaimed else { return false }
        state.endClaimed = true
        inputPoint = state.lastAdmittedPoint ?? point
      case .barrier:
        guard state.needsBarrier, !state.startAdmitted || state.endReturned else { return false }
      }
      if call != .barrier { state.needsBarrier = true }
      state.inputInFlight = call
      return true
    }
    if clockExpired { operationTimer.cancel() }
    if let refusal { stop(refusal) }
    guard admitted else {
      advance()
      return
    }
    var failure: (any Error)?
    do {
      switch call {
      case .start: try transport.send(.start, inputPoint)
      case .position: try transport.send(.position, inputPoint)
      case .end: try transport.send(.end, inputPoint)
      case .barrier: try transport.barrier()
      }
    } catch { failure = error }
    let summary = failure.map { DeviceHIDError.native($0, operation: call.rawValue) }
    let changes = withExtendedLifetime(failure) {
      state.sync { state -> (Bool, Bool) in
        var changes = (state.reconcile(deadline: deadline), false)
        state.inputInFlight = nil
        switch call {
        case .start:
          state.startReturned = true
          state.holdUntil = ContinuousClock.now.advanced(by: .seconds(hold))
        case .position:
          state.positionIndex += 1
          state.holdUntil = ContinuousClock.now.advanced(by: .seconds(hold))
        case .end:
          state.endReturned = true
          state.endSucceeded = summary == nil
        case .barrier:
          state.barrierReturned = true
          state.needsBarrier = false
        }
        if let summary {
          let failure = state.fail(summary, uncertain: true, cleanup: true)
          changes = (changes.0 || failure.0, changes.1 || failure.1)
        }
        return changes
      }
    }
    if changes.1 { quarantine() }
    if changes.0 { operationTimer.cancel() }
    if hold > 0 {
      cleanupQueue.asyncAfter(deadline: .now() + hold) { [weak self] in self?.advance() }
    }
    advance()
  }
}
