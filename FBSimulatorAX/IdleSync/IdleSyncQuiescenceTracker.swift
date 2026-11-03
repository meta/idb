/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
internal import ShimulatorIdleSyncCore

/// Turns one process's `IdleSyncState`s into quiescence events. The process already waits 100 ms before it reports
/// itself idle; `quietWindowMs` is how much longer it must stay idle before it counts as quiet.
struct IdleSyncQuiescenceTracker {
  let pid: pid_t
  let quietWindowMs: UInt64
  private var idleSince: UInt64?
  private var last: QuiescenceState?
  // The latest input reported; one handled before the stream opened is never reported.
  private var lastInputAt: UInt64

  /// `openedAt` is the wall-clock time the stream opened.
  init(pid: pid_t, quietWindowMs: UInt64, openedAt: UInt64) {
    self.pid = pid
    self.quietWindowMs = quietWindowMs
    self.lastInputAt = openedAt
  }

  /// The events `state` produces at wall-clock time `now`, and, while the process is settling, when to call
  /// `settle(now:)`. A `lastInputAt` after the stream opened and after the last one reported is `touchesCompleted`,
  /// the process having finished handling input, ahead of the state the same report carries.
  mutating func receive(_ state: IdleSyncState, now: UInt64) -> (events: [QuiescenceEvent], settleAt: UInt64?) {
    var events: [QuiescenceEvent] = []
    if let inputAt = state.lastInputAt, inputAt > lastInputAt {
      lastInputAt = inputAt
      events.append(.touchesCompleted(pid: pid))
    }
    guard let since = state.idleSince else {
      idleSince = nil
      return (events + transition(to: .busy(Set(state.reasons.compactMap(QuiescenceSignal.init(idleSyncReason:))))), nil)
    }
    idleSince = since
    let quietAt = Self.adding(quietWindowMs, to: since)
    guard now < quietAt else { return (events + transition(to: .quiet), nil) }
    return (events + transition(to: .settling), quietAt)
  }

  /// `quiet` once the process has stayed idle for the quiet window.
  mutating func settle(now: UInt64) -> [QuiescenceEvent] {
    guard let idleSince, now >= Self.adding(quietWindowMs, to: idleSince) else { return [] }
    return transition(to: .quiet)
  }

  private mutating func transition(to state: QuiescenceState) -> [QuiescenceEvent] {
    guard state != last else { return [] }
    last = state
    return [.state(state, pid: pid)]
  }

  /// The times come from the process, so a sum past the end of time saturates rather than traps.
  private static func adding(_ milliseconds: UInt64, to time: UInt64) -> UInt64 {
    let (sum, overflow) = time.addingReportingOverflow(milliseconds)
    return overflow ? .max : sum
  }
}

extension QuiescenceSignal {
  /// The signal a reason the process reports leaves unanswered, or `nil` for one with no signal here, including one
  /// a newer shim names. Matched on the raw value, so a reason added to `IdleSyncReason` needs no change here.
  init?(idleSyncReason reason: String) {
    switch reason {
    case IdleSyncReason.main.rawValue: self = .runLoopIdle
    case IdleSyncReason.animation.rawValue: self = .animationsInactive
    case IdleSyncReason.scroll.rawValue: self = .scrollIdle
    default: return nil
    }
  }
}
