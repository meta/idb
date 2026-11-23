/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
import Foundation
import SimulatorFrameworkBridgeRuntime
import SimulatorFrameworkBridgeSupport
import Testing

@Suite
final class QuiescenceTrackerTests {
  private var tracker = QuiescenceTracker(busyThreshold: 0.02, quietWindow: 0.25)

  private func requestBoth(at time: TimeInterval) {
    tracker.requested(.runLoopIdle, at: time)
    tracker.requested(.animationsInactive, at: time)
  }

  @Test
  func theStateIsUnknownUntilEverySignalIsAnsweredOrBusy() {
    requestBoth(at: 0)
    #expect(tracker.state(at: 0.01) == nil)
    tracker.answered(.runLoopIdle, at: 0.001)
    #expect(tracker.state(at: 0.01) == nil)
    #expect(tracker.state(at: 0.02) == .busy([.animationsInactive]))
  }

  @Test
  func promptAnswersSettleThenGoQuietOnceTheWindowPasses() {
    requestBoth(at: 0)
    tracker.answered(.runLoopIdle, at: 0.001)
    tracker.answered(.animationsInactive, at: 0.002)
    #expect(tracker.state(at: 0.1) == .settling)
    #expect(tracker.state(at: 0.252) == .quiet)
  }

  @Test
  func aPromptReArmDoesNotRestartTheWindow() {
    requestBoth(at: 0)
    tracker.answered(.runLoopIdle, at: 0.001)
    tracker.answered(.animationsInactive, at: 0.001)
    tracker.requested(.runLoopIdle, at: 0.05)
    tracker.answered(.runLoopIdle, at: 0.051)
    #expect(tracker.state(at: 0.251) == .quiet)
  }

  @Test
  func aBusyAnswerRestartsTheWindowFromTheAnswer() {
    requestBoth(at: 0)
    tracker.answered(.runLoopIdle, at: 0.001)
    tracker.answered(.animationsInactive, at: 0.001)
    tracker.requested(.animationsInactive, at: 1)
    #expect(tracker.state(at: 1.5) == .busy([.animationsInactive]))
    tracker.answered(.animationsInactive, at: 2)
    #expect(tracker.state(at: 2.1) == .settling)
    #expect(tracker.state(at: 2.25) == .quiet)
  }

  @Test
  func anAnswerThatWasNotRequestedIsIgnored() {
    tracker.answered(.runLoopIdle, at: 0)
    tracker.answered(.animationsInactive, at: 0)
    #expect(tracker.state(at: 1) == nil)
  }

  @Test
  func theNextDeadlineIsTheEarliestThresholdOrWindowEnd() throws {
    requestBoth(at: 0)
    let firstDeadline = try #require(tracker.nextDeadline(after: 0))
    #expect(abs(firstDeadline - 0.02) <= 1e-9)
    tracker.answered(.runLoopIdle, at: 0.001)
    tracker.answered(.animationsInactive, at: 0.004)
    let windowDeadline = try #require(tracker.nextDeadline(after: 0.01))
    #expect(abs(windowDeadline - 0.254) <= 1e-9)
    tracker.requested(.runLoopIdle, at: 0.1)
    let thresholdDeadline = try #require(tracker.nextDeadline(after: 0.1))
    #expect(abs(thresholdDeadline - 0.12) <= 1e-9)
    #expect(tracker.nextDeadline(after: 0.3) == nil, "a busy signal changes only when it is answered")
  }

  @Test
  func resetForgetsEverything() {
    requestBoth(at: 0)
    tracker.answered(.runLoopIdle, at: 0.001)
    tracker.answered(.animationsInactive, at: 0.001)
    tracker.reset()
    #expect(tracker.state(at: 1) == nil)
    #expect(tracker.nextDeadline(after: 1) == nil)
  }
}
