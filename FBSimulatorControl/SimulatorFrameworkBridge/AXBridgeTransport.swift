/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorBridgeProtocol
import Foundation

/// A guest's answer to one request, and the size of the frame it came in.
package struct AXBridgeReply: Sendable, Equatable {
  package let answer: BridgeAXAnswer
  /// Bytes the guest sent back, for a read's profile.
  package let frameBytes: Int

  package init(answer: BridgeAXAnswer, frameBytes: Int) {
    self.answer = answer
    self.frameBytes = frameBytes
  }

  /// The answer a guest wrote on its own to `request`. One that does not decode is the guest's failure, as the
  /// transports raise it.
  package init(answer data: Data, for request: AXBridgeRequest) throws {
    self.init(answer: try Self.decoding(request) { try JSONDecoder().decode(BridgeAXAnswer.self, from: data) }, frameBytes: data.count)
  }

  /// Runs `decode`, raising an answer that does not decode as the guest's failure to answer `request`.
  package static func decoding<T>(_ request: AXBridgeRequest, _ decode: () throws -> T) throws -> T {
    do {
      return try decode()
    } catch let error as DecodingError {
      throw unparseable(error, answering: request)
    }
  }

  package static func unparseable(_ error: DecodingError, answering request: AXBridgeRequest) -> AXBridgeError {
    .guestFailure("\(request.verb.rawValue): unparseable guest response (\(error))")
  }
}

package protocol AXBridgeTransport {
  func send(_ request: AXBridgeRequest) async throws -> AXBridgeReply
  /// As `send`, failing with `AXBridgeError.guestNotAnswering` when the guest has sent nothing back within
  /// `receiveTimeout`.
  func send(_ request: AXBridgeRequest, receiveTimeout: TimeInterval) async throws -> AXBridgeReply
}

extension AXBridgeTransport where Self: Sendable {
  /// Races the round trip against the timeout. A transport that can bound its own wait — and so drop a
  /// connection a late reply would otherwise arrive on — overrides this.
  ///
  /// The round trip runs unstructured, so a `send` that ignores cancellation cannot hold the caller past the
  /// timeout; it is cancelled and left to finish alone.
  package func send(_ request: AXBridgeRequest, receiveTimeout: TimeInterval) async throws -> AXBridgeReply {
    let answer = AsyncEvent<AXBridgeReply>()
    let roundTrip = Task {
      do {
        answer.happen(try await send(request))
      } catch {
        answer.fail(error)
      }
    }
    defer { roundTrip.cancel() }
    do {
      return try await answer.wait(timeout: receiveTimeout, waitingFor: "the axbridge guest to answer")
    } catch is PollTimeoutError {
      throw AXBridgeError.guestNotAnswering(after: receiveTimeout)
    }
  }
}

/// A transport that can hold a connection open for a response streamed in many frames.
package protocol AXBridgeStreamingTransport: AXBridgeTransport {
  func stream(_ request: AXBridgeRequest) async throws -> AsyncThrowingStream<BridgeAXAnswer, any Error>
}
