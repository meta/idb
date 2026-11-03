/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import Foundation

/// A condition an application meets once it has gone idle.
public enum QuiescenceSignal: String, Sendable, Hashable, CaseIterable {
  /// The application's main run loop has gone idle.
  case runLoopIdle = "run_loop_idle"
  /// No animation is running in the application.
  case animationsInactive = "animations_inactive"
  /// No scroll view in the application is moving its content. Reported only by the Shimulator backend.
  case scrollIdle = "scroll_idle"
  /// The application accepts touches and key presses; one that ignores them drops input. Reported only by the
  /// Shimulator backend.
  case interactionEnabled = "interaction_enabled"
}

public enum QuiescenceState: Sendable, Equatable {
  /// At least one signal has gone unanswered for longer than the busy threshold.
  case busy(Set<QuiescenceSignal>)
  /// Nothing is busy, but the signals have not all been answered for the whole quiet window.
  case settling
  /// Every signal has been answered for at least the quiet window.
  case quiet
}

public enum QuiescenceEvent: Sendable, Equatable {
  /// The application's state, reported once it is known and then on every change.
  case state(QuiescenceState, pid: pid_t)
  /// A touch sequence finished. Informational: it does not affect the state.
  case touchesCompleted(pid: pid_t)
  /// A stream following the frontmost application moved to the one named. Its state starts over.
  case targetChanged(pid: pid_t)
  /// The application a stream was opened for exited. The last event of that stream.
  case targetExited(pid: pid_t)
}

/// A `nil` tunable takes the default of the backend measuring it.
public struct QuiescenceParameters: Sendable, Equatable {
  /// How long a signal may go unanswered before the application counts as busy.
  public var busyThreshold: TimeInterval?
  /// How long every signal must stay answered before the application counts as quiet.
  public var quietWindow: TimeInterval?

  public init(busyThreshold: TimeInterval? = nil, quietWindow: TimeInterval? = nil) {
    self.busyThreshold = busyThreshold
    self.quietWindow = quietWindow
  }
}

public enum QuiescenceError: LocalizedError, Sendable, Equatable {
  /// The application was not quiet within `timeout`. `last` is the last state reported, if any was.
  case timedOut(timeout: TimeInterval, last: QuiescenceState?)
  /// The application exited before it went quiet.
  case targetExited(pid: pid_t)
  /// The stream ended without answering, and without saying why.
  case streamEnded

  public var errorDescription: String? {
    switch self {
    case let .timedOut(timeout, last):
      guard let last else {
        return "no quiescence state was reported within \(timeout)s"
      }
      return "the application was not quiet within \(timeout)s; it was last \(last.summary)"
    case let .targetExited(pid):
      return "the application with pid \(pid) exited before it went quiet"
    case .streamEnded:
      return "the quiescence stream ended without reporting a state"
    }
  }
}

public extension QuiescenceState {
  /// `busy (animations_inactive)`, `settling` or `quiet`.
  var summary: String {
    switch self {
    case let .busy(signals):
      "busy (\(signals.map(\.rawValue).sorted().joined(separator: ", ")))"
    case .settling:
      "settling"
    case .quiet:
      "quiet"
    }
  }
}

public extension UIAutomation {

  /// Whether the application is quiet now: the first state that is `quiet` or `busy`. `settling` answers
  /// neither way, so it waits for the state that follows. `onEvent` sees every event up to the answer.
  func quiescenceState(
    _ query: AccessibilityElementQuery,
    parameters: QuiescenceParameters = QuiescenceParameters(),
    onEvent: (QuiescenceEvent) -> Void = { _ in }
  ) async throws -> (state: QuiescenceState, pid: pid_t) {
    for try await event in try await quiescence(query, parameters: parameters) {
      onEvent(event)
      switch event {
      case .state(.settling, _), .touchesCompleted, .targetChanged:
        continue
      case let .state(state, pid):
        return (state, pid)
      case let .targetExited(pid):
        throw QuiescenceError.targetExited(pid: pid)
      }
    }
    throw QuiescenceError.streamEnded
  }

  /// Returns the pid of the application once it is quiet, or throws `QuiescenceError.timedOut` once
  /// `timeout` elapses first; a `nil` timeout waits until it is quiet or the caller is cancelled. Ending the
  /// wait closes the stream. `onEvent` sees every event up to the answer.
  func waitForQuiet(
    _ query: AccessibilityElementQuery,
    timeout: TimeInterval?,
    parameters: QuiescenceParameters = QuiescenceParameters(),
    onEvent: @escaping @Sendable (QuiescenceEvent) -> Void = { _ in }
  ) async throws -> pid_t {
    let events = try await quiescence(query, parameters: parameters)
    let last = LastQuiescenceState()
    return try await withThrowingTaskGroup(of: pid_t.self) { group in
      group.addTask {
        for try await event in events {
          onEvent(event)
          switch event {
          case let .state(.quiet, pid):
            return pid
          case let .state(state, _):
            last.value = state
          case .targetChanged:
            last.value = nil
          case .touchesCompleted:
            continue
          case let .targetExited(pid):
            throw QuiescenceError.targetExited(pid: pid)
          }
        }
        // A cancelled caller ends the stream too, and that is not the guest going away.
        try Task.checkCancellation()
        throw QuiescenceError.streamEnded
      }
      if let timeout {
        group.addTask {
          try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
          throw QuiescenceError.timedOut(timeout: timeout, last: last.value)
        }
      }
      defer { group.cancelAll() }
      guard let pid = try await group.next() else { throw QuiescenceError.streamEnded }
      return pid
    }
  }

  /// Reports every event to `onEvent` until `duration` elapses, then returns the last state the followed
  /// application reported, if any. Going quiet does not end the watch; a `nil` duration watches until the
  /// caller is cancelled. Throws `QuiescenceError.targetExited` if the application exits first. Ending the watch closes the stream.
  func watchQuiescence(
    _ query: AccessibilityElementQuery,
    duration: TimeInterval?,
    parameters: QuiescenceParameters = QuiescenceParameters(),
    onEvent: @escaping @Sendable (QuiescenceEvent) -> Void
  ) async throws -> QuiescenceState? {
    let events = try await quiescence(query, parameters: parameters)
    let last = LastQuiescenceState()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for try await event in events {
          onEvent(event)
          switch event {
          case let .state(state, _):
            last.value = state
          case .targetChanged:
            last.value = nil
          case .touchesCompleted:
            continue
          case let .targetExited(pid):
            throw QuiescenceError.targetExited(pid: pid)
          }
        }
        try Task.checkCancellation()
        throw QuiescenceError.streamEnded
      }
      if let duration {
        group.addTask { try await Task.sleep(nanoseconds: UInt64(max(duration, 0) * 1_000_000_000)) }
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
    return last.value
  }
}

// SAFETY: `state` is only read or written with `lock` held.
// patternlint-disable-next-line unchecked-sendable
private final class LastQuiescenceState: @unchecked Sendable {
  private let lock = NSLock()
  private var state: QuiescenceState?

  var value: QuiescenceState? {
    get { lock.withLock { state } }
    set { lock.withLock { state = newValue } }
  }
}
