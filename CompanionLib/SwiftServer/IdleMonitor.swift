/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Dispatch
import FBControlCore
import Foundation

/// Tracks in-flight work and signals when none has run for `idleTime`.
///
/// Work counts as in flight while a `tracking { }` block (or a balanced
/// `requestStarted()` / `requestEnded()` pair) is open: the countdown starts when
/// the last in-flight operation finishes (or at `start()` if nothing is running),
/// and is cancelled as soon as new work arrives, so a long-running operation holds
/// it off. When the countdown elapses with nothing in flight, `onShutdownStarted`
/// runs synchronously and then `expired` resolves.
public final class IdleMonitor: @unchecked Sendable {

  private let expiredPromise = AsyncEvent<Void>()

  /// Suspends until `idleTime` seconds pass with no active or newly-received requests.
  public func waitUntilExpired() async throws {
    try await expiredPromise.wait()
  }

  private let idleTime: TimeInterval
  private let logger: IDBLogger
  /// Invoked synchronously the instant idle shutdown begins, before `expired`
  /// resolves — used to release externally-visible resources (e.g. unlink the
  /// gRPC socket) without waiting for the async teardown.
  private let onShutdownStarted: (@Sendable () -> Void)?
  private let queue = DispatchQueue(label: "com.facebook.idb.IdleMonitor")
  private let lock = NSLock()

  private var activeRequests = 0
  private var timer: (any DispatchSourceTimer)?
  /// Bumped whenever the timer is armed or invalidated so a timer that fires after
  /// it has been superseded can tell it is stale and do nothing.
  private var generation = 0
  /// Set once `expired` has resolved; no further work happens afterwards.
  private var fired = false

  public init(idleTime: TimeInterval, logger: IDBLogger, onShutdownStarted: (@Sendable () -> Void)? = nil) {
    self.idleTime = idleTime
    self.logger = logger
    self.onShutdownStarted = onShutdownStarted
  }

  /// Starts the idle countdown if nothing is in flight. Call once the server is
  /// listening so that a companion which is never used still exits.
  public func start() {
    lock.lock()
    defer { lock.unlock() }
    guard !fired, activeRequests == 0 else { return }
    armLocked()
  }

  func requestStarted() {
    lock.lock()
    defer { lock.unlock() }
    guard !fired else { return }
    activeRequests += 1
    invalidateLocked()
  }

  func requestEnded() {
    lock.lock()
    defer { lock.unlock() }
    guard !fired else { return }
    if activeRequests > 0 {
      activeRequests -= 1
    }
    if activeRequests == 0 {
      armLocked()
    }
  }

  /// Runs `body` as a single in-flight operation: the idle countdown is held off while it runs and
  /// re-armed when it finishes, on every exit path.
  func tracking<R>(_ body: () async throws -> R) async throws -> R {
    requestStarted()
    defer { requestEnded() }
    return try await body()
  }

  // MARK: - Timer (callers must hold `lock`)

  private func armLocked() {
    generation += 1
    let armedGeneration = generation
    let newTimer = DispatchSource.makeTimerSource(queue: queue)
    newTimer.schedule(deadline: .now() + idleTime)
    newTimer.setEventHandler { [weak self] in
      self?.handleFire(generation: armedGeneration)
    }
    timer?.cancel()
    timer = newTimer
    newTimer.resume()
  }

  private func invalidateLocked() {
    generation += 1
    timer?.cancel()
    timer = nil
  }

  private func handleFire(generation armedGeneration: Int) {
    lock.lock()
    // Ignore a superseded timer (a request arrived or finished since it was
    // armed) or a duplicate fire, and never fire while a request is in flight.
    guard !fired, armedGeneration == generation, activeRequests == 0 else {
      lock.unlock()
      return
    }
    fired = true
    timer?.cancel()
    timer = nil
    lock.unlock()

    logger.info().log("No activity for \(Int(idleTime))s; signalling idle")
    onShutdownStarted?()
    expiredPromise.happen()
  }
}
