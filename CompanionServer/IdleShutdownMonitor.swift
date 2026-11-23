/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Dispatch
import Foundation

/// Shuts a server down after a period without activity. While a request is being
/// processed the countdown is paused (`beginActivity()`); it restarts at the full
/// `timeout` once processing completes (`endActivity()`). If `timeout` elapses
/// with nothing in flight, `onTimeout` is invoked exactly once.
///
/// `@unchecked Sendable`: the timer and in-flight counter are guarded by `lock`,
/// so the begin/end calls (on cooperative threads) and the timer's own firing (on
/// `queue`) are serialised.
final class IdleShutdownMonitor: @unchecked Sendable {
  private let timeout: TimeInterval
  private let onTimeout: @Sendable () -> Void
  private let queue = DispatchQueue(label: "com.facebook.idb.companionserver.idle")
  private let lock = NSLock()
  private var timer: (any DispatchSourceTimer)?
  private var inFlight = 0
  private var finished = false

  init(timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
    self.timeout = timeout
    self.onTimeout = onTimeout
  }

  /// Starts the countdown. Call once, when the server is listening.
  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard timer == nil, !finished else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.setEventHandler { [weak self] in self?.fire() }
    self.timer = timer
    timer.schedule(deadline: .now() + timeout)
    timer.resume()
  }

  /// Marks a request as in flight, pausing the countdown until it completes.
  func beginActivity() {
    lock.lock()
    defer { lock.unlock() }
    guard let timer, !finished else { return }
    inFlight += 1
    if inFlight == 1 {
      timer.schedule(deadline: .distantFuture)
    }
  }

  /// Marks an in-flight request complete; when none remain, restarts the
  /// countdown at the full `timeout`.
  func endActivity() {
    lock.lock()
    defer { lock.unlock() }
    guard let timer, !finished else { return }
    if inFlight > 0 {
      inFlight -= 1
    }
    if inFlight == 0 {
      timer.schedule(deadline: .now() + timeout)
    }
  }

  /// Cancels the countdown without invoking `onTimeout`.
  func stop() {
    lock.lock()
    defer { lock.unlock() }
    finished = true
    timer?.cancel()
    timer = nil
  }

  private func fire() {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    timer?.cancel()
    timer = nil
    lock.unlock()
    onTimeout()
  }
}
