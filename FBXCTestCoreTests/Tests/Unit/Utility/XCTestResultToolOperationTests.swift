/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBXCTestCore
import Foundation
import Testing

/// Pins how `XCTestResultToolOperation` launches `xcrun xcresulttool` and what a
/// caller sees when it fails: which exit-code policy applies, and what reaches an
/// optional logger.
///
/// Nothing here asserts a desirable design. Each case records what callers observe
/// today so that a later replacement has to either reproduce it or change it
/// deliberately.
@Suite(.serialized)
final class XCTestResultToolOperationTests {

  private let temporaryDirectory: URL

  init() throws {
    temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("XCTestResultToolOperationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: temporaryDirectory)
  }

  private var absentResultBundlePath: String {
    temporaryDirectory.appendingPathComponent("Absent.xcresult").path
  }

  // MARK: - Decoding

  @Test
  func aJSONObjectDecodesToItsFields() throws {
    let actions = try XCTestResultToolOperation.jsonObject(parsing: #"{"actions": {"_values": []}}"#)["actions"] as? [String: Any]
    #expect((actions?["_values"] as? [Any])?.count == 0)
  }

  @Test
  func outputThatIsNotJSONIsRejected() {
    let error = #expect(throws: (any Error).self) { try XCTestResultToolOperation.jsonObject(parsing: "xcresulttool: error: something went wrong") }
    let description = error?.localizedDescription ?? ""
    #expect(description.contains("something went wrong"), "\(description)")
  }

  @Test
  func aJSONArrayIsRejected() {
    #expect(throws: (any Error).self) { try XCTestResultToolOperation.jsonObject(parsing: "[1, 2]") }
  }

  // MARK: - Exit code policy

  @Test
  func gettingJSONFailsWhenTheToolExitsNonZero() async throws {
    do {
      _ = try await XCTestResultToolOperation.json(from: absentResultBundlePath, forId: nil, logger: nil)
      Issue.record("Expected reading an absent result bundle to fail")
    } catch {
      // Every entry point launches with `[0]` as the only acceptable exit code, so a
      // failure surfaces as the launcher's exit-code rejection rather than as
      // anything `xcresulttool` said about the request.
      #expect(error.localizedDescription.contains("is not acceptable"), "\(error.localizedDescription)")
    }
  }

  @Test
  func exportingAFileFailsWhenTheToolExitsNonZero() async throws {
    do {
      _ = try await XCTestResultToolOperation.exportFile(
        from: absentResultBundlePath,
        to: temporaryDirectory.appendingPathComponent("out.bin").path,
        forId: "0~abcdef",
        logger: nil)
      Issue.record("Expected exporting from an absent result bundle to fail")
    } catch {
      #expect(error.localizedDescription.contains("is not acceptable"), "\(error.localizedDescription)")
    }
  }

  @Test
  func anUnrecognizedScreenshotEncodingIsMaskedByAnExportFailure() async throws {
    do {
      _ = try await XCTestResultToolOperation.exportJPEG(
        from: absentResultBundlePath,
        to: temporaryDirectory.appendingPathComponent("out.jpg").path,
        forId: "0~abcdef",
        type: "public.png",
        logger: nil)
      Issue.record("Expected the failing export to throw")
    } catch {
      // The export runs first, so an unusable result bundle masks the encoding
      // check entirely — the caller never learns the encoding was wrong.
      #expect(error.localizedDescription.contains("is not acceptable"), "\(error.localizedDescription)")
      #expect(!error.localizedDescription.contains("Unrecognized XCTest screenshot encoding"), "\(error.localizedDescription)")
    }
  }

  // MARK: - Legacy flag

  @Test
  func theLegacyFlagFollowsTheSubcommand() {
    #expect(
      XCTestResultToolOperation.withLegacyFlag(["get", "--path", "P", "--format", "json"])
        == ["get", "--legacy", "--path", "P", "--format", "json"])
    #expect(
      XCTestResultToolOperation.withLegacyFlag(["export", "--path", "P", "--type", "file"])
        == ["export", "--legacy", "--path", "P", "--type", "file"])
  }

  @Test
  func theInstalledToolDoesNotRejectGettingJSONAsDeprecated() async throws {
    let logger = RecordingLogger()
    _ = try? await XCTestResultToolOperation.json(from: absentResultBundlePath, forId: nil, logger: logger)
    try expectTheToolRanWithoutADeprecationError(logger.messages)
  }

  @Test
  func theInstalledToolDoesNotRejectExportingAFileAsDeprecated() async throws {
    let logger = RecordingLogger()
    try? await XCTestResultToolOperation.exportFile(
      from: absentResultBundlePath,
      to: temporaryDirectory.appendingPathComponent("out.bin").path,
      forId: "0~abcdef",
      logger: logger)
    try expectTheToolRanWithoutADeprecationError(logger.messages)
  }

  @Test
  func theInstalledToolDoesNotRejectExportingADirectoryAsDeprecated() async throws {
    let logger = RecordingLogger()
    try? await XCTestResultToolOperation.exportDirectory(
      from: absentResultBundlePath,
      to: temporaryDirectory.appendingPathComponent("out").path,
      forId: "0~abcdef",
      logger: logger)
    try expectTheToolRanWithoutADeprecationError(logger.messages)
  }

  /// The tool must have launched and rejected the absent bundle by name, so a launch failure, lost
  /// stderr or a rejected argument (a deprecation, or an unknown `--legacy`) cannot pass.
  private func expectTheToolRanWithoutADeprecationError(_ messages: [String]) throws {
    try #require(messages.contains { $0.contains("Launched with pid") }, "\(messages)")
    // Stderr arrives in arbitrary chunks trimmed of newlines, so the bundle name is searched in the
    // chunks rejoined without separators.
    let output = messages.joined()
    try #require(
      output.contains((absentResultBundlePath as NSString).lastPathComponent),
      "xcresulttool did not report the absent bundle: \(messages)")
    #expect(!output.contains("deprecated"), "\(messages)")
  }

  // MARK: - Logging

  @Test
  func aSuppliedLoggerReceivesBothTheLaunchAndTheToolsStandardError() async throws {
    // What the tool writes to stderr for this exact invocation, captured by running
    // it directly. Asserting against this rather than a hardcoded message keeps the
    // case pinned to stderr forwarding itself, whatever the current toolchain emits.
    let capturedStdErr = try await standardError(
      ofDirectlyRunning: ["xcresulttool"] + XCTestResultToolOperation.withLegacyFlag(["get", "--path", absentResultBundlePath, "--format", "json"]))
    guard !capturedStdErr.isEmpty else {
      Issue.record("xcresulttool wrote nothing to stderr for a failing get; this case needs a stderr-producing invocation to pin forwarding")
      return
    }

    // A logger is the only way to see the tool's stderr from these entry points:
    // the stderr-to-logger sink is attached only when one is supplied, and every
    // failing run throws the exit-code rejection rather than returning output.
    let logger = RecordingLogger()

    do {
      _ = try await XCTestResultToolOperation.json(from: absentResultBundlePath, forId: nil, logger: logger)
    } catch {
      // The failure itself is covered above; this case is about what was logged.
    }

    let messages = logger.messages
    #expect(
      messages.contains { $0.contains("Launched with pid") },
      "Lifecycle logging should announce the launch: \(messages)")

    // The tool's stderr is not forwarded line by line. It arrives as arbitrary read
    // chunks, trimmed of newlines at each chunk's edges.
    //
    // The walk below verifies the whole of the captured stderr reached the logger
    // in order, whatever the chunking: a message that continues the expected text
    // consumes it, an immediate repeat of it that the text does not also continue
    // with is a duplicate delivery, and anything else (the lifecycle lines) is
    // passed over.
    var remainder = Substring(capturedStdErr.replacingOccurrences(of: "\n", with: ""))
    var duplicated = [String]()
    var index = 0
    while index < messages.count {
      let chunk = messages[index].replacingOccurrences(of: "\n", with: "")
      guard !chunk.isEmpty, remainder.hasPrefix(chunk) else {
        index += 1
        continue
      }
      remainder = remainder.dropFirst(chunk.count)
      if index + 1 < messages.count, messages[index + 1] == messages[index], !remainder.hasPrefix(chunk) {
        duplicated.append(messages[index])
        index += 2
      } else {
        index += 1
      }
    }
    #expect(
      remainder.isEmpty,
      "The whole of the tool's stderr should reach the logger; never received: \(remainder) given: \(messages)")
    #expect(
      duplicated.isEmpty,
      "Every stderr chunk should reach the logger exactly once; these arrived twice: \(duplicated)")
  }

  private func standardError(ofDirectlyRunning arguments: [String]) async throws -> String {
    try await Subprocess(executable: "/usr/bin/xcrun", arguments: arguments)
      .run(output: .nullDevice, error: .string, exitPolicy: .any)
      .standardError
  }
}

// MARK: - Logger double

/// Records every line handed to it, so a test can assert on what a process forwarded.
private final class RecordingLogger: ControlCoreLogger, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  var messages: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  var name: String? { nil }
  var level: ControlCoreLogLevel { .multiple }

  func log(_ message: String) -> any ControlCoreLogger {
    lock.lock()
    recorded.append(message)
    lock.unlock()
    return self
  }

  func info() -> any ControlCoreLogger { self }
  func debug() -> any ControlCoreLogger { self }
  func error() -> any ControlCoreLogger { self }
  func withName(_ name: String) -> any ControlCoreLogger { self }
  func withDateFormatEnabled(_ enabled: Bool) -> any ControlCoreLogger { self }
}
