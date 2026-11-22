/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import FBVideoCore
import GRPCCore
import IDBConcurrency
import IDBGRPCSwift
import SwiftProtobuf

struct VideoStreamMethodHandler {

  let target: CompanionTarget
  let targetLogger: ControlCoreLogger
  let commandExecutor: IDBCommandExecutor

  func handle(requestStream: RequestStreamReader<Idb_VideoStreamRequest>, responseStream: RPCWriter<Idb_VideoStreamResponse>, context: ServerContext) async throws {
    guard case let .start(start) = try await requestStream.requiredNext().control
    else { throw RPCError(code: .failedPrecondition, message: "Expected start control") }

    let videoStream = try await startVideoStream(request: start, responseStream: responseStream)

    let observeClientCancelStreaming = Task<Void, Error> {
      for try await request in requestStream {
        switch request.control {
        case .start:
          throw RPCError(code: .failedPrecondition, message: "Video streaming already started")
        case .stop:
          return
        case .none:
          throw RPCError(code: .invalidArgument, message: "Client should not close request stream explicitly, send `stop` frame first")
        }
      }
    }

    let observeVideoStreamStop = Task<Void, Error> {
      try await videoStream.awaitCompletion()
    }

    try await Task.select(observeClientCancelStreaming, observeVideoStreamStop).value

    try await videoStream.stopStreaming()
    targetLogger.log("The video stream is terminated")
  }

  private func startVideoStream(request start: Idb_VideoStreamRequest.Start, responseStream: RPCWriter<Idb_VideoStreamResponse>) async throws -> VideoStreamOperation {
    let consumer: DataConsumer

    if start.filePath.isEmpty {
      let responseWriter = FIFOStreamWriter(stream: responseStream)

      consumer = ResponseForwardingConsumer { data in
        try responseWriter.send(Idb_VideoStreamResponse.with { $0.payload.data = data })
      }
    } else {
      consumer = try FileWriter.syncWriter(forFilePath: start.filePath)
    }

    return try await target.videoStream.create(
      configuration: VideoStreamRequestTranslation.configuration(from: start), to: consumer)
  }
}
