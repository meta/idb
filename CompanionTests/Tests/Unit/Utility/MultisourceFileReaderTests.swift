/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBArtifactStaging
@preconcurrency import FBControlCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import Testing
import os

@Suite(.serialized)
struct MultisourceFileReaderTests {

  @Test
  func writePayloadsStopsWhenTheReaderHasGone() async throws {
    let source = ChunkSource()
    source.abandon()
    let pulled = OSAllocatedUnfairLock(initialState: 0)

    do {
      try await MultisourceFileReader.writePayloads(
        initialData: Data([0xFF]),
        from: Self.requestStream(chunkCount: 4, pulled: pulled),
        to: source)
      Issue.record("Expected the failed write to end the transfer")
    } catch {
      let status = ErrorMapping.rpcError(from: error)
      #expect(status.code == .aborted)
      #expect(status.message == "The reader stopped before the input ended")
    }

    #expect(pulled.withLock { $0 } == 0)
  }

  private struct ClientFailed: Error {}

  /// A client stream that fails part way truncates the archive, so the extraction fails too, and the client's failure is
  /// what the call reports.
  @Test
  func aClientStreamFailingPartWayReportsTheExtractionNotTheClient() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("payload"), withIntermediateDirectories: true)
    var random = Data(count: 1 << 20)
    random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
    try random.write(to: directory.appendingPathComponent("payload/file"))
    let logger = ControlCoreGlobalConfiguration.systemLogger(writingToStderr: false, debugLogging: false)
    let archive = try await ArchiveOperations.createGzippedTarData(forPath: directory.appendingPathComponent("payload").path, logger: logger)
    let source = AsyncThrowingStream<Idb_PushRequest, any Error> { continuation in
      continuation.yield(Idb_PushRequest.with { $0.payload = .with { $0.data = archive.prefix(archive.count / 2) } })
      continuation.finish(throwing: ClientFailed())
    }

    do {
      _ = try await MultisourceFileReader.withFilePathURLs(
        from: RequestStreamReader(RPCAsyncSequence(wrapping: source)), temporaryDirectory: TemporaryDirectory(logger: logger),
        extractFromSubdir: false
      ) { $0 }
      Issue.record("Expected a truncated push to fail")
    } catch {
      #expect(error is ClientFailed, "\(error)")
    }
  }

  private static func requestStream(chunkCount: Int, pulled: OSAllocatedUnfairLock<Int>) -> RequestStreamReader<Idb_PushRequest> {
    let source = AsyncThrowingStream<Idb_PushRequest, any Error> {
      let index = pulled.withLock { count -> Int in
        count += 1
        return count - 1
      }
      guard index < chunkCount else { return nil }
      return Idb_PushRequest.with {
        $0.payload = .with { $0.data = Data([UInt8(index)]) }
      }
    }
    return RequestStreamReader(RPCAsyncSequence(wrapping: source))
  }
}
