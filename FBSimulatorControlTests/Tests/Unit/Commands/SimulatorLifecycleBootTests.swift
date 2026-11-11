/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorControl
import Foundation
import Testing
import os

/// Stands in for a `SimDevice` whose boot completion handler runs before the device reports
/// `Booted`, as CoreSimulator's can: the first read of `state` after the handler still sees
/// `Booting`, and every later read sees `Booted`.
private final class LateBootedStateDeviceDouble: NSObject {

  private struct Boot {
    var state: TargetState = .shutdown
    var completed = false
  }

  private let boot = OSAllocatedUnfairLock(initialState: Boot())

  @objc let UDID: NSUUID = NSUUID()

  @objc var state: UInt64 {
    boot.withLock { boot in
      let state = boot.state
      if boot.completed {
        boot.state = .booted
      }
      return UInt64(state.rawValue)
    }
  }

  @objc(bootAsyncWithOptions:completionQueue:completionHandler:)
  func bootAsync(options: NSDictionary, completionQueue: DispatchQueue, completionHandler: @escaping @Sendable (NSError?) -> Void) {
    boot.withLock { $0.state = .booting }
    completionQueue.async { [boot] in
      boot.withLock { $0.completed = true }
      completionHandler(nil)
    }
  }
}

@Suite
struct SimulatorLifecycleBootTests {

  @Test
  func bootWithoutVerifyUsableReturnsOnlyOnceTheDeviceReportsBooted() async throws {
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: LateBootedStateDeviceDouble())

    try await simulator.lifecycle.boot(SimulatorBootConfiguration(options: [], environment: [:]))

    #expect(simulator.state == .booted)
  }
}
