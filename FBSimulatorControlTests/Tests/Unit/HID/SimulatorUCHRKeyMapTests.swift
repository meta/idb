/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import Foundation
import Testing

/// What is accepted as a keyboard layout. The layouts themselves are Apple's and ship in a
/// simulator runtime, so reading one is covered where there is a simulator: `SimulatorKeyboardSmokeTests`.
@Suite
struct SimulatorUCHRKeyMapTests {

  @Test
  func dataThatIsNotALayoutIsNotRead() {
    #expect(SimulatorUCHRKeyMap(uchr: Data()) == nil)
    #expect(SimulatorUCHRKeyMap(uchr: Data(repeating: 0, count: 4096)) == nil)
    #expect(SimulatorUCHRKeyMap(uchr: Data("<?xml version=\"1.0\"?>".utf8) + Data(repeating: 0x20, count: 64)) == nil)
  }

  @Test
  func aLayoutHeaderWhoseTablesLieOutsideTheDataIsNotRead() {
    // The header of a layout with one keyboard type, whose tables would all be past the end.
    var header = Data([0x02, 0x10, 0x00, 0x01, 0, 0, 0, 0, 1, 0, 0, 0])
    for field: UInt32 in [0, 0, 0x1000, 0x2000, 0, 0, 0] {
      header += withUnsafeBytes(of: field.littleEndian) { Data($0) }
    }
    #expect(SimulatorUCHRKeyMap(uchr: header) == nil)
    #expect(SimulatorUCHRKeyMap(uchr: header + Data(repeating: 0, count: 64)) == nil)
  }
}
