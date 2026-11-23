/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBSimulatorBridgeProtocol
import Foundation
import SimulatorFrameworkBridgeSupport
import UserNotifications
import XCTest

/// Every answer a service other than accessibility sends the host, as the text the host reports for it. The host
/// hands that text on unparsed, as `list` output and in a failure's message, so it is pinned exactly. Health reports
/// whether something succeeded or is allowed as a boolean.
final class ServiceAnswerTests: XCTestCase {
  /// The result `command` answers with, through the frame the host reads it from.
  private func answer(_ command: BridgeCommand, file: StaticString = #filePath, line: UInt = #line) throws -> BridgeResult {
    try answer(command) { BridgeServices.execute(command) }
  }

  private func answer(_ command: BridgeCommand, _ result: () -> BridgeResult) throws -> BridgeResult {
    let request = BridgeRequest(command: command, id: "pinned")
    let produced = result()
    let reply = BridgeRPC.process(try request.encoded()) { _ in produced }
    return try BridgeResponse.decode(reply.data, for: request).result
  }

  private func answer(_ command: BridgeCommand, from output: BridgeOutput, status: Int) throws -> BridgeResult {
    try answer(command) { output.finish(status: Int32(status)) }
  }

  // MARK: - Network

  func testNetworkListsAnswerWithTheStoredConfiguration() throws {
    let runtime = FBNetworkConfigurationTestRuntime()
    runtime.install()
    defer { runtime.uninstall() }
    let cases: [(Any?, String)] = [
      (["ServerAddresses": ["::1", "1.1.1.1"]], #"{"ServerAddresses":["::1","1.1.1.1"]}"# + "\n"),
      (
        ["HTTPEnable": 1, "HTTPProxy": "proxy.example/path", "HTTPPort": 8080, "ExceptionsList": ["*.local"], "FTPPassive": true],
        #"{"ExceptionsList":["*.local"],"FTPPassive":true,"HTTPEnable":1,"HTTPPort":8080,"HTTPProxy":"proxy.example\/path"}"# + "\n"
      ),
      (["SOCKSEnable": 1, "SOCKSProxy": "::1", "SOCKSPort": 1080.5], #"{"SOCKSEnable":1,"SOCKSPort":1080.5,"SOCKSProxy":"::1"}"# + "\n"),
      (nil, "{}\n"),
      (["first", 42] as [Any], #"["first",42]"# + "\n"),
    ]
    for (configuration, expected) in cases {
      runtime.configuration = configuration
      for command: BridgeCommand in [.dns(.list), .proxy(.list)] {
        let result = try answer(command)
        XCTAssertEqual(result.exitCode, 0, "\(command)")
        XCTAssertEqual(try result.jsonLines, expected, "\(command)")
      }
    }
    runtime.configuration = ["unsupported": Date()]
    let unsupported = try answer(.dns(.list))
    XCTAssertEqual(unsupported.exitCode, 1)
    XCTAssertEqual(try unsupported.jsonLines, "")
    XCTAssertEqual(
      unsupported.error, "Could not encode command output: The operation couldn’t be completed. (FBSimulatorBridgeProtocol.BridgeProtocolError error 1.)")
  }

  // MARK: - Health

  private func healthRuntime() -> FBHealthTestRuntime {
    let runtime = FBHealthTestRuntime()
    runtime.typeFactories = ["step": "HKQuantityType"]
    runtime.install()
    return runtime
  }

  func testHealthWritesAnswerWithWhatTheyResolvedAndHowEachStageEnded() throws {
    let cases: [(Bool, Bool, String?, String?, String, String?)] = [
      (true, true, nil, nil, #""ok":true,"resolvedTypes":["step"]"#, nil),
      (true, false, nil, "set failed", #""ok":false,"resolvedTypes":["step"],"setError":"set failed""#, "set failed"),
      (false, true, "seed failed", "seed warning", #""ok":false,"resolvedTypes":["step"],"seedError":"seed failed","setError":"seed warning""#, "seed warning"),
    ]
    for (seedOK, setOK, seedError, setError, fields, error) in cases {
      let runtime = healthRuntime()
      defer { runtime.uninstall() }
      runtime.seedOK = seedOK
      runtime.setOK = setOK
      runtime.seedError = seedError
      runtime.setError = setError
      let commands: [(BridgeCommand.Health, String)] = [
        (.approve(bundleID: "app", typeIDs: ["step", "unknown"]), #"{"action":"approve","bundleID":"app",\#(fields),"unresolvedTypes":["unknown"]}"#),
        (.revoke(bundleID: "app", typeIDs: ["step"]), #"{"action":"revoke","bundleID":"app",\#(fields),"unresolvedTypes":[]}"#),
      ]
      for (command, expected) in commands {
        let result = try answer(.health(command))
        XCTAssertEqual(result.exitCode, seedOK && setOK ? 0 : 1, "\(command)")
        XCTAssertEqual(try result.jsonLines, expected + "\n", "\(command)")
        XCTAssertEqual(result.error, error, "\(command)")
      }
    }
  }

  func testAHealthWriteThatResolvesNothingAnswersWithWhatItCouldNot() throws {
    let runtime = healthRuntime()
    defer { runtime.uninstall() }
    runtime.typeFactories = [:]
    let result = try answer(.health(.approve(bundleID: "app", typeIDs: ["unknown"])))
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertEqual(
      try result.jsonLines,
      #"{"action":"approve","bundleID":"app","error":"no resolvable HK types in request","ok":false,"unresolvedTypes":["unknown"]}"# + "\n")
    XCTAssertEqual(result.error, "no resolvable HK types in request")
  }

  func testHealthClearAndListAnswerWithTheirOutcome() throws {
    for fails in [false, true] {
      let runtime = healthRuntime()
      defer { runtime.uninstall() }
      runtime.clearOK = !fails
      runtime.clearError = fails ? "clear failed" : nil
      runtime.fetchError = fails ? "fetch failed" : nil
      runtime.records = [
        ["identifier": "step", "sharingAuthorizationAllowed": true, "readingAuthorizationAllowed": 0],
        ["identifier": "<opaque>", "sharingAuthorizationAllowed": NSNull()],
        [:],
      ]
      let clear = try answer(.health(.clear(bundleID: "app")))
      XCTAssertEqual(
        try clear.jsonLines,
        (fails ? #"{"action":"clear","bundleID":"app","error":"clear failed","ok":false}"# : #"{"action":"clear","bundleID":"app","ok":true}"#) + "\n")
      XCTAssertEqual(clear.error, fails ? "clear failed" : nil)
      let list = try answer(.health(.list(bundleID: "app")))
      let records = #""records":[{"identifier":"step","readingAuthorizationAllowed":false,"sharingAuthorizationAllowed":true},{"identifier":"opaque-value"},{}]"#
      XCTAssertEqual(
        try list.jsonLines,
        (fails
          ? #"{"action":"list","bundleID":"app","error":"fetch failed","ok":false,\#(records)}"#
          : #"{"action":"list","bundleID":"app","ok":true,\#(records)}"#) + "\n")
      XCTAssertEqual(list.error, fails ? "fetch failed" : nil)
    }
  }

  func testAHealthStageThatTimesOutAnswersWithItsStatus() throws {
    for stage in ["seed", "set", "clear", "list"] {
      let runtime = healthRuntime()
      defer { runtime.uninstall() }
      runtime.deferredCompletion = stage
      let command: BridgeCommand.Health =
        switch stage {
        case "clear": .clear(bundleID: "app")
        case "list": .list(bundleID: "app")
        default: .approve(bundleID: "app", typeIDs: ["step"])
        }
      let (action, error) =
        switch stage {
        case "seed": ("approve", "Health seed timed out")
        case "set": ("approve", "Health authorization write timed out")
        case "clear": ("clear", "Health clear timed out")
        default: ("list", "Health list timed out")
        }
      let result = try answer(.health(command))
      XCTAssertEqual(
        try result.jsonLines, #"{"action":"\#(action)","bundleID":"app","completionStatus":"timedOut","error":"\#(error)","ok":false}"# + "\n", stage)
      runtime.completePendingCallbacks()
    }
  }

  // MARK: - Notification settings

  func testNotificationSettingsAnswerWithEachSection() throws {
    XCTAssertNotEqual(dlopen("/System/Library/PrivateFrameworks/BulletinBoard.framework/BulletinBoard", RTLD_NOW), nil)
    let gateway = FakeNotificationSettingsGateway()
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: "com.example.a", gateway: gateway), 0)
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "approve", bundleID: "com.example.b", gateway: gateway), 0)
    XCTAssertEqual(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "revoke", bundleID: "com.example.b", gateway: gateway), 0)
    gateway.setSectionInfo(FBSectionInfoWithoutEffectiveFlags(), forSectionID: "com.example.flagless")
    let cases: [(String?, String)] = [
      (
        "com.example.a",
        #"{"allowsNotifications":true,"authorizationStatus":2,"bundleID":"com.example.a","found":true,"showsInLockScreen":true,"showsInNotificationCenter":true}"#
      ),
      (
        "com.example.b",
        #"{"allowsNotifications":false,"authorizationStatus":0,"bundleID":"com.example.b","found":true,"showsInLockScreen":true,"showsInNotificationCenter":true}"#
      ),
      (
        "com.example.flagless",
        #"{"allowsNotifications":false,"authorizationStatus":0,"bundleID":"com.example.flagless","found":true}"#
      ),
      ("com.example.missing", #"{"bundleID":"com.example.missing","found":false}"#),
    ]
    for (bundleID, expected) in cases {
      let output = BridgeOutput()
      let status = NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: "list", bundleID: bundleID, gateway: gateway, output: output)
      XCTAssertEqual(try answer(.notifications(.list(bundleID: bundleID)), from: output, status: status).jsonLines, expected + "\n", "\(bundleID ?? "every")")
    }
  }

  // MARK: - Delivered notifications

  func testDeliveredNotificationsAnswerOneLineEach() throws {
    let content = UNMutableNotificationContent()
    content.title = "Title \"quoted\""
    content.subtitle = "Sub/title"
    content.body = "Body\nline"
    content.threadIdentifier = "thread"
    let request = UNNotificationRequest(identifier: "first", content: content, trigger: nil)
    let dated = DeliveredNotificationFixture(request: request, date: Date(timeIntervalSince1970: 1_700_000_000.25))
    let bare = FBFakeDeliveredNotification()
    bare.identifier = "second"
    let center = FBFakeDeliveredNotificationsCenter()
    center.notifications = [dated, bare]
    let output = BridgeOutput()
    let status = DeliveredNotificationsService.handleActionWithCenter(
      "delivered", bundleID: "com.example.test", center: center, directory: NSTemporaryDirectory(), timeout: 0, output: output)
    let result = try answer(.notifications(.delivered(bundleID: "com.example.test")), from: output, status: Int(status))
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(
      try result.jsonLines,
      #"{"body":"Body\nline","bundleID":"com.example.test","date":1700000000.25,"identifier":"first","subtitle":"Sub\/title","threadIdentifier":"thread","title":"Title \"quoted\""}"#
        + "\n" + #"{"body":"","bundleID":"com.example.test","identifier":"second","subtitle":"","threadIdentifier":"","title":""}"# + "\n")
  }
}
