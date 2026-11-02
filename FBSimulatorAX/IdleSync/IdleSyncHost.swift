/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
internal import ShimulatorIdleSyncCore
internal import ShimulatorProtocol
import os

/// Serves the Shimulator `idle` capability on one socket while a stream is open, and keeps the latest state of every
/// armed process connected to it. It keeps serving for `idleTimeout` after the last stream ends, so back-to-back
/// requests find the processes still connected; then it releases the socket, and the processes wait for it again.
final class IdleSyncHost: Sendable {

  /// What a process last reported: its state, or why its report could not be read.
  enum Report: Equatable, Sendable {
    case state(IdleSyncState)
    case unreadable(reason: String)
  }

  enum Update: Equatable, Sendable {
    case state(pid: pid_t, IdleSyncState)
    /// A report from a process could not be read, for example one from a shim of another version.
    case unreadable(pid: pid_t, reason: String)
    /// The connection of a process that had reported a state closed.
    case disconnected(pid: pid_t)
  }

  static let idleTimeout = Duration.seconds(10)

  let path: String
  private let idleTimeout: Duration
  // `State` holds continuations, which are not `Sendable`; every access is under the lock. Socket calls are made
  // only by the server thread, outside it.
  private let state = OSAllocatedUnfairLock(uncheckedState: State())

  private struct State {
    /// What the server thread is to serve; `nil` asks it to release the socket and exit.
    var wanted: IdleSyncParameters?
    /// What the bound server serves, `nil` while none is bound.
    var serving: IdleSyncParameters?
    /// The pipe that wakes the server thread, open while the thread runs.
    var wake: (read: Int32, write: Int32)?
    var binding: [CheckedContinuation<Void, Error>] = []
    var streams = 0
    var releaseAt: ContinuousClock.Instant?
    var latest: [pid_t: Report] = [:]
    var subscribers: [UUID: AsyncStream<Update>.Continuation] = [:]

    mutating func wakeServer() {
      guard let wake else { return }
      var byte: UInt8 = 0
      _ = Darwin.write(wake.write, &byte, 1)
    }
  }

  init(path: String, idleTimeout: Duration = IdleSyncHost.idleTimeout) {
    self.path = path
    self.idleTimeout = idleTimeout
  }

  /// Opens a stream: delivers every update from now on, and returns the latest state of each process connected now,
  /// so that an update about any other process is one about a process that connected since. The server serves until
  /// the last stream's updates end and `idleTimeout` passes.
  ///
  /// Every stream shares the server's parameters. While a stream is open, a request with no busy threshold takes that
  /// stream's, and one with another threshold is refused, since serving it reconnects every process.
  func open(_ requested: IdleSyncParameters) async throws -> (current: [pid_t: Report], updates: AsyncStream<Update>) {
    // Decided and queued under one lock, so that a bind finishing in between cannot be missed.
    try await withCheckedThrowingContinuation { (bound: CheckedContinuation<Void, Error>) in
      state.withLockUnchecked { state in
        // Only an open stream's threshold is in use; one lingering after the last stream ended is not.
        let parameters = requested.busyThresholdMs == nil && state.streams > 0 ? (state.wanted ?? requested) : requested
        if state.streams > 0, let wanted = state.wanted, wanted != parameters {
          bound.resume(throwing: IdleSyncError.busyThresholdInUse(path: path, current: wanted.busyThresholdMs, requested: requested.busyThresholdMs))
          return
        }
        if state.wake == nil {
          do {
            try startServer(&state)
          } catch {
            bound.resume(throwing: error)
            return
          }
        }
        state.streams += 1
        state.releaseAt = nil
        state.wanted = parameters
        guard state.serving != parameters else {
          bound.resume()
          return
        }
        state.binding.append(bound)
        state.wakeServer()
      }
    }
    let (updates, continuation) = AsyncStream<Update>.makeStream()
    let id = UUID()
    continuation.onTermination = { [weak self] _ in
      self?.close(subscriber: id)
    }
    let current = state.withLockUnchecked { state in
      state.subscribers[id] = continuation
      return state.latest
    }
    return (current, updates)
  }

  private func close(subscriber id: UUID) {
    state.withLockUnchecked { state in
      state.subscribers.removeValue(forKey: id)
      state.streams -= 1
      guard state.streams == 0 else { return }
      state.releaseAt = .now + idleTimeout
      state.wakeServer()
    }
  }

  private func startServer(_ state: inout State) throws {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else {
      throw IdleSyncError.socketUnavailable(path: path, reason: "pipe: \(String(cString: strerror(errno)))")
    }
    for descriptor in descriptors {
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }
    state.wake = (descriptors[0], descriptors[1])
    let wake = descriptors[0]
    Thread.detachNewThread { [self] in
      serve(wake: wake)
    }
  }

  private enum Action {
    case bind(IdleSyncParameters)
    case release
    case wait(timeoutMilliseconds: Int32)
    case exit
  }

  /// The server thread: the only code that touches the server. It blocks until a process or a stream needs it.
  private func serve(wake: Int32) {
    var server: ShimulatorServer?
    var bound: IdleSyncParameters?
    while true {
      let action = state.withLockUnchecked { (state: inout State) -> Action in
        if state.streams == 0, let releaseAt = state.releaseAt, releaseAt <= .now {
          state.wanted = nil
          state.releaseAt = nil
        }
        guard let wanted = state.wanted else {
          guard server == nil, let wake = state.wake else { return .release }
          Darwin.close(wake.read)
          Darwin.close(wake.write)
          state.wake = nil
          return .exit
        }
        guard bound == wanted else { return server == nil ? .bind(wanted) : .release }
        return .wait(timeoutMilliseconds: state.releaseAt.map { Self.milliseconds(until: $0) } ?? -1)
      }
      switch action {
      case .exit:
        return
      case .release:
        // Released first: the next server binds the same path.
        server = nil
        bound = nil
        let (dropped, subscribers) = state.withLockUnchecked { state -> ([Update], [AsyncStream<Update>.Continuation]) in
          state.serving = nil
          let dropped = state.latest.keys.sorted().map { Update.disconnected(pid: $0) }
          state.latest = [:]
          return (dropped, Array(state.subscribers.values))
        }
        Self.deliver(dropped, to: subscribers)
      case let .bind(parameters):
        let result = Result { () throws(IdleSyncError) in try bind(parameters) }
        server = try? result.get()
        bound = server == nil ? nil : parameters
        let waiting = state.withLockUnchecked { state in
          if server == nil {
            // Every stream waiting for it fails, and no other is open: one is only rebound while none is.
            state.wanted = nil
            state.streams -= state.binding.count
          } else {
            state.serving = parameters
          }
          defer { state.binding = [] }
          return state.binding
        }
        for continuation in waiting {
          continuation.resume(with: result.map { _ in () })
        }
      case let .wait(timeoutMilliseconds):
        guard let server else { continue }
        server.wait(timeoutMilliseconds: timeoutMilliseconds, wakeDescriptor: wake)
        var drain = [UInt8](repeating: 0, count: 64)
        while Darwin.read(wake, &drain, drain.count) > 0 {}
        receive(server.poll())
      }
    }
  }

  private func bind(_ parameters: IdleSyncParameters) throws(IdleSyncError) -> ShimulatorServer {
    let server: ShimulatorServer?
    do {
      server = try ShimulatorServer(path: path, parameters: parameters)
    } catch {
      throw .socketUnavailable(path: path, reason: String(describing: error))
    }
    guard let server else { throw .socketInUse(path: path) }
    return server
  }

  private func receive(_ responders: [ShimulatorResponder]) {
    let (updates, subscribers) = state.withLockUnchecked { state -> ([Update], [AsyncStream<Update>.Continuation]) in
      var updates: [Update] = []
      for responder in responders {
        guard let response = responder.response else { continue }
        let pid = response.processIdentifier
        guard responder.connected else {
          if state.latest.removeValue(forKey: pid) != nil {
            updates.append(.disconnected(pid: pid))
          }
          continue
        }
        guard let payload = response.payload else { continue }
        let report: Report
        do {
          report = .state(try JSONDecoder().decode(IdleSyncState.self, from: payload))
        } catch {
          report = .unreadable(reason: String(describing: error))
        }
        guard report != state.latest[pid] else { continue }
        state.latest[pid] = report
        switch report {
        case let .state(reported):
          updates.append(.state(pid: pid, reported))
        case let .unreadable(reason):
          updates.append(.unreadable(pid: pid, reason: reason))
        }
      }
      return (updates, updates.isEmpty ? [] : Array(state.subscribers.values))
    }
    Self.deliver(updates, to: subscribers)
  }

  private static func milliseconds(until instant: ContinuousClock.Instant) -> Int32 {
    let remaining = ContinuousClock.now.duration(to: instant).components
    guard remaining.seconds >= 0 else { return 0 }
    return Int32(clamping: remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000 + 1)
  }

  private static func deliver(_ updates: [Update], to subscribers: [AsyncStream<Update>.Continuation]) {
    for update in updates {
      for subscriber in subscribers {
        subscriber.yield(update)
      }
    }
  }
}
