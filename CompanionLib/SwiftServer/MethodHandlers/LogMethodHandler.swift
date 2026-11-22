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

/// Starts the log a `log` request streams, writing its output to `consumer`.
protocol LogStarting: Sendable {
  func start(consumer: any DataConsumer) async throws -> any LogOperation
}

struct LogMethodHandler: @unchecked Sendable {

  let target: any Target
  let commandExecutor: IDBCommandExecutor

  func handle(request: Idb_LogRequest, responseStream: RPCWriter<Idb_LogResponse>, context: ServerContext) async throws {
    let streamWriter = FIFOStreamWriter(stream: responseStream)
    try await Self.tail(
      cancellation: context.cancellation,
      send: { try streamWriter.send($0) },
      log: RequestedLog(request: request, target: target, commandExecutor: commandExecutor))
  }

  /// Forwards the log `log` starts until the log ends, a write fails, or `cancellation` reports the RPC
  /// cancelled, as it does when the client goes away. Only a write would otherwise notice the client is gone.
  static func tail(
    cancellation: ServerContext.RPCCancellationHandle,
    send: @escaping @Sendable (Idb_LogResponse) throws -> Void,
    log: any LogStarting
  ) async throws {
    try await withRPCCancellation(cancellation) {
      try await forward(send: send, log: log)
    }
  }

  private static func forward(
    send: @escaping @Sendable (Idb_LogResponse) throws -> Void,
    log: any LogStarting
  ) async throws {
    let writingDone = AsyncEvent<Void>()

    let consumer = SynchronousDataConsumer { data in
      if writingDone.hasHappened {
        return
      }
      let response = Idb_LogResponse.with {
        $0.output = data
      }
      do {
        try send(response)
      } catch {
        writingDone.fail(error)
      }
    }

    let operation = try await log.start(consumer: consumer)

    let observeWritingDone = Task<Void, Error> {
      try await writingDone.wait()
    }
    // `operation` is a thread-safe handle but not Sendable; rebind as
    // nonisolated(unsafe) so the observer Task can capture it.
    nonisolated(unsafe) let operationToObserve = operation
    let observeOperationCompletion = Task<Void, Error> {
      try await operationToObserve.waitUntilCompleted()
    }
    try await Task.select(observeWritingDone, observeOperationCompletion).value
    writingDone.happen()

    observeOperationCompletion.cancel()
  }
}

/// The log a request names: the companion's own, or the target's.
// SAFETY: holds the same non-Sendable target the handler does, which is itself `@unchecked Sendable`
// for the same reason; the target and executor are thread-safe handles.
// patternlint-disable-next-line unchecked-sendable
private struct RequestedLog: LogStarting, @unchecked Sendable {
  let request: Idb_LogRequest
  let target: any Target
  let commandExecutor: IDBCommandExecutor

  func start(consumer: any DataConsumer) async throws -> any LogOperation {
    if request.source == .companion {
      return try await commandExecutor.logger.tailToConsumer(consumer)
    }
    return try await target.log.tail(arguments: request.arguments, consumer: consumer)
  }
}
