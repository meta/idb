/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
@_implementationOnly import SimulatorIPC

public struct ShimulatorResponder: Equatable, Sendable {
  public var response: ShimulatorResponse?
  public var connected: Bool
  public var error: String?

  public init(response: ShimulatorResponse? = nil, connected: Bool, error: String? = nil) {
    self.response = response
    self.connected = connected
    self.error = error
  }
}

public final class ShimulatorServer {
  private var listener: IPCListener?
  private var admitting = true
  private let request: Data
  private var connections: [(fileDescriptor: Int32, responder: ShimulatorResponder)] = []
  private var settled: [ShimulatorResponder] = []

  public init?<Parameters: Codable & Sendable>(path: String, parameters: Parameters) throws {
    try IPCSocket.requirePrivateDirectory((path as NSString).deletingLastPathComponent, creating: true)
    guard let listener = try IPCListener.bind(path: path, backlog: 16) else { return nil }
    self.listener = listener
    request = try JSONEncoder().encode(ShimulatorRequest(parameters: parameters))
  }

  deinit {
    listener = nil
    for connection in connections {
      close(connection.fileDescriptor)
    }
  }

  public func stopAdmitting() {
    admitting = false
  }

  public func poll() -> [ShimulatorResponder] {
    admit()
    var live: [(fileDescriptor: Int32, responder: ShimulatorResponder)] = []
    for connection in connections {
      let responder = read(connection.fileDescriptor, updating: connection.responder)
      if responder.connected {
        live.append((connection.fileDescriptor, responder))
        continue
      }
      close(connection.fileDescriptor)
      if responder.response != nil || responder.error != nil {
        settled.append(responder)
      }
    }
    connections = live
    defer { settled = [] }
    return settled + connections.map(\.responder)
  }

  /// Blocks until a process can be admitted, a connection has something to read or has closed, `wakeDescriptor` is
  /// readable, or `timeoutMilliseconds` pass (`-1` waits indefinitely), so a host need not poll on a timer.
  public func wait(timeoutMilliseconds: Int32, wakeDescriptor: Int32) {
    var descriptors = [pollfd(fd: wakeDescriptor, events: Int16(POLLIN), revents: 0)]
    if admitting, let listener {
      descriptors.append(pollfd(fd: listener.fileDescriptor, events: Int16(POLLIN), revents: 0))
    }
    descriptors += connections.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
    _ = Darwin.poll(&descriptors, nfds_t(descriptors.count), timeoutMilliseconds)
  }

  private func admit() {
    guard admitting, let listener else { return }
    while Self.isReadable(listener.fileDescriptor) {
      let connection = accept(listener.fileDescriptor, nil, nil)
      guard connection >= 0 else { return }
      var noSigPipe: Int32 = 1
      setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
      IPCSocket.setTimeout(connection, seconds: 1)
      do {
        try IPCSocket.writeFrame(connection, request)
      } catch IPCError.closed, IPCError.failed(_, EPIPE), IPCError.failed(_, ECONNRESET) {
        close(connection)
        continue
      } catch {
        close(connection)
        settled.append(ShimulatorResponder(connected: false, error: String(describing: error)))
        continue
      }
      connections.append((connection, ShimulatorResponder(connected: true)))
    }
  }

  private func read(_ fileDescriptor: Int32, updating responder: ShimulatorResponder) -> ShimulatorResponder {
    guard Self.isReadable(fileDescriptor) else { return responder }
    var updated = responder
    do {
      updated.response = try ShimulatorResponse.decode(IPCSocket.readFrame(fileDescriptor))
    } catch IPCError.closed {
      updated.connected = false
    } catch {
      updated.connected = false
      updated.error = String(describing: error)
    }
    return updated
  }

  private static func isReadable(_ fileDescriptor: Int32) -> Bool {
    var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
    return Darwin.poll(&descriptor, 1, 0) > 0
  }
}
