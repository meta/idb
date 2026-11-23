/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
internal import NIOCore

/// Per-connection handler sitting after `NewlineFrameDecoder`. It decodes the
/// first line as a `JSONRPCRequest` and hands it (with this connection's channel)
/// to the server's `submit` closure, which processes it asynchronously, writes the
/// response back, and closes the connection. The client keeps the connection open
/// and reads the response, so it is reliably delivered. A malformed line gets no
/// response and the connection is closed.
final class JSONRPCConnectionHandler: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer

  private let submit: @Sendable (JSONRPCRequest, any Channel) -> Void

  init(submit: @escaping @Sendable (JSONRPCRequest, any Channel) -> Void) {
    self.submit = submit
  }

  func channelActive(context: ChannelHandlerContext) {
    companionServerLog("CompanionServer: accepted connection")
    context.fireChannelActive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var buffer = unwrapInboundIn(data)
    let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
    let payload = Data(bytes)
    do {
      let request = try JSONDecoder().decode(JSONRPCRequest.self, from: payload)
      // The server owns closing the channel once it has written the response.
      submit(request, context.channel)
    } catch {
      companionServerLog("CompanionServer: ignoring non-JSON-RPC line: \(String(decoding: payload, as: UTF8.self))")
      context.close(promise: nil)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    companionServerLog("CompanionServer: connection error: \(error)")
    context.close(promise: nil)
  }
}
