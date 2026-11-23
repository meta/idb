/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import Foundation
import os

/// A stimulus to push one frame, produced by either cadence: the `FrameCadence` clock (eager) or
/// `LazyFrameTriggers` (lazy, fed by damage/overlay callbacks). Modelling both as the same element
/// lets a single push loop serve both modes.
struct FrameTrigger {
  /// Whether this push should force a keyframe — e.g. a `.lazy` overlay change, so consumers that
  /// need a keyframe can decode it immediately. Cadence-clock ticks never force one.
  let forceKeyFrame: Bool
  /// True when the previous push overshot its deadline (eager cadence only — always false for VFR).
  let overran: Bool
  /// True when no rendered frame was signaled since the previous `.lazy` trigger, so the push only redraws the overlay
  /// over the screen the Simulator last presented. Always false for the eager clock.
  let overlayOnly: Bool
}

/// The `.lazy` (VFR) stimulus: an `AsyncSequence` of `FrameTrigger`s poked by rendered frames and overlay changes.
/// Triggers coalesce to the newest (`bufferingNewest(1)`) so a slow consumer drops redundant frames, and a trigger
/// still reports any keyframe request or rendered frame signaled since the previous one.
///
/// Triggers are paced to at most `maximumFramesPerSecond`: a trigger that arrives sooner than that
/// after the last one is held, not dropped, until the interval has passed, so the newest content is
/// still pushed but never twice within one display interval — a signal that lands mid-push would
/// otherwise be pushed the instant the push returns, and a 120 Hz display would otherwise cost 120
/// encodes a second for viewers that show 60.
final class LazyFrameTriggers: AsyncSequence, Sendable {
  typealias Element = FrameTrigger

  /// The default pace: one push per 60 Hz display interval.
  static let defaultMaximumFramesPerSecond: UInt = 60

  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  /// What the next trigger reports, held beside the stream rather than in its elements, which coalescing drops
  private struct Pending {
    var keyFrame = false
    var frameRendered = false
  }

  private let pending = OSAllocatedUnfairLock(initialState: Pending())
  fileprivate let minimumIntervalMach: UInt64

  init(maximumFramesPerSecond: UInt = LazyFrameTriggers.defaultMaximumFramesPerSecond) {
    var timebase = mach_timebase_info_data_t()
    unsafe mach_timebase_info(&timebase)
    self.minimumIntervalMach = (NSEC_PER_SEC / UInt64(maximumFramesPerSecond)) * UInt64(timebase.denom) / UInt64(timebase.numer)
    // The builder hands back the continuation synchronously, so the IUO is assigned before use.
    // swiftlint:disable:next implicitly_unwrapped_optional
    var continuation: AsyncStream<Void>.Continuation!
    self.stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
    self.continuation = continuation
  }

  /// Signal that a new frame was rendered — enqueue a push of the latest state.
  func signalFrameRendered() {
    pending.withLock { $0.frameRendered = true }
    continuation.yield(())
  }

  /// Signal that the overlay's contents changed in place, enqueueing a push that redraws it
  func signalOverlayChanged() {
    continuation.yield(())
  }

  /// Signal that the overlay changed — mark the next push a keyframe so consumers that need a keyframe
  /// can decode the change immediately, then enqueue a push.
  func signalKeyFrame() {
    pending.withLock { $0.keyFrame = true }
    continuation.yield(())
  }

  /// End the stream, completing the push loop's `for await`.
  func finish() {
    continuation.finish()
  }

  private func takePending() -> Pending {
    pending.withLock { pending in
      defer { pending = Pending() }
      return pending
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(base: stream.makeAsyncIterator(), source: self)
  }

  struct AsyncIterator: nonisolated AsyncIteratorProtocol {
    var base: AsyncStream<Void>.Iterator
    let source: LazyFrameTriggers
    private var lastTriggerMach: UInt64 = 0

    init(base: AsyncStream<Void>.Iterator, source: LazyFrameTriggers) {
      self.base = base
      self.source = source
    }

    mutating func next() async -> FrameTrigger? {
      guard await base.next() != nil else { return nil }
      let earliest = lastTriggerMach + source.minimumIntervalMach
      if mach_absolute_time() < earliest {
        var timebase = mach_timebase_info_data_t()
        unsafe mach_timebase_info(&timebase)
        guard (try? await StrictTimer.wait(untilUptimeNanoseconds: earliest * UInt64(timebase.numer) / UInt64(timebase.denom))) != nil else {
          return nil // cancelled while pacing
        }
      }
      lastTriggerMach = mach_absolute_time()
      let pending = source.takePending()
      return FrameTrigger(forceKeyFrame: pending.keyFrame, overran: false, overlayOnly: !pending.frameRendered)
    }
  }
}
