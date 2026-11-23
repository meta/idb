/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import Foundation

/// A drift-corrected frame clock for `.eager` mode. Iterating it (`for await trigger in …`) suspends
/// until the next frame deadline and yields a `FrameTrigger`, so the push loop can read as just
/// "push each tick". The iterator owns all the timing — Mach-tick deadlines, the `Task.sleep` wait
/// and drift correction — and ends (returns `nil`) when the surrounding `Task` is cancelled.
///
/// An overrun (a push that overshoots its deadline) is detected on the *following* `next()`, when
/// the clock finds it is already past the deadline. That tick fires immediately and the deadlines
/// the stall consumed are skipped, so a stall of N intervals costs one late frame rather than N
/// back-to-back copies of it. `CadenceStats` reports the overrun count; at a window boundary the
/// count can attribute to the next 5s stats window.
struct FrameCadence: AsyncSequence {
  typealias Element = FrameTrigger

  let framesPerSecond: UInt

  func makeAsyncIterator() -> Iterator {
    Iterator(framesPerSecond: framesPerSecond)
  }

  struct Iterator: nonisolated AsyncIteratorProtocol {
    private let frameIntervalMach: UInt64
    private let machNumer: UInt64
    private let machDenom: UInt64
    private var nextTargetTime: UInt64
    private var firstTickPending = true

    init(framesPerSecond: UInt) {
      let frameIntervalNanos = NSEC_PER_SEC / UInt64(framesPerSecond)
      var timebase = mach_timebase_info_data_t()
      unsafe mach_timebase_info(&timebase)
      self.machNumer = UInt64(timebase.numer)
      self.machDenom = UInt64(timebase.denom)
      self.frameIntervalMach = frameIntervalNanos * UInt64(timebase.denom) / UInt64(timebase.numer)
      self.nextTargetTime = mach_absolute_time() + self.frameIntervalMach
    }

    mutating func next() async -> FrameTrigger? {
      if Task.isCancelled {
        return nil
      }
      // The first tick fires immediately, before any sleep.
      if firstTickPending {
        firstTickPending = false
        return FrameTrigger(forceKeyFrame: false, overran: false, overlayOnly: false)
      }

      let now = mach_absolute_time()
      var overran = false
      if now < nextTargetTime {
        do {
          try await StrictTimer.wait(untilUptimeNanoseconds: nextTargetTime * machNumer / machDenom)
        } catch {
          return nil // cancelled while waiting
        }
      } else {
        // Already past the deadline — the previous push overshot the frame budget. Skip the
        // deadlines the stall consumed so the grid stays aligned but no catch-up burst follows.
        overran = true
        let missed = (now - nextTargetTime) / frameIntervalMach
        nextTargetTime += missed * frameIntervalMach
      }
      nextTargetTime += frameIntervalMach
      return FrameTrigger(forceKeyFrame: false, overran: overran, overlayOnly: false)
    }
  }
}
