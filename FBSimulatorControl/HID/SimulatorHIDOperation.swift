/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Exclusive use of HID for one complete operation, shared by a simulator's HID instances.
// SAFETY: All mutable state is protected by lock; continuations resume outside it.
final class SimulatorHIDOperationLease: @unchecked Sendable {
  private let lock = NSLock()
  private var inUse = false
  private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []

  func withLease<T>(_ operation: () async throws -> T) async throws -> T {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        park(id, continuation)
      }
    } onCancel: {
      cancel(id)
    }
    defer { release() }
    try Task.checkCancellation()
    return try await operation()
  }

  private func park(_ id: UUID, _ continuation: CheckedContinuation<Void, any Error>) {
    lock.lock()
    if Task.isCancelled {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
    } else if inUse {
      waiters.append((id, continuation))
      lock.unlock()
    } else {
      inUse = true
      lock.unlock()
      continuation.resume()
    }
  }

  private func cancel(_ id: UUID) {
    lock.lock()
    guard let index = waiters.firstIndex(where: { $0.0 == id }) else {
      lock.unlock()
      return
    }
    let (_, continuation) = waiters.remove(at: index)
    lock.unlock()
    continuation.resume(throwing: CancellationError())
  }

  private func release() {
    lock.lock()
    if waiters.isEmpty {
      inUse = false
      lock.unlock()
    } else {
      let (_, continuation) = waiters.removeFirst()
      lock.unlock()
      continuation.resume()
    }
  }
}

/// Latches observed changes so a later matching snapshot cannot hide a transition.
// SAFETY: The failure is accessed only while holding lock.
final class SimulatorHIDDisplayObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var failure: (any Error)?

  func record(_ result: Result<SimulatorHIDDisplay?, any Error>, matching display: SimulatorHIDDisplay) {
    let error: (any Error)?
    switch result {
    case let .success(current):
      error = current.map { display.hasSameConfiguration(as: $0) } == true ? nil : SimulatorDisplayError.changed
    // Mid-gesture, a transition means the display is changing; the gesture must not wait for it to settle.
    case .failure(SimulatorDisplayError.transitioning): error = SimulatorDisplayError.changed
    case let .failure(cause): error = cause
    }
    lock.lock()
    if failure == nil { failure = error }
    lock.unlock()
  }

  func check() throws {
    lock.lock()
    let error = failure
    lock.unlock()
    if let error { throw error }
  }
}

/// What the operation did with one primitive event it delivered.
enum SimulatorHIDDelivery: Equatable, Sendable {
  /// Delivered as sent.
  case unchanged(SimulatorHIDEvent)
  /// Delivered with its touch points moved onto the display.
  case clamped(requested: SimulatorHIDEvent, delivered: SimulatorHIDEvent, bounds: CGSize)

  func logDescription(_ logging: SimulatorHIDEventLogging) -> String {
    switch self {
    case let .unchanged(event): "Delivered \(event.logDescription(logging))"
    case let .clamped(requested, delivered, bounds):
      "Clamped \(requested.logDescription(logging)) to \(delivered.logDescription(logging)) within the display's point bounds (\(bounds.width) x \(bounds.height))"
    }
  }
}

/// Where an operation's events go. Cleanup calls it from a task that outlives the operation's cancellation.
protocol SimulatorHIDOperationSink: Sendable {
  func deliver(_ event: SimulatorHIDEvent, display: SimulatorHIDDisplay?) async throws
  func flush() async throws
}

/// Operation-local state; no caller can send another event through this binding concurrently.
struct SimulatorHIDOperation {
  let displays: (any DisplayCommands)?
  let binding: DisplaySelection
  let sink: any SimulatorHIDOperationSink

  private let observation: SimulatorHIDDisplayObservation
  private var observationTask: Task<Void, Never>?
  private var resolvedDisplay = false
  private var display: SimulatorHIDDisplay?
  private var generation: UInt64?
  private var singleRelease: SimulatorHIDEvent?
  private var twoFingerRelease: SimulatorHIDEvent?
  /// The releases that end a crown turn or a Watch button press the operation began.
  private var crownRelease: SimulatorHIDEvent?
  private var watchButtonRelease: SimulatorHIDEvent?
  private var needsFlush = false

  init(
    displays: (any DisplayCommands)?,
    binding: DisplaySelection = .active,
    sink: any SimulatorHIDOperationSink,
    observation: SimulatorHIDDisplayObservation = SimulatorHIDDisplayObservation()
  ) {
    self.observation = observation
    self.displays = displays
    self.binding = binding
    self.sink = sink
  }

  /// One delivery per primitive in `event`, in order; composites contribute their children's.
  mutating func send(_ event: SimulatorHIDEvent) async throws -> [SimulatorHIDDelivery] {
    try Task.checkCancellation()
    if case let .composite(events) = event {
      var deliveries: [SimulatorHIDDelivery] = []
      for child in events { deliveries += try await send(child) }
      return deliveries
    }
    var delivered = event
    switch event {
    case let .touch(direction, x, y, edge):
      try await bindOrValidateDisplay()
      let point = try clamp(CGPoint(x: x, y: y))
      delivered = .touch(direction: direction, x: point.x, y: point.y, edge: edge)
      if direction == .down { singleRelease = .touch(direction: .up, x: point.x, y: point.y, edge: edge) }
    case let .twoFingerTouch(direction, first, second):
      try await bindOrValidateDisplay()
      let first = try clamp(first)
      let second = try clamp(second)
      delivered = .twoFingerTouch(direction: direction, finger1: first, finger2: second)
      if direction == .down { twoFingerRelease = .twoFingerTouch(direction: .up, finger1: first, finger2: second) }
    case let .crown(direction, _):
      if direction == .down { crownRelease = .crown(direction: .up, delta: 0) }
    case let .watchButton(direction, button):
      if direction == .down { watchButtonRelease = .watchButton(direction: .up, button: button) }
    case .button, .remoteButton, .keyboard, .trackpad, .delay, .composite:
      break
    }
    try Task.checkCancellation()
    try observation.check()
    try await sink.deliver(delivered, display: display)
    needsFlush = true
    switch delivered {
    case .touch(.up, _, _, _): singleRelease = nil
    case .twoFingerTouch(.up, _, _): twoFingerRelease = nil
    case .crown(.up, _): crownRelease = nil
    case .watchButton(.up, _): watchButtonRelease = nil
    case .touch, .twoFingerTouch, .button, .remoteButton, .keyboard, .trackpad, .crown, .watchButton, .delay, .composite:
      break
    }
    guard delivered != event, let display else { return [.unchanged(delivered)] }
    return [.clamped(requested: event, delivered: delivered, bounds: display.geometry.pointSize)]
  }

  mutating func finish(flushing: Bool) async throws {
    try Task.checkCancellation()
    if flushing, needsFlush {
      needsFlush = false
      try await sink.flush()
    }
    try Task.checkCancellation()
    if let display {
      observation.record(.success(try await Self.route(displays)), matching: display)
      if Self.configurationMoved(in: displays, from: generation) { observation.record(.failure(SimulatorDisplayError.changed), matching: display) }
    }
    await stopObserving()
    try Task.checkCancellation()
    try observation.check()
  }

  private func clamp(_ point: CGPoint) throws -> CGPoint {
    guard point.x.isFinite, point.y.isFinite else { throw SimulatorDisplayInteractionError.nonFinitePoint(point) }
    guard let display else { return point }
    return display.geometry.clampedPoint(point)
  }

  private mutating func bindOrValidateDisplay() async throws {
    if !resolvedDisplay {
      display = try await Self.route(displays)
      let latest = displays?.configurationTracker.latest
      try binding.confirm(routedTo: display?.interactionDisplay, latest: latest)
      try Task.checkCancellation()
      resolvedDisplay = true
      generation = latest?.generation
      if let display, let displays, let generation {
        let observation = observation
        // The operation owns this observer and joins it before releasing its lease, including on cancellation.
        observationTask = Task {
          for await configuration in displays.followConfigurations(polling: .milliseconds(50)) {
            let failure: SimulatorDisplayError? =
              switch configuration.phase {
              case .transitioning: .transitioning
              case .settled: configuration.generation == generation ? nil : .changed
              }
            if let failure {
              if !Task.isCancelled { observation.record(.failure(failure), matching: display) }
              return
            }
          }
        }
      }
    }
    try observation.check()
  }

  /// Nil when interactions fall back to the main display, which input reaches without a digitizer target.
  private static func route(_ displays: (any DisplayCommands)?) async throws -> SimulatorHIDDisplay? {
    guard let displays else { return nil }
    switch try await displays.resolveDisplay() {
    case .transitioning: throw SimulatorDisplayError.transitioning
    case .fallback: return nil
    case let .target(.sole(display)): return .sole(display)
    case let .target(.selected(display)): return .selected(display, id: try await displays.digitizerTarget(for: display))
    }
  }

  private static func configurationMoved(in displays: (any DisplayCommands)?, from generation: UInt64?) -> Bool {
    guard let generation, let latest = displays?.configurationTracker.latest else { return false }
    return latest.generation != generation
  }

  private func stopObserving() async {
    observationTask?.cancel()
    await observationTask?.value
  }

  /// Cleanup is shielded from cancellation and uses the original target, even if it became inactive.
  /// Returns the failures from releasing contacts and draining; each step runs regardless.
  func cleanup() async -> [any Error] {
    await stopObserving()
    let releases = [singleRelease, twoFingerRelease, crownRelease, watchButtonRelease].compactMap { $0 }
    let display = display
    let sink = sink
    let shouldFlush = needsFlush || !releases.isEmpty
    let cleanup = Task {
      var failures: [any Error] = []
      for event in releases {
        do { try await sink.deliver(event, display: display) } catch { failures.append(error) }
      }
      if shouldFlush {
        do { try await sink.flush() } catch { failures.append(error) }
      }
      return failures
    }
    return await cleanup.value
  }
}
