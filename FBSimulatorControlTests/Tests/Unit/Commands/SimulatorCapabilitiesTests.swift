/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBSimulatorControl
import Foundation
import Testing

@Suite
struct SimulatorCapabilitiesTests {

  private func display(_ id: String, integrated: Bool = true) -> SimulatorDisplay {
    SimulatorDisplay(
      uniqueID: id, name: id, activity: .active, isPrimary: false, isIntegrated: integrated,
      bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: .upright)
  }

  private func configuration(_ displays: [SimulatorDisplay]) -> SimulatorDisplayConfiguration {
    SimulatorDisplayConfiguration(generation: 1, displays: displays, active: displays.first.map { .identified($0) } ?? .unresolved, phase: .settled)
  }

  @Test
  func anIPhoneDuoHasEveryCapability() throws {
    let capabilities = try SimulatorCapabilities(
      motion: MotionCapabilities(hingeAngle: true, deviceMotionState: true), displays: .success(configuration([display("cover"), display("inner")])))
    #expect(capabilities == SimulatorCapabilities(hingeAngle: true, deviceMotion: true, multipleDisplays: true))
  }

  @Test
  func onlyIntegratedDisplaysCount() throws {
    let capabilities = try SimulatorCapabilities(motion: .none, displays: .success(configuration([display("lcd"), display("tv", integrated: false)])))
    #expect(capabilities == SimulatorCapabilities(hingeAngle: false, deviceMotion: false, multipleDisplays: false))
  }

  @Test
  func aRuntimeWithoutDisplayReportsHasOneDisplay() throws {
    let capabilities = try SimulatorCapabilities(
      motion: MotionCapabilities(hingeAngle: nil, deviceMotionState: true), displays: .failure(SimulatorCoreDeviceError.unsupported("display info")))
    #expect(capabilities == SimulatorCapabilities(hingeAngle: false, deviceMotion: true, multipleDisplays: false))
  }

  @Test
  func aServiceThatIsNotReadyIsThrown() throws {
    let error = try #require(
      #expect(throws: (any Error).self) {
        try SimulatorCapabilities(motion: .none, displays: .failure(SimulatorCoreDeviceError.timedOut))
      })
    #expect(SimulatorFailureKind(error) == .notReady)
  }
}
