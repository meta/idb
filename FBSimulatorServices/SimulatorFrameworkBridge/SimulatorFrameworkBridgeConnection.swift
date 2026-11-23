/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBControlCore
import FBSimulatorBridgeProtocol
import FBSimulatorControl
import Foundation
import SimulatorIPC

enum BridgeGuestOwnership: Sendable {
  case privateToThisHost(RunningSubprocess)
  case shared(RunningSubprocess?)

  var process: RunningSubprocess? {
    switch self {
    case let .privateToThisHost(process): process
    case let .shared(process): process
    }
  }

  var isPrivate: Bool {
    switch self {
    case .privateToThisHost: true
    case .shared: false
    }
  }
}

/// A serialized connection to a guest serving length-prefixed JSON over a Unix socket.
// SAFETY: socket I/O and `terminalError` are accessed only on `queue`.
// patternlint-disable-next-line unchecked-sendable
final class SimulatorFrameworkBridgeConnection: BridgeConnection, @unchecked Sendable {
  private let fileDescriptor: Int32
  private let ownership: BridgeGuestOwnership
  private let queue = DispatchQueue(label: "com.facebook.FBSimulatorControl.frameworkbridge.connection")

  private var terminalError: (any Error)?

  /// The per-`recv` silence deadline, rather than a deadline for the whole response.
  static let receiveTimeoutSeconds = 30

  var mayBeHeldBetweenRoundTrips: Bool {
    ownership.isPrivate
  }

  init(fileDescriptor: Int32, ownership: BridgeGuestOwnership) {
    self.fileDescriptor = fileDescriptor
    self.ownership = ownership
  }

  deinit {
    close(fileDescriptor)
  }

  /// Cancelling the awaiting task shuts the socket down, which ends a read waiting on the guest at once; the
  /// connection cannot be used again.
  func roundTrip(_ requestData: Data, receiveTimeout: TimeInterval?) async throws -> Data {
    do {
      return try await withTaskCancellationHandler {
        try await exchange(requestData, receiveTimeout: receiveTimeout)
      } onCancel: { [fileDescriptor] in
        shutdown(fileDescriptor, SHUT_RDWR)
      }
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }

  private func exchange(_ requestData: Data, receiveTimeout: TimeInterval?) async throws -> Data {
    try await queue.perform { [self] in
      do {
        if let terminalError { throw terminalError }
        let request = try BridgeRequest.decode(requestData)
        if let receiveTimeout {
          try setReceiveWindow(receiveTimeout)
        }
        try SimulatorFrameworkBridgeConnection.writeFrame(fileDescriptor, requestData)
        let responseData = try SimulatorFrameworkBridgeConnection.readFrame(
          fileDescriptor, guest: ownership.process, receiveTimeout: receiveTimeout)
        // The caller decodes the answer; checking the frame is this request's is all that is needed here.
        try BridgeResponse.validate(responseData, for: request)
        if receiveTimeout != nil {
          do {
            try setReceiveWindow(TimeInterval(Self.receiveTimeoutSeconds))
          } catch {
            // The answer stands, but the next round trip would inherit this one's narrower window.
            terminalError = error
          }
        }
        return responseData
      } catch {
        terminalError = error
        throw error
      }
    }
  }

  /// Sends `request` and yields the result of every response frame until the guest closes the connection.
  ///
  /// A stream may stay silent for as long as nothing happens, so the per-`recv` deadline is lifted.
  /// Ending the iteration shuts the socket down, which is how the guest learns to stop.
  func stream(_ request: BridgeRequest) -> AsyncThrowingStream<BridgeResult, any Error> {
    AsyncThrowingStream { continuation in
      continuation.onTermination = { [self] _ in
        shutdown(fileDescriptor, SHUT_RDWR)
      }
      queue.async { [self] in
        do {
          var noDeadline = timeval()
          unsafe setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &noDeadline, socklen_t(MemoryLayout<timeval>.size))
          try SimulatorFrameworkBridgeConnection.writeFrame(fileDescriptor, request.encoded())
          while let frame = try SimulatorFrameworkBridgeConnection.readFrameUnlessClosed(fileDescriptor, guest: ownership.process) {
            continuation.yield(try BridgeResponse.decode(frame, for: request).result)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  /// Connects until the deadline or guest failure. A shared lock loser may exit before its winner binds.
  ///
  /// `guest` is the process expected to bind `path`, passed only when this host spawned it.
  static func connect(
    path: String,
    timeout: TimeInterval,
    guest: RunningSubprocess? = nil,
    scope: BridgeServiceScope = .exclusive,
    attempt: @escaping @Sendable (String) -> Int32? = attemptConnection
  ) async throws -> Int32 {
    guard path.utf8.count < IPCSocket.pathCapacity else {
      throw AXBridgeError.socketPathTooLong(path: path, limit: IPCSocket.pathCapacity)
    }
    return try await DispatchQueue.global().perform {
      let deadline = Date().addingTimeInterval(timeout)
      repeat {
        if let fileDescriptor = attempt(path) {
          return fileDescriptor
        }
        // Our guest exiting does not mean the socket is unbound: the shared per-UDID path may be served by
        // another host's guest, so try once more before failing.
        if let guest, let status = guest.observedTerminationStatus {
          let exit = terminationCause(status)
          if scope != .shared || exit.signal != nil || exit.exitCode != 0 {
            if let fileDescriptor = attempt(path) {
              return fileDescriptor
            }
            throw AXBridgeError.guestDiedBeforeBinding(
              pid: guest.processIdentifier, signal: exit.signal, exitCode: exit.exitCode, path: path)
          }
        }
        usleep(100_000)
      } while Date() < deadline
      throw AXBridgeError.guestFailure("timed out connecting to the serve socket at \(path)")
    }
  }

  /// One connect attempt, carrying the socket options a serving connection needs when it lands.
  private static func attemptConnection(toPath path: String) -> Int32? {
    (try? IPCSocket.connect(path: path, timeoutSeconds: receiveTimeoutSeconds)) ?? nil
  }

  static func writeFrame(_ fileDescriptor: Int32, _ payload: Data) throws {
    do {
      try IPCSocket.writeFrame(fileDescriptor, payload)
    } catch IPCError.closed {
      throw AXBridgeError.guestFailure("socket write returned 0")
    } catch let IPCError.failed(_, code) {
      throw AXBridgeError.guestFailure(unsafe "socket write failed: \(String(cString: strerror(code)))")
    } catch {
      throw AXBridgeError.guestFailure("socket write failed: \(error)")
    }
  }

  private func setReceiveWindow(_ timeout: TimeInterval) throws {
    var window = SimulatorFrameworkBridgePersistentTransport.receiveWindow(timeout)
    guard unsafe setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
      throw AXBridgeError.guestFailure(unsafe "could not set the socket's receive timeout: \(String(cString: strerror(errno)))")
    }
  }

  static func readFrame(
    _ fileDescriptor: Int32,
    guest: RunningSubprocess?,
    receiveTimeout: TimeInterval? = nil
  ) throws -> Data {
    do {
      return try IPCSocket.readFrame(fileDescriptor)
    } catch IPCError.closed {
      throw AXBridgeError.guestFailure(SimulatorFrameworkBridgeConnection.socketClosedMessage(process: guest))
    } catch IPCError.timedOut {
      if let receiveTimeout {
        throw AXBridgeError.guestNotAnswering(after: receiveTimeout)
      }
      throw AXBridgeError.guestFailure("serve read timed out after \(receiveTimeoutSeconds)s with no data")
    } catch let IPCError.failed(_, code) {
      throw AXBridgeError.guestFailure(unsafe "socket read failed: \(String(cString: strerror(code)))")
    } catch {
      throw AXBridgeError.guestFailure("socket read failed: \(error)")
    }
  }

  /// A frame, or `nil` when the peer closed the connection at a frame boundary: the end of a stream
  /// rather than a truncated response.
  static func readFrameUnlessClosed(
    _ fileDescriptor: Int32,
    guest: RunningSubprocess?
  ) throws -> Data? {
    var byte: UInt8 = 0
    while true {
      let peeked = unsafe recv(fileDescriptor, &byte, 1, MSG_PEEK)
      if peeked == 0 {
        return nil
      }
      if peeked > 0 {
        return try readFrame(fileDescriptor, guest: guest)
      }
      if errno != EINTR {
        throw AXBridgeError.guestFailure(unsafe "socket read failed: \(String(cString: strerror(errno)))")
      }
    }
  }

  static func socketClosedMessage(process: RunningSubprocess?) -> String {
    guard let process else {
      return socketClosedMessage(pid: nil, signal: nil, exitCode: nil)
    }
    // EOF can arrive before the exit is observed, so this reports only what is already known rather than waiting.
    let exit = terminationCause(process.observedTerminationStatus)
    return socketClosedMessage(pid: process.processIdentifier, signal: exit.signal, exitCode: exit.exitCode)
  }

  static func socketClosedMessage(pid: pid_t?, signal: Int?, exitCode: Int?) -> String {
    let base = "serve socket closed by peer"
    guard let pid else {
      return base
    }
    if let signal, signal != 0 {
      return "\(base): the guest (pid \(pid)) was killed by signal \(signal)"
    }
    if let exitCode {
      return "\(base): the guest (pid \(pid)) exited with code \(exitCode)"
    }
    return "\(base): the guest (pid \(pid)) is gone, with no exit status recorded"
  }

  /// Splits a termination into whichever of the two outcomes it is, or neither when none is known.
  static func terminationCause(_ status: TerminationStatus?) -> (signal: Int?, exitCode: Int?) {
    switch status {
    case .none:
      return (signal: nil, exitCode: nil)
    case let .signalled(signo):
      return (signal: Int(signo), exitCode: nil)
    case let .exited(code):
      return (signal: nil, exitCode: Int(code))
    }
  }
}
