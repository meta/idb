/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import Foundation
import os

/// A wait that fires on its deadline. `Task.sleep`, `usleep` and `mach_wait_until` are all subject to
/// timer coalescing, which for a process at utility or background QoS — a recorder launched by a
/// test harness or a daemon — lands the wake-up 25–40 ms late, most of a 30 fps frame budget. Only a
/// dispatch timer with the `.strict` flag opts out of coalescing (measured 0.1 ms median lateness
/// where `Task.sleep` measured 25 ms on the same host).
enum StrictTimer {
  private static let queue = DispatchQueue(label: "com.facebook.FBSimulatorControl.frame-cadence", qos: .userInteractive)

  /// Resumes exactly once, whichever of the timer's handlers runs first: the continuation is taken
  /// out under the lock, so a second caller finds nothing to resume.
  private final class Resumer: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Void, any Error>?>

    init(_ continuation: CheckedContinuation<Void, any Error>) {
      self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(_ result: Result<Void, any Error>) {
      continuation.withLock { continuation in
        defer { continuation = nil }
        return continuation
      }?.resume(with: result)
    }
  }

  /// Suspends until the uptime deadline (`mach_absolute_time` converted to nanoseconds), throwing
  /// `CancellationError` if the task is cancelled first.
  static func wait(untilUptimeNanoseconds deadline: UInt64) async throws {
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let resumer = Resumer(continuation)
        timer.setEventHandler {
          resumer.resume(.success(()))
          timer.cancel()
        }
        timer.setCancelHandler {
          resumer.resume(.failure(CancellationError()))
        }
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
        timer.resume()
        // A cancellation that raced the setup above has no timer to cancel yet; honour it now.
        if Task.isCancelled {
          timer.cancel()
        }
      }
    } onCancel: {
      timer.cancel()
    }
  }
}
