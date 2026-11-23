/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CompanionDiscovery
import Foundation
internal import NIOCore
internal import NIOPosix
internal import NIOSSL

/// Connects to a companion (Unix domain socket or TCP) and runs a `cli` command
/// over newline-framed JSON-RPC, returning the raw response bytes.
///
/// For a TCP companion, TLS is chosen by `CompanionClientTLS`: `.metaIdentity`
/// presents the client identity from the registered `CompanionTLS.provider` (no
/// peer verification) and falls back to plaintext when no provider is registered;
/// `.disabled` is always plaintext. A Unix domain socket is always plaintext.
public enum CompanionClient {
  public static func sendCLICommand(
    _ arguments: [String],
    to address: CompanionAddress,
    tls: CompanionClientTLS = .metaIdentity
  ) async throws -> Data {
    let request: [String: Any] = [
      "jsonrpc": "2.0",
      "method": "cli",
      "params": arguments,
      "id": 1,
    ]
    guard var payload = try? JSONSerialization.data(withJSONObject: request) else {
      throw CompanionClientError.encodeFailed
    }
    payload.append(0x0A) // newline frames the message for the server

    let sslContext = try makeClientSSLContext(for: address, tls: tls)

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
      // The accumulator completes this promise with the full response on EOF (the
      // companion writes one line then closes) or with an error on failure.
      let responsePromise = group.next().makePromise(of: Data.self)
      let bootstrap = ClientBootstrap(group: group)
        .channelInitializer { channel in
          var handlers: [any ChannelHandler] = []
          if let sslContext {
            do {
              // No serverHostname: peer verification is disabled, so SNI /
              // hostname checks are intentionally skipped.
              handlers.append(try NIOSSLClientHandler(context: sslContext, serverHostname: nil))
            } catch {
              return channel.eventLoop.makeFailedFuture(error)
            }
          }
          handlers.append(ResponseAccumulator(promise: responsePromise))
          return channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandlers(handlers)
          }
        }

      let channel: any Channel
      switch address {
      case let .domainSocket(path):
        channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
      case let .tcp(host, port):
        channel = try await bootstrap.connect(host: host, port: port).get()
      }

      var buffer = channel.allocator.buffer(capacity: payload.count)
      buffer.writeBytes(payload)
      try await channel.writeAndFlush(buffer).get()
      let response = try await responsePromise.futureResult.get()
      try? await group.shutdownGracefully()
      return response
    } catch {
      try? await group.shutdownGracefully()
      throw error
    }
  }

  /// Builds the client TLS context for a TCP companion using the provider's client
  /// identity, or nil for plaintext (a Unix domain socket, `.disabled`, or
  /// `.metaIdentity` with no registered provider). Verification is disabled
  /// (present an identity, do not verify the peer).
  private static func makeClientSSLContext(
    for address: CompanionAddress,
    tls: CompanionClientTLS
  ) throws -> NIOSSLContext? {
    guard case .tcp = address, tls == .metaIdentity,
      let identity = CompanionTLS.provider?.clientIdentity()
    else {
      return nil
    }
    do {
      var configuration = TLSConfiguration.makeClientConfiguration()
      // NIOSSL defaults the floor to TLS 1.0; pin it to 1.2 so the deprecated
      // TLS 1.0/1.1 protocols and their legacy cipher suites are never negotiated.
      configuration.minimumTLSVersion = .tlsv12
      configuration.certificateVerification = .none
      configuration.certificateChain = try NIOSSLCertificate.fromPEMFile(identity.certificateChainPath).map { .certificate($0) }
      configuration.privateKey = .privateKey(try NIOSSLPrivateKey(file: identity.privateKeyPath, format: .pem))
      return try NIOSSLContext(configuration: configuration)
    } catch {
      throw CompanionClientError.tlsContextFailed(underlying: error)
    }
  }
}

/// Errors raised by `CompanionClient` before the transport takes over. Connection,
/// TLS-handshake, and write failures surface as the underlying NIO errors.
public enum CompanionClientError: Error, CustomStringConvertible {
  case encodeFailed
  case tlsContextFailed(underlying: any Error)

  public var description: String {
    switch self {
    case .encodeFailed:
      return "Failed to encode the JSON-RPC request"
    case let .tlsContextFailed(underlying):
      return "Failed to build the client TLS context: \(underlying)"
    }
  }
}

/// Collects all bytes received on a connection and completes `promise` with them
/// when the peer closes (EOF). The companion writes one JSON-RPC response line and
/// then closes, so EOF marks the end of the response. All callbacks run on the
/// channel's event loop, so the mutable state needs no extra synchronization.
final class ResponseAccumulator: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer

  private let promise: EventLoopPromise<Data>
  private var accumulated = Data()
  private var finished = false

  init(promise: EventLoopPromise<Data>) {
    self.promise = promise
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var buffer = unwrapInboundIn(data)
    if let bytes = buffer.readBytes(length: buffer.readableBytes) {
      accumulated.append(contentsOf: bytes)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    finish(.success(accumulated))
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    finish(.failure(error))
    context.close(promise: nil)
  }

  private func finish(_ result: Result<Data, any Error>) {
    guard !finished else { return }
    finished = true
    promise.completeWith(result)
  }
}
