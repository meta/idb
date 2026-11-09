/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
import Foundation
import Testing

@Suite
struct BridgeAnswerTests {
  /// Each answer beside the line the host reports for it. The host hands the line on unparsed, so it is pinned.
  private static let reported: [(BridgeAnswer, String)] = [
    (
      .notificationSettings(
        BridgeNotificationSettings(
          bundleID: "com.example.a",
          settings: .init(allowsNotifications: true, authorizationStatus: 2, showsInNotificationCenter: true, showsInLockScreen: false))),
      #"{"allowsNotifications":true,"authorizationStatus":2,"bundleID":"com.example.a","found":true,"showsInLockScreen":false,"showsInNotificationCenter":true}"#
    ),
    (
      .notificationSettings(
        BridgeNotificationSettings(
          bundleID: "com.example.flagless",
          settings: .init(allowsNotifications: false, authorizationStatus: 0, showsInNotificationCenter: nil, showsInLockScreen: nil))),
      #"{"allowsNotifications":false,"authorizationStatus":0,"bundleID":"com.example.flagless","found":true}"#
    ),
    (.notificationSettings(BridgeNotificationSettings(bundleID: "com.example.missing", settings: nil)), #"{"bundleID":"com.example.missing","found":false}"#),
    (
      .deliveredNotification(
        BridgeDeliveredNotification(
          bundleID: "com.example.test", identifier: "first", title: "Title \"quoted\"", subtitle: "Sub/title", body: "Body\nline", threadIdentifier: "thread",
          date: 1_700_000_000.25)),
      #"{"body":"Body\nline","bundleID":"com.example.test","date":1700000000.25,"identifier":"first","subtitle":"Sub\/title","threadIdentifier":"thread","title":"Title \"quoted\""}"#
    ),
    (
      .deliveredNotification(
        BridgeDeliveredNotification(bundleID: "com.example.test", identifier: "second", title: "", subtitle: "", body: "", threadIdentifier: "", date: nil)),
      #"{"body":"","bundleID":"com.example.test","identifier":"second","subtitle":"","threadIdentifier":"","title":""}"#
    ),
    (
      .health(.write(action: .approve, bundleID: "app", ok: true, resolvedTypes: ["step"], unresolvedTypes: ["unknown"], seedError: nil, setError: nil)),
      #"{"action":"approve","bundleID":"app","ok":true,"resolvedTypes":["step"],"unresolvedTypes":["unknown"]}"#
    ),
    (
      .health(.write(action: .revoke, bundleID: "app", ok: false, resolvedTypes: ["step"], unresolvedTypes: [], seedError: "seed failed", setError: "seed warning")),
      #"{"action":"revoke","bundleID":"app","ok":false,"resolvedTypes":["step"],"seedError":"seed failed","setError":"seed warning","unresolvedTypes":[]}"#
    ),
    (
      .health(.nothingResolved(action: .approve, bundleID: "app", unresolvedTypes: ["unknown"])),
      #"{"action":"approve","bundleID":"app","error":"no resolvable HK types in request","ok":false,"unresolvedTypes":["unknown"]}"#
    ),
    (
      .health(.noAuthorizationSpelling(action: .revoke, bundleID: "app", resolvedTypes: ["step"], unresolvedTypes: [])),
      #"{"action":"revoke","bundleID":"app","error":"HKAuthorizationStore declares no known setAuthorizationStatuses: spelling","ok":false,"resolvedTypes":["step"],"unresolvedTypes":[]}"#
    ),
    (.health(.clear(bundleID: "app", ok: true, error: nil)), #"{"action":"clear","bundleID":"app","ok":true}"#),
    (.lockScreen(BridgeLockScreenState(locked: true)), #"{"locked":true}"#),
    (.lockScreen(BridgeLockScreenState(locked: true, passcodeEnabled: false)), #"{"locked":true,"passcodeEnabled":false}"#),
    (.health(.clear(bundleID: "app", ok: false, error: "clear failed")), #"{"action":"clear","bundleID":"app","error":"clear failed","ok":false}"#),
    (
      .health(
        .list(
          bundleID: "app", ok: false, error: "fetch failed",
          records: [
            BridgeHealthRecord(identifier: "step", sharingAuthorizationAllowed: true, readingAuthorizationAllowed: false),
            BridgeHealthRecord(identifier: "opaque-value", sharingAuthorizationAllowed: nil, readingAuthorizationAllowed: nil),
            BridgeHealthRecord(identifier: nil, sharingAuthorizationAllowed: nil, readingAuthorizationAllowed: nil),
          ])),
      #"{"action":"list","bundleID":"app","error":"fetch failed","ok":false,"records":[{"identifier":"step","readingAuthorizationAllowed":false,"sharingAuthorizationAllowed":true},{"identifier":"opaque-value"},{}]}"#
    ),
    (
      .health(.timedOut(action: .list, bundleID: "app", error: "Health list timed out")),
      #"{"action":"list","bundleID":"app","completionStatus":"timedOut","error":"Health list timed out","ok":false}"#
    ),
  ]

  @Test
  func eachAnswerIsReportedAsItsLine() throws {
    for (answer, line) in Self.reported {
      #expect(try answer.jsonLine() == line, "\(answer)")
    }
  }

  @Test
  func eachAnswerTravelsInAFrameUnchanged() throws {
    for (answer, _) in Self.reported {
      let request = BridgeRequest(command: .ping, id: "answer")
      let frame = try BridgeResponse(request: request, result: BridgeResult(exitCode: 0, answers: [answer])).encoded()
      #expect(try BridgeResponse.decode(frame, for: request).result.answers == [answer], "\(answer)")
    }
  }

  // A network store holds whatever was written to it, so its contents travel as the property list they are.
  @Test
  func aNetworkConfigurationIsReportedAsTheJSONItHolds() throws {
    let cases: [(Any, String)] = [
      (["ServerAddresses": ["::1", "1.1.1.1"]], #"{"ServerAddresses":["::1","1.1.1.1"]}"#),
      (
        ["HTTPEnable": 1, "HTTPProxy": "proxy.example/path", "HTTPPort": 8080, "ExceptionsList": ["*.local"], "FTPPassive": true],
        #"{"ExceptionsList":["*.local"],"FTPPassive":true,"HTTPEnable":1,"HTTPPort":8080,"HTTPProxy":"proxy.example\/path"}"#
      ),
      (["SOCKSEnable": 1, "SOCKSProxy": "::1", "SOCKSPort": 1080.5], #"{"SOCKSEnable":1,"SOCKSPort":1080.5,"SOCKSProxy":"::1"}"#),
      ([String: Any](), "{}"),
      (["first", 42] as [Any], #"["first",42]"#),
    ]
    for (configuration, line) in cases {
      let answer = BridgeAnswer.networkConfiguration(try BridgeNetworkConfiguration(configuration))
      #expect(try answer.jsonLine() == line)
      let request = BridgeRequest(command: .dns(.list), id: "network")
      let frame = try BridgeResponse(request: request, result: BridgeResult(exitCode: 0, answers: [answer])).encoded()
      #expect(try BridgeResponse.decode(frame, for: request).result.answers == [answer])
    }
  }

  @Test
  func aNetworkConfigurationJSONCannotHoldIsRefused() {
    #expect(throws: (any Error).self) { try BridgeNetworkConfiguration(["date": Date()]) }
    #expect(throws: (any Error).self) { try BridgeNetworkConfiguration(["data": Data([1])]) }
  }

  @Test
  func anAnswerJSONCannotRepresentDoesNotEncode() {
    let notification = BridgeDeliveredNotification(bundleID: "a", identifier: "b", title: "", subtitle: "", body: "", threadIdentifier: "", date: .infinity)
    #expect(throws: (any Error).self) { try BridgeAnswer.deliveredNotification(notification).jsonLine() }
  }

  @Test
  func aResultIsReportedAsItsErrorThenALineForEachAnswer() throws {
    let answer = BridgeAnswer.health(.clear(bundleID: "a/b", ok: true, error: nil))
    let line = #"{"action":"clear","bundleID":"a\/b","ok":true}"#
    #expect(try BridgeResult(exitCode: 0).reportedOutput == "")
    #expect(try BridgeResult(exitCode: 0, answers: [answer, answer]).reportedOutput == line + "\n" + line + "\n")
    #expect(try BridgeResult(exitCode: 1, error: "it failed", answers: [answer]).reportedOutput == "it failed\n" + line + "\n")
    #expect(try BridgeResult(exitCode: 1, error: "it failed").reportedOutput == "it failed")
    #expect(try BridgeResult(exitCode: 1, error: "").reportedOutput == "")
  }
}
