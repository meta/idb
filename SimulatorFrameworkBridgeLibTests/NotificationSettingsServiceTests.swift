/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
import SimulatorFrameworkBridgeSupport
import XCTest

final class NotificationSettingsServiceTests: XCTestCase {
  var gateway = FakeNotificationSettingsGateway()

  override func setUp() {
    super.setUp()
    XCTAssertNotEqual(
      dlopen("/System/Library/PrivateFrameworks/BulletinBoard.framework/BulletinBoard", RTLD_NOW),
      nil
    )
    gateway = FakeNotificationSettingsGateway()
  }

  private func runCommand(_ action: String?, _ bundleID: String?) -> [String: Any] {
    var status = -1
    let output = FBStdoutWhileRunning {
      status = NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: action, bundleID: bundleID, gateway: gateway)
    }
    return ["status": status, "output": output]
  }

  func testApproveSetsAuthorizedState() {
    let bundleID = "com.example.test.approve"

    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)

    let sectionInfo = gateway.sectionInfo(forSectionID: bundleID)
    XCTAssertNotNil(sectionInfo)
    XCTAssertTrue(FBNotificationAllowsNotifications(sectionInfo))
    XCTAssertEqual(FBNotificationAuthorizationStatus(sectionInfo), 2)
  }

  func testApproveMakesNotificationsRetainable() {
    // The effective flags, as distinct from the user-preference settings above.
    // BulletinBoard honours these when deciding whether to keep a delivered notification, so
    // approving without them leaves an app that shows a banner and retains nothing.
    let bundleID = "com.example.test.retention"

    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)

    let sectionInfo = gateway.sectionInfo(forSectionID: bundleID)
    XCTAssertTrue(FBNotificationShowsInNotificationCenter(sectionInfo))
    XCTAssertTrue(FBNotificationShowsInLockScreen(sectionInfo))
  }

  func testRevokeLeavesTheEffectiveFlagsForTheNextGrantToOwn() {
    // Measured on iOS 26.2: a system grant writes the authorization but not these flags, so a
    // revoke that cleared them would outlive itself -- the app comes back authorized from the
    // normal prompt with retention still off, which is the state this service exists to
    // prevent. Revoke resets the authorization; what a re-granted app retains is the grant's
    // to decide.
    let bundleID = "com.example.test.retention.revoke"
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)

    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "revoke", bundleID: bundleID, gateway: gateway), 0)

    let sectionInfo = gateway.sectionInfo(forSectionID: bundleID)
    XCTAssertFalse(FBNotificationAllowsNotifications(sectionInfo))
    XCTAssertEqual(FBNotificationAuthorizationStatus(sectionInfo), 0)
    XCTAssertTrue(FBNotificationShowsInNotificationCenter(sectionInfo))
    XCTAssertTrue(FBNotificationShowsInLockScreen(sectionInfo))
  }

  func testApproveStillAuthorizesWhenTheRuntimeHasNoEffectiveFlags() {
    // Whether the flags exist is a property of the runtime, not of the request. Refusing here
    // would take away the authorization approve used to grant on such a runtime, rather than
    // adding the retention it cannot; the app is authorized and `check` reports the flags as
    // unknown.
    let bundleID = "com.example.test.retention.absent"
    let section = FBSectionInfoWithoutEffectiveFlags()
    gateway.setSectionInfo(section, forSectionID: bundleID)

    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)

    XCTAssertTrue(section.allowsNotifications)
    XCTAssertEqual(section.authorizationStatus, 2)
    XCTAssertEqual(section.alertType, 1)
    XCTAssertEqual(section.lockScreenSetting, 1)
    XCTAssertEqual(section.notificationCenterSetting, 1)
  }

  func testApproveWritesTheEffectiveFlagThisRuntimeHas() {
    // The two flags are independent capabilities. Probing them together would write neither on
    // a runtime carrying one, turning off the retention this can configure there -- and `check`
    // reads them separately, so it would then report `false` for a flag approve never wrote.
    let bundleID = "com.example.test.retention.partial"
    let section = FBSectionInfoWithOnlyNotificationCenterFlag()
    gateway.setSectionInfo(section, forSectionID: bundleID)

    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)

    XCTAssertTrue(section.showsInNotificationCenter)
    XCTAssertTrue(section.allowsNotifications)
    XCTAssertEqual(section.authorizationStatus, 2)
  }

  func testCheckAgreesWithApproveOnARuntimeCarryingOneFlag() {
    // The read and the write have to classify the same runtime the same way: the flag that
    // exists reads back as the `true` approve wrote, and the absent one as `null` rather than
    // as a `false` that would say the app is configured to retain nothing.
    let bundleID = "com.example.test.retention.partial.check"
    gateway.setSectionInfo(FBSectionInfoWithOnlyNotificationCenterFlag(), forSectionID: bundleID)
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)
    var result = -1

    let output = FBStdoutWhileRunning {
      result = NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "check", bundleID: bundleID, gateway: self.gateway)
    }

    XCTAssertEqual(result, 0)
    let printed = FBParsedJSONLine(output)
    XCTAssertEqual(printed?["showsInNotificationCenter"] as? Bool, true)
    XCTAssertTrue(printed?["showsInLockScreen"] is NSNull)
  }

  func testStdoutCaptureOutlivesAPipeBufferOfOutput() {
    // The capture drains while the block runs. Draining only afterwards deadlocks the whole
    // test process once a block prints more than a pipe holds, which the services this helper
    // is shared with can: a listing prints a record per section.
    let line = String(repeating: "x", count: 1024)
    let expected = 256 // 256 KiB, past any Darwin pipe buffer

    let output = FBStdoutWhileRunning {
      for _ in 0..<expected {
        // `fputs` rather than `print`: the capture exists to read what the services write to
        // stdout, and they write with `printf`. A logger would not reach the pipe under test.
        fputs(line + "\n", stdout)
      }
    }

    XCTAssertEqual(output.count, expected * (line.count + 1))
  }

  func testRevokeSucceedsWhenTheRuntimeHasNoEffectiveFlags() {
    let bundleID = "com.example.test.retention.absent.revoke"
    let section = FBSectionInfoWithoutEffectiveFlags()
    section.allowsNotifications = true
    section.authorizationStatus = 2
    gateway.setSectionInfo(section, forSectionID: bundleID)

    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "revoke", bundleID: bundleID, gateway: gateway), 0)

    XCTAssertFalse(section.allowsNotifications)
    XCTAssertEqual(section.authorizationStatus, 0)
  }

  func testCheckReportsTheEffectiveFlagsApproveWrote() {
    // Approve writes the two together, so a check that reported one of them could not say
    // whether the app will retain what it is shown.
    let bundleID = "com.example.test.retention.check"
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)
    var result = -1

    let output = FBStdoutWhileRunning {
      result = NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "check", bundleID: bundleID, gateway: self.gateway)
    }

    XCTAssertEqual(result, 0)
    let printed = FBParsedJSONLine(output)
    XCTAssertEqual(printed?["showsInNotificationCenter"] as? Bool, true)
    XCTAssertEqual(printed?["showsInLockScreen"] as? Bool, true)
  }

  func testCheckReadsASectionWithoutTheEffectiveFlags() {
    // Reading either flag unconditionally would raise rather than report it as unknown, and
    // `false` would say the app is configured to retain nothing rather than that this runtime
    // cannot answer.
    let bundleID = "com.example.test.retention.absent.check"
    gateway.setSectionInfo(FBSectionInfoWithoutEffectiveFlags(), forSectionID: bundleID)
    var result = -1

    let output = FBStdoutWhileRunning {
      result = NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "check", bundleID: bundleID, gateway: self.gateway)
    }

    XCTAssertEqual(result, 0)
    let printed = FBParsedJSONLine(output)
    XCTAssertTrue(printed?["showsInNotificationCenter"] is NSNull)
    XCTAssertTrue(printed?["showsInLockScreen"] is NSNull)
  }

  func testRevokeResetsExistingSection() {
    let bundleID = "com.example.test.revoke"
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)

    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "revoke", bundleID: bundleID, gateway: gateway), 0)

    let sectionInfo = gateway.sectionInfo(forSectionID: bundleID)
    XCTAssertNotNil(sectionInfo)
    XCTAssertFalse(FBNotificationAllowsNotifications(sectionInfo))
    XCTAssertEqual(FBNotificationAuthorizationStatus(sectionInfo), 0)
  }

  func testRevokeWithoutAnExistingSectionSucceeds() {
    let bundleID = "com.example.test." + UUID().uuidString

    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "revoke", bundleID: bundleID, gateway: gateway), 0)
    XCTAssertNil(gateway.sectionInfo(forSectionID: bundleID))
  }

  func testRevokeWithoutABundleIDReturnsFailure() {
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "revoke", bundleID: nil, gateway: gateway), 1)
  }

  func testCheckSucceeds() {
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "check", bundleID: "com.example.test", gateway: gateway), 0)
  }

  func testListWithoutABundleIDSucceeds() {
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "list", bundleID: nil, gateway: gateway), 0)
  }

  func testUnknownActionReturnsFailure() {
    XCTAssertEqual(
      NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "unknown", bundleID: "com.example.test", gateway: gateway),
      1
    )
  }

  func testApproveCreatedSectionSetsAllFieldsAndWritesOnce() throws {
    let bundleID = "com.example.created"
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)
    let section = try XCTUnwrap(gateway.sectionInfo(forSectionID: bundleID))
    XCTAssertEqual(
      FBNotificationSectionSnapshot(section) as NSDictionary,
      [
        "sectionID": bundleID, "allowsNotifications": true, "authorizationStatus": 2,
        "alertType": 1, "lockScreenSetting": 2, "notificationCenterSetting": 2,
      ] as NSDictionary)
    XCTAssertEqual(gateway.writtenSectionIDs as NSArray, [bundleID] as NSArray)
  }

  func testApproveExistingSectionUpdatesTheSameObject() throws {
    let bundleID = "com.example.existing"
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)
    let section = try XCTUnwrap(gateway.sectionInfo(forSectionID: bundleID) as AnyObject?)
    FBNotificationSetPresentation(section, 2, 0, 0)
    gateway.writtenSectionIDs.removeAllObjects()
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)
    XCTAssertTrue(gateway.sectionInfo(forSectionID: bundleID) as AnyObject? === section)
    XCTAssertEqual(
      FBNotificationSectionSnapshot(section) as NSDictionary,
      [
        "sectionID": bundleID, "allowsNotifications": true, "authorizationStatus": 2,
        "alertType": 1, "lockScreenSetting": 2, "notificationCenterSetting": 2,
      ] as NSDictionary)
    XCTAssertEqual(gateway.writtenSectionIDs as NSArray, [bundleID] as NSArray)
  }

  func testRevokePreservesPresentationFields() throws {
    let bundleID = "com.example.presentation"
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)
    let section = try XCTUnwrap(gateway.sectionInfo(forSectionID: bundleID))
    FBNotificationSetPresentation(section, 2, 0, 1)
    gateway.writtenSectionIDs.removeAllObjects()
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "revoke", bundleID: bundleID, gateway: gateway), 0)
    XCTAssertEqual(
      FBNotificationSectionSnapshot(section) as NSDictionary,
      [
        "sectionID": bundleID, "allowsNotifications": false, "authorizationStatus": 0,
        "alertType": 2, "lockScreenSetting": 0, "notificationCenterSetting": 1,
      ] as NSDictionary)
    XCTAssertEqual(gateway.writtenSectionIDs as NSArray, [bundleID] as NSArray)
  }

  func testCheckPrintsExactMissingAndExistingSectionOutput() {
    let bundleID = "com.example.output"
    XCTAssertEqual(
      runCommand("check", bundleID) as NSDictionary,
      [
        "status": 0, "output": "{\"bundleID\":\"com.example.output\",\"found\":false}\n",
      ] as NSDictionary)
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)
    gateway.writtenSectionIDs.removeAllObjects()
    let expected: NSDictionary = [
      "status": 0,
      "output": "{\"bundleID\":\"com.example.output\",\"found\":true,\"allowsNotifications\":true,\"authorizationStatus\":2,\"showsInNotificationCenter\":true,\"showsInLockScreen\":true}\n",
    ]
    XCTAssertEqual(runCommand("check", bundleID) as NSDictionary, expected)
    XCTAssertEqual(runCommand("list", bundleID) as NSDictionary, expected)
    XCTAssertEqual(gateway.writtenSectionIDs.count, 0)
  }

  func testListAndCheckWithoutBundlePrintEverySection() throws {
    for bundleID in ["com.example.a", "com.example.b"] {
      XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: bundleID, gateway: gateway), 0)
    }
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "revoke", bundleID: "com.example.b", gateway: gateway), 0)
    gateway.writtenSectionIDs.removeAllObjects()
    for action in ["list", "check"] {
      let result = runCommand(action, nil)
      XCTAssertEqual(result["status"] as? NSNumber, 0)
      let output = try XCTUnwrap(result["output"] as? String)
      XCTAssertTrue(output.hasSuffix("\n"))
      XCTAssertEqual(
        output.split(separator: "\n").map(String.init).sorted(),
        [
          "{\"bundleID\":\"com.example.a\",\"found\":true,\"allowsNotifications\":true,\"authorizationStatus\":2,\"showsInNotificationCenter\":true,\"showsInLockScreen\":true}",
          "{\"bundleID\":\"com.example.b\",\"found\":true,\"allowsNotifications\":false,\"authorizationStatus\":0,\"showsInNotificationCenter\":true,\"showsInLockScreen\":true}",
        ])
    }
    XCTAssertEqual(gateway.writtenSectionIDs.count, 0)
  }

  func testRejectedAndMissingSectionMutationsDoNotWrite() {
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: nil, gateway: gateway), 1)
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "revoke", bundleID: nil, gateway: gateway), 1)
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "unknown", bundleID: "com.example.missing", gateway: gateway), 1)
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "revoke", bundleID: "com.example.missing", gateway: gateway), 0)
    XCTAssertEqual(gateway.writtenSectionIDs.count, 0)
    XCTAssertEqual(gateway.allSectionIDs(), [])
  }

  func testNilActionFailsWithoutWritingOrPrinting() {
    XCTAssertEqual(
      runCommand(nil, "com.example.missing") as NSDictionary,
      ["status": 1, "output": ""] as NSDictionary)
    XCTAssertEqual(gateway.writtenSectionIDs.count, 0)
    XCTAssertEqual(gateway.allSectionIDs(), [])
  }
}
