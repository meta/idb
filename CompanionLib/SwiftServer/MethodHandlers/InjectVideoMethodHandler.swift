/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorCodeInjection
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf

struct InjectVideoMethodHandler {

  typealias Update = @Sendable ([String]) async throws -> Void

  let target: CompanionTarget

  func handle(
    requestStream: RequestStreamReader<Idb_InjectVideoRequest>,
    responseStream: RPCWriter<Idb_InjectVideoResponse>,
    context: ServerContext
  ) async throws {
    // Resolved up front so the closure can hold it, and thrown only once the start request has arrived.
    let simulator = Result { try target.simulator() }
    do {
      try await Self.withVideoInjection(
        from: requestStream,
        cancellation: context.cancellation,
        send: { processes in
          try await responseStream.send(Idb_InjectVideoResponse.with { $0.processes = processes })
        }
      ) { start, onUpdate in
        try await simulator.get().videoInjection.inject(
          back: URL(fileURLWithPath: start.backPath),
          front: start.frontPath.isEmpty ? nil : URL(fileURLWithPath: start.frontPath),
          loop: start.loop,
          onUpdate: onUpdate)
      }
    } catch let error as VideoInjectionError {
      throw Self.rpcError(for: error)
    } catch let error as IDBCommandError {
      if let rpcError = Self.rpcError(for: error) {
        throw rpcError
      }
      throw error
    }
  }

  /// Runs `inject` from the `start` request until it returns by itself, or the client sends its next
  /// request or ends its stream, either of which stops it without an error.
  static func withVideoInjection(
    from requestStream: RequestStreamReader<Idb_InjectVideoRequest>,
    cancellation: ServerContext.RPCCancellationHandle,
    send: @escaping Update,
    _ inject: @escaping @Sendable (Idb_InjectVideoRequest.Start, Update) async throws -> Void
  ) async throws {
    guard case let .start(start) = try await requestStream.requiredNext().control else {
      throw RPCError(code: .failedPrecondition, message: "Video injection requires start as the first request")
    }
    guard !start.backPath.isEmpty else {
      throw RPCError(code: .invalidArgument, message: "Video injection requires a back_path")
    }
    try await withRPCCancellation(cancellation) {
      let injection = Task { try await inject(start, send) }
      // Not awaited: the request stream may stay open after an injection that ended by itself.
      let stop = Task {
        _ = try? await requestStream.next()
        injection.cancel()
      }
      defer { stop.cancel() }
      do {
        try await withTaskCancellationHandler {
          try await injection.value
        } onCancel: {
          injection.cancel()
        }
      } catch is CancellationError where !Task.isCancelled {
        // Stopped by the client.
      }
    }
  }

  static func rpcError(for error: VideoInjectionError) -> RPCError {
    let code: RPCError.Code
    switch error {
    case .inputUnreadable, .noVideoTrack:
      code = .invalidArgument
    case .unsupportedPlatform, .alreadyRunning, .failedInGuest:
      code = .failedPrecondition
    case .socketUnavailable, .stagingFailed:
      code = .internalError
    @unknown default:
      code = .internalError
    }
    return RPCError(code: code, message: error.localizedDescription)
  }

  static func rpcError(for error: IDBCommandError) -> RPCError? {
    guard case .notASimulator = error else {
      return nil
    }
    return RPCError(code: .failedPrecondition, message: error.localizedDescription)
  }
}
