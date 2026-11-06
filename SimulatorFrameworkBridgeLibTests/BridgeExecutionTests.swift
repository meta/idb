/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
import Foundation
@_implementationOnly import SimulatorFrameworkBridgeSupport
@_implementationOnly import SimulatorIPC
import XCTest

final class BridgeExecutionTests: XCTestCase {
  func testRPCAndSocketAdaptersPreserveTheCommandIdentityAndPartialFailure() throws {
    let commands: [BridgeCommand] = [
      .clearContacts, .clearPhotos, .dns(.list), .proxy(.clear),
      .health(.approve(bundleID: "app", typeIDs: ["step"])),
      .notifications(.delivered(bundleID: "app")), .notifications(.clearDelivered(bundleID: "app")),
      .accessibility(.displays), .ping,
    ]
    let expected = BridgeResult(exitCode: 23, error: "The remaining records could not be read", answers: [.health(.clear(bundleID: "first", ok: true, error: nil)), .health(.clear(bundleID: "second", ok: true, error: nil))])
    var received: [BridgeCommand] = []
    for command in commands {
      let request = BridgeRequest(command: command, id: "test")
      let execute: (BridgeCommand) -> BridgeResult = {
        received.append($0)
        return expected
      }
      let cli = BridgeRPC.process(Data(try request.arguments[1].utf8), execute: execute)
      let socket = BridgeRPC.handle(try request.encoded(), execute: execute)
      XCTAssertEqual(cli.data, socket.frame?.data)
      XCTAssertEqual(try BridgeResponse.decode(cli.data, for: request).result, expected)
      XCTAssertEqual(cli.exitCode, 23)
      XCTAssertFalse(cli.shutdown)
      XCTAssertEqual(socket.frame?.shutdown, false)
    }
    XCTAssertEqual(received, commands.flatMap { [$0, $0] })
  }

  func testInvalidRequestsNeverExecuteAndDoNotPoisonTheNextRequest() throws {
    var calls = 0
    let execute: (BridgeCommand) -> BridgeResult = { _ in
      calls += 1
      return BridgeResult(exitCode: 0)
    }
    for text in ["{", "null"] {
      let reply = BridgeRPC.process(Data(text.utf8), execute: execute)
      XCTAssertEqual(reply.exitCode, 1)
      XCTAssertFalse(reply.shutdown)
      let response = try JSONDecoder().decode(BridgeResponse.self, from: reply.data)
      XCTAssertNil(response.id)
      XCTAssertEqual(response.result.exitCode, 1)
      XCTAssertNotNil(failureMessage(response.result))
    }
    // A request whose identity survives decoding is answered under that identity, so the host can
    // match the failure to what it sent instead of reporting a mismatched response.
    let unanswerable: [(String, String)] = [
      (#"{"version":8,"id":"future-version","command":{"ping":{}}}"#, "unsupportedVersion(8)"),
      (#"{"version":7,"id":"future-command","command":{"future":{}}}"#, "command"),
    ]
    for (text, expected) in unanswerable {
      let reply = BridgeRPC.process(Data(text.utf8), execute: execute)
      XCTAssertEqual(reply.exitCode, 1)
      let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
      let response = try JSONDecoder().decode(BridgeResponse.self, from: reply.data)
      XCTAssertEqual(response.id, request["id"] as? String)
      XCTAssertEqual(response.result.exitCode, 1)
      let message = try XCTUnwrap(failureMessage(response.result))
      XCTAssertTrue(message.contains(expected), message)
    }
    XCTAssertEqual(calls, 0)
    let request = BridgeRequest(command: .ping)
    XCTAssertEqual(try BridgeResponse.decode(BridgeRPC.process(request.encoded(), execute: execute).data, for: request).result.exitCode, 0)
    XCTAssertEqual(calls, 1)
  }

  func testOversizedAndInvalidOutputBecomesAMatchingFailureInBothAdapters() throws {
    let request = BridgeRequest(command: .dns(.list), id: "bounded")
    let results = [
      BridgeResult(exitCode: 0, answers: [.health(.clear(bundleID: String(repeating: "x", count: IPCFrame.maximumSize), ok: true, error: nil))]),
      BridgeResult(
        exitCode: 0,
        answers: [.deliveredNotification(BridgeDeliveredNotification(bundleID: "a", identifier: "b", title: "", subtitle: "", body: "", threadIdentifier: "", date: .infinity))]),
      BridgeResult(exitCode: 0, answers: [.dynamicStoreSnapshot(try PropertyListSerialization.data(fromPropertyList: ["value": Data(repeating: 0, count: 13 * 1024 * 1024)], format: .binary, options: 0))]),
    ]
    for result in results {
      let execute: (BridgeCommand) -> BridgeResult = { _ in result }
      let cli = BridgeRPC.process(try request.encoded(), execute: execute)
      let socket = BridgeRPC.handle(try request.encoded(), execute: execute)
      XCTAssertEqual(cli.data, socket.frame?.data)
      XCTAssertEqual(cli.exitCode, 1)
      XCTAssertLessThan(cli.data.count, IPCFrame.maximumSize)
      let failure = try BridgeResponse.decode(cli.data, for: request).result
      XCTAssertEqual(failure.exitCode, 1)
      XCTAssertNil(failure.propertyList)
    }
    let ping = BridgeRequest(command: .ping)
    XCTAssertEqual(try BridgeResponse.decode(BridgeRPC.process(ping.encoded()).data, for: ping).result, BridgeResult(exitCode: 0))
  }

  private func failureMessage(_ result: BridgeResult) -> String? {
    guard result.answers.isEmpty else { return nil }
    return result.error
  }

  func testServeBindsTheAccessibilityRuntimeBeforeItsFirstClient() throws {
    let path = "/tmp/sfb-prepare-" + UUID().uuidString
    defer { unlink(path) }
    let probe = FBAXBridgeServeProbe { BridgeCommandLine.run(arguments: ["SimulatorFrameworkBridge", "serve", path, "--startup-timeout", "1"]) }
    XCTAssertEqual(probe["status"] as? Int32, 0)
    XCTAssertEqual(probe["calls"] as? Int, 1, "the runtime is bound once, before any client connects")
  }

  func testOnlySuccessfulShutdownEndsTheServer() throws {
    for command: BridgeCommand in [.ping, .shutdown] {
      for status: Int32 in [0, 1] {
        let request = BridgeRequest(command: command)
        let response = BridgeRPC.process(try request.encoded()) { _ in BridgeResult(exitCode: status) }
        XCTAssertEqual(response.shutdown, command == .shutdown && status == 0)
      }
    }
  }

  func testOutputIsRequestLocalRetainsOrderAndReportsEncodingFailures() {
    let first = BridgeOutput()
    XCTAssertTrue(first.write(.health(.clear(bundleID: "first", ok: true, error: nil))))
    XCTAssertFalse(
      first.write(
        .deliveredNotification(BridgeDeliveredNotification(bundleID: "a", identifier: "b", title: "", subtitle: "", body: "", threadIdentifier: "", date: .infinity))))
    XCTAssertTrue(first.write(.health(.clear(bundleID: "second", ok: true, error: nil))))
    let result = first.finish(status: 0)
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertEqual(result.answers, [.health(.clear(bundleID: "first", ok: true, error: nil)), .health(.clear(bundleID: "second", ok: true, error: nil))])
    XCTAssertTrue(result.error?.hasPrefix("Could not encode command output:") == true)
    XCTAssertEqual(BridgeOutput().finish(status: 0), BridgeResult(exitCode: 0))
  }

  // Both adapters carry the answer in the frame as it is.
  func testAnAccessibilityAnswerTravelsTheSameInBothAdapters() throws {
    let request = BridgeRequest(command: .accessibility(.displays), id: "answer")
    let answer = BridgeAXAnswer.displays(
      BridgeAXDisplayInventory(displayScopedInteractions: true, displayScopedTrees: true, displayScopedQuiescence: true, displays: []))
    let output = BridgeOutput()
    output.write(accessibility: answer)
    let result = output.finish(status: 0)
    XCTAssertEqual(result, BridgeResult(exitCode: 0, answers: [.accessibility(answer)]))
    let cli = BridgeRPC.process(try request.encoded()) { _ in result }
    let socket = BridgeRPC.handle(try request.encoded()) { _ in result }
    XCTAssertEqual(cli.data, socket.frame?.data)
    XCTAssertEqual(try BridgeResponse.decode(cli.data, for: request).result.accessibility, answer)
  }

  func testNetworkCommandsCollectResultsWithoutWritingStdout() throws {
    let runtime = FBNetworkConfigurationTestRuntime()
    runtime.install()
    defer { runtime.uninstall() }
    runtime.configuration = ["ServerAddresses": ["::1", "1.1.1.1"]]
    var result = BridgeResult(exitCode: 1)
    let printed = FBStdoutWhileRunning { result = BridgeServices.execute(.dns(.list)) }
    XCTAssertEqual(printed, "")
    XCTAssertEqual(result, BridgeResult(exitCode: 0, answers: [.networkConfiguration(try BridgeNetworkConfiguration(["ServerAddresses": ["::1", "1.1.1.1"]]))]))
    XCTAssertEqual(BridgeServices.execute(.dns(.set(servers: ["8.8.8.8"]))).exitCode, 0)
    XCTAssertEqual(runtime.writes as NSArray, [["ServerAddresses": ["8.8.8.8"]]] as NSArray)
    XCTAssertEqual(Array(runtime.operations.suffix(2)) as NSArray, ["write", "notify"] as NSArray)
    runtime.configuration = ["unsupported": Date()]
    XCTAssertEqual(BridgeServices.execute(.dns(.list)).exitCode, 1)
    runtime.configuration = ["SOCKSProxy": "localhost"]
    XCTAssertEqual(BridgeServices.execute(.proxy(.list)), BridgeResult(exitCode: 0, answers: [.networkConfiguration(try BridgeNetworkConfiguration(["SOCKSProxy": "localhost"]))]))
    XCTAssertEqual(BridgeServices.execute(.proxy(.set(host: "::1", port: 1080, kind: .socks))).exitCode, 0)
    XCTAssertEqual((runtime.writes.lastObject as? [String: Any])?["SOCKSPort"] as? Int, 1080)
    runtime.configuration = ["first", 42] as [Any]
    let array = BridgeResult(exitCode: 0, answers: [.networkConfiguration(try BridgeNetworkConfiguration(["first", 42] as [Any]))])
    XCTAssertEqual(BridgeServices.execute(.dns(.list)), array)
    XCTAssertEqual(BridgeServices.execute(.proxy(.list)), array)
  }

  // An unset proto3 string arrives empty, and answering 0 would report a malformed request as done.
  func testDeliveredNotificationCommandsRefuseAnEmptyBundleIDBeforeReachingTheDaemon() {
    for command: BridgeCommand.Notifications in [.delivered(bundleID: ""), .clearDelivered(bundleID: "")] {
      let result = BridgeServices.execute(.notifications(command))
      XCTAssertEqual(result.exitCode, 1)
      XCTAssertEqual(result.error, "Delivered notifications require a bundle identifier")
    }
  }

  func testRuntimeFailureDiagnosticsAreRequestLocal() {
    let runtime = FBNetworkConfigurationTestRuntime()
    runtime.install()
    defer { runtime.uninstall() }
    runtime.writeSucceeds = false
    XCTAssertEqual(BridgeServices.execute(.dns(.clear)).error, "Could not write DNS configuration")
    XCTAssertEqual(BridgeServices.execute(.proxy(.clear)).error, "Could not write proxy configuration")
    runtime.writeSucceeds = true
    XCTAssertEqual(BridgeServices.execute(.dns(.clear)), BridgeResult(exitCode: 0))
    runtime.libraryAvailable = false
    XCTAssertEqual(BridgeServices.execute(.dns(.list)).error, "The DNS private API is unavailable")
  }

  func testTypedHealthTimeoutsReportFailureWithoutMutatingTheNextResult() throws {
    for stage in ["seed", "set", "clear", "list"] {
      let runtime = FBHealthTestRuntime()
      runtime.typeFactories = ["step": "HKQuantityType"]
      runtime.deferredCompletion = stage
      runtime.install()
      defer { runtime.uninstall() }
      let command: BridgeCommand
      switch stage {
      case "clear": command = .health(.clear(bundleID: "app"))
      case "list": command = .health(.list(bundleID: "app"))
      default: command = .health(.approve(bundleID: "app", typeIDs: ["step"]))
      }
      let result = BridgeServices.execute(command)
      XCTAssertEqual(result.exitCode, 1, stage)
      guard case let .health(health)? = result.answers.first, health.completionStatus == .timedOut, let error = health.error else {
        return XCTFail("missing timeout response")
      }
      let timeouts = ["seed": "Health seed timed out", "set": "Health authorization write timed out", "clear": "Health clear timed out", "list": "Health list timed out"]
      XCTAssertEqual(result.error, timeouts[stage], stage)
      XCTAssertEqual(error, timeouts[stage], stage)
      let answer = result.answers.first
      runtime.completePendingCallbacks()
      XCTAssertEqual(result.answers.first, answer)
      runtime.deferredCompletion = ""
      XCTAssertEqual(BridgeServices.execute(command).exitCode, 0)
    }
  }

  func testTypedHealthFailuresCarryTheirDiagnostic() {
    let runtime = FBHealthTestRuntime()
    runtime.typeFactories = ["step": "HKQuantityType"]
    runtime.setOK = false
    runtime.setError = "set failed"
    runtime.clearOK = false
    runtime.clearError = "clear failed"
    runtime.fetchError = "fetch failed"
    runtime.install()
    defer { runtime.uninstall() }
    let results = [
      BridgeServices.execute(.health(.approve(bundleID: "app", typeIDs: ["step"]))),
      BridgeServices.execute(.health(.approve(bundleID: "app", typeIDs: ["unknown"]))),
      BridgeServices.execute(.health(.clear(bundleID: "app"))),
      BridgeServices.execute(.health(.list(bundleID: "app"))),
    ]
    XCTAssertEqual(results.map(\.exitCode), [1, 1, 1, 1])
    XCTAssertEqual(results.map(\.error), ["set failed", "no resolvable HK types in request", "clear failed", "fetch failed"])
  }

  func testDynamicStoreAdaptersPreserveBinaryPlistsWithoutWritingStdout() throws {
    let value: [Any] = [Data([0, 255]), Date(timeIntervalSince1970: 1234), ["nested": true]]
    let present: [String: Any] = ["present": true, "value": value]
    let absent: [String: Any] = ["present": false]
    let data = try PropertyListSerialization.data(fromPropertyList: present, format: .binary, options: 0)
    let empty = try PropertyListSerialization.data(fromPropertyList: absent, format: .binary, options: 0)
    let cases: [(BridgeCommand, [String: Any])] = [
      (.dynamicStore(.restore(key: "dns", snapshot: data)), present),
      (.dynamicStore(.snapshot(key: "dns")), present),
      (.dynamicStore(.restore(key: "dns", snapshot: empty)), absent),
      (.dynamicStore(.snapshot(key: "dns")), absent),
    ]
    for socket in [false, true] {
      let runtime = FBDynamicStoreTestRuntime()
      runtime.install()
      defer { runtime.uninstall() }
      for (command, expected) in cases {
        let request = BridgeRequest(command: command)
        let encoded = try request.encoded()
        var response = Data()
        let printed = FBStdoutWhileRunning {
          response = socket ? BridgeRPC.handle(encoded).frame?.data ?? Data() : BridgeRPC.process(encoded).data
        }
        let result = try BridgeResponse.decode(response, for: request).result
        XCTAssertEqual(printed, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.answers.count, 1)
        XCTAssertNil(result.error)
        let snapshot = try XCTUnwrap(result.propertyList)
        XCTAssertTrue(snapshot.starts(with: Data("bplist00".utf8)))
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: snapshot, options: [], format: nil) as? NSDictionary, expected as NSDictionary)
      }
    }
  }

  func testDynamicStoreFailureDoesNotLeakDataIntoTheNextRequest() throws {
    let runtime = FBDynamicStoreTestRuntime()
    runtime.install()
    defer { runtime.uninstall() }
    for socket in [false, true] {
      let request = BridgeRequest(command: .dynamicStore(.restore(key: "dns", snapshot: Data("invalid".utf8))))
      let encoded = try request.encoded()
      let response = socket ? BridgeRPC.handle(encoded).frame?.data ?? Data() : BridgeRPC.process(encoded).data
      let result = try BridgeResponse.decode(response, for: request).result
      XCTAssertEqual(result.exitCode, 1)
      XCTAssertNotNil(result.error)
      XCTAssertNil(result.propertyList)
      XCTAssertEqual(result.answers, [])
      XCTAssertFalse(runtime.operations.contains("write"))
      let recovered = BridgeServices.execute(.dynamicStore(.snapshot(key: "dns")))
      XCTAssertEqual(recovered.exitCode, 0)
      XCTAssertNil(recovered.error)
      let snapshot = try XCTUnwrap(recovered.propertyList)
      XCTAssertEqual(try PropertyListSerialization.propertyList(from: snapshot, options: [], format: nil) as? NSDictionary, ["present": false] as NSDictionary)
    }
  }

  func testAStreamingCommandAnswersEveryResultAsAResponseToItsRequest() throws {
    let request = BridgeRequest(command: .accessibility(.quiescence(pid: nil, busyThresholdMs: nil, quietWindowMs: nil)), id: "stream")
    let results = [BridgeResult(exitCode: 0, answers: [.health(.clear(bundleID: "quiet", ok: true, error: nil))]), BridgeResult(exitCode: 1, error: "gone")]
    let source = ScriptedResultStream(results: results)
    var executed = 0
    let response = BridgeRPC.handle(
      try request.encoded(),
      execute: { _ in
        executed += 1
        return BridgeResult(exitCode: 0)
      }
    ) { command in
      XCTAssertEqual(command, request.command)
      return .stream(source)
    }
    guard case let .stream(stream) = response else { return XCTFail("expected a stream, got \(response)") }
    var frames: [Data] = []
    stream.run { data in
      frames.append(data)
      return true
    }
    XCTAssertEqual(try frames.map { try BridgeResponse.decode($0, for: request).result }, results)
    stream.cancel()
    XCTAssertTrue(source.wasCancelled)
    XCTAssertEqual(executed, 0)
  }

  func testAStreamStopsOnceAFrameCannotBeWritten() throws {
    let request = BridgeRequest(command: .accessibility(.quiescence(pid: nil, busyThresholdMs: nil, quietWindowMs: nil)))
    let source = ScriptedResultStream(results: [BridgeResult(exitCode: 0), BridgeResult(exitCode: 0)])
    let response = BridgeRPC.handle(try request.encoded(), stream: { _ in .stream(source) })
    guard case let .stream(stream) = response else { return XCTFail("expected a stream, got \(response)") }
    var writes = 0
    stream.run { _ in
      writes += 1
      return false
    }
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(source.delivered, [false])
  }

  func testAnAccessibilityRequestThatCannotBeAnsweredIsABadRequest() throws {
    // A streaming verb too: one that cannot be answered never starts its stream, and is answered in one frame.
    let cases: [(String, (String) -> Bool)] = [
      (#"{"quiescence":{"method":"window-server","quietWindowMs":-1,"x":0,"y":0}}"#, { $0 == "quietWindowMs must not be negative, got -1" }),
      (
        #"{"read":{"displayID":0,"options":{"clientType":0,"explainUnreachable":false,"maxDepth":1,"maxNodes":1,"traversal":"semantic"},"pid":3}}"#,
        { $0 == "displayID must be a positive 32-bit integer" }
      ),
      (#"{"dance":{}}"#, { $0.hasPrefix("the request does not decode: ") }),
      (#"{"deviceSettingChanges":{}}"#, { $0.hasPrefix("the request does not decode: ") }),
    ]
    for (action, expected) in cases {
      let frame = Data(#"{"command":{"accessibility":{"action":\#(action)}},"id":"unanswerable","version":\#(BridgeRequest.currentVersion)}"#.utf8)
      for data in [BridgeRPC.process(frame).data, try XCTUnwrap(BridgeRPC.handle(frame).frame, action).data] {
        let response = try JSONDecoder().decode(BridgeResponse.self, from: data)
        XCTAssertEqual(response.id, "unanswerable")
        XCTAssertEqual(response.result.exitCode, 1)
        XCTAssertEqual(response.result.answers.count, 1)
        guard case let .failure(failure)? = response.result.accessibility else { return XCTFail("expected a failure for \(action)") }
        XCTAssertEqual(failure.kind, .badRequest, action)
        XCTAssertTrue(expected(failure.message ?? ""), "\(action): \(failure.message ?? "")")
      }
    }
  }

  func testAStreamThatCannotStartAnswersWithOneFrame() throws {
    let request = BridgeRequest(command: .accessibility(.quiescence(pid: nil, busyThresholdMs: nil, quietWindowMs: nil)), id: "refused")
    let refusal = BridgeResult(exitCode: 1, answers: [.health(.clear(bundleID: "refused", ok: false, error: nil))])
    let response = BridgeRPC.handle(try request.encoded(), execute: { _ in BridgeResult(exitCode: 0) }) { _ in .result(refusal) }
    let frame = try XCTUnwrap(response.frame)
    XCTAssertFalse(frame.shutdown)
    XCTAssertEqual(try BridgeResponse.decode(frame.data, for: request).result, refusal)
  }
}

private final class ScriptedResultStream: BridgeResultStream {
  private let results: [BridgeResult]
  private(set) var delivered: [Bool] = []
  private(set) var wasCancelled = false

  init(results: [BridgeResult]) {
    self.results = results
  }

  func run(emit: @escaping (BridgeResult) -> Bool) {
    for result in results {
      let written = emit(result)
      delivered.append(written)
      guard written else { return }
    }
  }

  func cancel() {
    wasCancelled = true
  }
}
