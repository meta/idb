/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import os

/// Serves each registered URL its body a chunk at a time with a pause between, as a slow link does, and records how much
/// of each body it delivered and whether the transfer was stopped before the end.
// SAFETY: `URLSession` drives the protocol from its own threads, and a later delivery runs on a dispatch queue; the
// subclass adds no instance state, and its shared state is behind a lock.
// patternlint-disable-next-line unchecked-sendable
final class SlowURLProtocol: URLProtocol, @unchecked Sendable {

  struct Transfer {
    let body: Data
    let chunkSize: Int
    let pause: DispatchTimeInterval
    var delivered = 0
    var stopped = false
    var finished = false
  }

  private static let transfers = OSAllocatedUnfairLock(initialState: [URL: Transfer]())

  /// A URL that serves `body` in chunks of `chunkSize`, pausing `pause` between them.
  static func serving(_ body: Data, chunkSize: Int = 64 * 1024, pause: DispatchTimeInterval = .milliseconds(20)) -> URL {
    // swiftlint:disable:next force_unwrapping
    let url = URL(string: "https://slow.invalid/\(UUID().uuidString)")!
    transfers.withLock { $0[url] = Transfer(body: body, chunkSize: chunkSize, pause: pause) }
    return url
  }

  static func transfer(_ url: URL) -> Transfer? {
    transfers.withLock { $0[url] }
  }

  static var configuration: URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SlowURLProtocol.self]
    return configuration
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url, let transfer = Self.transfer(url) else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    // swiftlint:disable:next force_unwrapping
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(transfer.body.count)])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    deliver(url)
  }

  private func deliver(_ url: URL) {
    let next: (Data, DispatchTimeInterval)? = Self.transfers.withLock { transfers in
      guard var transfer = transfers[url], !transfer.stopped else {
        return nil
      }
      guard transfer.delivered < transfer.body.count else {
        transfer.finished = true
        transfers[url] = transfer
        return nil
      }
      let end = min(transfer.delivered + transfer.chunkSize, transfer.body.count)
      let chunk = transfer.body[transfer.delivered..<end]
      transfer.delivered = end
      transfers[url] = transfer
      return (Data(chunk), transfer.pause)
    }
    guard let (chunk, pause) = next else {
      if Self.transfer(url)?.finished == true {
        client?.urlProtocolDidFinishLoading(self)
      }
      return
    }
    client?.urlProtocol(self, didLoad: chunk)
    DispatchQueue.global().asyncAfter(deadline: .now() + pause) { self.deliver(url) }
  }

  override func stopLoading() {
    guard let url = request.url else {
      return
    }
    Self.transfers.withLock { transfers in
      transfers[url]?.stopped = true
    }
  }
}
