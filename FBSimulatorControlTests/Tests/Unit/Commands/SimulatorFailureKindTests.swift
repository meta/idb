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
struct SimulatorFailureKindTests {

  @Test
  func missingCapabilitiesAreUnsupported() {
    #expect(SimulatorFailureKind(SimulatorDisplayInteractionError.unsupportedCapability("hinge")) == .unsupported(capability: "hinge"))
    #expect(SimulatorFailureKind(SimulatorCoreDeviceError.unsupported("display switching")) == .unsupported(capability: "display switching"))
  }

  @Test
  func statesALaterAttemptMayFindChangedAreNotReady() {
    let errors: [any Error] = [
      SimulatorCoreDeviceError.unavailable("not booted"), SimulatorCoreDeviceError.timedOut,
      SimulatorDisplayError.changed, SimulatorDisplayError.transitioning, SimulatorDisplayError.noActiveIntegratedDisplay,
      SimulatorDisplayError.ambiguousActiveDisplays(["cover", "inner"]), SimulatorDisplayError.screensNotReported(within: 5),
    ]
    for error in errors {
      #expect(SimulatorFailureKind(error) == .notReady, "\(error)")
    }
  }

  @Test
  func failedAttemptsAndWrongRequestsAreFailed() throws {
    struct Foreign: Error {}
    let errors: [any Error] = [
      SimulatorCoreDeviceError.malformed("reply"), SimulatorDisplayInteractionError.inactiveDisplay("inner"),
      SimulatorDisplayInteractionError.missingMapping("inner"), SimulatorDisplayInteractionError.invalidPoint(.zero, bounds: .zero),
      SimulatorDisplayInteractionError.nonFinitePoint(.zero),
      SimulatorPoseConfirmationError.notReached(target: .hinge(try SimulatorHingeAngle(degrees: 180)), last: .hinge(try SimulatorHingeAngle(degrees: 90))),
      SimulatorOrientationError.unwritable(.faceUp), NSError(domain: "unsupportedCapability", code: 1), Foreign(),
    ]
    for error in errors {
      #expect(SimulatorFailureKind(error) == .failed, "\(error)")
    }
  }

  @Test
  func anUnsupportedCaseWithNoDetailIsFailed() {
    #expect(SimulatorFailureKind(SimulatorDisplayInteractionError.unsupportedCapability("")) == .failed)
    #expect(SimulatorFailureKind(SimulatorCoreDeviceError.unsupported("")) == .failed)
  }
}
