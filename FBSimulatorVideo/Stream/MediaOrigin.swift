/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import Foundation

/// Where a recording's media time zero falls on the wall clock and on the host clock.
///
/// The file's timeline is anchored at the first sample actually muxed, which the encoder stamps
/// relative to the frame it was first pushed, so media zero is `anchor` seconds after that frame.
/// When that frame was captured is read from the wall clock as it was captured: a clock read any
/// later has had time to be set, and would move a moment that has already happened.
public struct MediaOrigin: Equatable, Sendable {
  /// The Unix timestamp when the first frame was pushed into the encoder, read then.
  public let wallClockAtFirstFrame: TimeInterval
  /// The host clock, in `mach_absolute_time` ticks, when the first frame was pushed, read then.
  public let hostTimeAtFirstFrame: UInt64

  public init(wallClockAtFirstFrame: TimeInterval, hostTimeAtFirstFrame: UInt64 = 0) {
    self.wallClockAtFirstFrame = wallClockAtFirstFrame
    self.hostTimeAtFirstFrame = hostTimeAtFirstFrame
  }

  /// The Unix timestamp of media time zero, for a recording whose file is anchored `anchor`
  /// seconds after the first pushed frame.
  public func startedAt(anchor: TimeInterval) -> TimeInterval {
    wallClockAtFirstFrame + anchor
  }

  /// Media time zero on the host clock, in `mach_absolute_time` ticks: the clock Core Audio stamps
  /// what the simulator plays with.
  public func startHostTime(anchor: TimeInterval) -> UInt64 {
    let ticks = Self.ticks(seconds: anchor)
    return ticks < 0 ? hostTimeAtFirstFrame - min(hostTimeAtFirstFrame, ticks.magnitude) : hostTimeAtFirstFrame + ticks.magnitude
  }

  /// The seconds from `start` to `end` on the host clock, negative when `end` came first.
  public static func seconds(fromHostTime start: UInt64, to end: UInt64) -> TimeInterval {
    let (numerator, denominator) = timebase
    let ticks = end >= start ? Double(end - start) : -Double(start - end)
    return ticks * numerator / denominator / 1e9
  }

  private static func ticks(seconds: TimeInterval) -> Int64 {
    let (numerator, denominator) = timebase
    return Int64((seconds * 1e9 * denominator / numerator).rounded())
  }

  private static var timebase: (numerator: Double, denominator: Double) {
    var info = mach_timebase_info_data_t()
    unsafe mach_timebase_info(&info)
    return (Double(info.numer), Double(max(info.denom, 1)))
  }
}
