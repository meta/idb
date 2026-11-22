/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import GRPCCore
import IDBConcurrency
import IDBGRPCSwift
import SwiftProtobuf

protocol TailOperation {
  func cancel() async throws
}

extension FileContainerTailOperation: TailOperation {}

/// Starts the tail a `tail` request streams, writing its output to `consumer`.
protocol TailStarting {
  func start(consumer: any DataConsumer) async throws -> any TailOperation
}

struct TailMethodHandler {

  let commandExecutor: IDBCommandExecutor

  func handle(requestStream: RequestStreamReader<Idb_TailRequest>, responseStream: RPCWriter<Idb_TailResponse>, context: ServerContext) async throws {
    guard case let .start(start) = try await requestStream.requiredNext().control
    else { throw RPCError(code: .failedPrecondition, message: "Expected start control") }

    let responseWriter = FIFOStreamWriter(stream: responseStream)
    let fileContainer = FileContainerTranslation.rawFileContainer(from: start.container)
    try await Self.tail(
      send: { try responseWriter.send($0) },
      awaitStop: {
        guard case .stop = try await requestStream.requiredNext().control
        else { throw RPCError(code: .failedPrecondition, message: "Expected end control") }
      },
      source: RequestedTail(commandExecutor: commandExecutor, path: start.path, fileContainer: fileContainer))
  }

  /// Forwards the tail `source` starts until `awaitStop` returns or throws, then cancels it.
  static func tail(
    send: @escaping @Sendable (Idb_TailResponse) throws -> Void,
    awaitStop: () async throws -> Void,
    source: any TailStarting
  ) async throws {
    let consumer = ResponseForwardingConsumer { data in
      try send(Idb_TailResponse.with { $0.data = data })
    }

    let tail = try await source.start(consumer: consumer)
    do {
      try await awaitStop()
    } catch {
      // A client that goes away without a stop ends the stream here, and nothing else would stop the tail.
      consumer.stopForwarding()
      try? await tail.cancel()
      throw error
    }
    try await tail.cancel()
    consumer.stopForwarding()
  }
}

/// The file in a container that a `tail` request names.
private struct RequestedTail: TailStarting {
  let commandExecutor: IDBCommandExecutor
  let path: String
  let fileContainer: String?

  func start(consumer: any DataConsumer) async throws -> any TailOperation {
    try await commandExecutor.withFileContainer(for: fileContainer) { container in
      try await container.tail(path, to: consumer)
    }
  }
}
