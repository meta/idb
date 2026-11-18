/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBControlCore
import FBVideoCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import Testing

/// A recording whose `stop()` either returns a URL or fails, standing in for the finalize step.
private final class StubRecording: VideoRecording, @unchecked Sendable {
  private let result: Result<URL, any Error>

  init(_ result: Result<URL, any Error>) {
    self.result = result
  }

  func stop() async throws -> URL {
    try result.get()
  }
}

/// A recording that counts the times it is stopped.
private final class CountingRecording: VideoRecording, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var stops: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func stop() async throws -> URL {
    lock.lock()
    count += 1
    lock.unlock()
    return URL(fileURLWithPath: "/dev/null")
  }
}

/// A logger that keeps what it is sent, and which of it was sent at error level.
private final class RecordingLogger: ControlCoreLogger, @unchecked Sendable {
  private final class Store: @unchecked Sendable {
    let lock = NSLock()
    var logged: [(message: String, isError: Bool)] = []
  }

  private let store: Store
  private let isError: Bool

  convenience init() {
    self.init(store: Store(), isError: false)
  }

  private init(store: Store, isError: Bool) {
    self.store = store
    self.isError = isError
  }

  var messages: [String] {
    store.lock.lock()
    defer { store.lock.unlock() }
    return store.logged.map(\.message)
  }

  var errors: [String] {
    store.lock.lock()
    defer { store.lock.unlock() }
    return store.logged.filter(\.isError).map(\.message)
  }

  @discardableResult
  func log(_ message: String) -> any ControlCoreLogger {
    store.lock.lock()
    store.logged.append((message, isError))
    store.lock.unlock()
    return self
  }

  func info() -> any ControlCoreLogger { RecordingLogger(store: store, isError: false) }
  func debug() -> any ControlCoreLogger { RecordingLogger(store: store, isError: false) }
  func error() -> any ControlCoreLogger { RecordingLogger(store: store, isError: true) }
  func withName(_ name: String) -> any ControlCoreLogger { self }
  func withDateFormatEnabled(_ enabled: Bool) -> any ControlCoreLogger { self }
  var name: String? { nil }
  var level: ControlCoreLogLevel { .multiple }
}

private struct StubError: Error, CustomStringConvertible {
  let description: String
}

/// Decompresses with the system `gzip`, as a client does.
private func gunzip(_ data: Data) throws -> Data {
  let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("record-gunzip-\(UUID().uuidString).gz")
  try data.write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  let gzip = Process()
  gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
  gzip.arguments = ["-dc", file.path]
  let output = Pipe()
  gzip.standardOutput = output
  try gzip.run()
  let decompressed = output.fileHandleForReading.readDataToEndOfFile()
  gzip.waitUntilExit()
  #expect(gzip.terminationStatus == 0)
  return decompressed
}

@Suite
struct RecordMethodHandlerTests {

  /// The ordinary path is unchanged: the URL the recorder reports is the one delivered.
  @Test
  func finalizeReportsTheRecordedFileWhenStoppingSucceeds() async {
    let recorded = URL(fileURLWithPath: "/tmp/recorded.mp4")
    let logger = RecordingLogger()

    let (outputURL, finalizeError) = await RecordMethodHandler.finalizeForDelivery(
      StubRecording(.success(recorded)),
      fallbackPath: "/tmp/started-against.mp4",
      logger: logger)

    #expect(outputURL == recorded)
    #expect(finalizeError == nil)
    #expect(logger.messages.isEmpty)
  }

  /// The failure this exists for: the frames are already on disk, so a finalize that fails must
  /// still yield a file to send. Throwing instead skipped the transfer and the caller received
  /// nothing at all.
  @Test
  func finalizeStillYieldsAFileToSendWhenStoppingFails() async {
    let startedAgainst = "/tmp/started-against.mp4"
    let failure = StubError(description: "AVAssetWriter failed to finish writing")
    let logger = RecordingLogger()

    let (outputURL, finalizeError) = await RecordMethodHandler.finalizeForDelivery(
      StubRecording(.failure(failure)),
      fallbackPath: startedAgainst,
      logger: logger)

    #expect(outputURL == URL(fileURLWithPath: startedAgainst))
    #expect(finalizeError != nil)
  }

  /// The failure is returned, not swallowed: the caller reports it after delivering the file, so a
  /// broken recording is never silently presented as a good one.
  @Test
  func finalizeHandsBackTheOriginalFailure() async {
    let failure = StubError(description: "sentinel finalize failure")

    let (_, finalizeError) = await RecordMethodHandler.finalizeForDelivery(
      StubRecording(.failure(failure)),
      fallbackPath: "/tmp/started-against.mp4",
      logger: RecordingLogger())

    #expect((finalizeError as? StubError)?.description == failure.description)
  }

  /// A dropped recording is worth a line in the companion log, since the client only learns the
  /// file is short and not why.
  @Test
  func finalizeLogsWhyTheRecordingWasNotFinalized() async {
    let logger = RecordingLogger()

    _ = await RecordMethodHandler.finalizeForDelivery(
      StubRecording(.failure(StubError(description: "sentinel finalize failure"))),
      fallbackPath: "/tmp/started-against.mp4",
      logger: logger)

    #expect(logger.messages.contains { $0.contains("sentinel finalize failure") })
  }

  /// A client that goes away before its stop leaves a recording nothing else would stop.
  @Test
  func aRecordingIsStoppedWhenItsCallEndsBeforeItsStop() async {
    let recording = CountingRecording()
    let failure = StubError(description: "the request stream ended")

    let error = await #expect(throws: StubError.self) {
      try await RecordMethodHandler.stoppingOnFailure(recording, logger: RecordingLogger()) {
        throw failure
      }
    }

    #expect(error?.description == failure.description)
    #expect(recording.stops == 1)
  }

  @Test
  func aCancelledCallStillStopsItsRecording() async {
    let recording = CountingRecording()
    let call = Task {
      try await RecordMethodHandler.stoppingOnFailure(recording, logger: RecordingLogger()) {
        try await Task.sleep(for: .seconds(3600))
      }
    }
    call.cancel()

    await #expect(throws: CancellationError.self) {
      try await call.value
    }
    #expect(recording.stops == 1)
  }

  /// Two calls record at once, each with its own recording. Cancelling one, as a killed client does,
  /// stops that call's recording and leaves the other's running until its own call reaches its stop.
  @Test
  func cancellingOneCallLeavesTheOtherCallsRecordingRunning() async throws {
    let cancelled = CountingRecording()
    let running = CountingRecording()
    let (stopArrives, stop) = AsyncStream.makeStream(of: Void.self)
    let cancelledCall = Task {
      try await RecordMethodHandler.stoppingOnFailure(cancelled, logger: RecordingLogger()) {
        try await Task.sleep(for: .seconds(3600))
      }
    }
    let runningCall = Task {
      try await RecordMethodHandler.stoppingOnFailure(running, logger: RecordingLogger()) {
        for await _ in stopArrives { return }
      }
    }

    cancelledCall.cancel()
    await #expect(throws: CancellationError.self) {
      try await cancelledCall.value
    }
    #expect(cancelled.stops == 1)
    #expect(running.stops == 0)

    stop.yield()
    try await runningCall.value
    #expect(running.stops == 0, "a call that reaches its stop leaves its recording to the stop")
    #expect(cancelled.stops == 1)
  }

  /// Once the call has failed nothing reaches the client, so a recording that will not stop is
  /// reported where it can still be seen.
  @Test
  func aRecordingThatWillNotStopAfterItsCallEndsIsLoggedAsAnError() async {
    let recording = StubRecording(.failure(StubError(description: "sentinel stop failure")))
    let logger = RecordingLogger()
    let failure = StubError(description: "the request stream ended")

    let error = await #expect(throws: StubError.self) {
      try await RecordMethodHandler.stoppingOnFailure(recording, logger: logger) {
        throw failure
      }
    }

    #expect(error?.description == failure.description)
    #expect(logger.errors.contains { $0.contains("sentinel stop failure") })
  }

  /// A call that reaches its stop leaves the recording to the code that stops and delivers it.
  @Test
  func aCallThatReachesItsStopDoesNotStopTheRecordingItself() async throws {
    let recording = CountingRecording()

    try await RecordMethodHandler.stoppingOnFailure(recording, logger: RecordingLogger()) {}

    #expect(recording.stops == 0)
  }

  /// Two recordings streamed at once must not write the same file, or one would send a file the other
  /// is still writing.
  @Test
  func eachStreamedRecordingIsStagedInAFileOfItsOwn() {
    let directory = "/tmp/companion-aux"
    let first = RecordMethodHandler.stagingPath(in: directory)
    let second = RecordMethodHandler.stagingPath(in: directory)

    #expect(first != second)
    for path in [first, second] {
      #expect((path as NSString).deletingLastPathComponent == directory)
      #expect((path as NSString).pathExtension == "mp4")
    }
  }

  /// The claim the fix exists to make: a recording that failed to finalize is still delivered, and
  /// the failure is reported only afterwards. Before the fix the error was raised first and the
  /// caller received nothing at all.
  @Test
  func deliveryHappensBeforeTheFinalizeFailureIsReported() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("record-deliver-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorded = directory.appendingPathComponent("segment_001.mp4")
    try Data(repeating: 0xAB, count: 64 * 1024).write(to: recorded)

    let collector = CollectingWriter<Idb_RecordResponse>()
    let failure = StubError(description: "AVAssetWriter failed to finish writing")

    var thrown: (any Error)?
    do {
      try await RecordMethodHandler.deliverThenReport(
        outputURL: recorded,
        streamingToClient: true,
        localFilePath: "",
        finalizeError: failure,
        responseStream: RPCWriter(wrapping: collector),
        logger: RecordingLogger())
    } catch {
      thrown = error
    }

    // The failure still fails the RPC...
    #expect((thrown as? StubError)?.description == failure.description)
    // ...but the bytes went out first, which is what was being thrown away.
    let delivered = collector.elements.reduce(0) { $0 + $1.payload.data.count }
    #expect(delivered > 0, "expected the recording to be sent before the failure was reported")
  }

  /// Nothing to send and gzip would fail on the missing path with an error that hides the real one,
  /// so the transfer is skipped and the finalize failure is still what surfaces.
  @Test
  func aMissingFileIsNotSentAndTheFinalizeFailureStillSurfaces() async {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("absent-\(UUID().uuidString).mp4")
    let collector = CollectingWriter<Idb_RecordResponse>()
    let failure = StubError(description: "sentinel finalize failure")

    var thrown: (any Error)?
    do {
      try await RecordMethodHandler.deliverThenReport(
        outputURL: missing,
        streamingToClient: true,
        localFilePath: "",
        finalizeError: failure,
        responseStream: RPCWriter(wrapping: collector),
        logger: RecordingLogger())
    } catch {
      thrown = error
    }

    #expect((thrown as? StubError)?.description == failure.description)
    #expect(collector.elements.isEmpty)
  }

  /// The ordinary path is untouched: a clean finalize delivers the recording, gzipped, and returns without throwing.
  @Test
  func aCleanFinalizeDeliversAndDoesNotThrow() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("record-clean-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorded = directory.appendingPathComponent("segment_001.mp4")
    try Data(repeating: 0xCD, count: 32 * 1024).write(to: recorded)

    let collector = CollectingWriter<Idb_RecordResponse>()

    try await RecordMethodHandler.deliverThenReport(
      outputURL: recorded,
      streamingToClient: true,
      localFilePath: "",
      finalizeError: nil,
      responseStream: RPCWriter(wrapping: collector),
      logger: RecordingLogger())

    let delivered = collector.elements.reduce(into: Data()) { $0.append($1.payload.data) }
    #expect(try gunzip(delivered) == Data(contentsOf: recorded))
  }

  @Test(.enabled(if: getuid() != 0, "root reads a file whatever its mode"))
  func aRecordingThatCannotBeCompressedReportsTheExitCode() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("record-unreadable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorded = directory.appendingPathComponent("segment_001.mp4")
    try Data(repeating: 0xCD, count: 1024).write(to: recorded)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: recorded.path)
    let collector = CollectingWriter<Idb_RecordResponse>()

    let error = await #expect(throws: RPCError.self) {
      try await RecordMethodHandler.deliverThenReport(
        outputURL: recorded,
        streamingToClient: true,
        localFilePath: "",
        finalizeError: nil,
        responseStream: RPCWriter(wrapping: collector),
        logger: RecordingLogger())
    }

    #expect(error?.message.hasPrefix("Draining operation failed with exit code 1: ") == true)
    #expect(error?.message.contains("Permission denied") == true)
    #expect(collector.elements.isEmpty)
  }
}
