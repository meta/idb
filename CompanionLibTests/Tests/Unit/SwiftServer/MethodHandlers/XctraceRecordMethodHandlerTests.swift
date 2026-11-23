/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBControlCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import Testing

/// An xctrace that exits with `status` on its own, or never exits until stopped when `status` is nil.
private final class FakeRecording: XCTraceRecording, @unchecked Sendable {
  private let status: Int32?
  private let lock = NSLock()
  private var timeouts: [TimeInterval] = []

  init(exitingWith status: Int32?) {
    self.status = status
  }

  var stopTimeouts: [TimeInterval] {
    lock.lock()
    defer { lock.unlock() }
    return timeouts
  }

  func exitStatus() async throws -> Int32 {
    if let status {
      return status
    }
    try await Task.sleep(for: .seconds(3600))
    throw CancellationError()
  }

  func stop(withTimeout timeout: TimeInterval) async throws -> URL {
    lock.withLock { timeouts.append(timeout) }
    return URL(fileURLWithPath: "/tmp/fake.trace")
  }
}

private let logger = ControlCoreGlobalConfiguration.systemLogger(writingToStderr: false, debugLogging: false)

/// Extracts a gzipped tar with the system `tar`, as a client does.
private func extract(_ archive: Data, into destination: URL) throws {
  try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
  let file = destination.appendingPathExtension("tar.gz")
  try archive.write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  let tar = try Process.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", file.path, "-C", destination.path])
  tar.waitUntilExit()
  #expect(tar.terminationStatus == 0)
}

private enum Outcome {
  case returned(Idb_XctraceRecordRequest.Stop)
  case threw(any Error)
  case stillWaiting
}

/// A request stream the test controls: it yields what the test sends and never ends on its own.
private func clientStream() -> (RequestStreamReader<Idb_XctraceRecordRequest>, AsyncThrowingStream<Idb_XctraceRecordRequest, any Error>.Continuation) {
  let (stream, continuation) = AsyncThrowingStream.makeStream(of: Idb_XctraceRecordRequest.self, throwing: (any Error).self)
  return (RequestStreamReader(RPCAsyncSequence(wrapping: stream)), continuation)
}

private func stopRequest(timeout: Double) -> Idb_XctraceRecordRequest {
  .with { $0.stop = .with { $0.timeout = timeout } }
}

/// How `recordUntilStopped` has finished after `wait`, cancelling it if it has not.
private func outcome(of recording: some XCTraceRecording, requests: RequestStreamReader<Idb_XctraceRecordRequest>, after wait: Duration = .milliseconds(300)) async -> Outcome {
  await withTaskGroup(of: Outcome.self) { group in
    group.addTask {
      do {
        return .returned(try await XctraceRecordMethodHandler.recordUntilStopped(requestStream: requests, recording: recording))
      } catch {
        return .threw(error)
      }
    }
    group.addTask {
      try? await Task.sleep(for: wait)
      return .stillWaiting
    }
    let first = await group.next() ?? .stillWaiting
    group.cancelAll()
    return first
  }
}

@Suite
struct XctraceRecordMethodHandlerTests {

  @Test
  func stopFromTheClientStopsXctraceWithTheRequestedTimeout() async throws {
    let recording = FakeRecording(exitingWith: nil)
    let (requests, client) = clientStream()
    client.yield(stopRequest(timeout: 42))

    let result = await outcome(of: recording, requests: requests)

    guard case let .returned(stop) = result else {
      Issue.record("expected recording to end on Stop, got \(result)")
      return
    }
    #expect(stop.timeout == 42)
    #expect(recording.stopTimeouts == [42])
  }

  @Test
  func stopWithoutATimeoutUsesTheDefault() async throws {
    let recording = FakeRecording(exitingWith: nil)
    let (requests, client) = clientStream()
    client.yield(stopRequest(timeout: 0))

    _ = await outcome(of: recording, requests: requests)

    #expect(recording.stopTimeouts == [DefaultXCTraceRecordStopTimeout])
  }

  /// A clean exit (such as reaching its time limit) leaves a trace to collect, so the session keeps
  /// waiting for the client to ask for it.
  @Test
  func xctraceExitingCleanlyStillWaitsForStop() async throws {
    let recording = FakeRecording(exitingWith: 0)
    let (requests, _) = clientStream()

    let result = await outcome(of: recording, requests: requests)

    guard case .stillWaiting = result else {
      Issue.record("expected recording to wait for Stop after a clean exit, got \(result)")
      return
    }
  }

  @Test
  func xctraceFailingBeforeStopEndsTheSession() async throws {
    let recording = FakeRecording(exitingWith: 1)
    let (requests, _) = clientStream()

    let result = await outcome(of: recording, requests: requests)

    guard case let .threw(error) = result else {
      Issue.record("expected recording to fail once xctrace exited, got \(result)")
      return
    }
    #expect((error as? RPCError)?.message.contains("status 1") == true)
    #expect(recording.stopTimeouts.isEmpty)
  }

  @Test
  func theTraceIsSentAsASingleArchive() async throws {
    let trace = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xctrace-send-\(UUID().uuidString).trace")
    try FileManager.default.createDirectory(at: trace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: trace) }
    try Data(repeating: 0xAB, count: 64 * 1024).write(to: trace.appendingPathComponent("sample"))
    let collector = CollectingWriter<Idb_XctraceRecordResponse>()

    try await XctraceRecordMethodHandler.sendTrace(atPath: trace.path, responseStream: RPCWriter(wrapping: collector), logger: logger)

    let received = collector.elements.reduce(into: Data()) { $0.append($1.payload.data) }
    #expect(gzipMembers(in: received) == 1)
  }

  @Test(.enabled(if: getuid() != 0, "root reads a file whatever its mode"))
  func aTraceThatCannotBeArchivedReportsTheExitCode() async throws {
    let trace = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xctrace-unreadable-\(UUID().uuidString).trace")
    try FileManager.default.createDirectory(at: trace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: trace) }
    let sample = trace.appendingPathComponent("sample")
    try Data(repeating: 0xAB, count: 1024).write(to: sample)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sample.path)
    let collector = CollectingWriter<Idb_XctraceRecordResponse>()

    let error = await #expect(throws: RPCError.self) {
      try await XctraceRecordMethodHandler.sendTrace(atPath: trace.path, responseStream: RPCWriter(wrapping: collector), logger: logger)
    }

    #expect(error?.message.hasPrefix("Draining operation failed with exit code 1: ") == true)
    #expect(error?.message.contains("Permission denied") == true)
  }

  @Test
  func theTraceArchiveExtractsToTheTrace() async throws {
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xctrace-extract-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let trace = scratch.appendingPathComponent("recording.trace")
    try FileManager.default.createDirectory(at: trace.appendingPathComponent("corespace/run1"), withIntermediateDirectories: true)
    let sample = Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    try sample.write(to: trace.appendingPathComponent("corespace/run1/store"))
    try Data("form".utf8).write(to: trace.appendingPathComponent("form.template"))
    let collector = CollectingWriter<Idb_XctraceRecordResponse>()

    try await XctraceRecordMethodHandler.sendTrace(atPath: trace.path, responseStream: RPCWriter(wrapping: collector), logger: logger)

    let extracted = scratch.appendingPathComponent("extracted")
    try extract(collector.elements.reduce(into: Data()) { $0.append($1.payload.data) }, into: extracted)
    #expect(FileManager.default.contents(atPath: extracted.appendingPathComponent("corespace/run1/store").path) == sample)
    #expect(FileManager.default.contents(atPath: extracted.appendingPathComponent("form.template").path) == Data("form".utf8))
  }

  @Test
  func postProcessingWithoutArgumentsPassesTheTraceThrough() async throws {
    let traceFile = URL(fileURLWithPath: "/tmp/does-not-need-to-exist.trace")

    #expect(try await XctraceRecordMethodHandler.postProcess(arguments: nil, traceFile: traceFile, logger: nil) == traceFile)
    #expect(try await XctraceRecordMethodHandler.postProcess(arguments: [], traceFile: traceFile, logger: nil) == traceFile)
  }

  @Test
  func postProcessingReturnsTheToolOutputBesideTheTrace() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (traceFile, result) = try await postProcess(
      in: directory, script: #"printf '%s\n' "$@" > "$3""#, extraArguments: ["--extra", "value"])

    #expect(result == traceFile.deletingLastPathComponent().appendingPathComponent("processed.trace"))
    #expect(
      try String(contentsOf: result, encoding: .utf8)
        == [traceFile.path, "-o", result.path, "--extra", "value"].joined(separator: "\n") + "\n",
      "the tool receives the trace, the output path and the extra arguments in that order")
  }

  @Test
  func postProcessingFailsWhenTheToolExitsNonZero() async throws {
    await #expect(throws: (any Error).self) {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      _ = try await postProcess(in: directory, script: "exit 7", logger: logger)
    }
  }

  @Test
  func postProcessingHandsTheToolAnOpenStandardInputThatIsNeverWritten() async throws {
    // A pipe rules out /dev/null and a closed descriptor; a `read` that waits out its timeout rather
    // than returning at once rules out end-of-file. bash 3.2 exits 1 for both, hence the clock.
    // perl fstats descriptor 0 itself; `[ -p /dev/stdin ]` goes through devfs and fails on CI hosts.
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (_, result) = try await postProcess(
      in: directory, script: #"perl -e 'exit 3 unless -p STDIN' || exit 3; start=$SECONDS; read -t 2 _ && exit 4; [ $((SECONDS - start)) -ge 1 ] || exit 5; : > "$3""#)

    #expect(FileManager.default.fileExists(atPath: result.path))
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Runs `script` in `directory` as the post-processing tool: `bash <script> <trace> -o <output> <extra...>`.
  private func postProcess(
    in directory: URL, script: String, extraArguments: [String] = [], logger: (any ControlCoreLogger)? = nil
  ) async throws -> (traceFile: URL, result: URL) {
    let scriptFile = directory.appendingPathComponent("tool.sh")
    try script.write(to: scriptFile, atomically: true, encoding: .utf8)
    let traceFile = directory.appendingPathComponent("recording.trace")

    let result = try await XctraceRecordMethodHandler.postProcess(
      arguments: ["/bin/bash", scriptFile.path, "processed.trace"] + extraArguments,
      traceFile: traceFile, logger: logger)
    return (traceFile, result)
  }
}
