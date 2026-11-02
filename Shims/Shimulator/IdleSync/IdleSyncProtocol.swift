/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

public enum ShimulatorIdleSync {
  public static let capability = "idle"
  /// Set to `1` in the launch environment of a process to measure. The shim reads it once, at load.
  public static let armedEnvironmentVariable = "IDB_IDLE_SYNC"
}

/// How the process measures itself while this host is connected.
public struct IdleSyncParameters: Codable, Equatable, Sendable {
  /// Main-thread work shorter than this many milliseconds does not make the process busy; `nil` takes the
  /// shim's own, 8 ms, which a timer or display link tick with nothing to show stays under.
  public let busyThresholdMs: UInt32?

  public init(busyThresholdMs: UInt32? = nil) {
    self.busyThresholdMs = busyThresholdMs
  }
}

/// What keeps a process busy. A state carries the raw values, so a host skips one it does not know.
public enum IdleSyncReason: String, CaseIterable, Sendable {
  /// Main-thread work longer than a timer tick.
  case main
  /// A Core Animation animation that ends within the tracked horizon.
  case animation
  /// A scroll view's content moving.
  case scroll
  /// Main-thread work the app scheduled to run shortly: `dispatch_after` on the main queue,
  /// `performSelector:afterDelay:`, a one-shot timer.
  case delayed
}

/// What a process reports whenever it goes busy or idle, or what keeps it busy changes.
public struct IdleSyncState: Codable, Equatable, Sendable {
  /// Wall-clock milliseconds, which a simulator process shares with its host, when the current idle period began;
  /// `nil` while busy.
  public let idleSince: UInt64?
  /// What keeps the process busy; empty while idle.
  public let reasons: [String]
  /// Wall-clock milliseconds when the process last finished handling the end of a touch sequence or a key press;
  /// absent until it has handled one.
  public let lastInputAt: UInt64?

  public init(idleSince: UInt64?, reasons: [String], lastInputAt: UInt64? = nil) {
    self.idleSince = idleSince
    self.reasons = reasons
    self.lastInputAt = lastInputAt
  }
}
