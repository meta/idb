/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBControlCore
@preconcurrency import FBSimulatorControl
import Foundation
internal import ShimulatorIdleSyncCore
internal import ShimulatorProtocol

/// The failures of measuring an app's quiescence through the Shimulator shim.
public enum IdleSyncError: LocalizedError, Sendable, Equatable {
  case unsupportedPlatform(udid: String)
  /// The request named a point or an element rather than an application.
  case notAnApplication
  case socketInUse(path: String)
  case socketUnavailable(path: String, reason: String)
  /// No armed app (`pid` `nil`), or not the named one, connected in time.
  case notConnected(pid: pid_t?, path: String, waited: TimeInterval)
  /// No target was named and more than one armed app is connected.
  case severalApplications(pids: [pid_t])
  /// Another open request is measured with a different busy threshold (`nil`: the shim's own).
  case busyThresholdInUse(path: String, current: UInt32?, requested: UInt32?)
  /// The app's report could not be read, for example because its shim is from another version of idb.
  case unreadableState(pid: pid_t, reason: String)

  public var errorDescription: String? {
    switch self {
    case let .unsupportedPlatform(udid):
      return "Idle synchronization supports iPhone and iPad simulators. Simulator \(udid) is neither, and the shim is built for the iOS simulator only."
    case .notAnApplication:
      return "The shimulator backend measures an application; name one by pid or bundle id, or none for the one armed app."
    case let .socketInUse(path):
      return "Another process serves idle synchronization at \(path)."
    case let .socketUnavailable(path, reason):
      return "Could not serve idle synchronization at \(path): \(reason)"
    case let .notConnected(pid, path, waited):
      let app = pid.map { "The application with pid \($0) did not connect" } ?? "No armed application connected"
      return "\(app) to \(path) within \(waited)s. Launch it through idb with \(ShimulatorIdleSync.armedEnvironmentVariable)=1 in its environment (IDB_\(ShimulatorIdleSync.armedEnvironmentVariable)=1 in the client's), which arms the Shimulator shim's idle capability."
    case let .severalApplications(pids):
      return "Several armed applications are connected (pids \(pids.map(String.init).joined(separator: ", "))); name one by pid or bundle id."
    case let .busyThresholdInUse(path, current, requested):
      let threshold = { (milliseconds: UInt32?) in milliseconds.map { "\($0) ms" } ?? "the shim's own" }
      return "Idle synchronization at \(path) is measuring another request with a busy threshold of \(threshold(current)), and serving \(threshold(requested)) would reconnect its apps. Ask for the same threshold or none, or wait for that request to end."
    case let .unreadableState(pid, reason):
      return "The application with pid \(pid) reported an idle state this host cannot read, so its Shimulator shim may be from another version of idb: \(reason)"
    }
  }
}

/// Measures quiescence from inside the app, through the `idle` capability of the Shimulator shim that idb inserts into
/// the apps it launches. Only an app launched with `IDB_IDLE_SYNC=1` is measured.
public struct SimulatorIdleSyncCommands {

  /// How long an app has to connect before a request about it fails. An armed app connects as soon as the socket
  /// appears.
  static let connectionTimeout: TimeInterval = 1
  /// How long after its connection closes an app still running is given to reconnect before it is checked again.
  static let reconnectionInterval: TimeInterval = 0.25

  let simulator: Simulator

  /// Streams the quiescence of an application: `.application` names one by pid, and `.frontmost` measures the one
  /// armed application connected. The events are `UIAutomation.quiescence`'s, and the stream ends the same ways.
  ///
  /// `parameters.quietWindow` is how long the app must stay idle, beyond the 100 ms the shim already waits, before
  /// it counts as quiet; `nil` adds nothing. `parameters.busyThreshold` is how long main-thread work must last to
  /// make the app busy. The simulator's apps are measured with one threshold at a time: `nil` takes the one in use,
  /// or the shim's own if there is none, and a request with another one fails with `busyThresholdInUse` while
  /// another request is open.
  public func quiescence(
    _ query: AccessibilityElementQuery,
    parameters: QuiescenceParameters
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, Error> {
    guard [.iPhone, .iPad].contains(simulator.productFamily) else {
      throw IdleSyncError.unsupportedPlatform(udid: simulator.udid)
    }
    let pid: pid_t?
    switch query {
    case let .application(requested):
      pid = requested
    case .frontmost:
      pid = nil
    case .point, .marker:
      throw IdleSyncError.notAnApplication
    }
    let quietWindowMs = UInt64((max(parameters.quietWindow ?? 0, 0) * 1000).rounded())
    return try await Self.quiescence(
      of: pid, on: simulator.idleSyncHost,
      parameters: IdleSyncParameters(busyThresholdMs: parameters.busyThresholdMs.map { UInt32(clamping: $0) }),
      quietWindowMs: quietWindowMs)
  }

  static func quiescence(
    of pid: pid_t?,
    on host: IdleSyncHost,
    parameters: IdleSyncParameters = IdleSyncParameters(),
    quietWindowMs: UInt64,
    connectionTimeout: TimeInterval = SimulatorIdleSyncCommands.connectionTimeout,
    isRunning: @escaping @Sendable (pid_t) -> Bool = { HostProcess.isRunning($0) }
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, Error> {
    // The host serves while `updates` is consumed, so the stream's end releases it.
    let (current, updates) = try await host.open(parameters)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var measurement = IdleSyncStream(
            requested: pid, path: host.path, quietWindowMs: quietWindowMs, connectionTimeout: connectionTimeout, isRunning: isRunning)
          try await measurement.run(current: current, updates: updates) { continuation.yield($0) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

/// One stream's state: which app it follows, and the tracker turning that app's reports into events.
struct IdleSyncStream {
  private enum Step: Sendable {
    case update(IdleSyncHost.Update)
    case connectionDeadline
    case settle
    case recheck
  }

  let requested: pid_t?
  let path: String
  let quietWindowMs: UInt64
  let connectionTimeout: TimeInterval
  let isRunning: @Sendable (pid_t) -> Bool
  private var tracker: IdleSyncQuiescenceTracker?
  private var disconnected = false

  /// A day: longer than any quiet window, and short enough to sleep for.
  static let maximumSettleDelayMs: UInt64 = 86_400_000

  init(requested: pid_t?, path: String, quietWindowMs: UInt64, connectionTimeout: TimeInterval, isRunning: @escaping @Sendable (pid_t) -> Bool) {
    self.requested = requested
    self.path = path
    self.quietWindowMs = quietWindowMs
    self.connectionTimeout = connectionTimeout
    self.isRunning = isRunning
  }

  mutating func run(
    current: [pid_t: IdleSyncHost.Report],
    updates: AsyncStream<IdleSyncHost.Update>,
    emit: (QuiescenceEvent) -> Void
  ) async throws {
    let openedAt = Self.now()
    let (steps, input) = AsyncStream<Step>.makeStream()
    let relay = Task {
      for await update in updates {
        input.yield(.update(update))
      }
      input.finish()
    }
    var timers: [Task<Void, Never>] = []
    defer {
      relay.cancel()
      timers.forEach { $0.cancel() }
    }
    func schedule(_ step: Step, after seconds: TimeInterval) {
      timers.append(
        Task {
          try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
          guard !Task.isCancelled else { return }
          input.yield(step)
        })
    }

    func receive(_ state: IdleSyncState) {
      let now = Self.now()
      guard let received = tracker?.receive(state, now: now) else { return }
      received.events.forEach(emit)
      // `idleSince` comes from the app, so its settle time may lie anywhere ahead, up to the end of time.
      if let settleAt = received.settleAt {
        schedule(.settle, after: TimeInterval(min(settleAt - now, Self.maximumSettleDelayMs)) / 1000)
      }
    }

    if let following = try target(current: current), let report = current[following] {
      tracker = IdleSyncQuiescenceTracker(pid: following, quietWindowMs: quietWindowMs, openedAt: openedAt)
      switch report {
      case let .state(state):
        receive(state)
      case let .unreadable(reason):
        throw IdleSyncError.unreadableState(pid: following, reason: reason)
      }
    } else {
      schedule(.connectionDeadline, after: connectionTimeout)
    }

    for await step in steps {
      switch step {
      case .connectionDeadline:
        guard tracker == nil else { continue }
        throw IdleSyncError.notConnected(pid: requested, path: path, waited: connectionTimeout)
      case .settle:
        // A disconnected app's last state is stale; the first state it reconnects with schedules a settle again.
        guard !disconnected else { continue }
        tracker?.settle(now: Self.now()).forEach(emit)
      case .recheck:
        guard disconnected, let pid = tracker?.pid else { continue }
        guard isRunning(pid) else {
          emit(.targetExited(pid: pid))
          return
        }
        schedule(.recheck, after: SimulatorIdleSyncCommands.reconnectionInterval)
      case let .update(.state(pid, state)):
        if tracker == nil, requested == nil || requested == pid {
          tracker = IdleSyncQuiescenceTracker(pid: pid, quietWindowMs: quietWindowMs, openedAt: openedAt)
        }
        guard pid == tracker?.pid else { continue }
        disconnected = false
        receive(state)
      case let .update(.unreadable(pid, reason)):
        // The app this stream follows, or would start following.
        guard tracker.map({ $0.pid == pid }) ?? (requested == nil || requested == pid) else { continue }
        throw IdleSyncError.unreadableState(pid: pid, reason: reason)
      case let .update(.disconnected(pid)):
        guard pid == tracker?.pid else { continue }
        // The app holds its connection for its whole life, so a close is its exit unless it is still running, in
        // which case it reconnects.
        guard isRunning(pid) else {
          emit(.targetExited(pid: pid))
          return
        }
        disconnected = true
        schedule(.recheck, after: SimulatorIdleSyncCommands.reconnectionInterval)
      }
    }
    // A cancelled consumer ends the stream too, and that is not the host going away.
    try Task.checkCancellation()
    throw QuiescenceError.streamEnded
  }

  /// The app to follow, if it is known before any update arrives.
  private func target(current: [pid_t: IdleSyncHost.Report]) throws -> pid_t? {
    if let requested {
      return requested
    }
    guard current.count <= 1 else {
      throw IdleSyncError.severalApplications(pids: current.keys.sorted())
    }
    return current.keys.first
  }

  private static func now() -> UInt64 {
    // A clock set before 1970 reads as 1970 rather than trapping.
    UInt64(max(Date().timeIntervalSince1970 * 1000, 0))
  }
}

extension Simulator {

  /// Measures app quiescence through the Shimulator shim.
  public var idleSync: SimulatorIdleSyncCommands {
    SimulatorIdleSyncCommands(simulator: self)
  }

  /// One per simulator, so apps stay connected between back-to-back requests.
  var idleSyncHost: IdleSyncHost {
    commandCache.resolve {
      IdleSyncHost(path: ShimulatorWireProtocol.socketPath(capability: ShimulatorIdleSync.capability, simulatorUDID: udid))
    }
  }
}
