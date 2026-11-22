/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBControlCore
import Foundation
import IDBGRPCSwift
import SwiftProtobuf
import Testing

@Suite
struct DescribeMethodHandlerTests {
  private struct Failure: Error {}

  @Test
  func aDisplaySurvivesTheWire() throws {
    let display = TargetDisplayDescription(
      uniqueID: "FA9C9507-0D45-4189-A7D6-A3335032D47B", name: "LCD-1", isActive: true, isIntegrated: true, widthPixels: 2854,
      heightPixels: 2008, scale: 3)

    let decoded = try Idb_Display(serializedBytes: DescribeMethodHandler.display(display).serializedData())

    #expect(decoded.uniqueID == "FA9C9507-0D45-4189-A7D6-A3335032D47B")
    #expect(decoded.name == "LCD-1")
    #expect(decoded.active)
    #expect(decoded.integrated)
    #expect(decoded.width == 2854)
    #expect(decoded.height == 2008)
    #expect(decoded.density == 3)
  }

  @Test
  func aTargetWithoutDiagnosticsIsDescribedWithEmptyOnes() throws {
    #expect(try DescribeMethodHandler.diagnostics(.unsupported).isEmpty)
  }

  @Test
  func diagnosticsThatCannotBeReadFailTheDescription() {
    #expect(throws: (any Error).self) { try DescribeMethodHandler.diagnostics(.failed(Failure())) }
  }
}
