/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBConcurrency
import IDBGRPCSwift
import SwiftProtobuf

struct DapMethodHandler: Sendable {

  let commandExecutor: IDBCommandExecutor
  let targetLogger: ControlCoreLogger

  func handle(requestStream: RequestStreamReader<Idb_DapRequest>, responseStream: RPCWriter<Idb_DapResponse>, context: ServerContext) async throws {
    guard case let .start(start) = try await requestStream.requiredNext().control
    else { throw RPCError(code: .failedPrecondition, message: "Dap command expected a Start messaged in the beginning of the Stream") }

    let lldbVSCode = "dap/\(start.debuggerPkgID)/usr/bin/lldb-vscode"
    let input = InputSource()
    targetLogger.debug().log("Starting dap server with path \(lldbVSCode)")
    try await commandExecutor.withDapServer(path: lldbVSCode, input: input, output: createDataConsumer(to: responseStream)) { process in
      targetLogger.debug().log("Dap server spawn with PID: \(process.processIdentifier)")
      try await responseStream.send(.with { $0.event = .started(.init()) })

      let tenHours: UInt64 = 36000 * 1000000000
      try await Task.timeout(nanoseconds: tenHours) {
        try await consumeElements(from: requestStream, to: input)
      }
    }

    let stoppedResponse = Idb_DapResponse.with {
      $0.event = .stopped(
        .with { $0.desc = "Dap server stopped" }
      )
    }
    try await responseStream.send(stoppedResponse)
  }

  private func consumeElements(from requestStream: RequestStreamReader<Idb_DapRequest>, to input: InputSource) async throws {
    for try await request in requestStream {
      switch request.control {
      case .start:
        throw RPCError(code: .failedPrecondition, message: "DAP server already started")

      case .none:
        throw RPCError(code: .invalidArgument, message: "Empty control in request")

      case let .pipe(pipe):
        guard !pipe.data.isEmpty else {
          targetLogger.debug().log("Dap request received empty message. Transmission finished")
          return
        }
        targetLogger.debug().log("Dap Request. Received \(pipe.data.count) bytes from client")
        input.write(pipe.data)

      case .stop:
        targetLogger.debug().log("Received stop from Dap Request")
        return
      }
    }
  }

  private func createDataConsumer(to responseStream: RPCWriter<Idb_DapResponse>) -> DataConsumer {
    let responseWriter = FIFOStreamWriter(stream: responseStream)

    return SynchronousDataConsumer { data in
      let response = Idb_DapResponse.with {
        $0.event = .stdout(
          .with { $0.data = data }
        )
      }
      do {
        try responseWriter.send(response)
        targetLogger.debug().log("Dap server stdout consumer: sent \(data.count) bytes.")
      } catch {
        targetLogger.debug().log("Dap server stdout consumer: error \(error) when tried to send bytes.")
      }
    }
  }
}
