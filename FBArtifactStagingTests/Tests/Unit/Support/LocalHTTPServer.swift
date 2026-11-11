/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import Network

/// Serves one file over HTTP/1.1 on the loopback interface, to every request, as fast as the client reads it: a link
/// faster than anything reading from it.
// SAFETY: `url` is written once, on `queue`, before `serving` returns, and read only after; everything else is
// immutable or confined to `queue`.
// patternlint-disable-next-line unchecked-sendable
final class LocalHTTPServer: @unchecked Sendable {

  private let listener: NWListener
  private let file: URL
  private let extraHeaders: [String]
  private let queue = DispatchQueue(label: "idb.tests.http")
  private(set) var url: URL

  private init(listener: NWListener, file: URL, extraHeaders: [String]) {
    self.listener = listener
    self.file = file
    self.extraHeaders = extraHeaders
    // swiftlint:disable:next force_unwrapping
    url = URL(string: "http://127.0.0.1/")!
  }

  /// Serves `file` with `extraHeaders` (`Name: value` lines) added to every response.
  static func serving(_ file: URL, extraHeaders: [String] = []) async throws -> LocalHTTPServer {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let server = LocalHTTPServer(listener: try NWListener(using: parameters), file: file, extraHeaders: extraHeaders)
    try await server.start()
    return server
  }

  private func start() async throws {
    listener.newConnectionHandler = { [weak self] connection in
      self?.serve(connection)
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      listener.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          guard let self, let port = self.listener.port else {
            return
          }
          // swiftlint:disable:next force_unwrapping
          self.url = URL(string: "http://127.0.0.1:\(port.rawValue)/archive")!
          self.listener.stateUpdateHandler = nil
          continuation.resume()
        case .failed(let error):
          self?.listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        case .setup, .waiting, .cancelled:
          break
        @unknown default:
          break
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop() {
    listener.cancel()
  }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    readRequest(connection, received: Data())
  }

  private func readRequest(_ connection: NWConnection, received: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, isComplete, error in
      guard let self, error == nil else {
        connection.cancel()
        return
      }
      let received = received + (data ?? Data())
      guard received.range(of: Data("\r\n\r\n".utf8)) != nil else {
        if isComplete {
          connection.cancel()
        } else {
          self.readRequest(connection, received: received)
        }
        return
      }
      self.respond(connection)
    }
  }

  private func respond(_ connection: NWConnection) {
    guard let input = FileHandle(forReadingAtPath: file.path),
      let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int
    else {
      connection.cancel()
      return
    }
    let extra = extraHeaders.map { "\($0)\r\n" }.joined()
    let header = "HTTP/1.1 200 OK\r\nContent-Length: \(size)\r\nContent-Type: application/octet-stream\r\n\(extra)Connection: close\r\n\r\n"
    connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in self?.sendBody(connection, from: input) })
  }

  /// One chunk at a time, each sent once the last was taken, so the client's pace sets the server's.
  private func sendBody(_ connection: NWConnection, from input: FileHandle) {
    guard let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty else {
      try? input.close()
      connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
      return
    }
    connection.send(
      content: chunk,
      completion: .contentProcessed { [weak self] error in
        guard let self, error == nil else {
          try? input.close()
          connection.cancel()
          return
        }
        self.sendBody(connection, from: input)
      })
  }
}
