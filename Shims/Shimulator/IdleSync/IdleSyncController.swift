/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import ShimulatorProtocol

/// One evaluation of what keeps the process busy.
public struct IdleSyncSample: Equatable, Sendable {
  /// Empty when nothing does.
  public let reasons: [IdleSyncReason]
  /// Wall-clock milliseconds when the current idle period began, as the trackers recorded it from load; read only
  /// while `reasons` is empty.
  public let idleSince: UInt64
  /// See `IdleSyncState.lastInputAt`.
  public let lastInputAt: UInt64?
  /// Wall-clock milliseconds when it was taken.
  public let at: UInt64

  public init(
    reasons: [IdleSyncReason], idleSince: UInt64, lastInputAt: UInt64? = nil, at: UInt64
  ) {
    self.reasons = reasons
    self.idleSince = idleSince
    self.lastInputAt = lastInputAt
    self.at = at
  }
}

/// The trackers the controller reads; the shim's observe the main run loop, Core Animation and scrolling.
public protocol IdleSyncProbe {
  func sample() -> IdleSyncSample
  /// `nil` restores the trackers' own threshold.
  func setBusyThreshold(milliseconds: UInt32?)
}

/// Reports the process's state to the host each time it changes. The trackers run from load, so an idle period that
/// began before the host connected is reported from when it began, unless the busy threshold changed since.
public final class IdleSyncController: ShimulatorMethodHandler {
  public struct Admission: Sendable {}

  private let probe: IdleSyncProbe
  /// The threshold the trackers run with; `nil` is their own.
  private var busyThresholdMs: UInt32?
  /// Work the current threshold counts may have gone unrecorded under the previous one, so no idle period is dated
  /// before the first sample after a change.
  private var historyStart: UInt64 = 0
  private var thresholdChanged = false

  public init(probe: IdleSyncProbe) {
    self.probe = probe
  }

  public func start(_ parameters: IdleSyncParameters) throws -> Admission {
    setBusyThreshold(parameters.busyThresholdMs)
    return Admission()
  }

  /// The next host may ask for another threshold, or none.
  public func stop(_ admission: Admission) {
    setBusyThreshold(nil)
  }

  public func poll(_ admission: Admission) -> ShimulatorMethodUpdate? {
    let state = currentState()
    // Sorted keys keep equal states byte-identical, so the client sends each state once.
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let payload = try? encoder.encode(state) else { return nil }
    return ShimulatorMethodUpdate(.accepted, payload: payload)
  }

  func currentState() -> IdleSyncState {
    let sample = probe.sample()
    if thresholdChanged {
      historyStart = sample.at
      thresholdChanged = false
    }
    let idleSince = sample.reasons.isEmpty ? min(max(sample.idleSince, historyStart), sample.at) : nil
    return IdleSyncState(
      idleSince: idleSince, reasons: sample.reasons.map(\.rawValue),
      lastInputAt: sample.lastInputAt)
  }

  private func setBusyThreshold(_ milliseconds: UInt32?) {
    probe.setBusyThreshold(milliseconds: milliseconds)
    if milliseconds != busyThresholdMs {
      busyThresholdMs = milliseconds
      thresholdChanged = true
    }
  }
}
