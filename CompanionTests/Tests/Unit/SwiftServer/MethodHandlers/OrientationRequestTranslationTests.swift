/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import Testing

@Suite
struct OrientationRequestTranslationTests {
  @Test
  func allReadStatesSurviveTheWire() throws {
    let cases: [(SimulatorDeviceOrientation, Idb_GetOrientationResponse.Orientation)] = [
      (.unknown, .unknown), (.portrait, .portrait), (.portraitUpsideDown, .portraitUpsideDown),
      (.landscapeLeft, .landscapeLeft), (.landscapeRight, .landscapeRight),
      (.faceUp, .faceUp), (.faceDown, .faceDown),
    ]
    for (state, expected) in cases {
      let response = OrientationMethodHandler.response(state)
      let decoded = try Idb_GetOrientationResponse(serializedBytes: response.serializedData())
      #expect(decoded.orientation == expected)
    }
  }

  @Test
  func writesPreservePhysicalDirectionNames() throws {
    let cases: [(Idb_HIDEvent.HIDOrientationType, SimulatorHIDDeviceOrientation)] = [
      (.portrait, .portrait), (.portraitUpsideDown, .portraitUpsideDown),
      (.landscapeLeft, .landscapeLeft), (.landscapeRight, .landscapeRight),
    ]
    for (input, expected) in cases {
      #expect(try OrientationMethodHandler.orientation(input) == expected)
    }
    let error = #expect(throws: (any Error).self) { try OrientationMethodHandler.orientation(.UNRECOGNIZED(99)) }
    #expect((error as? RPCError)?.code == .invalidArgument)
  }
}
