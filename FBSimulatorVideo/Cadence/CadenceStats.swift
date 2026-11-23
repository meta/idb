/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import Foundation

/// Welford online mean/variance of push duration plus an overrun count, logged every 5 seconds.
struct CadenceStats {
  private let frameIntervalNanos: UInt64
  private let machToMs: Double
  private let statsIntervalMach: UInt64
  private let logger: any ControlCoreLogger

  private var statsStartTime: UInt64
  private var pushCount: UInt64 = 0
  private var overrunCount: UInt64 = 0
  private var maxPushMach: UInt64 = 0
  private var pushMean = 0.0 // Welford mean (in Mach ticks)
  private var pushM2 = 0.0 // Welford M2 (sum of squared deviations)

  init(frameIntervalNanos: UInt64, logger: any ControlCoreLogger) {
    var timebase = mach_timebase_info_data_t()
    unsafe mach_timebase_info(&timebase)
    self.machToMs = Double(timebase.numer) / Double(timebase.denom) / 1e6
    let statsIntervalSeconds = 5.0
    self.statsIntervalMach = UInt64(statsIntervalSeconds * 1e9) * UInt64(timebase.denom) / UInt64(timebase.numer)
    self.frameIntervalNanos = frameIntervalNanos
    self.logger = logger
    self.statsStartTime = mach_absolute_time()
  }

  mutating func record(pushDurationMach: UInt64, overran: Bool) {
    pushCount += 1
    if overran {
      overrunCount += 1
    }
    if pushDurationMach > maxPushMach {
      maxPushMach = pushDurationMach
    }
    let delta = Double(pushDurationMach) - pushMean
    pushMean += delta / Double(pushCount)
    pushM2 += delta * (Double(pushDurationMach) - pushMean)

    let now = mach_absolute_time()
    guard now - statsStartTime >= statsIntervalMach else {
      return
    }
    let avgMs = pushMean * machToMs
    let maxMs = Double(maxPushMach) * machToMs
    let stddevMs = pushCount > 1 ? sqrt(pushM2 / Double(pushCount - 1)) * machToMs : 0
    let intervalSeconds = Double(now - statsStartTime) * machToMs / 1e3
    unsafe logger.info().log(
      String(
        format: "Cadence stats (%.1fs): %llu pushes, %llu overruns, push duration avg %.1f ms / max %.1f ms, jitter stddev %.1f ms (budget: %.1f ms)",
        intervalSeconds, pushCount, overrunCount, avgMs, maxMs, stddevMs, Double(frameIntervalNanos) / 1e6))

    statsStartTime = now
    pushCount = 0
    overrunCount = 0
    maxPushMach = 0
    pushMean = 0
    pushM2 = 0
  }
}
