/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreVideo
import FBControlCore
import FBSimulatorControl
import Foundation

public enum VideoSession {
  /// Wire the stdin command handler and the optional 1Hz stats-bar timers over a live video stream.
  /// Shared by `video-stream` and `record`, which differ only in how the stream is created and stopped.
  @MainActor
  public static func makeHandler(
    videoStream: SimulatorVideoStream?,
    renderer: OverlayRenderer,
    screenshotDir: String?,
    parsedBars: [(position: String, height: Int, mode: BarMode)],
    barStats: [String],
    logger: any ControlCoreLogger
  ) -> (handler: StdinCommandHandler, statsTimers: [Task<Void, Never>]) {
    let handler = StdinCommandHandler(
      renderer: renderer,
      screenshotDir: screenshotDir,
      logger: logger
    )
    handler.videoStream = videoStream
    videoStream?.setOverlayLayout(renderer)

    // Apply per-position bar mode (drives bar background alpha).
    for entry in parsedBars {
      renderer.setBarMode(entry.mode, position: entry.position)
    }

    // Prime bars that requested --bar-stats with stats mode at startup.
    for statsPosition in barStats {
      renderer.setBarContent(.stats, position: statsPosition)
    }

    // Start a 1 Hz stats task for each --bar-stats position, awaiting the stream's actor-isolated
    // stats between renders.
    // Stats use windowed (last-interval) rates rather than cumulative averages
    // so they respond quickly to changes (e.g. static screen → near-zero fb rate).
    var statsTimers: [Task<Void, Never>] = []
    for statsPosition in barStats {
      guard let videoStream else { break }
      let task = Task.detached { [weak videoStream] in
        var prevFbStats = FramebufferStats()
        var prevEncStats = VideoEncoderStats()
        var prevStatsTime: CFTimeInterval = 0
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
          guard !Task.isCancelled, let videoStream else { return }
          let encoder = await videoStream.currentEncoderStats()
          let fb = videoStream.currentFramebufferStats()
          let now = CFAbsoluteTimeGetCurrent()
          let interval = now - prevStatsTime
          let fbRate: Double
          let encFps: Double
          let encKbps: Double
          if interval > 0 && prevStatsTime > 0 {
            fbRate = Double(fb.frameRenderedCount - prevFbStats.frameRenderedCount) / interval
            encFps = Double(encoder.callbackCount - prevEncStats.callbackCount) / interval
            encKbps = Double(encoder.totalEncodedBytes - prevEncStats.totalEncodedBytes) * 8.0 / 1000.0 / interval
          } else {
            fbRate = 0
            encFps = 0
            encKbps = 0
          }
          prevFbStats = fb
          prevEncStats = encoder
          prevStatsTime = now
          let text = unsafe String(
            format: "fb:%.1f/s enc:%.1ffps %.0fkbps | w:%lu d:%lu e:%lu t:%lu",
            fbRate, encFps, encKbps,
            encoder.writeCount, encoder.dropCount, encoder.encodeErrorCount, encoder.tornFrameCount
          )
          renderer.setStatsText(text, position: statsPosition)
          // patternlint-disable-next-line swift-nonisolated-unsafe
          nonisolated(unsafe) let buffer: CVPixelBuffer? = renderer.buffer
          unsafe await videoStream.updateOverlayBuffer(buffer)
        }
      }
      statsTimers.append(task)
    }
    return (handler, statsTimers)
  }

}
