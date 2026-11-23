/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
import SimScopeProtocol

enum ControlChannelError: Error, LocalizedError {
  case socketPathTooLong(String)
  case socketFailed(operation: String, errno: Int32)

  var errorDescription: String? {
    switch self {
    case let .socketPathTooLong(path):
      return "The control socket path is too long for a sockaddr_un: \(path)"
    case let .socketFailed(operation, code):
      return unsafe "Control socket \(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
    }
  }
}

/// The agent's way into a running SimScope: a unix-domain socket speaking newline-delimited JSON,
/// one request object per line, one response object per line.
///
/// A unix socket rather than a TCP port so there is nothing to allocate, collide over, or expose
/// beyond the filesystem. The channel decodes lines and hands them to `AgentDispatcher`, where anything
/// touching the simulator happens.
///
/// One thread accepts, one thread per connection reads. Blocking reads are what a long-polling
/// `events` call parks on, and there is at most a handful of clients, so the cost of a thread each is
/// not worth an event loop.
final class ControlChannel: @unchecked Sendable {

  private let path: String
  private let dispatcher: AgentDispatcher
  private let lock = NSLock()
  private var listenFD: Int32 = -1
  private var isStopping = false

  init(path: String, dispatcher: AgentDispatcher) {
    self.path = path
    self.dispatcher = dispatcher
  }

  // MARK: - Lifecycle

  /// Binds and begins accepting. The returned path is where clients should connect.
  @discardableResult
  func start() throws -> String {
    try ControlSocket.prepareDirectory(for: path)
    // A socket file left behind by a crashed run would make bind fail with EADDRINUSE; nothing else
    // owns this path, so reclaiming it is always right.
    unsafe unlink(path)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ControlChannelError.socketFailed(operation: "socket", errno: errno) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else {
      close(fd)
      throw ControlChannelError.socketPathTooLong(path)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      unsafe destination.copyBytes(from: bytes)
      unsafe destination[bytes.count] = 0
    }

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) { pointer in
      unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe bind(fd, $0, size) }
    }
    guard bound == 0 else {
      let code = errno
      close(fd)
      throw ControlChannelError.socketFailed(operation: "bind", errno: code)
    }
    guard listen(fd, 4) == 0 else {
      let code = errno
      close(fd)
      throw ControlChannelError.socketFailed(operation: "listen", errno: code)
    }
    // Only this user's agent should be able to drive their simulator.
    unsafe chmod(path, 0o600)

    lock.withLock { listenFD = fd }
    Thread.detachNewThread { [weak self] in self?.acceptLoop(on: fd) }
    return path
  }

  func stop() {
    let fd: Int32 = lock.withLock {
      isStopping = true
      let current = listenFD
      listenFD = -1
      return current
    }
    if fd >= 0 { close(fd) }
    unsafe unlink(path)
  }

  // MARK: - Accept / serve

  private func acceptLoop(on fd: Int32) {
    Thread.current.name = "com.facebook.SimScope.control.accept"
    while !lock.withLock({ isStopping }) {
      let connection = accept(fd, nil, nil)
      guard connection >= 0 else {
        // A closed listener during `stop()` lands here; anything else is transient and worth retrying.
        if lock.withLock({ isStopping }) { return }
        if errno == EINTR { continue }
        return
      }
      var on: Int32 = 1
      unsafe setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      Thread.detachNewThread { [weak self] in self?.serve(connection) }
    }
  }

  private func serve(_ fd: Int32) {
    Thread.current.name = "com.facebook.SimScope.control.connection"
    defer { close(fd) }

    var pending = Data()
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)

    while !lock.withLock({ isStopping }) {
      let count = unsafe read(fd, &chunk, chunk.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { return } // peer closed, or error
      pending.append(contentsOf: chunk[0..<count])

      while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
        let line = Data(pending[pending.startIndex..<newline])
        pending.removeSubrange(pending.startIndex...newline)
        guard !line.isEmpty else { continue }
        var reply = respond(to: line)
        reply.append(UInt8(ascii: "\n"))
        guard writeAll(reply, to: fd) else { return }
      }
    }
  }

  /// Decodes one request line, runs it, and encodes the reply. Never throws: a bad line earns an
  /// error object, not a dropped connection.
  private func respond(to line: Data) -> Data {
    let decoder = JSONDecoder()
    let response: AgentResponse
    do {
      let request = try decoder.decode(AgentRequest.self, from: line)
      response = runOnMainActor(request)
    } catch {
      // Recover the id if the line was at least JSON, so a client matching replies to requests can
      // still pair up its error.
      let id = (try? decoder.decode(RequestEnvelope.self, from: line))?.id
      response = .failure(id: id, error)
    }
    guard let encoded = try? JSONEncoder().encode(response) else {
      return Data(#"{"ok":false,"error":"Could not encode the response"}"#.utf8)
    }
    return encoded
  }

  /// Bridges this connection's thread to the main actor, where the backend and session live.
  ///
  /// Blocking the connection thread is the point: the reply is written by the same thread that read
  /// the request, so responses cannot be interleaved, and a long-polling `events` call simply parks
  /// here until the human does something.
  private func runOnMainActor(_ request: AgentRequest) -> AgentResponse {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResponseBox()
    Task { @MainActor [dispatcher] in
      box.value = await dispatcher.handle(request)
      semaphore.signal()
    }
    semaphore.wait()
    return box.value ?? .failure(id: request.id, ControlChannelError.socketFailed(operation: "dispatch", errno: 0))
  }

  private func writeAll(_ data: Data, to fd: Int32) -> Bool {
    unsafe data.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return true }
      var offset = 0
      while offset < raw.count {
        let written = unsafe write(fd, base.advanced(by: offset), raw.count - offset)
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { return false }
        offset += written
      }
      return true
    }
  }

  /// Just enough of a request to recover its id when the rest of it failed to decode.
  private struct RequestEnvelope: Decodable {
    let id: Int?
  }

  /// Carries the reply back across the semaphore. A class so the `Task` writes where the waiting
  /// thread reads; the semaphore is the happens-before edge.
  private final class ResponseBox: @unchecked Sendable {
    var value: AgentResponse?
  }
}
