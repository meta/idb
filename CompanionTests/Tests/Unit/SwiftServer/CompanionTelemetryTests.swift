/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBControlCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import IDBTelemetry
import SwiftProtobuf
import Testing

/// Captures every subject the telemetry reports, so the per-RPC emission can
/// be asserted without a scribe process.
private final class RecordingEventReporter: NSObject, EventReporter, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [EventReporterSubject] = []

  var subjects: [EventReporterSubject] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  var metadata: [String: String] { [:] }

  func report(_ subject: EventReporterSubject) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(subject)
  }

  func addMetadata(_ metadata: [String: String]) {}
}

private struct FetchRequest {
  let bundleID: String
  let verbose: Bool
}

/// Mirrors how SwiftProtobuf renders its per-request unknown-fields storage,
/// without importing SwiftProtobuf into the test target.
private struct EmptyUnknownStorage: CustomStringConvertible {
  var description: String { "UnknownStorage(data: 0 bytes)" }
}

private struct NonEmptyUnknownStorage: CustomStringConvertible {
  var description: String { "UnknownStorage(data: 3 bytes)" }
}

private struct RequestWithUnknownFields<Storage: CustomStringConvertible> {
  let bundleID: String
  let unknownFields: Storage
}

/// Renders the way a nested protobuf message does: across lines.
private struct MultilineDescription: CustomStringConvertible {
  var description: String { "Envelope:\nkind: ROOT\n" }
}

private struct RequestWithMultilineValue {
  let container: MultilineDescription
}

private struct TelemetryTestError: Error, LocalizedError {
  var errorDescription: String? { "request exploded" }
}

/// Captures log lines so completion-line rendering is assertable without
/// reading stderr.
private final class RecordingLogger: ControlCoreLogger, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  var messages: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  var name: String? { nil }
  var level: ControlCoreLogLevel { .info }

  @discardableResult
  func log(_ message: String) -> ControlCoreLogger {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(message)
    return self
  }

  func info() -> ControlCoreLogger { self }
  func debug() -> ControlCoreLogger { self }
  func error() -> ControlCoreLogger { self }
  func withName(_ name: String) -> ControlCoreLogger { self }
  func withDateFormatEnabled(_ enabled: Bool) -> ControlCoreLogger { self }
}

@Suite
struct CompanionTelemetryTests {

  private static let logger = IDBLogger(
    loggers: [ControlCoreGlobalConfiguration.systemLogger(writingToStderr: true, debugLogging: false)])

  private func makeTelemetry() -> (CompanionTelemetry, RecordingEventReporter) {
    let recorder = RecordingEventReporter()
    return (CompanionTelemetry(logger: Self.logger, reporter: recorder), recorder)
  }

  @Test
  func unaryCallSuccessReportsOneSuccessSubject() async throws {
    let (telemetry, recorder) = makeTelemetry()
    let request = FetchRequest(bundleID: "com.example.app", verbose: true)
    let value = try await telemetry.unaryCall("list_apps", request: request) { "ok" }
    #expect((value) == ("ok"))
    // Pinned: exactly one terminal subject per RPC; no started subject.
    #expect((recorder.subjects.count) == (1))
    let subject = recorder.subjects[0]
    #expect((subject.eventName) == ("list_apps"))
    #expect((subject.eventType) == (.success))
    #expect((subject.duration) != nil)
    #expect((subject.size) == nil)
    #expect((subject.ints) == ([:]))
    #expect((subject.normals) == ([:]))
    #expect((subject.arguments) == (["bundleID=com.example.app", "verbose=true"]))
  }

  @Test
  func columnsAHandlerSetsReachItsSuccessSubject() async throws {
    let (telemetry, recorder) = makeTelemetry()
    try await telemetry.clientStreaming("install") {
      CallTelemetry.current?.setSize(4096)
      CallTelemetry.current?.setInt(12, forKey: "install_ms")
      CallTelemetry.current?.setNormal("url", forKey: "payload_kind")
    }
    #expect((recorder.subjects.count) == (1))
    let subject = recorder.subjects[0]
    #expect((subject.eventType) == (.success))
    #expect((subject.size) == (4096))
    #expect((subject.ints) == (["install_ms": 12]))
    #expect((subject.normals) == (["payload_kind": "url"]))
  }

  @Test
  func columnsSetBeforeAFailureReachTheFailureSubject() async {
    let (telemetry, recorder) = makeTelemetry()
    do {
      try await telemetry.clientStreaming("install") { () async throws in
        CallTelemetry.current?.setSize(10)
        CallTelemetry.current?.setNormal("extract", forKey: "failure_stage")
        throw TelemetryTestError()
      }
      Issue.record("clientStreaming should rethrow the body's error")
    } catch {
      #expect((error is TelemetryTestError))
    }
    #expect((recorder.subjects.count) == (1))
    let subject = recorder.subjects[0]
    #expect((subject.eventType) == (.failure))
    #expect((subject.size) == (10))
    #expect((subject.normals) == (["failure_stage": "extract"]))
  }

  @Test
  func columnsSetFromAChildTaskReachTheSubject() async throws {
    let (telemetry, recorder) = makeTelemetry()
    try await telemetry.clientStreaming("install") {
      async let child: Void = CallTelemetry.current?.setInt(7, forKey: "receive_ms") ?? ()
      await child
    }
    #expect((recorder.subjects[0].ints) == (["receive_ms": 7]))
  }

  @Test
  func settingAColumnAgainReplacesItsValue() async throws {
    let (telemetry, recorder) = makeTelemetry()
    try await telemetry.clientStreaming("install") {
      CallTelemetry.current?.setSize(1)
      CallTelemetry.current?.setSize(2)
      CallTelemetry.current?.setInt(1, forKey: "extract_ms")
      CallTelemetry.current?.setInt(2, forKey: "extract_ms")
    }
    let subject = recorder.subjects[0]
    #expect((subject.size) == (2))
    #expect((subject.ints) == (["extract_ms": 2]))
  }

  @Test
  func eachCallGetsItsOwnColumns() async throws {
    let (telemetry, recorder) = makeTelemetry()
    try await telemetry.clientStreaming("install") {
      CallTelemetry.current?.setInt(1, forKey: "install_ms")
    }
    try await telemetry.clientStreaming("push") {}
    #expect((recorder.subjects.count) == (2))
    #expect((recorder.subjects[1].ints) == ([:]))
    #expect(CallTelemetry.current == nil)
  }

  @Test
  func unaryCallFailureReportsFailureSubjectAndRethrows() async {
    let (telemetry, recorder) = makeTelemetry()
    let request = FetchRequest(bundleID: "com.example.app", verbose: false)
    do {
      _ = try await telemetry.unaryCall("list_apps", request: request) { () async throws -> String in
        throw TelemetryTestError()
      }
      Issue.record("unaryCall should rethrow the body's error")
    } catch {
      #expect((error is TelemetryTestError))
    }
    #expect((recorder.subjects.count) == (1))
    let subject = recorder.subjects[0]
    #expect((subject.eventName) == ("list_apps"))
    #expect((subject.eventType) == (.failure))
    #expect((subject.message) == ("request exploded"))
    #expect((subject.duration) != nil)
  }

  @Test
  func clientStreamingReportsWithEmptyArguments() async throws {
    let (telemetry, recorder) = makeTelemetry()
    _ = try await telemetry.clientStreaming("push") { "done" }
    #expect((recorder.subjects.count) == (1))
    let subject = recorder.subjects[0]
    #expect((subject.eventName) == ("push"))
    #expect((subject.eventType) == (.success))
    #expect((subject.arguments) == ([]))
  }

  @Test
  func serverStreamingSuccessReportsRequestArguments() async throws {
    let (telemetry, recorder) = makeTelemetry()
    let request = FetchRequest(bundleID: "com.example.app", verbose: false)
    try await telemetry.serverStreaming("pull", request: request) {}
    #expect((recorder.subjects.count) == (1))
    let subject = recorder.subjects[0]
    #expect((subject.eventType) == (.success))
    #expect((subject.arguments) == (["bundleID=com.example.app", "verbose=false"]))
  }

  @Test
  func emptyUnknownFieldsAreOmittedFromArguments() async throws {
    let (telemetry, recorder) = makeTelemetry()
    let request = RequestWithUnknownFields(
      bundleID: "com.example.app",
      unknownFields: EmptyUnknownStorage(),
    )
    try await telemetry.unaryCall("list_apps", request: request) {}
    #expect((recorder.subjects.count) == (1))
    #expect((recorder.subjects[0].arguments) == (["bundleID=com.example.app"]))
  }

  @Test
  func nonEmptyUnknownFieldsAreKeptInArguments() async throws {
    let (telemetry, recorder) = makeTelemetry()
    let request = RequestWithUnknownFields(
      bundleID: "com.example.app",
      unknownFields: NonEmptyUnknownStorage(),
    )
    try await telemetry.unaryCall("list_apps", request: request) {}
    #expect((recorder.subjects.count) == (1))
    #expect(
      (recorder.subjects[0].arguments)
        == ([
          "bundleID=com.example.app",
          "unknownFields=UnknownStorage(data: 3 bytes)",
        ]))
  }

  @Test
  func formatDurationUsesMillisecondsBelowOneSecond() {
    #expect((CompanionTelemetry.formatDuration(0)) == ("0ms"))
    #expect((CompanionTelemetry.formatDuration(0.0123)) == ("12ms"))
    #expect((CompanionTelemetry.formatDuration(0.9999)) == ("1000ms"))
  }

  @Test
  func formatDurationUsesSecondsAtAndAboveOneSecond() {
    #expect((CompanionTelemetry.formatDuration(1)) == ("1.00s"))
    #expect((CompanionTelemetry.formatDuration(16.647)) == ("16.65s"))
  }

  @Test
  func truncateMiddlePassesShortValuesThrough() {
    #expect((CompanionTelemetry.truncateMiddle("abc", limit: 10)) == ("abc"))
    #expect((CompanionTelemetry.truncateMiddle("0123456789", limit: 10)) == ("0123456789"))
  }

  @Test
  func truncateMiddleKeepsBothEndsAtExactLimit() {
    let truncated = CompanionTelemetry.truncateMiddle("0123456789ABCDEF", limit: 10)
    #expect((truncated.count) == (10))
    #expect((truncated) == ("012...CDEF"))
  }

  @Test
  func multilineValuesAreFlattenedToOneLine() async throws {
    let (telemetry, recorder) = makeTelemetry()
    let request = RequestWithMultilineValue(container: MultilineDescription())
    try await telemetry.unaryCall("ls", request: request) {}
    #expect((recorder.subjects.count) == (1))
    #expect((recorder.subjects[0].arguments) == (["container=Envelope: kind: ROOT"]))
  }

  @Test
  func unaryCallSummaryIsAppendedToCompletionLine() async throws {
    let recorder = RecordingLogger()
    let telemetry = CompanionTelemetry(
      logger: IDBLogger(loggers: [recorder]),
      reporter: RecordingEventReporter())
    let request = FetchRequest(bundleID: "com.example.app", verbose: true)
    try await telemetry.unaryCall("ls", request: request, summarize: { _ in "5 entries" }) { "ok" }
    #expect((recorder.messages.count) == (2))
    #expect((recorder.messages[0]) == ("ls called with: [bundleID=com.example.app, verbose=true]"))
    #expect((recorder.messages[1].hasPrefix("ls succeeded in ")) == (true))
    #expect((recorder.messages[1].hasSuffix(" (5 entries)")) == (true))
  }

  @Test
  func unaryCallWithoutSummaryLogsBareCompletionLine() async throws {
    let recorder = RecordingLogger()
    let telemetry = CompanionTelemetry(
      logger: IDBLogger(loggers: [recorder]),
      reporter: RecordingEventReporter())
    let request = FetchRequest(bundleID: "com.example.app", verbose: true)
    try await telemetry.unaryCall("ls", request: request) { "ok" }
    #expect((recorder.messages.count) == (2))
    #expect((recorder.messages[1].hasPrefix("ls succeeded in ")) == (true))
    #expect((recorder.messages[1].contains(" (")) == (false))
  }

  @Test
  func columnsAreAppendedToTheSuccessLine() async throws {
    let recorder = RecordingLogger()
    let telemetry = CompanionTelemetry(
      logger: IDBLogger(loggers: [recorder]),
      reporter: RecordingEventReporter())
    let request = FetchRequest(bundleID: "com.example.app", verbose: true)
    try await telemetry.unaryCall("ls", request: request, summarize: { _ in "5 entries" }) {
      CallTelemetry.current?.setNormal("url", forKey: "payload_kind")
      CallTelemetry.current?.setInt(12, forKey: "install_ms")
      CallTelemetry.current?.setSize(4096)
      return "ok"
    }
    #expect((recorder.messages.count) == (2))
    #expect((recorder.messages[1].hasPrefix("ls succeeded in ")) == (true))
    #expect(
      (recorder.messages[1].hasSuffix(" (5 entries) {size=4096, install_ms=12, payload_kind=url}")) == (true))
  }

  @Test
  func anIntAndANormalSharingAKeyAreBothAppended() async throws {
    let recorder = RecordingLogger()
    let telemetry = CompanionTelemetry(
      logger: IDBLogger(loggers: [recorder]),
      reporter: RecordingEventReporter())
    try await telemetry.unaryCall("ls", request: FetchRequest(bundleID: "com.example.app", verbose: true)) {
      CallTelemetry.current?.setNormal("url", forKey: "payload")
      CallTelemetry.current?.setInt(12, forKey: "payload")
      return "ok"
    }
    #expect((recorder.messages[1].hasSuffix(" {payload=12, payload=url}")) == (true))
  }

  @Test
  func columnsAreAppendedToTheFailureLine() async {
    let recorder = RecordingLogger()
    let telemetry = CompanionTelemetry(
      logger: IDBLogger(loggers: [recorder]),
      reporter: RecordingEventReporter())
    try? await telemetry.clientStreaming("install") { () async throws in
      CallTelemetry.current?.setNormal("download", forKey: "failure_stage")
      throw TelemetryTestError()
    }
    #expect((recorder.messages.count) == (2))
    #expect((recorder.messages[1].hasPrefix("install failed after ")) == (true))
    #expect((recorder.messages[1].hasSuffix(": request exploded {failure_stage=download}")) == (true))
  }

  @Test
  func lsSummarizeCountsFilesAndListings() {
    #expect((LsMethodHandler.summarize(Idb_LsResponse())) == ("0 entries"))
    let filesOnly = Idb_LsResponse.with {
      $0.files = [
        Idb_FileInfo.with { $0.path = "a" },
        Idb_FileInfo.with { $0.path = "b" },
      ]
    }
    #expect((LsMethodHandler.summarize(filesOnly)) == ("2 entries"))
    let mixed = Idb_LsResponse.with {
      $0.files = [Idb_FileInfo.with { $0.path = "a" }]
      $0.listings = [
        Idb_FileListing.with {
          $0.parent = Idb_FileInfo.with { $0.path = "parent" }
          $0.files = [
            Idb_FileInfo.with { $0.path = "b" },
            Idb_FileInfo.with { $0.path = "c" },
          ]
        }
      ]
    }
    #expect((LsMethodHandler.summarize(mixed)) == ("3 entries"))
    let singular = Idb_LsResponse.with {
      $0.files = [Idb_FileInfo.with { $0.path = "only" }]
    }
    #expect((LsMethodHandler.summarize(singular)) == ("1 entry"))
  }

  @Test
  func formatBytesUsesUnits() {
    #expect((PullMethodHandler.formatBytes(0)) == ("0 B"))
    #expect((PullMethodHandler.formatBytes(512)) == ("512 B"))
    #expect((PullMethodHandler.formatBytes(1023)) == ("1023 B"))
    #expect((PullMethodHandler.formatBytes(1024)) == ("1.0 KB"))
    #expect((PullMethodHandler.formatBytes(1536)) == ("1.5 KB"))
    #expect((PullMethodHandler.formatBytes(5 * 1024 * 1024)) == ("5.0 MB"))
    #expect((PullMethodHandler.formatBytes(2 * 1024 * 1024 * 1024)) == ("2.0 GB"))
  }

  /// The event name of every RPC the companion reports, as consumers see it.
  ///
  /// Spelled out rather than derived: these are a logged dimension, so a proto rename that
  /// silently moved one would otherwise reach Scuba with nothing failing in between.
  private static let expectedMethodNames: Set<String> = [
    "connect", "debugserver", "dap", "forward_port", "describe", "install", "log",
    "xctrace_record", "profile", "accessibility_info", "accessibility_action",
    "accessibility_quiescence",
    "focus", "hid", "open_url",
    "set_location", "send_notification", "delivered_notifications", "clear_delivered_notifications",
    "simulate_memory_warning", "approve", "revoke", "clear_keychain", "contacts_update",
    "contacts_clear", "photos_clear", "lock_screen", "setting", "get_setting", "list_settings", "launch",
    "list_apps", "terminate", "uninstall", "add_media", "inject_audio", "inject_video", "record",
    "screenshot", "video_stream", "crash_delete", "crash_list", "crash_show", "xctest_list_bundles",
    "xctest_list_tests", "xctest_run", "repl", "ls", "mkdir", "mv", "rm", "pull", "push", "tail",
    "get_orientation", "set_orientation", "hinge_angle",
  ]

  @Test
  func generatedDescriptorsCarryTheReportedMethodNames() {
    let descriptorNames = Set(Idb_CompanionService.Method.descriptors.map(\.method))
    #expect((descriptorNames) == (Self.expectedMethodNames))
  }

  @Test
  func bidiStreamingFailureReportsFailureSubject() async {
    let (telemetry, recorder) = makeTelemetry()
    do {
      try await telemetry.bidiStreaming("repl") {
        throw TelemetryTestError()
      }
      Issue.record("bidiStreaming should rethrow the body's error")
    } catch {
      #expect((error is TelemetryTestError))
    }
    #expect((recorder.subjects.count) == (1))
    let subject = recorder.subjects[0]
    #expect((subject.eventName) == ("repl"))
    #expect((subject.eventType) == (.failure))
  }
}
