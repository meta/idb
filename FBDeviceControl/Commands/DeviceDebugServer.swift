/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

private let connectionReadSizeLimit: size_t = 1024

public final class DeviceDebugServer: SocketServerDelegate, DebugServer {
  private let serviceConnection: LockdownServiceConnection
  private lazy var teardown = Teardown(
    tcpServer: SocketServer(onPort: self.port, delegate: self),
    connection: serviceConnection,
    logger: logger)
  private let port: in_port_t
  private let logger: any ControlCoreLogger

  public let lldbBootstrapCommands: [String]

  public let queue: DispatchQueue

  // MARK: - Initializers

  /// Starts a debug server that proxies `serviceConnection` to whichever client connects on `port`.
  ///
  /// The server owns the connection: it is held open across the separate requests that start,
  /// query and stop the server, and handed back to `MobileDevice.invalidateServiceConnection` when
  /// the server is cancelled or its client disconnects. A server that fails to start hands the
  /// connection back before throwing.
  public static func debugServer(
    forServiceConnection serviceConnection: LockdownServiceConnection,
    port: in_port_t,
    lldbBootstrapCommands: [String],
    queue: DispatchQueue,
    logger: any ControlCoreLogger
  ) async throws -> DeviceDebugServer {
    let server = DeviceDebugServer(
      serviceConnection: serviceConnection,
      port: port,
      lldbBootstrapCommands: lldbBootstrapCommands,
      queue: queue,
      logger: logger
    )
    do {
      try await server.startListening()
    } catch {
      await MobileDevice.invalidateServiceConnection(serviceConnection, service: serviceConnection.name, logger: logger)
      throw error
    }
    return server
  }

  init(
    serviceConnection: LockdownServiceConnection,
    port: in_port_t,
    lldbBootstrapCommands: [String],
    queue: DispatchQueue,
    logger: any ControlCoreLogger
  ) {
    self.serviceConnection = serviceConnection
    self.port = port
    self.lldbBootstrapCommands = lldbBootstrapCommands
    self.queue = queue
    self.logger = logger
  }

  // MARK: - SocketServerDelegate

  public func socketServer(
    _ server: SocketServer,
    clientConnected address: in6_addr,
    fileDescriptor: Int32
  ) {
    let teardown = self.teardown
    guard teardown.claimClient() else {
      logger.log("Rejecting connection, we have an existing pair")
      if let data = "$NEUnspecified#00".data(using: .ascii) {
        unsafe data.withUnsafeBytes { bufferPointer in
          guard let baseAddress = bufferPointer.baseAddress else { return }
          _ = unsafe Darwin.write(fileDescriptor, baseAddress, data.count)
        }
      }
      close(fileDescriptor)
      return
    }
    logger.log("Client connected, connecting all file handles")
    TwistedPairFiles(
      socket: fileDescriptor,
      connection: serviceConnection,
      logger: logger
    )
    .start(notifying: queue) {
      Task { await teardown.clientDisconnected() }
    }
  }

  // MARK: - DebugServer

  public func cancel() async throws {
    await teardown.stop()
  }

  /// Creates `teardown`, and with it the socket server, before any client can connect.
  private func startListening() async throws {
    try teardown.tcpServer.startListening()
    logger.log("TCP Server now running, bootstrap commands for lldb are \(lldbBootstrapCommands.joined(separator: "\n"))")
  }

  /// What the client disconnecting and `cancel()` share. Either can stop the server, from any
  /// thread, and only the first does: the socket server and connection are touched by that one alone.
  private final class Teardown: @unchecked Sendable {
    let tcpServer: SocketServer
    private let connection: LockdownServiceConnection
    private let logger: any ControlCoreLogger
    private let lock = NSLock()
    private var hasClient = false
    private var stopped = false

    init(tcpServer: SocketServer, connection: LockdownServiceConnection, logger: any ControlCoreLogger) {
      self.tcpServer = tcpServer
      self.connection = connection
      self.logger = logger
    }

    /// The server proxies one client at a time.
    func claimClient() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if hasClient {
        return false
      }
      hasClient = true
      return true
    }

    func clientDisconnected() async {
      lock.withLock { hasClient = false }
      logger.log("Client Disconnected")
      await stop()
    }

    /// Innermost first: the socket a client would reach the connection through goes before the
    /// connection itself.
    func stop() async {
      let alreadyStopped = lock.withLock {
        defer { stopped = true }
        return stopped
      }
      if alreadyStopped {
        return
      }
      try? tcpServer.stopListening()
      await MobileDevice.invalidateServiceConnection(connection, service: connection.name, logger: logger)
    }
  }

  private class TwistedPairFiles {
    let socket: Int32
    let connection: LockdownServiceConnection
    let logger: any ControlCoreLogger
    let socketToConnectionQueue: DispatchQueue
    let connectionToSocketQueue: DispatchQueue

    init(
      socket: Int32,
      connection: LockdownServiceConnection,
      logger: any ControlCoreLogger
    ) {
      self.socket = socket
      self.connection = connection
      self.logger = logger
      self.socketToConnectionQueue = DispatchQueue(label: "com.facebook.fbdevicecontrol.debugserver.socket_to_connection")
      self.connectionToSocketQueue = DispatchQueue(label: "com.facebook.fbdevicecontrol.debugserver.connection_to_socket")
    }

    /// Pumps bytes both ways until either side ends, then closes the socket and calls `completion`
    /// on `queue`.
    func start(notifying queue: DispatchQueue, completion: @escaping @Sendable () -> Void) {
      let logger = self.logger
      let socket = self.socket
      let socketReadHandle = FileHandle(fileDescriptor: socket)
      nonisolated(unsafe) let connection = self.connection
      let ended = PumpEnded()
      let pumps = DispatchGroup()

      pumps.enter()
      socketToConnectionQueue.async {
        while !ended.value {
          let data = socketReadHandle.availableData
          if data.isEmpty {
            logger.log("Socket read reached end of file")
            break
          }
          do {
            unsafe try connection.send(data as Data)
          } catch {
            logger.log("Sending data to remote debugserver failed: \(error)")
            break
          }
        }
        logger.log("Exiting socket \(socket) read loop")
        ended.end()
        pumps.leave()
      }

      pumps.enter()
      connectionToSocketQueue.async {
        while !ended.value {
          do {
            let data = unsafe try connection.receiveUp(to: connectionReadSizeLimit)
            if data.isEmpty {
              logger.log("debugserver read ended")
              break
            }
            unsafe data.withUnsafeBytes { bufferPointer in
              guard let baseAddress = bufferPointer.baseAddress else { return }
              var totalWritten = 0
              while totalWritten < data.count {
                let written = unsafe Darwin.write(socket, baseAddress.advanced(by: totalWritten), data.count - totalWritten)
                if written <= 0 {
                  logger.log("Socket write failed")
                  return
                }
                totalWritten += written
              }
            }
          } catch {
            logger.log("debugserver read ended: \(error)")
            break
          }
        }
        logger.log(unsafe "Exiting connection \(connection) read loop")
        ended.end()
        pumps.leave()
      }

      pumps.notify(queue: queue) {
        logger.log("Closing socket file descriptor \(socket)")
        close(socket)
        completion()
      }
    }
  }

  /// Set once either pump loop exits, so the other stops at its next iteration.
  private final class PumpEnded: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    var value: Bool {
      lock.lock()
      defer { lock.unlock() }
      return ended
    }

    func end() {
      lock.lock()
      ended = true
      lock.unlock()
    }
  }
}
