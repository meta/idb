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

@Suite
struct SimulatorDefaultsTests {

  @Test
  func readReturnsTrimmedStdoutOnZeroExit() throws {
    let output = InSimulatorToolOutput(stdout: Data("value\n".utf8), stderr: Data(), exitCode: 0)
    let result = try SimulatorDefaults.stdout(orThrowFrom: output, command: .read(domain: "d", key: "k"), logger: nil)
    #expect(result == "value")
  }

  @Test
  func readToleratesMissingKeyNonZeroExit() throws {
    // defaults returns 1 for a missing key/domain; a benign optional read, not a failure.
    let output = InSimulatorToolOutput(stdout: Data(), stderr: Data("does not exist\n".utf8), exitCode: 1)
    let result = try SimulatorDefaults.stdout(orThrowFrom: output, command: .read(domain: "d", key: "missing"), logger: nil)
    #expect(result == "")
  }

  @Test
  func deleteToleratesMissingKeyNonZeroExit() throws {
    let output = InSimulatorToolOutput(stdout: Data(), stderr: Data("does not exist\n".utf8), exitCode: 1)
    let result = try SimulatorDefaults.stdout(orThrowFrom: output, command: .delete(domainOrPath: "p", key: "k"), logger: nil)
    #expect(result == "")
  }

  @Test
  func writeThrowsOnNonZeroExit() throws {
    let output = InSimulatorToolOutput(stdout: Data(), stderr: Data("bad type\n".utf8), exitCode: 1)
    let error = try #require(#expect(throws: (any Error).self) { try SimulatorDefaults.stdout(orThrowFrom: output, command: .write(domain: "d", key: "k", type: "string", value: "v"), logger: nil) })
    #expect(String(describing: error).contains("exit code 1"), "got: \(String(describing: error))")
    #expect(String(describing: error).contains("bad type"), "got: \(String(describing: error))")
  }
}
