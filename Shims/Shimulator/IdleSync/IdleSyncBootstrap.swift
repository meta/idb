/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
@_implementationOnly import ShimulatorIdleSyncCore
@_implementationOnly import ShimulatorIdleSyncTrackers
@_implementationOnly import ShimulatorProtocol
import os

private struct TrackerProbe: IdleSyncProbe {
  func sample() -> IdleSyncSample {
    let sample = FBIdleSyncSampleNow()
    var reasons: [IdleSyncReason] = []
    if sample.mainBusy {
      reasons.append(.main)
    }
    if sample.animating {
      reasons.append(.animation)
    }
    return IdleSyncSample(reasons: reasons, idleSince: sample.idleSince, at: sample.at)
  }

  func setBusyThreshold(milliseconds: UInt32?) {
    FBIdleSyncSetBusyThreshold(milliseconds.map(UInt64.init) ?? FBIdleSyncDefaultBusyThresholdMs)
  }
}

/// Called once, at load, by an armed process; the trackers are already running.
// `@_cdecl`, not `@c @implementation`: the open-source build supports Swift 6.2.
// patternlint-disable-next-line cdecl-unsupported
@_cdecl("FBIdleSyncStartClient")
func FBIdleSyncStartClient() {
  let logger = Logger(subsystem: "com.facebook.idb", category: "idle-sync")
  guard let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"], !udid.isEmpty else {
    logger.error("No simulator UDID is available to find the idle socket")
    return
  }
  let path = ShimulatorWireProtocol.socketPath(capability: ShimulatorIdleSync.capability, simulatorUDID: udid)
  Thread.detachNewThread {
    // A short poll, because a host waits on each change: the state reaches it at most this late.
    ShimulatorClient(
      socketPath: path,
      handler: IdleSyncController(probe: TrackerProbe()),
      pollIntervalMilliseconds: 10,
      log: { message in logger.log("\(message, privacy: .public)") }
    ).run()
  }
}
