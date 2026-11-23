/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
@unsafe @preconcurrency import XPC
import os

/// What arrives on a channel other than a reply.
package enum SimulatorXPCEvent {
  /// A message the peer sent unprompted, such as a pushed stream event awaiting acknowledgement.
  case message(xpc_object_t)
  /// The peer went away. XPC reconnects on the next send, so the channel is still usable, but
  /// anything the peer held for this connection is gone.
  case interrupted
  /// The connection is finished: the service is gone, or the channel was cancelled.
  case invalidated

  init(_ object: xpc_object_t) {
    if unsafe xpc_get_type(object) != XPC_TYPE_ERROR {
      self = .message(object)
    } else if object === XPC_ERROR_CONNECTION_INTERRUPTED {
      self = .interrupted
    } else {
      self = .invalidated
    }
  }
}

/// How a request on a channel went unanswered.
package enum SimulatorXPCError: Error, Equatable, CustomStringConvertible {
  /// XPC answered on the peer's behalf, so no peer took the message.
  case peerUnavailable(String)
  /// Nothing answered within the request's deadline.
  case timedOut
  /// The connection is finished, so nothing sent on it can arrive.
  case invalidated

  init(errorReply reply: xpc_object_t) {
    self = unsafe .peerUnavailable(
      xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION).map { unsafe String(cString: $0) } ?? "unknown XPC error")
  }

  package var description: String {
    switch self {
    case let .peerUnavailable(detail): detail
    case .timedOut: "no reply before the deadline"
    case .invalidated: "the connection has been invalidated"
    }
  }
}

/**
 One host XPC connection into a simulator, and every way the simulator transports use one. CoreDevice
 opens a channel per request and may be pushed events on it; DTUHID holds one for the life of a
 transport and mostly sends one-way. Both go through here, so what crosses XPC is decided in one place.

 Events and callback replies are delivered on `queue`, the connection's target queue.
 */
package final class SimulatorXPCChannel: Sendable {
  package let queue: DispatchQueue
  // SAFETY: XPC connections support concurrent sending and cancellation.
  // patternlint-disable-next-line swift-nonisolated-unsafe
  nonisolated(unsafe) private let connection: xpc_connection_t
  private let lifecycle = OSAllocatedUnfairLock(initialState: Lifecycle.suspended)

  private enum Lifecycle {
    case suspended
    case active
    case invalidated
  }

  /// Takes an unresumed connection, as `SimulatorXPCConnector` returns it.
  package init(connection: xpc_connection_t, queue: DispatchQueue) {
    unsafe self.connection = connection
    self.queue = queue
    xpc_connection_set_target_queue(connection, queue)
  }

  /// Installs the event handler and resumes the connection. Only the first call takes effect.
  package func activate(events: @escaping @Sendable (SimulatorXPCEvent) -> Void) {
    guard
      lifecycle.withLock({ lifecycle in
        guard case .suspended = lifecycle else { return false }
        lifecycle = .active
        return true
      })
    else { return }
    unsafe xpc_connection_set_event_handler(connection) { [weak self] object in
      let event = SimulatorXPCEvent(object)
      if case .invalidated = event { self?.invalidate() }
      events(event)
    }
    unsafe xpc_connection_resume(connection)
  }

  /// Sends a message that expects no reply. XPC accepts sends on a finished connection and drops
  /// them, so this throws `SimulatorXPCError.invalidated` once the channel knows it is finished.
  func send(_ message: xpc_object_t) throws {
    guard !isInvalidated else { throw SimulatorXPCError.invalidated }
    unsafe xpc_connection_send_message(connection, message)
  }

  private var isInvalidated: Bool {
    lifecycle.withLock { if case .invalidated = $0 { true } else { false } }
  }

  private func invalidate() {
    lifecycle.withLock { $0 = .invalidated }
  }

  /// Resolves once XPC has sent everything sent before this call. Says nothing about the peer
  /// having read it.
  func sendBarrier() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      unsafe xpc_connection_send_barrier(connection) { continuation.resume() }
    }
  }

  /// Sends `message` and hands its reply to `reply` on `queue`, or the `SimulatorXPCError` XPC
  /// answered with instead of the peer.
  package func request(_ message: xpc_object_t, reply: @escaping @Sendable (sending Result<xpc_object_t, SimulatorXPCError>) -> Void) {
    unsafe xpc_connection_send_message_with_reply(connection, message, queue) { [weak self] object in
      guard unsafe xpc_get_type(object) == XPC_TYPE_ERROR else { return reply(.success(object)) }
      // The reply can arrive ahead of the invalidation event, and the caller may send next.
      if object === XPC_ERROR_CONNECTION_INVALID { self?.invalidate() }
      reply(.failure(SimulatorXPCError(errorReply: object)))
    }
  }

  /// Sends `message` and resolves with its reply. Throws `SimulatorXPCError` when XPC answers
  /// instead of the peer or `timeout` passes first, and `CancellationError` when the task is cancelled.
  func request(_ message: xpc_object_t, timeout: DispatchTimeInterval) async throws -> xpc_object_t {
    try await firstAnswer(timeout: timeout) { answer in
      request(message) { answer.resolve($0.mapError { $0 }) }
    }
  }

  /// Resolves with whatever `start` resolves its answer with, unless `timeout` passes first, which
  /// throws `SimulatorXPCError.timedOut`, or the task is cancelled first, which throws
  /// `CancellationError`. `start` does not run for a task that is already cancelled.
  func firstAnswer<Value: Sendable>(timeout: DispatchTimeInterval, _ start: (FirstAnswer<Value>) -> Void) async throws -> Value {
    let answer = FirstAnswer<Value>()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      start(answer)
      queue.asyncAfter(deadline: .now() + timeout) { answer.resolve(.failure(SimulatorXPCError.timedOut)) }
      return try await answer.outcome.wait()
    } onCancel: {
      answer.resolve(.failure(CancellationError()))
    }
  }

  /// Answers a message the peer sent with a reply, filled in by `fill`. Does nothing for a message
  /// that expects no reply.
  func reply(to message: xpc_object_t, _ fill: (xpc_object_t) -> Void) {
    guard unsafe xpc_get_type(message) == XPC_TYPE_DICTIONARY, let reply = xpc_dictionary_create_reply(message) else { return }
    fill(reply)
    unsafe xpc_connection_send_message(connection, reply)
  }

  /// Cancels the connection. XPC will not release a suspended connection, so one never activated is
  /// activated first.
  package func cancel() {
    activate { _ in }
    invalidate()
    unsafe xpc_connection_cancel(connection)
  }
}

/// Whichever of an answer, a deadline or a cancellation comes first resolves the request; the rest are
/// dropped.
final class FirstAnswer<Value: Sendable>: Sendable {
  fileprivate let outcome = AsyncEvent<Value>()

  func resolve(_ result: sending Result<Value, any Error>) {
    switch result {
    case let .success(value):
      outcome.happen(value)
    case let .failure(error):
      outcome.fail(error)
    }
  }
}
