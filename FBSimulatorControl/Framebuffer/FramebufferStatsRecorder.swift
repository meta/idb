/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import IOSurface

/// Accumulates framebuffer surface-change and frame-rendered counters and periodically logs
/// interval/total rates. The callbacks that feed it fire on arbitrary private-framework threads
/// while `snapshot()` / `startTime` are read from a consumer's queue; all of it sits in one
/// `PeriodicStatsLog`.
final class FramebufferStatsRecorder: Sendable {

  private let logger: any ControlCoreLogger
  private let log = PeriodicStatsLog(initial: FramebufferStats())

  init(logger: any ControlCoreLogger) {
    self.logger = logger
  }

  func recordIOSurfaceChange(surface: IOSurface?) {
    let isFirstChange = log.update { stats -> Bool in
      stats.ioSurfaceChangeCount += 1
      return stats.ioSurfaceChangeCount == 1
    }
    if isFirstChange {
      logger.info().log("First IOSurface change callback, surface=\(String(describing: surface))")
    }
  }

  func recordFrameRendered() {
    switch log.updateAndTick({ $0.frameRenderedCount += 1 }).1 {
    case .started:
      logger.info().log("First frame-rendered callback received")
    case .pending:
      break
    case let .elapsed(current, last, interval, total):
      let intervalCallbacks = current.frameRenderedCount - last.frameRenderedCount
      let intervalIOSurface = current.ioSurfaceChangeCount - last.ioSurfaceChangeCount

      let intervalSeconds = interval.seconds
      let totalSeconds = total.seconds
      let intervalRate = intervalSeconds > 0 ? Double(intervalCallbacks) / intervalSeconds : 0
      let totalRate = totalSeconds > 0 ? Double(current.frameRenderedCount) / totalSeconds : 0

      unsafe logger.info().log(
        String(
          format: "Framebuffer stats (interval): %lu frames in %.1fs (%.1f/s) — %lu IOSurface changes",
          intervalCallbacks, intervalSeconds, intervalRate, intervalIOSurface))
      unsafe logger.info().log(
        String(
          format: "Framebuffer stats (total): %lu frames in %.1fs (%.1f/s) — %lu IOSurface changes",
          current.frameRenderedCount, totalSeconds, totalRate, current.ioSurfaceChangeCount))
    }
  }

  func snapshot() -> FramebufferStats {
    log.snapshot
  }

  var startTime: ContinuousClock.Instant? {
    log.startTime
  }
}
