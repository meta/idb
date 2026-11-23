/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// `behaviour` is static because `URLSession` instantiates the protocol itself.
// SAFETY: `URLSession` drives the protocol from its own threads, and a later delivery runs on a dispatch queue; the
// subclass adds no instance state, and `behaviour` is guarded as described there.
// patternlint-disable-next-line unchecked-sendable
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

  enum Behaviour {
    case none
    case respond(statusCode: Int, body: Data)
    case truncate(statusCode: Int, body: Data, bytesBeforeFailure: Int)
  }

  // SAFETY: set by the test before the request starts and cleared in tearDown,
  // read on the session's delegate queue in between; the two never overlap.
  // patternlint-disable-next-line swift-nonisolated-unsafe
  nonisolated(unsafe) static var behaviour: Behaviour = .none

  override class func canInit(with request: URLRequest) -> Bool {
    return true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  /// The download starts on construction but the consuming process attaches its pipe
  /// only once extraction starts; delivering immediately races that attachment.
  private static let step = DispatchTimeInterval.milliseconds(200)

  override func startLoading() {
    guard let url = request.url else { return }
    switch Self.behaviour {
    case .none:
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    case let .respond(statusCode, body):
      after(Self.step) {
        self.send(response: self.makeResponse(url: url, statusCode: statusCode, length: body.count))
        self.client?.urlProtocol(self, didLoad: body)
        self.client?.urlProtocolDidFinishLoading(self)
      }
    case let .truncate(statusCode, body, bytesBeforeFailure):
      after(Self.step) {
        self.send(response: self.makeResponse(url: url, statusCode: statusCode, length: body.count))
        self.client?.urlProtocol(self, didLoad: body.prefix(bytesBeforeFailure))
        self.after(Self.step) {
          self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
      }
    }
  }

  private func after(_ interval: DispatchTimeInterval, _ work: @escaping @Sendable () -> Void) {
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + interval, execute: work)
  }

  override func stopLoading() {}

  private func makeResponse(url: URL, statusCode: Int, length: Int) -> HTTPURLResponse {
    // swiftlint:disable:next force_unwrapping
    return HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Length": String(length)])!
  }

  private func send(response: HTTPURLResponse) {
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }
}
