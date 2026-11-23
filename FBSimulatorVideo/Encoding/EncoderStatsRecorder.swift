/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import FBControlCore
import FBSimulatorControl
import Foundation

/// Stats tracked by the video encoder (VideoToolbox).
/// Zeroed if the stream uses a non-encoded format (e.g. bitmap/BGRA).
public struct VideoEncoderStats: Sendable {
  public var callbackCount: UInt = 0
  public var writeCount: UInt = 0
  public var dropCount: UInt = 0
  var writeFailureCount: UInt = 0
  public var encodeErrorCount: UInt = 0
  public var tornFrameCount: UInt = 0
  public var totalEncodedBytes: UInt = 0
  var totalEncodeSubmitSeconds: TimeInterval = 0

  public init() {}
}

/// Accounts for what the encoder does with each frame: the running `VideoEncoderStats`, the
/// warmup and starvation diagnostics, and a stats line every `logInterval` seconds.
///
/// Every mutable field lives in one `PeriodicStatsLog`, so the recorder is `Sendable` as it stands:
/// the VideoToolbox output handler records outcomes, the encode submission records its timing, and
/// the owning actor reads snapshots, from whatever threads they run on.
final class EncoderStatsRecorder: Sendable {

  /// What became of one frame the encoder was given.
  enum Outcome: Sendable {
    /// The encoded sample reached the consumer, carrying this many bytes.
    case written(encodedBytes: Int)
    /// VideoToolbox dropped the frame (rate control had no budget for it).
    case dropped
    /// The sample was produced but the consumer refused it.
    case writeFailed
    /// VideoToolbox reported an error for the frame.
    case encodeError(OSStatus)
  }

  private struct State: Sendable {
    var stats = VideoEncoderStats()
    var consecutiveNotReadyFrameCount: UInt = 0
    var warmupComplete = false
    var starvationWarningLogged = false
    /// When the first frame was submitted, so the first callback can report the encoder's start-up latency.
    var firstSubmission: ContinuousClock.Instant?
  }

  /// Frames the encoder may take to produce its first output before that is worth a warning.
  static let warmupWindowFrames: UInt = 20
  /// Consecutive unproduced frames after warmup that indicate the bitrate is too low.
  static let starvationThreshold: UInt = 10

  private let logger: any ControlCoreLogger
  private let log: PeriodicStatsLog<State>

  init(logger: any ControlCoreLogger, logInterval: Duration = .seconds(5)) {
    self.logger = logger
    self.log = PeriodicStatsLog(initial: State(), interval: logInterval)
  }

  /// The stats so far.
  var snapshot: VideoEncoderStats {
    log.snapshot.stats
  }

  var warmupComplete: Bool {
    log.snapshot.warmupComplete
  }

  var consecutiveNotReadyFrameCount: UInt {
    log.snapshot.consecutiveNotReadyFrameCount
  }

  var starvationWarningLogged: Bool {
    log.snapshot.starvationWarningLogged
  }

  /// Test seam: move the periodic log's last-fired time back so the next `record` logs.
  func backdateStatsTimerForTesting(by duration: Duration) {
    log.backdateForTesting(by: duration)
  }

  /// A log line produced under the lock and emitted after it is released.
  private enum LogLine: Sendable {
    case info(String)
    case warning(String)
  }

  /// One encoder callback's outcome. Counts it, tracks warmup and starvation, and logs the periodic
  /// stats line when the interval has elapsed. Logging happens outside the lock.
  func record(_ outcome: Outcome) {
    var ((lines, firstSubmission), tick) = log.updateAndTick { state in (Self.record(outcome, in: &state), state.firstSubmission) }
    switch tick {
    case .started:
      lines.insert(.info(Self.firstCallbackLine(since: firstSubmission)), at: 0)
    case .pending:
      break
    case let .elapsed(current, last, interval, total):
      lines += Self.periodicStats(current: current.stats, last: last.stats, interval: interval, total: total)
    }
    for line in lines {
      switch line {
      case let .info(text):
        logger.info().log(text)
      case let .warning(text):
        logger.log(text)
      }
    }
  }

  /// How long an encode submission took, converter included.
  func recordEncodeSubmission(_ duration: Duration) {
    log.update { $0.stats.totalEncodeSubmitSeconds += duration.seconds }
  }

  /// A frame is about to be submitted. Recorded before the submission, as VideoToolbox may call back before
  /// the submission returns.
  func recordSubmissionStarting(at instant: ContinuousClock.Instant) {
    log.update { state in
      if state.firstSubmission == nil { state.firstSubmission = instant }
    }
  }

  private static func firstCallbackLine(since firstSubmission: ContinuousClock.Instant?) -> String {
    guard let firstSubmission else { return "First encode callback received" }
    return unsafe String(format: "First encode callback received %.1f ms after its frame was submitted", (ContinuousClock.now - firstSubmission).seconds * 1000)
  }

  /// The source surface changed while a frame was being read.
  func recordTornFrame() {
    log.update { $0.stats.tornFrameCount += 1 }
  }

  // MARK: - Warmup and starvation

  private static func record(_ outcome: Outcome, in state: inout State) -> [LogLine] {
    state.stats.callbackCount += 1
    switch outcome {
    case let .encodeError(status):
      state.stats.encodeErrorCount += 1
      return [.warning("VideoToolbox encode error: OSStatus \(status)")]
    case .dropped:
      state.stats.dropCount += 1
      return recordFrameNotProduced(&state)
    case .writeFailed:
      state.stats.writeFailureCount += 1
      return recordFrameNotProduced(&state)
    case let .written(encodedBytes):
      state.stats.writeCount += 1
      state.stats.totalEncodedBytes += UInt(encodedBytes)
      return recordFrameProduced(&state)
    }
  }

  private static func recordFrameNotProduced(_ state: inout State) -> [LogLine] {
    state.consecutiveNotReadyFrameCount += 1
    let consecutiveFailures = state.consecutiveNotReadyFrameCount
    if !state.warmupComplete {
      if consecutiveFailures == warmupWindowFrames {
        state.starvationWarningLogged = true
        return [.warning("Encoder has not produced a frame after \(consecutiveFailures) attempts — bitrate may be too low for this resolution")]
      }
    } else if consecutiveFailures == starvationThreshold && !state.starvationWarningLogged {
      state.starvationWarningLogged = true
      return [.warning("Encoder starvation: \(consecutiveFailures) consecutive frames not ready after warmup — bitrate is likely too low")]
    }
    return []
  }

  private static func recordFrameProduced(_ state: inout State) -> [LogLine] {
    let failuresBefore = state.consecutiveNotReadyFrameCount
    state.consecutiveNotReadyFrameCount = 0
    state.starvationWarningLogged = false
    guard !state.warmupComplete else {
      return []
    }
    state.warmupComplete = true
    return failuresBefore > 0 ? [.warning("Encoder warmed up after \(failuresBefore) skipped frames")] : []
  }

  // MARK: - Periodic log

  private static func periodicStats(current: VideoEncoderStats, last: VideoEncoderStats, interval: Duration, total: Duration) -> [LogLine] {
    let intervalDuration = interval.seconds
    let totalElapsed = total.seconds

    let intervalCallbacks = current.callbackCount - last.callbackCount
    let intervalEncodedBytes = current.totalEncodedBytes - last.totalEncodedBytes
    let intervalEncodeSubmitSeconds = current.totalEncodeSubmitSeconds - last.totalEncodeSubmitSeconds

    let totalFps = totalElapsed > 0 ? Double(current.callbackCount) / totalElapsed : 0
    let intervalFps = intervalDuration > 0 ? Double(intervalCallbacks) / intervalDuration : 0
    let intervalBitrateKbps = intervalDuration > 0 ? Double(intervalEncodedBytes) * 8.0 / 1000.0 / intervalDuration : 0
    let totalBitrateKbps = totalElapsed > 0 ? Double(current.totalEncodedBytes) * 8.0 / 1000.0 / totalElapsed : 0
    let intervalAvgEncodeMs = intervalCallbacks > 0 ? (intervalEncodeSubmitSeconds / Double(intervalCallbacks)) * 1000.0 : 0
    let totalAvgEncodeMs = current.callbackCount > 0 ? (current.totalEncodeSubmitSeconds / Double(current.callbackCount)) * 1000.0 : 0

    return unsafe [
      .info(
        String(
          format:
            "Video stats (interval): %lu callbacks in %.1fs (%.1f fps, %.0f kbps, %.2f ms/frame encode) — %lu written, %lu dropped, %lu write failures, %lu encode errors, %lu torn",
          intervalCallbacks, intervalDuration, intervalFps, intervalBitrateKbps, intervalAvgEncodeMs,
          current.writeCount - last.writeCount, current.dropCount - last.dropCount, current.writeFailureCount - last.writeFailureCount,
          current.encodeErrorCount - last.encodeErrorCount, current.tornFrameCount - last.tornFrameCount)),
      .info(
        String(
          format:
            "Video stats (total): %lu callbacks in %.1fs (%.1f fps, %.0f kbps, %.2f ms/frame encode) — %lu written, %lu dropped, %lu write failures, %lu encode errors, %lu torn",
          current.callbackCount, totalElapsed, totalFps, totalBitrateKbps, totalAvgEncodeMs,
          current.writeCount, current.dropCount, current.writeFailureCount, current.encodeErrorCount, current.tornFrameCount)),
    ]
  }
}
