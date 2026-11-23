/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import Foundation
import Testing

@Suite
struct SimulatorControlTransientTests {

  // MARK: - SimulatorBootConfiguration

  @Test
  func defaultConfigurationHasVerifyUsable() {
    let config = SimulatorBootConfiguration.default
    #expect(
      config.options.contains(.verifyUsable),
      "Default configuration should have VerifyUsable option"
    )
    #expect(
      !config.options.contains(.tieToProcessLifecycle),
      "Default configuration should not have TieToProcessLifecycle option"
    )
  }

  @Test
  func defaultConfigurationHasEmptyEnvironment() {
    let config = SimulatorBootConfiguration.default
    #expect(config.environment.count == 0)
  }

  @Test
  func bootConfigurationDescription() {
    let config = SimulatorBootConfiguration(
      options: .tieToProcessLifecycle,
      environment: ["KEY": "VAL"]
    )
    let desc = config.description
    #expect(desc.contains("Boot Environment"), "Description should contain 'Boot Environment'")
    #expect(desc.contains("Options"), "Description should contain 'Options'")
  }

  @Test
  func bootConfigurationDescriptionContainsDirectLaunch() {
    let config = SimulatorBootConfiguration(
      options: .tieToProcessLifecycle,
      environment: [:]
    )
    let desc = config.description
    #expect(desc.contains("Direct Launch"), "Description should contain 'Direct Launch' for tieToProcessLifecycle")
  }

  @Test
  func bootConfigurationDescriptionWithoutDirectLaunch() {
    let config = SimulatorBootConfiguration(
      options: .verifyUsable,
      environment: [:]
    )
    let desc = config.description
    #expect(!desc.contains("Direct Launch"), "Description should not contain 'Direct Launch' for verifyUsable only")
  }

  // MARK: - SimulatorHIDEvent - Swipe

  @Test
  func swipeDiagonalProducesCorrectStepCount() {
    // Diagonal: distance = sqrt(30^2 + 40^2) = 50, delta=10 -> 5 steps
    let swipe = SimulatorHIDEvent.swipe(0, yStart: 0, xEnd: 30, yEnd: 40, delta: 10, duration: 1.0)
    let expectedSteps = 5
    let expectedEvents = (expectedSteps + 1) * 2 + 2 + 1
    #expect(swipe.subEvents?.count == expectedEvents)
  }

  @Test
  func swipeShorterThanDeltaClampsToOneStep() {
    // distance = 5 < delta 10 gives Int(0.5) = 0 steps, which divides by zero in
    // dx/dy and yields NaN touch coordinates. Steps must be clamped to at least 1,
    // mirroring `pinchAt` and `pan`.
    let swipe = SimulatorHIDEvent.swipe(0, yStart: 0, xEnd: 5, yEnd: 0, delta: 10, duration: 1.0)
    let expectedSteps = 1
    let expectedEvents = (expectedSteps + 1) * 2 + 2 + 1
    #expect(swipe.subEvents?.count == expectedEvents)
    for event in swipe.subEvents ?? [] {
      if case let .touch(_, x, y, _) = event {
        #expect(x.isFinite && y.isFinite, "Swipe produced a non-finite coordinate (\(x), \(y))")
      }
    }
  }
}
