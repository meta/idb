/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
import SimScopeProtocol

/// Why a call did not produce a reply. An error the app phrased itself arrives as `.remote`, so what
/// the agent reads is the app's sentence rather than this client's paraphrase of it.
enum ChannelError: Error, LocalizedError {
  case socketPathTooLong(String)
  case noListener(path: String, errno: Int32)
  case socketFailed(operation: String, errno: Int32)
  case closed
  case remote(String)

  var errorDescription: String? {
    switch self {
    case let .socketPathTooLong(path):
      return "The control socket path is too long for a sockaddr_un: \(path)"
    case let .noListener(path, code):
      return unsafe """
      no SimScope listening on \(path) (\(String(cString: strerror(code)))).
      Start one with:  simscope --udid <UDID> [--control-socket <path>]
      """
    case let .socketFailed(operation, code):
      return unsafe "Control socket \(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
    case .closed:
      return "SimScope closed the connection"
    case let .remote(message):
      return message
    }
  }
}

/// One connection to a running SimScope, reused across calls so `watch` can hold a long poll open.
///
/// Requests and replies are built out of `SimScopeProtocol`, which is the same module the app decodes
/// them with — the shapes on this side of the socket cannot drift from the shapes on the other.
final class Channel {

  /// Added to whatever a command may legitimately wait for, so a long poll or a compile is never cut
  /// off by the client's own timeout.
  static let timeoutSlack: TimeInterval = 30

  private let path: String
  private let fd: Int32
  private var nextID = 1
  private var pending = Data()

  init(path: String, timeout: TimeInterval) throws {
    self.path = path

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw ChannelError.socketPathTooLong(path)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      unsafe destination.copyBytes(from: bytes)
      unsafe destination[bytes.count] = 0
    }

    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ChannelError.socketFailed(operation: "socket", errno: errno) }

    var interval = timeval(
      tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
    unsafe setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let joined = withUnsafePointer(to: &address) { pointer in
      unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe connect(fd, $0, size) }
    }
    guard joined == 0 else {
      let code = errno
      close(fd)
      throw ChannelError.noListener(path: path, errno: code)
    }
  }

  deinit {
    close(fd)
  }

  /// Sends one command and returns the payload its reply carries, or throws the app's own error text.
  func call<Payload: Decodable>(_ command: AgentCommand, intent: String? = nil) throws -> Payload {
    let request = AgentRequest(id: nextID, intent: intent, command: command)
    nextID += 1
    let reply = try JSONDecoder().decode(
      AgentReply<Payload>.self, from: try exchange(JSONEncoder().encode(request)))
    guard reply.ok, let result = reply.result else {
      throw ChannelError.remote(reply.error ?? "unknown error")
    }
    return result
  }

  /// Sends a line as written and returns the reply line as received — the escape hatch behind `cmd`,
  /// which exists precisely for requests this client does not model.
  func exchange(_ line: Data) throws -> Data {
    var outgoing = line
    outgoing.append(UInt8(ascii: "\n"))
    try write(outgoing)
    return try readLine()
  }

  // MARK: - Framing

  private func write(_ data: Data) throws {
    unsafe try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var offset = 0
      while offset < raw.count {
        let written = unsafe Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { throw ChannelError.socketFailed(operation: "write", errno: errno) }
        offset += written
      }
    }
  }

  private func readLine() throws -> Data {
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
        let line = Data(pending[pending.startIndex..<newline])
        pending.removeSubrange(pending.startIndex...newline)
        return line
      }
      let count = unsafe read(fd, &chunk, chunk.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        // A timed-out receive and a closed peer are both "no more line", but only one of them is
        // worth naming: a wait this client set too short is its own bug, not the app's.
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
          throw ChannelError.socketFailed(operation: "read", errno: errno)
        }
        throw ChannelError.closed
      }
      pending.append(contentsOf: chunk[0..<count])
    }
  }
}
