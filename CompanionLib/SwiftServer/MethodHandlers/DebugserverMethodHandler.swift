/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf

struct DebugserverMethodHandler {

  let commandExecutor: IDBCommandExecutor

  func handle(requestStream: RequestStreamReader<Idb_DebugServerRequest>, responseStream: RPCWriter<Idb_DebugServerResponse>, context: ServerContext) async throws {

    for try await request in requestStream {
      switch request.control {
      case let .start(start):
        let debugServer = try await commandExecutor.debugserverStart(start.bundleID)
        try await responseStream.send(debugserverStatusToProto(debugServer: debugServer))
        return

      case .status:
        // Status with no server running is an empty response, not an error.
        if let debugServer = try? commandExecutor.debugserverStatus() {
          try await responseStream.send(debugserverStatusToProto(debugServer: debugServer))
        } else {
          try await responseStream.send(.init())
        }
        return

      case .stop:
        let debugServer = try await commandExecutor.debugserverStop()
        try await responseStream.send(debugserverStatusToProto(debugServer: debugServer))
        return

      case .pipe:
        throw RPCError(code: .unimplemented, message: "debugserver pipe is not supported")

      case .none:
        throw RPCError(code: .invalidArgument, message: "Received empty control")
      }
    }
  }

  private func debugserverStatusToProto(debugServer: any DebugServer) -> Idb_DebugServerResponse {
    return .with {
      $0.status = .with {
        $0.lldbBootstrapCommands = debugServer.lldbBootstrapCommands
      }
    }
  }
}
