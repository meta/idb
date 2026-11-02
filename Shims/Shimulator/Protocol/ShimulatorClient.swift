/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
@_implementationOnly import SimulatorIPC

public struct ShimulatorMethodUpdate: Equatable, Sendable {
  public let state: ShimulatorResponseState
  public let message: String?
  /// See `ShimulatorResponse.payload`. A change to it alone is reported, as a change of state is.
  public let payload: Data?

  public init(_ state: ShimulatorResponseState, message: String? = nil, payload: Data? = nil) {
    self.state = state
    self.message = message
    self.payload = payload
  }
}

public protocol ShimulatorMethodHandler: AnyObject {
  associatedtype Parameters: Codable, Sendable
  associatedtype Admission

  func start(_ parameters: Parameters) throws -> Admission
  func stop(_ admission: Admission)
  func poll(_ admission: Admission) -> ShimulatorMethodUpdate?
}

public final class ShimulatorClient<Handler: ShimulatorMethodHandler> {
  private let socketPath: String
  private let handler: Handler
  private let processIdentifier: Int32
  private let processName: String
  private let pollIntervalMilliseconds: Int32
  private let recheckIntervalMilliseconds: Int32
  private let log: (String) -> Void
  private var lastRefusal: String?

  public init(
    socketPath: String,
    handler: Handler,
    processIdentifier: Int32 = getpid(),
    processName: String = ProcessInfo.processInfo.processName,
    pollIntervalMilliseconds: Int32 = 50,
    recheckIntervalMilliseconds: Int32 = 5_000,
    log: @escaping (String) -> Void
  ) {
    self.socketPath = socketPath
    self.handler = handler
    self.processIdentifier = processIdentifier
    self.processName = processName
    self.pollIntervalMilliseconds = pollIntervalMilliseconds
    self.recheckIntervalMilliseconds = recheckIntervalMilliseconds
    self.log = log
  }

  public func run() -> Never {
    let directory = (socketPath as NSString).deletingLastPathComponent
    while true {
      let watch = IPCDirectoryWatch(directory: directory)
      if !serveOnce() {
        _ = watch.wait(timeoutMilliseconds: recheckIntervalMilliseconds)
      }
    }
  }

  @discardableResult
  public func serveOnce() -> Bool {
    let connection: Int32
    do {
      try IPCSocket.requirePrivateDirectory((socketPath as NSString).deletingLastPathComponent, creating: false)
      guard let connected = try IPCSocket.connect(path: socketPath, timeoutSeconds: 5) else { return false }
      connection = connected
    } catch {
      refuse("Will not connect to \(socketPath): \(error)")
      return false
    }
    defer { close(connection) }
    guard waitForDisconnect(connection, timeoutMilliseconds: Self.operationTimeoutMilliseconds) else {
      refuse("No operation arrived from \(socketPath) within \(Self.operationTimeoutMilliseconds) ms")
      return false
    }
    lastRefusal = nil
    let frame: Data
    do {
      frame = try IPCSocket.readFrame(connection)
    } catch IPCError.closed {
      return true
    } catch {
      refuse("Could not read the operation from \(socketPath): \(error)")
      return false
    }
    let admission: Handler.Admission
    do {
      admission = try handler.start(ShimulatorRequest<Handler.Parameters>.decode(frame).parameters)
    } catch {
      log("Could not start the operation from \(socketPath): \(error)")
      if send(ShimulatorMethodUpdate(.failed, message: String(describing: error)), to: connection) {
        waitForDisconnect(connection, timeoutMilliseconds: -1)
      }
      return true
    }
    defer { handler.stop(admission) }
    var published: ShimulatorMethodUpdate?
    repeat {
      if let update = handler.poll(admission), update != published {
        guard send(update, to: connection) else { return true }
        published = update
      }
    } while !waitForDisconnect(connection, timeoutMilliseconds: pollIntervalMilliseconds)
    return true
  }

  private static var operationTimeoutMilliseconds: Int32 { 5_000 }

  private func refuse(_ message: String) {
    if message != lastRefusal {
      log(message)
      lastRefusal = message
    }
  }

  private func send(_ update: ShimulatorMethodUpdate, to connection: Int32) -> Bool {
    let response = ShimulatorResponse(
      processIdentifier: processIdentifier,
      processName: processName,
      state: update.state,
      message: update.message,
      payload: update.payload)
    do {
      try IPCSocket.writeFrame(connection, JSONEncoder().encode(response))
      return true
    } catch {
      log("Could not report \(update.state) to \(socketPath): \(error)")
      return false
    }
  }

  @discardableResult
  private func waitForDisconnect(_ connection: Int32, timeoutMilliseconds: Int32) -> Bool {
    while true {
      var descriptor = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
      let ready = poll(&descriptor, 1, timeoutMilliseconds)
      if ready >= 0 { return ready > 0 }
      if errno == EINTR { continue }
      log("Could not wait on \(socketPath), so the operation ends: \(String(cString: strerror(errno)))")
      return true
    }
  }
}
