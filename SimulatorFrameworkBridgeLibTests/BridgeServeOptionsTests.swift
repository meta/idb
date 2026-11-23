/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import SimulatorFrameworkBridgeSupport
import Testing

@Suite
struct BridgeServeOptionsTests {

  @Test
  func serveBacklogAccommodatesConcurrentProbes() {
    // A full backlog can reject a probe with ECONNREFUSED, which is indistinguishable from no listener.
    // Leave room for competing hosts to connect and learn that the single-threaded guest is busy.
    #expect(BridgeServer.serveBacklog == 16)
  }

  @Test
  func exitOnDisconnectIsOffUnlessAsked() {
    #expect(!BridgeServeOptions.exitOnDisconnect(arguments: []))
    #expect(!BridgeServeOptions.exitOnDisconnect(arguments: ["--idle-timeout", "30"]))
  }

  @Test
  func exitOnDisconnectIsHonouredWhenAsked() {
    #expect(BridgeServeOptions.exitOnDisconnect(arguments: ["--exit-on-disconnect", "1"]))
    #expect(BridgeServeOptions.exitOnDisconnect(arguments: ["--idle-timeout", "30", "--exit-on-disconnect", "1"]))
  }

  @Test
  func exitOnDisconnectCanBeTurnedOffExplicitly() {
    #expect(!BridgeServeOptions.exitOnDisconnect(arguments: ["--exit-on-disconnect", "0"]))
  }

  @Test
  func anIdleTimeoutOnTheCommandLineIsHonoured() {
    #expect(BridgeServeOptions.idleTimeout(arguments: ["--idle-timeout", "45"], fallback: 300) == 45)
  }

  @Test
  func aServeWithNoIdleTimeoutUsesTheDefault() {
    #expect(BridgeServeOptions.idleTimeout(arguments: [], fallback: 300) == 300)
    #expect(BridgeServeOptions.idleTimeout(arguments: ["--something-else", "1"], fallback: 300) == 300)
    #expect(BridgeServer.defaultIdleTimeoutSeconds == 300)
  }

  @Test
  func anUnusableIdleTimeoutFallsBackToTheDefault() {
    #expect(BridgeServeOptions.idleTimeout(arguments: ["--idle-timeout", "0"], fallback: 300) == 300)
    #expect(BridgeServeOptions.idleTimeout(arguments: ["--idle-timeout", "-5"], fallback: 300) == 300)
    #expect(BridgeServeOptions.idleTimeout(arguments: ["--idle-timeout", "soon"], fallback: 300) == 300)
    #expect(BridgeServeOptions.idleTimeout(arguments: ["--idle-timeout", "12x"], fallback: 300) == 300)
    #expect(BridgeServeOptions.idleTimeout(arguments: ["--idle-timeout"], fallback: 300) == 300)
  }

  @Test
  func serveOptionsUseFirstDuplicateEvenWhenInvalid() {
    #expect(BridgeServeOptions.idleTimeout(arguments: ["--idle-timeout", "bad", "--idle-timeout", "45"], fallback: 300) == 300)
    #expect(BridgeServeOptions.idleTimeout(arguments: ["--idle-timeout", "45", "--idle-timeout", "90"], fallback: 300) == 45)
    #expect(!BridgeServeOptions.exitOnDisconnect(arguments: ["--exit-on-disconnect", "0", "--exit-on-disconnect", "1"]))
    #expect(BridgeServeOptions.exitOnDisconnect(arguments: ["--exit-on-disconnect", "YES"]))
    #expect(!BridgeServeOptions.exitOnDisconnect(arguments: ["--exit-on-disconnect"]))
  }

  @Test
  func serveTimeoutKeepsScannerWhitespaceAndSignHandling() {
    #expect(BridgeServeOptions.idleTimeout(arguments: ["--idle-timeout", "  +45"], fallback: 300) == 45)
    #expect(BridgeServeOptions.idleTimeout(arguments: ["--idle-timeout", "45tail"], fallback: 300) == 300)
  }

  @Test
  func startupTimeoutIsOptionalAndUsesServeOptionParsing() {
    #expect(BridgeServeOptions.startupTimeout(arguments: []) == nil)
    for value in ["0", "-1", "bad", "12tail"] {
      #expect(BridgeServeOptions.startupTimeout(arguments: ["--startup-timeout", value]) == nil)
    }
    #expect(BridgeServeOptions.startupTimeout(arguments: ["--startup-timeout"]) == nil)
    #expect(BridgeServeOptions.startupTimeout(arguments: ["--startup-timeout", "bad", "--startup-timeout", "10"]) == nil)
    #expect(BridgeServeOptions.startupTimeout(arguments: ["--startup-timeout", "  +10", "--startup-timeout", "20"]) == 10)
    #expect(BridgeServeOptions.startupTimeout(arguments: ["--startup-timeout", String(Int32.max)]) == Int32.max)
  }
}
