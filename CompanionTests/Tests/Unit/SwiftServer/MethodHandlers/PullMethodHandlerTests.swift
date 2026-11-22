/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBControlCore
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import XCTest

private let logger = ControlCoreGlobalConfiguration.systemLogger(writingToStderr: false, debugLogging: false)

private final class ScriptedFilePuller: FilePulling, @unchecked Sendable {
  let temporaryDirectory = TemporaryDirectory(logger: logger)
  let holdsOpen: Bool
  let land: @Sendable (String) throws -> Void
  let onStart: @Sendable () -> Void
  let onStop: @Sendable () -> Void

  /// A pull lands at its destination at once, writing whatever `land` puts there, or with `holdsOpen` runs until it
  /// is cancelled.
  init(
    holdsOpen: Bool = false,
    land: @escaping @Sendable (String) throws -> Void = { _ in },
    onStart: @escaping @Sendable () -> Void = {},
    onStop: @escaping @Sendable () -> Void = {}
  ) {
    self.holdsOpen = holdsOpen
    self.land = land
    self.onStart = onStart
    self.onStop = onStop
  }

  func pullFilePath(_ path: String, destinationPath: String, containerType: String?) async throws -> String {
    onStart()
    guard holdsOpen else {
      try land(destinationPath)
      return destinationPath
    }
    do {
      try await Task.sleep(nanoseconds: 60_000_000_000)
    } catch {
      onStop()
      throw error
    }
    return destinationPath
  }
}

private final class SentResponses: @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [Idb_PullResponse] = []

  var all: [Idb_PullResponse] { lock.withLock { responses } }

  func append(_ response: Idb_PullResponse) {
    lock.withLock { responses.append(response) }
  }
}

/// Pulls by writing `contents` to the destination, unreadable when `readable` is false.
private final class LocalFilePuller: FilePulling, @unchecked Sendable {
  let temporaryDirectory = TemporaryDirectory(logger: logger)
  let contents: Data
  let readable: Bool

  init(contents: Data, readable: Bool = true) {
    self.contents = contents
    self.readable = readable
  }

  func pullFilePath(_ path: String, destinationPath: String, containerType: String?) async throws -> String {
    try contents.write(to: URL(fileURLWithPath: destinationPath))
    if !readable {
      try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: destinationPath)
    }
    return destinationPath
  }
}

/// Extracts a gzipped tar with the system `tar`, as a client does.
private func extract(_ archive: Data) throws -> URL {
  let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pull-extract-\(UUID().uuidString)")
  let destination = scratch.appendingPathComponent("extracted")
  try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
  let file = scratch.appendingPathComponent("archive.tar.gz")
  try archive.write(to: file)
  let tar = try Process.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", file.path, "-C", destination.path])
  tar.waitUntilExit()
  XCTAssertEqual(tar.terminationStatus, 0)
  return destination
}

final class PullMethodHandlerTests: XCTestCase {

  private let request = Idb_PullRequest.with {
    $0.srcPath = "Documents/file.txt"
    $0.dstPath = "/tmp/file.txt"
  }

  func testAPullToADestinationSendsWhereItLanded() async throws {
    let sent = SentResponses()
    try await PullMethodHandler.pull(request, using: ScriptedFilePuller(), logger: logger, cancellation: ServerContext.RPCCancellationHandle()) {
      sent.append($0)
    }
    XCTAssertEqual(sent.all, [.with { $0.payload = .with { $0.source = .filePath("/tmp/file.txt") } }])
  }

  func testAPullWithoutADestinationStreamsAGzippedTar() async throws {
    let sent = SentResponses()
    let request = Idb_PullRequest.with { $0.srcPath = "Documents/file.txt" }
    try await PullMethodHandler.pull(request, using: LocalFilePuller(contents: Data(repeating: 0xAB, count: 64 * 1024)), logger: logger, cancellation: ServerContext.RPCCancellationHandle()) {
      sent.append($0)
    }
    let received = sent.all.reduce(into: Data()) { $0.append($1.payload.data) }
    XCTAssertEqual(Array(received.prefix(2)), [0x1F, 0x8B])
  }

  func testAPullThatCannotBeArchivedReportsTheExitCode() async throws {
    try XCTSkipIf(getuid() == 0, "root reads a file whatever its mode")
    let request = Idb_PullRequest.with { $0.srcPath = "Documents/file.txt" }
    do {
      try await PullMethodHandler.pull(request, using: LocalFilePuller(contents: Data("x".utf8), readable: false), logger: logger, cancellation: ServerContext.RPCCancellationHandle()) { _ in }
      XCTFail("an unreadable file was archived")
    } catch let error as RPCError {
      XCTAssertTrue(error.message.hasPrefix("Draining operation failed with exit code 1: "), error.message)
      XCTAssertTrue(error.message.contains("Permission denied"), error.message)
    }
  }

  func testAPullWithoutADestinationStreamsAnArchiveOfWhatLanded() async throws {
    let puller = ScriptedFilePuller(land: { destination in
      try FileManager.default.createDirectory(atPath: "\(destination)/nested", withIntermediateDirectories: true)
      try Data("top".utf8).write(to: URL(fileURLWithPath: "\(destination)/top.txt"))
      try Data("deep".utf8).write(to: URL(fileURLWithPath: "\(destination)/nested/deep.txt"))
    })
    let request = Idb_PullRequest.with { $0.srcPath = "Documents/folder" }
    let sent = SentResponses()

    try await PullMethodHandler.pull(request, using: puller, logger: logger, cancellation: ServerContext.RPCCancellationHandle()) {
      sent.append($0)
    }

    let extracted = try extract(sent.all.reduce(into: Data()) { $0.append($1.payload.data) })
    defer { try? FileManager.default.removeItem(at: extracted.deletingLastPathComponent()) }
    XCTAssertEqual(FileManager.default.contents(atPath: extracted.appendingPathComponent("top.txt").path), Data("top".utf8))
    XCTAssertEqual(FileManager.default.contents(atPath: extracted.appendingPathComponent("nested/deep.txt").path), Data("deep".utf8))
  }

  // gRPC reports a client going away through the RPC's cancellation handle, not by cancelling the
  // handler's task.
  func testAClientGoingAwayStopsThePull() async throws {
    let started = expectation(description: "the pull starts")
    let stopped = expectation(description: "the pull stops")
    let puller = ScriptedFilePuller(holdsOpen: true, onStart: { started.fulfill() }, onStop: { stopped.fulfill() })
    let cancellation = ServerContext.RPCCancellationHandle()
    let request = request
    let call = Task {
      try await PullMethodHandler.pull(request, using: puller, logger: logger, cancellation: cancellation) { _ in }
    }
    await fulfillment(of: [started], timeout: 5)
    cancellation.cancel()
    await fulfillment(of: [stopped], timeout: 1)
    do {
      try await call.value
      XCTFail("the call outlived its cancellation")
    } catch is CancellationError {}
  }
}
