/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

public enum SocketServerError: Error, LocalizedError {
  case alreadyListening
  case notListening
  case socketCreationFailed(reason: String)
  case bindFailed(port: in_port_t, reason: String)
  case listenFailed(port: in_port_t, reason: String)

  public var errorDescription: String? {
    switch self {
    case .alreadyListening:
      return "Cannot start listening, socket is already listening"
    case .notListening:
      return "Cannot stop listening, there is no active socket"
    case let .socketCreationFailed(reason):
      return "Failed to create a socket with error '\(reason)'"
    case let .bindFailed(port, reason):
      return "Failed to bind the socket on port \(port) with error '\(reason)'"
    case let .listenFailed(port, reason):
      return "Failed to listen on the socket on port \(port) error '\(reason)'"
    }
  }
}

/// A generic socket server.
public final class SocketServer {

  /// The port the server is bound on.
  public private(set) var port: in_port_t

  private let delegate: any SocketServerDelegate
  private var acceptSource: DispatchSourceRead?

  /// Creates a socket server for the provided port and delegate.
  public init(onPort port: in_port_t, delegate: any SocketServerDelegate) {
    self.port = port
    self.delegate = delegate
  }

  /// Create and listen to the socket.
  public func startListening() throws {
    if acceptSource != nil {
      throw SocketServerError.alreadyListening
    }
    try createSocket(port: port)
  }

  /// Stop listening to the socket.
  public func stopListening() throws {
    guard let acceptSource else {
      throw SocketServerError.notListening
    }
    acceptSource.cancel()
    self.acceptSource = nil
  }

  private func createSocket(port: in_port_t) throws {
    let socketDescriptor = socket(PF_INET6, SOCK_STREAM, IPPROTO_TCP)
    guard socketDescriptor > 0 else {
      throw SocketServerError.socketCreationFailed(reason: Self.lastErrorDescription())
    }
    var flagTrue: Int32 = 1
    setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &flagTrue, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = port.bigEndian
    address.sin6_addr = in6addr_any
    guard Self.withSocketAddress(&address, { bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }) == 0 else {
      throw SocketServerError.bindFailed(port: port, reason: Self.lastErrorDescription())
    }
    guard listen(socketDescriptor, 10) == 0 else {
      throw SocketServerError.listenFailed(port: port, reason: Self.lastErrorDescription())
    }

    // Since the client queue may be concurrent, accept() calls are serialized on a queue of their
    // own. It targets the client queue, so the delegate is called there.
    let clientQueue = delegate.queue
    let acceptQueue = DispatchQueue(label: "\(clientQueue.label).accept", target: clientQueue)
    let acceptSource = DispatchSource.makeReadSource(fileDescriptor: socketDescriptor, queue: acceptQueue)
    acceptSource.setEventHandler { [weak self] in
      self?.accept(socketDescriptor)
    }
    acceptSource.setCancelHandler {
      close(socketDescriptor)
    }
    self.acceptSource = acceptSource
    acceptSource.resume()

    // Read back the port the kernel actually bound, since 0 requests an ephemeral one.
    var bound = sockaddr_in6()
    var boundLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
    _ = Self.withSocketAddress(&bound) { getsockname(socketDescriptor, $0, &boundLength) }
    self.port = bound.sin6_port.bigEndian
  }

  private func accept(_ socketDescriptor: Int32) {
    var address = sockaddr_in6()
    var addressLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
    let acceptDescriptor = Self.withSocketAddress(&address) { Darwin.accept(socketDescriptor, $0, &addressLength) }
    guard acceptDescriptor > 0 else {
      return
    }
    delegate.socketServer(self, clientConnected: address.sin6_addr, fileDescriptor: acceptDescriptor)
  }

  private static func withSocketAddress<Result>(
    _ address: inout sockaddr_in6,
    _ body: (UnsafeMutablePointer<sockaddr>) -> Result
  ) -> Result {
    withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, body)
    }
  }

  private static func lastErrorDescription() -> String {
    String(cString: strerror(errno))
  }
}
