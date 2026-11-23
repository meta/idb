/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBSimulatorBridgeProtocol
import Foundation
internal import SimulatorIPC

#if canImport(SimulatorFrameworkBridgeRuntime)
internal import SimulatorFrameworkBridgeRuntime
#endif

public struct BridgeRPCReply {
  public let data: Data
  public let exitCode: Int32
  public let shutdown: Bool
}

/// Results a command goes on answering with after its request, until it ends or the peer goes away.
public protocol BridgeResultStream: AnyObject {
  /// Runs until the stream ends, answering each result through `emit`, which answers false once it could not be delivered.
  func run(emit: @escaping (BridgeResult) -> Bool)
  /// Asks a running stream to end, from another thread; `run` must return promptly afterwards.
  func cancel()
}

/// How a streaming command answers: with its stream, or with the one result that stands in for it when it cannot start.
public enum BridgeStreamStart {
  case stream(any BridgeResultStream)
  case result(BridgeResult)
}

public enum BridgeRPC {
  public static func process(_ data: Data, execute: (BridgeCommand) -> BridgeResult = BridgeServices.execute) -> BridgeRPCReply {
    guard (try? IPCFrame.header(forSize: data.count)) != nil else { return failure(id: nil, message: "invalid request size") }
    let request: BridgeRequest
    do {
      request = try BridgeRequest.decode(data)
    } catch {
      let id = BridgeRequest.identity(of: data)
      if let error = BridgeRequest.accessibilityRequestError(of: data) {
        return reply(id: id, result: BridgeServices.undecodedAccessibility(error))
      }
      return failure(id: id, message: String(describing: error))
    }
    let result = execute(request.command)
    do {
      let bytes = try BridgeResponse(request: request, result: result).encoded()
      _ = try IPCFrame.header(forSize: bytes.count)
      return BridgeRPCReply(data: bytes, exitCode: result.exitCode, shutdown: request.command == .shutdown && result.exitCode == 0)
    } catch {
      return failure(id: request.id, message: "response serialization failed or exceeded the frame limit")
    }
  }

  private static func reply(id: String?, result: BridgeResult) -> BridgeRPCReply {
    guard let data = try? BridgeResponse(id: id, result: result).encoded(), data.count <= IPCFrame.maximumSize else {
      return failure(id: id, message: "response serialization failed or exceeded the frame limit")
    }
    return BridgeRPCReply(data: data, exitCode: result.exitCode, shutdown: false)
  }

  private static func failure(id: String?, message: String) -> BridgeRPCReply {
    let response = BridgeResponse(id: id, result: BridgeResult(exitCode: 1, error: message))
    let encoded = try? response.encoded()
    let data = encoded.flatMap { $0.count <= IPCFrame.maximumSize ? $0 : nil } ?? Data(#"{"version":\#(BridgeRequest.currentVersion),"result":{"answers":[],"exitCode":1}}"#.utf8)
    return BridgeRPCReply(data: data, exitCode: 1, shutdown: false)
  }

  /// Only a socket can stream, so a streaming command is answered here rather than by `process`.
  public static func handle(
    _ data: Data,
    execute: (BridgeCommand) -> BridgeResult = BridgeServices.execute,
    stream: (BridgeCommand) -> BridgeStreamStart? = BridgeServices.stream
  ) -> BridgeSocketResponse {
    if let request = try? BridgeRequest.decode(data), let start = stream(request.command) {
      switch start {
      case let .stream(results):
        return .stream(ResponseStream(request: request, results: results))
      case let .result(result):
        return .frame(data: process(data) { _ in result }.data, shutdown: false)
      }
    }
    let reply = process(data, execute: execute)
    return .frame(data: reply.data, shutdown: reply.shutdown)
  }

  /// Every frame answers the one request, so a client validates each exactly as it would a single reply.
  private final class ResponseStream: BridgeResponseStream {
    private let request: BridgeRequest
    private let results: any BridgeResultStream

    init(request: BridgeRequest, results: any BridgeResultStream) {
      self.request = request
      self.results = results
    }

    func run(emit: @escaping (Data) -> Bool) {
      results.run { [request] result in
        guard let data = try? BridgeResponse(request: request, result: result).encoded(), (try? IPCFrame.header(forSize: data.count)) != nil else { return false }
        return emit(data)
      }
    }

    func cancel() {
      results.cancel()
    }
  }

  static func run(arguments: [String]) -> Int32? {
    guard arguments.count >= 2 else { return nil }
    switch arguments[1] {
    case "rpc":
      guard arguments.count == 3 else { return 1 }
      let reply = process(Data(arguments[2].utf8))
      let written = unsafe reply.data.withUnsafeBytes { unsafe fwrite($0.baseAddress, 1, $0.count, stdout) == $0.count }
      guard written, unsafe fputc(10, stdout) != EOF, unsafe fflush(stdout) == 0 else { return 1 }
      return reply.exitCode
    case "serve":
      guard arguments.count >= 3, !arguments[2].isEmpty else { return 1 }
      let options = Array(arguments.dropFirst(3))
      return BridgeServer.serve(
        socketPath: arguments[2],
        idleTimeoutSeconds: BridgeServeOptions.idleTimeout(arguments: options, fallback: BridgeServer.defaultIdleTimeoutSeconds),
        initialClientTimeoutSeconds: BridgeServeOptions.startupTimeout(arguments: options),
        exitOnDisconnect: BridgeServeOptions.exitOnDisconnect(arguments: options),
        // Bind the accessibility frameworks before the first client so the first read does not pay
        // for it inside the client's timeout.
        prepareRuntime: { FBAXClientProvider.prepare() },
        handleRequest: { handle($0) }
      )
    default:
      return nil
    }
  }
}
