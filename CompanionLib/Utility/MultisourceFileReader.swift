/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBArtifactStaging
import FBControlCore
import Foundation
import GRPCCore
import IDBGRPCSwift

enum MultisourceFileReader {

  /// Hands the file URLs from the request stream to `body`. Files extracted from a streamed
  /// archive live in a temporary directory scoped to `body`; files referenced by path belong to
  /// the caller of the RPC and are handed through untouched.
  static func withFilePathURLs<Request: PayloadExtractable, T>(
    from requestStream: RequestStreamReader<Request>,
    temporaryDirectory: TemporaryDirectory,
    extractFromSubdir: Bool,
    _ body: ([URL]) async throws -> T
  ) async throws -> T {
    func readNextPayload() async throws -> Idb_Payload {
      guard let p = try await requestStream.requiredNext().extractPayload()
      else { throw RPCError(code: .failedPrecondition, message: "Incorrect request. Expected payload") }
      return p
    }

    var payload = try await readNextPayload()

    // What the client declared is skipped: the archive's first bytes say how it is compressed.
    if case .compression = payload.source {
      payload = try await readNextPayload()
    }

    switch payload.source {
    case let .data(data):
      let (readTaskFromStreamTask, source) = pumpToSource(initialData: data, requestStream: requestStream)

      do {
        return try await Staging.extract(source, temporaryDirectory: temporaryDirectory, logger: temporaryDirectory.logger) { extractionDir in
          let files: [URL]
          if extractFromSubdir {
            files = try temporaryDirectory.files(inSubdirectoriesOf: extractionDir)
          } else {
            files = try FileManager.default.contentsOfDirectory(at: extractionDir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
          }
          // The extractor may stop before the stream does, and a client still sending would otherwise wait for room
          // forever; what it sends past a finished extraction doesn't matter. Any other failure of the stream does.
          source.abandon()
          do {
            _ = try await readTaskFromStreamTask.value
          } catch is ChunkSource.ReaderClosed {}
          return try await body(files)
        }
      } catch {
        source.abandon()
        // A client stream that fails truncates the archive, so extraction fails too; the client's failure is the cause.
        // A pump stopped only because extraction had stopped reading is the extraction's failure, not the client's.
        if case .failure(let clientFailure) = await readTaskFromStreamTask.result, !(clientFailure is ChunkSource.ReaderClosed) {
          throw clientFailure
        }
        throw error
      }

    case let .filePath(filePath):
      let filePaths = try await filepathsFromStream(initial: .init(fileURLWithPath: filePath), requestStream: requestStream)
      return try await body(filePaths)

    case .url, .compression, .none:
      throw RPCError(code: .invalidArgument, message: "Unrecognized initial payload type \(payload.source as Any)")
    }
  }

  private static func filepathsFromStream<Request: PayloadExtractable>(initial: URL, requestStream: RequestStreamReader<Request>) async throws -> [URL] {
    var filePaths = [initial]

    for try await request in requestStream {
      guard let payload = request.extractPayload()
      else { throw RPCError(code: .invalidArgument, message: "Unrecognized buffer frame. Expect payload, got \(request)") }

      guard case .filePath(let filePath) = payload.source
      else { throw RPCError(code: .invalidArgument, message: "Unrecognized buffer frame. Expect file path, got \(payload.source as Any)") }

      filePaths.append(URL(fileURLWithPath: filePath))
    }

    return filePaths
  }

  private static func pumpToSource<Request: PayloadExtractable>(initialData: Data, requestStream: RequestStreamReader<Request>) -> (Task<Void, any Error>, ChunkSource) {
    let source = ChunkSource()
    let pumpTask = Task {
      try await writePayloads(initialData: initialData, from: requestStream, to: source)
    }
    return (pumpTask, source)
  }

  /// Pumps `initialData` and then every payload in `requestStream` into `source`, so the request stream
  /// is read no faster than the extractor reads.
  static func writePayloads<Request: PayloadExtractable>(
    initialData: Data,
    from requestStream: RequestStreamReader<Request>,
    to source: ChunkSource
  ) async throws {
    let frames = requestStream.map { request -> Data in
      guard let payload = request.extractPayload()
      else { throw RPCError(code: .invalidArgument, message: "Unrecognized buffer frame. Expect payload, got \(request)") }

      guard case .data(let data) = payload.source
      else { throw RPCError(code: .invalidArgument, message: "Unrecognized buffer frame. Expect file path, got \(payload.source as Any)") }

      return data
    }
    try await source.pump(frames, after: initialData)
  }
}
