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
    defer { device.removeDataDirectory() }
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)

    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")

    #expect(device.spawnedArguments == [["/usr/bin/defaults", "write", Self.schemeApprovalDomain, Self.schemeApprovalKey, "-string", "com.test"]])
  }

  @Test
  func repeatingAnApprovalWritesItOnce() async throws {
    let device = SchemeApprovalDevice(state: .booted)
    defer { device.removeDataDirectory() }
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)

    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")
    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")

    #expect(device.writes == 1, "lsd was told about the first write, and the plist has not changed since")
  }

  @Test
  func onlyTheLastWriteIsSkipped() async throws {
    let device = SchemeApprovalDevice(state: .booted)
    defer { device.removeDataDirectory() }
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)

    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")
    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "otherapp")
    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")
    try await simulator.privacy.grantAccess(["com.other"], toDeeplink: "myapp")

    #expect(device.writes == 4)
  }

  @Test
  func aPlistReplacedBeforeTheWriteIsRecordedDoesNotStandForIt() async throws {
    let device = SchemeApprovalDevice(state: .booted)
    defer { device.removeDataDirectory() }
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)
    // Between the daemon finishing the write and the companion recording it, something replaces the plist with
    // another app's approval without telling the daemon, so lsd still holds com.test.
    device.afterNextWrite = { $0.replacePlist(with: [Self.schemeApprovalKey: "com.other"]) }

    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")
    try await simulator.privacy.grantAccess(["com.other"], toDeeplink: "myapp")

    #expect(device.writes == 2, "The replaced plist names com.other, but lsd was never told")
  }

  @Test
  func aPlistReplacedBeforeTheWriteIsRecordedWithTheSameApprovalStillCounts() async throws {
    let device = SchemeApprovalDevice(state: .booted)
    defer { device.removeDataDirectory() }
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)
    device.afterNextWrite = { $0.replacePlist(with: [Self.schemeApprovalKey: "com.test"]) }

    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")
    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")

    #expect(device.writes == 1, "lsd holds com.test from the write, and the file read afterwards names it")
  }

  @Test
  func anApprovalIsWrittenAgainAfterSomethingElseRewritesThePlist() async throws {
    let device = SchemeApprovalDevice(state: .booted)
    defer { device.removeDataDirectory() }
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)

    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")
    device.replacePlist(with: [:])
    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")
    device.replacePlist(with: [Self.schemeApprovalKey: "com.test"])
    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")

    #expect(device.writes == 3, "A revoke from elsewhere, or an edit lsd may not have been told about, is written over")
  }

  @Test
  func anApprovalInThePlistThatThisProcessDidNotWriteIsWritten() async throws {
    let device = SchemeApprovalDevice(state: .booted)
    defer { device.removeDataDirectory() }
    device.replacePlist(with: [Self.schemeApprovalKey: "com.test"])
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)

    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")

    #expect(device.writes == 1, "Something may have put it in the plist without telling lsd")
  }

  @Test
  func aFailedRevokeMakesTheNextApprovalWrite() async throws {
    let device = SchemeApprovalDevice(state: .booted, deletesFail: true)
    defer { device.removeDataDirectory() }
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: device)

    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")
    await #expect(throws: (any Error).self) { try await simulator.privacy.revokeAccess(["com.test"], toDeeplink: "myapp") }
    try await simulator.privacy.grantAccess(["com.test"], toDeeplink: "myapp")

    #expect(device.writes == 2, "After a revoke this process cannot vouch for what lsd holds")
  }

  @Test
  func revokingOnABootedSimulatorDeletesThroughItsPreferencesAndConfirmsTheKeyIsGone() async throws {
    let device = SchemeApprovalDevice(state: .booted)
    defer { device.removeDataDirectory() }
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
    let device = SchemeApprovalDevice(state: .booted, deletesFail: true)
    defer { device.removeDataDirectory() }
    device.replacePlist(with: [Self.schemeApprovalKey: "com.test"])
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

/// A Simulator in a given state with a data directory of its own. Tools it is asked to spawn are recorded rather than run,
/// and it stands in for the preferences daemon: a `defaults write` or `delete` replaces the scheme approval plist, unless
/// `deletesFail`, and a `defaults read` answers from it. Its runtime root is the host's, so the runtime's `defaults`
/// resolves to `/usr/bin/defaults`, which is validated but never run.
private final class SchemeApprovalDevice: @unchecked Sendable {
  @objc(UDID) let udid = NSUUID()
  @objc let state: UInt64
  @objc let runtime = HostRuntime()
  let dataDirectory = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
  private let deletesFail: Bool
  private(set) var spawnedArguments: [[String]] = []
  /// Runs once, after the next `defaults write` has replaced the plist and before the tool exits.
  var afterNextWrite: ((SchemeApprovalDevice) -> Void)?

  init(state: TargetState, deletesFail: Bool = false) {
    self.state = UInt64(state.rawValue)
    self.deletesFail = deletesFail
  }

  var schemeApprovalPlist: String {
    (dataDirectory as NSString).appendingPathComponent("Library/Preferences/com.apple.launchservices.schemeapproval.plist")
  }

  /// The `defaults write`s spawned so far.
  var writes: Int {
    spawnedArguments.filter { $0.dropFirst().first == "write" }.count
  }

  /// Replaces the plist with a new file holding `approvals`.
  func replacePlist(with approvals: [String: String]) {
    try? FileManager.default.createDirectory(
      atPath: (schemeApprovalPlist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    (approvals as NSDictionary).write(toFile: schemeApprovalPlist, atomically: true)
  }

  func removeDataDirectory() {
    try? FileManager.default.removeItem(atPath: dataDirectory)
  }

  @objc func dataPath() -> String {
    dataDirectory
  }

  @objc(spawnAsyncWithPath:options:terminationQueue:terminationHandler:completionQueue:completionHandler:)
  func spawnAsync(
    withPath path: String,
    options: [String: Any],
    terminationQueue: DispatchQueue,
    terminationHandler: @escaping @Sendable (Int32) -> Void,
    completionQueue: DispatchQueue,
    completionHandler: @escaping @Sendable (NSError?, pid_t) -> Void
  ) {
    let arguments = options["arguments"] as? [String] ?? []
    spawnedArguments.append(arguments)
    let command = Array(arguments.dropFirst())
    var approvals = NSDictionary(contentsOfFile: schemeApprovalPlist) as? [String: String] ?? [:]
    var output = ""
    switch command.first {
    case "write" where command.count == 5:
      approvals[command[2]] = command[4]
      replacePlist(with: approvals)
      let afterWrite = afterNextWrite
      afterNextWrite = nil
      afterWrite?(self)
    case "delete" where command.count == 3 && !deletesFail:
      approvals[command[2]] = nil
      replacePlist(with: approvals)
    case "read" where command.count == 3:
      output = approvals[command[2]].map { "\($0)\n" } ?? ""
    default:
      break
    }
    if let fileDescriptor = (options["stdout"] as? NSNumber)?.int32Value {
      Data(output.utf8).withUnsafeBytes { _ = write(fileDescriptor, $0.baseAddress, $0.count) }
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
