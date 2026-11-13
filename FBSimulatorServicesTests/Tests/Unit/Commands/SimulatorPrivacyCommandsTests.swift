/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorControl
@testable import FBSimulatorServices
import Foundation
import Testing

@Suite
struct SimulatorPrivacyCommandsTests {

  // MARK: - Helpers

  private func makeSimulator() -> Simulator {
    SimulatorTestSupport.testableSimulator()
  }

  private func assertThrowsAsync(
    _ message: String,
    _ expression: () async throws -> Void,
    expecting isExpected: (SimulatorPrivacyError) -> Bool
  ) async {
    do {
      try await expression()
      Issue.record(Comment(rawValue: message))
    } catch let error as SimulatorPrivacyError where isExpected(error) {
      // Expected.
    } catch {
      Issue.record("\(message); threw \(error)")
    }
  }

  // MARK: - Magic Deeplink Key

  @Test
  func magicDeeplinkKeyFormatsCorrectly() {
    let key = SimulatorPrivacyCommands.magicDeeplinkKey(forScheme: "myapp")
    #expect(key == "com.apple.CoreSimulator.CoreSimulatorBridge-->myapp", "Deeplink key should use CoreSimulatorBridge prefix with --> separator")
  }

  // MARK: - Grant/Revoke Access Input Validation

  @Test
  func grantAccessRejectsEmptyServices() async {
    let simulator = makeSimulator()
    await assertThrowsAsync(
      "grantAccess should reject empty services set",
      {
        try await simulator.privacy.grantAccess(["com.test"], toServices: [])
      }
    ) { if case .noServicesToGrant = $0 { return true } else { return false } }
  }

  @Test
  func grantAccessRejectsEmptyBundleIDs() async {
    let simulator = makeSimulator()
    await assertThrowsAsync(
      "grantAccess should reject empty bundle IDs set",
      {
        try await simulator.privacy.grantAccess([], toServices: [.contacts])
      }
    ) { if case .noBundleIDsToGrant = $0 { return true } else { return false } }
  }

  @Test
  func revokeAccessRejectsEmptyServices() async {
    let simulator = makeSimulator()
    await assertThrowsAsync(
      "revokeAccess should reject empty services set",
      {
        try await simulator.privacy.revokeAccess(["com.test"], toServices: [])
      }
    ) { if case .noServicesToRevoke = $0 { return true } else { return false } }
  }

  @Test
  func revokeAccessRejectsEmptyBundleIDs() async {
    let simulator = makeSimulator()
    await assertThrowsAsync(
      "revokeAccess should reject empty bundle IDs set",
      {
        try await simulator.privacy.revokeAccess([], toServices: [.contacts])
      }
    ) { if case .noBundleIDsToRevoke = $0 { return true } else { return false } }
  }

  // MARK: - Deeplink Access Validation

  @Test
  func grantDeeplinkRejectsEmptyScheme() async {
    let simulator = makeSimulator()
    await assertThrowsAsync(
      "grantAccess(toDeeplink:) should reject empty scheme",
      {
        try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "")
      }
    ) { if case .emptyScheme = $0 { return true } else { return false } }
  }

  @Test
  func grantDeeplinkRejectsEmptyBundleIDs() async {
    let simulator = makeSimulator()
    await assertThrowsAsync(
      "grantAccess(toDeeplink:) should reject empty bundle IDs",
      {
        try await simulator.privacy.grantAccess([], toDeeplink: "myapp")
      }
    ) { if case .emptyBundleIDs = $0 { return true } else { return false } }
  }

  @Test
  func revokeDeeplinkRejectsEmptyScheme() async {
    let simulator = makeSimulator()
    await assertThrowsAsync(
      "revokeAccess(toDeeplink:) should reject empty scheme",
      {
        try await simulator.privacy.revokeAccess(["com.test"], toDeeplink: "")
      }
    ) { if case .emptyScheme = $0 { return true } else { return false } }
  }

  @Test
  func revokeDeeplinkRejectsEmptyBundleIDs() async {
    let simulator = makeSimulator()
    await assertThrowsAsync(
      "revokeAccess(toDeeplink:) should reject empty bundle IDs",
      {
        try await simulator.privacy.revokeAccess([], toDeeplink: "myapp")
      }
    ) { if case .emptyBundleIDs = $0 { return true } else { return false } }
  }

  // MARK: - Deeplink Approval Store

  private static let schemeApprovalDomain = "com.apple.launchservices.schemeapproval"
  private static let schemeApprovalKey = "com.apple.CoreSimulator.CoreSimulatorBridge-->myapp"

  @Test
  func approvingOnABootedSimulatorWritesThroughItsPreferences() async throws {
    let device = SchemeApprovalDevice(state: .booted)
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)

    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")

    #expect(device.spawnedArguments == [["/usr/bin/defaults", "write", Self.schemeApprovalDomain, Self.schemeApprovalKey, "-string", "com.test"]])
    #expect(!FileManager.default.fileExists(atPath: device.schemeApprovalPlist), "lsd never sees a plist rewritten underneath its preferences")
  }

  @Test
  func revokingOnABootedSimulatorDeletesThroughItsPreferencesAndConfirmsTheKeyIsGone() async throws {
    let device = SchemeApprovalDevice(state: .booted)
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)

    try await simulator.privacy.revokeAccess(["com.test"], toDeeplink: "myapp")

    #expect(
      device.spawnedArguments == [
        ["/usr/bin/defaults", "delete", Self.schemeApprovalDomain, Self.schemeApprovalKey],
        ["/usr/bin/defaults", "read", Self.schemeApprovalDomain, Self.schemeApprovalKey],
      ])
  }

  @Test
  func revokingOnABootedSimulatorFailsWhenTheApprovalCanStillBeRead() async {
    let device = SchemeApprovalDevice(state: .booted, readOutput: "com.test\n")
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)

    do {
      try await simulator.privacy.revokeAccess(["com.test"], toDeeplink: "myapp")
      Issue.record("A revoke that left the approval readable reported success")
    } catch {
      #expect(error.localizedDescription.contains("still reads com.test"), "got: \(error.localizedDescription)")
    }
  }

  @Test
  func approvingAndRevokingOnAShutDownSimulatorRewriteThePlist() async throws {
    let device = SchemeApprovalDevice(state: .shutdown)
    defer { try? FileManager.default.removeItem(atPath: device.dataDirectory) }
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)

    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")
    #expect(NSDictionary(contentsOfFile: device.schemeApprovalPlist) as? [String: String] == [Self.schemeApprovalKey: "com.test"])

    try await simulator.privacy.revokeAccess(["com.test"], toDeeplink: "myapp")
    #expect(NSDictionary(contentsOfFile: device.schemeApprovalPlist) as? [String: String] == [:])
    #expect(device.spawnedArguments.isEmpty, "Nothing can run inside a shut-down Simulator")
  }

  @Test
  func deeplinkApprovalsAreRefusedWhileTheSimulatorIsBooting() async {
    let device = SchemeApprovalDevice(state: .booting)
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)

    await assertThrowsAsync(
      "grantAccess(toDeeplink:) should refuse a booting Simulator",
      {
        try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")
      }
    ) { if case .schemeApprovalUnavailable(state: .booting) = $0 { return true } else { return false } }
    await assertThrowsAsync(
      "revokeAccess(toDeeplink:) should refuse a booting Simulator",
      {
        try await simulator.privacy.revokeAccess(["com.test"], toDeeplink: "myapp")
      }
    ) { if case .schemeApprovalUnavailable(state: .booting) = $0 { return true } else { return false } }
    #expect(device.spawnedArguments.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: device.schemeApprovalPlist))
  }

  // MARK: - Guest Invocations

  @Test
  func everyTCCServiceMapsToItsGuestName() {
    let invocations = SimulatorPrivacyCommands.privacyInvocations(
      bundleIDs: ["com.test"],
      services: [.camera, .microphone, .photos, .contacts],
      approve: true)

    #expect(invocations == [.init(action: "approve", arguments: ["com.test", "camera", "contacts", "microphone", "photos"])])
  }

  @Test
  func servicesAreBatchedIntoOneCallPerBundleID() {
    let invocations = SimulatorPrivacyCommands.privacyInvocations(
      bundleIDs: ["com.b", "com.a"],
      services: [.camera, .photos],
      approve: true)

    #expect(
      invocations == [
        .init(action: "approve", arguments: ["com.a", "camera", "photos"]),
        .init(action: "approve", arguments: ["com.b", "camera", "photos"]),
      ],
      "Each bundle id gets one call carrying every service, ordered for a comparable trace")
  }

  @Test
  func revokeUsesTheRevokeAction() {
    let invocations = SimulatorPrivacyCommands.privacyInvocations(
      bundleIDs: ["com.test"],
      services: [.contacts],
      approve: false)

    #expect(invocations == [.init(action: "revoke", arguments: ["com.test", "contacts"])])
  }

  @Test
  func servicesTheGuestDoesNotHandleAreNotSentToIt() {
    let invocations = SimulatorPrivacyCommands.privacyInvocations(
      bundleIDs: ["com.test"],
      services: [.camera, .location],
      approve: true)

    #expect(invocations == [.init(action: "approve", arguments: ["com.test", "camera"])], "Location is routed through CoreSimulator, not the guest")
  }
}

// MARK: - Device double

/// A Simulator in a given state with a data directory of its own, which records the tools it is asked to
/// spawn rather than running them, answering each `defaults read` with `readOutput`. Its runtime root is the
/// host's, so the runtime's `defaults` resolves to `/usr/bin/defaults`, which is validated but never run.
private final class SchemeApprovalDevice: @unchecked Sendable {
  @objc(UDID) let udid = NSUUID()
  @objc let state: UInt64
  @objc let runtime = HostRuntime()
  let dataDirectory = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
  private let readOutput: Data
  private(set) var spawnedArguments: [[String]] = []

  init(state: TargetState, readOutput: String = "") {
    self.state = UInt64(state.rawValue)
    self.readOutput = Data(readOutput.utf8)
  }

  var schemeApprovalPlist: String {
    (dataDirectory as NSString).appendingPathComponent("Library/Preferences/com.apple.launchservices.schemeapproval.plist")
  }

  @objc func dataPath() -> String {
    dataDirectory
  }

  @objc(spawnAsyncWithPath:options:terminationQueue:terminationHandler:completionQueue:completionHandler:)
  func spawnAsync(
    withPath path: String,
    options: [String: Any],
    terminationQueue: DispatchQueue,
    terminationHandler: @escaping (Int32) -> Void,
    completionQueue: DispatchQueue,
    completionHandler: @escaping (NSError?, pid_t) -> Void
  ) {
    let arguments = options["arguments"] as? [String] ?? []
    spawnedArguments.append(arguments)
    if arguments.dropFirst().first == "read", let fileDescriptor = (options["stdout"] as? NSNumber)?.int32Value {
      readOutput.withUnsafeBytes { _ = write(fileDescriptor, $0.baseAddress, $0.count) }
    }
    completionQueue.async {
      completionHandler(nil, 4242)
      terminationQueue.async { terminationHandler(0) }
    }
  }
}

private final class HostRuntime: NSObject {
  @objc let root = "/"
}
