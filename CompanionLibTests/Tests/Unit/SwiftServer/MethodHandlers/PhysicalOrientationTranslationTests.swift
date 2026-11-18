/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBDeviceHID
import GRPCCore
import IDBGRPCSwift
import Testing

@Suite
struct PhysicalOrientationTranslationTests {
  @Test func dedicatedReadsPreserveAllPhysicalStates() {
    let cases: [(DeviceOrientation, Idb_GetOrientationResponse.Orientation)] = [
      (.unknown, .unknown), (.portrait, .portrait), (.portraitUpsideDown, .portraitUpsideDown),
      (.landscapeLeft, .landscapeLeft), (.landscapeRight, .landscapeRight), (.faceUp, .faceUp), (.faceDown, .faceDown),
    ]
    for (physical, wire) in cases {
      #expect(OrientationMethodHandler.response(physical).orientation == wire)
    }
  }

  @Test func dedicatedWritesUsePhysicalNamesNotLegacyNumbers() throws {
    let cases: [(Idb_HIDEvent.HIDOrientationType, DeviceOrientation)] = [
      (.portrait, .portrait), (.portraitUpsideDown, .portraitUpsideDown),
      (.landscapeLeft, .landscapeLeft), (.landscapeRight, .landscapeRight),
    ]
    for (wire, physical) in cases {
      #expect(try OrientationMethodHandler.physicalOrientation(wire) == physical)
    }
    do {
      _ = try OrientationMethodHandler.physicalOrientation(.UNRECOGNIZED(999))
      Issue.record("Unrecognized orientation accepted")
    } catch let error as RPCError {
      #expect(error.code == .invalidArgument)
    }
  }

  @Test(arguments: [Idb_HIDEvent.HIDOrientationType.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight])
  func legacyPhysicalHIDOrientationRemainsUnsupported(_ orientation: Idb_HIDEvent.HIDOrientationType) async throws {
    let requests = AsyncStream<Idb_HIDEvent> { continuation in
      continuation.yield(.with { $0.orientation = .with { $0.orientation = orientation } })
      continuation.finish()
    }
    do {
      _ = try await DeviceHIDRequest.read(from: requests)
      Issue.record("Legacy HID rotation accepted")
    } catch let error as RPCError {
      #expect(error.code == .unimplemented)
    }
  }
}
