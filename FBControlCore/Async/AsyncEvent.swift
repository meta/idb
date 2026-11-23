/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// Something to wait for that may happen, or fail, before it is waited on. Only the first outcome
/// counts, and every waiter, before or after it, receives it.
public final class AsyncEvent<Value: Sendable>: @unchecked Sendable {
  private enum State {
    case pending(waiters: [UUID: CheckedContinuation<Value, any Error>])
    case happened(Result<Value, any Error>)
  }

  private let lock = NSLock()
  private var state = State.pending(waiters: [:])

  public init() {}

  /// Whether the event has happened, successfully or not.
  public var hasHappened: Bool {
    lock.withLock {
      switch state {
      case .happened:
        return true
      case .pending:
        return false
      }
    }
  }

  /// The outcome, without waiting: nil until the event has happened.
  public var result: Result<Value, any Error>? {
    lock.withLock {
      guard case let .happened(result) = state else {
        return nil
      }
      return result
    }
  }

  public func happen(_ value: Value) {
    resolve(.success(value))
  }

  public func fail(_ error: any Error) {
    resolve(.failure(error))
  }

  /// Returns once the event has happened, throwing if it failed. Any number of callers may wait.
  /// Cancelling throws `CancellationError` for that waiter alone and leaves the event to be waited on
  /// again.
  public func wait() async throws -> Value {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
        lock.lock()
        switch state {
        case let .happened(result):
          lock.unlock()
          continuation.resume(with: result)
        case .pending where Task.isCancelled:
          lock.unlock()
          continuation.resume(throwing: CancellationError())
        case var .pending(waiters):
          waiters[id] = continuation
          state = .pending(waiters: waiters)
          lock.unlock()
        }
      }
    } onCancel: {
      let waiter: CheckedContinuation<Value, any Error>? = lock.withLock {
        guard case var .pending(waiters) = state, let waiter = waiters.removeValue(forKey: id) else {
          return nil
        }
        state = .pending(waiters: waiters)
        return waiter
      }
      waiter?.resume(throwing: CancellationError())
    }
  }

  /// As `wait()`, but cancelling the waiting task does not end the wait: it returns only once the
  /// event has happened. For waits that must see an outcome through, such as a file being finalised.
  public func waitIgnoringCancellation() async throws -> Value {
    let id = UUID()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
      lock.lock()
      switch state {
      case let .happened(result):
        lock.unlock()
        continuation.resume(with: result)
      case var .pending(waiters):
        waiters[id] = continuation
        state = .pending(waiters: waiters)
        lock.unlock()
      }
    }
  }

  /// As `wait()`, failing with a `PollTimeoutError` naming `description` if the event has not
  /// happened within `timeout` seconds.
  public func wait(timeout: TimeInterval, waitingFor description: String) async throws -> Value {
    try await withTimeout(timeout, orThrow: { PollTimeoutError(deadline: PollDeadline(timeout: timeout, waitingFor: description)) }) {
      try await self.wait()
    }
  }

  private func resolve(_ result: Result<Value, any Error>) {
    let waiters: [UUID: CheckedContinuation<Value, any Error>] = lock.withLock {
      guard case let .pending(waiters) = state else {
        return [:]
      }
      state = .happened(result)
      return waiters
    }
    for waiter in waiters.values {
      waiter.resume(with: result)
    }
  }
}

extension AsyncEvent where Value == Void {
  public func happen() {
    happen(())
  }
}
