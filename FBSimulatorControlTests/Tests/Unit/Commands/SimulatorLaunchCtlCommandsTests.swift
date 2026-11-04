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
struct SimulatorLaunchCtlCommandsTests {

  @Test
  func listReturnsStdoutOnZeroExit() throws {
    let output = InSimulatorToolOutput(stdout: Data("- 0 com.apple.foo\n".utf8), stderr: Data(), exitCode: 0)
    let result = try SimulatorLaunchCtlCommands.stdout(orThrowFrom: output, command: .list, logger: nil)
    #expect(result == "- 0 com.apple.foo\n")
  }

  @Test
  func listThrowsOnNonZeroExit() throws {
    let output = InSimulatorToolOutput(stdout: Data(), stderr: Data("boom\n".utf8), exitCode: 1)
    let error = try #require(
      #expect(throws: (any Error).self) {
        try SimulatorLaunchCtlCommands.stdout(orThrowFrom: output, command: .list, logger: nil)
      })
    #expect(error.localizedDescription.contains("exit code 1"), "got: \(error.localizedDescription)")
  }

  @Test
  func stopToleratesNotRunningExitCode() throws {
    // launchctl returns ESRCH (3) when the service is not running; idempotent, not a failure.
    let output = InSimulatorToolOutput(stdout: Data(), stderr: Data(), exitCode: 3)
    let result = try SimulatorLaunchCtlCommands.stdout(orThrowFrom: output, command: .stop(serviceName: "com.apple.foo"), logger: nil)
    #expect(result == "")
  }

  @Test
  func stopThrowsOnGenuineFailure() throws {
    let output = InSimulatorToolOutput(stdout: Data(), stderr: Data("Operation not permitted\n".utf8), exitCode: 1)
    let error = try #require(
      #expect(throws: (any Error).self) {
        try SimulatorLaunchCtlCommands.stdout(orThrowFrom: output, command: .stop(serviceName: "com.apple.foo"), logger: nil)
      })
    #expect(error.localizedDescription.contains("Operation not permitted"), "got: \(error.localizedDescription)")
  }

  @Test
  func startThrowsOnNotRunningExitCode() throws {
    // Unlike stop, for start ESRCH (3) means there is no such service to start — a genuine failure.
    let output = InSimulatorToolOutput(stdout: Data(), stderr: Data("Could not find service\n".utf8), exitCode: 3)
    let error = try #require(
      #expect(throws: (any Error).self) {
        try SimulatorLaunchCtlCommands.stdout(orThrowFrom: output, command: .start(serviceName: "com.apple.foo"), logger: nil)
      })
    #expect(error.localizedDescription.contains("exit code 3"), "got: \(error.localizedDescription)")
  }

  // MARK: - serviceMap parsing

  // Mirrors `launchctl list`: a header row, a stopped service ("-" pid), a live service, and a
  // malformed line. Tab-separated like the real output (extractServiceName splits on whitespace).
  private static let listOutput = "PID\tStatus\tLabel\n-\t0\tcom.apple.stopped\n4321\t0\tcom.apple.SpringBoard\nnot a valid line\n"

  @Test
  func serviceMapParsesRunningStoppedAndSkipsNoise() {
    let map = SimulatorLaunchCtlCommands.serviceMap(fromListOutput: Self.listOutput)
    #expect(map["com.apple.SpringBoard"] == 4321, "a live service maps to its pid")
    #expect(map["com.apple.stopped"] == -1, "a loaded-but-stopped service maps to -1")
    #expect(map["Label"] == nil, "the header row is skipped")
    #expect(map["line"] == nil, "malformed (non-three-column) lines are skipped")
  }

  @Test
  func listedServicesKeepAStoppedServiceAsANilPid() {
    let services = SimulatorLaunchCtlCommands.services(fromListOutput: Self.listOutput)
    #expect(services.count == 2)
    #expect(services["com.apple.SpringBoard"] == .some(4321))
    #expect(services["com.apple.stopped"] == .some(nil), "a stopped service is present with no pid")
  }

  // MARK: - Liveness queries (default protocol implementations over listServices())

  @Test
  func serviceIsRunningReflectsLivePid() async throws {
    let launchCtl = LaunchCtlDouble.with(running: ["com.apple.SpringBoard": 4321], stopped: ["com.apple.idle"])
    let running = try await launchCtl.serviceIsRunning(named: "com.apple.SpringBoard")
    let stopped = try await launchCtl.serviceIsRunning(named: "com.apple.idle")
    let absent = try await launchCtl.serviceIsRunning(named: "com.apple.absent")
    #expect(running)
    #expect(!stopped, "a loaded-but-stopped service is not running")
    #expect(!absent, "an absent service is not running")
  }

  @Test
  func processIsRunningReflectsLivePid() async throws {
    let launchCtl = LaunchCtlDouble.with(running: ["com.apple.SpringBoard": 4321])
    let livePidRunning = try await launchCtl.processIsRunning(processIdentifier: 4321)
    let absentPidRunning = try await launchCtl.processIsRunning(processIdentifier: 9999)
    #expect(livePidRunning)
    #expect(!absentPidRunning, "an unregistered pid is not running")
  }

  // MARK: - runningServices(matchingBundleID:) fallback for remote sheets

  @Test
  func runningServicesMatchesBareServiceLabel() {
    let services: [String: pid_t?] = ["com.apple.SafariViewService": 1234]
    let matches = SimulatorLaunchCtlCommands.runningServices(matchingBundleID: "com.apple.SafariViewService", in: services)
    #expect(matches == ["com.apple.SafariViewService": 1234])
  }

  @Test
  func runningServicesMatchesUIKitApplicationLabel() {
    let services: [String: pid_t?] = ["UIKitApplication:com.apple.SafariViewService[0x1234]": 1234]
    let matches = SimulatorLaunchCtlCommands.runningServices(matchingBundleID: "com.apple.SafariViewService", in: services)
    #expect(matches.count == 1)
    #expect(matches.values.first == 1234)
  }

  @Test
  func runningServicesSkipsStoppedAndUnrelatedServices() {
    let services: [String: pid_t?] = [
      "com.apple.SafariViewService": nil,
      "UIKitApplication:com.hackbook[0x1]": 111,
      "com.apple.mobilesafari": 222,
    ]
    let matches = SimulatorLaunchCtlCommands.runningServices(matchingBundleID: "com.apple.SafariViewService", in: services)
    #expect(matches.isEmpty, "a stopped service and unrelated labels are not matches")
  }

  @Test
  func runningServicesMatchesBracketSuffixedBareLabel() {
    let services: [String: pid_t?] = ["com.apple.SafariViewService[0x1234]": 1234]
    let matches = SimulatorLaunchCtlCommands.runningServices(matchingBundleID: "com.apple.SafariViewService", in: services)
    #expect(matches.count == 1)
    #expect(matches.values.first == 1234)
  }

  @Test
  func runningServicesIgnoresLongerSiblingLabels() {
    // Regression for test_ui_human's XCTestProbeUITests/testTargetInteraction:
    // the probe target is absent, but the runner and a helper share its
    // identifier as a prefix. Resolving either as the target hands launch
    // handling the wrong process.
    let services: [String: pid_t?] = [
      "UIKitApplication:com.facebook.idb.xctestprobe.xctrunner[0x1]": 4321,
      "com.facebook.idb.xctestprobe.helper": 5678,
    ]
    let matches = SimulatorLaunchCtlCommands.runningServices(matchingBundleID: "com.facebook.idb.xctestprobe", in: services)
    #expect(matches.isEmpty, "dotted siblings are different services, not matches")
  }

  @Test
  func runningServicesKeepsGenuinelyAmbiguousWholeMatches() {
    let services: [String: pid_t?] = [
      "com.apple.SafariViewService": 1234,
      "UIKitApplication:com.apple.SafariViewService[0x1]": 5678,
    ]
    let matches = SimulatorLaunchCtlCommands.runningServices(matchingBundleID: "com.apple.SafariViewService", in: services)
    #expect(matches.count == 2)
    #expect(matches["com.apple.SafariViewService"] == 1234)
    #expect(matches["UIKitApplication:com.apple.SafariViewService[0x1]"] == 5678)
  }
}
