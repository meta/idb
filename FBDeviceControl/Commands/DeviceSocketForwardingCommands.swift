/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import Foundation
import MobileDeviceAPI

public enum DeviceSocketForwardingError: Error {
  case socketDuplicationFailed(message: String)
  case callUnavailable(function: String)
  case connectionIDUnavailable
  case remoteConnectionFailed(remotePort: Int)
  case invalidPort(Int)
}

extension DeviceSocketForwardingError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .socketDuplicationFailed(message):
      return "Could not duplicate socket descriptor: \(message)"
    case let .callUnavailable(function):
      return "\(function) not available"
    case .connectionIDUnavailable:
      return "Failed to get ConnectionID from Device"
    case let .remoteConnectionFailed(remotePort):
      return "Failed to connect to remote port \(remotePort)"
    case let .invalidPort(port):
      return "Invalid device port \(port); expected 1...65535"
    }
  }
}

public struct DeviceSocketForwardingCommands {
  let device: Device

  public init(device: Device) {
    self.device = device
  }

  // MARK: - Socket forwarding

  /// Keeps the connected device alive until the socket operation and its cleanup finish.
  public func withPortConnection<Result: Sendable>(
    port: UInt16,
    operation: @Sendable (SocketStream) async throws -> Result
  ) async throws -> Result {
    guard port > 0 else { throw DeviceSocketForwardingError.invalidPort(Int(port)) }
    return try await device.withConnectedDevice(purpose: "Socket Connection") { connectedDevice in
      let descriptor = try Self.openLocalSocket(toRemotePort: Int(port), on: connectedDevice, logger: device.logger)
      return try await SocketStream.withSocket(adopting: descriptor, operation: operation)
    }
  }

  public func drainLocalFileInput(
    _ localFileDescriptorInput: Int32,
    localFileOutput localFileDescriptorOutput: Int32,
    remotePort: Int32
  ) async throws {
    guard (1...65535).contains(remotePort) else { throw DeviceSocketForwardingError.invalidPort(Int(remotePort)) }
    let localConsumer = try FileWriter.asyncWriter(withFileDescriptor: localFileDescriptorOutput, closeOnEndOfFile: false)
    try await device.withConnectedDevice(purpose: "Socket Connection") { connectedDevice in
      let localSocket = try Self.openLocalSocket(toRemotePort: Int(remotePort), on: connectedDevice, logger: device.logger)
      // The writer gets its own duplicate of the socket, owned and closed by its channel. Two
      // dispatch io channels must not share one descriptor: they share a per-descriptor entry
      // inside libdispatch, and one channel's cleanup is deferred behind the other's outstanding
      // operations, wedging teardown.
      let writerDescriptor = dup(localSocket)
      guard writerDescriptor >= 0 else {
        close(localSocket)
        throw DeviceSocketForwardingError.socketDuplicationFailed(message: String(cString: strerror(errno)))
      }
      let remoteWriter: any DataConsumer & DataConsumerLifecycle
      do {
        remoteWriter = try FileWriter.asyncWriter(withFileDescriptor: writerDescriptor, closeOnEndOfFile: true)
      } catch {
        close(writerDescriptor)
        close(localSocket)
        throw error
      }
      let remoteReader = DescriptorReader(fileDescriptor: localSocket, closeOnEndOfFile: false, consumer: localConsumer)
      let inputReader = DescriptorReader(fileDescriptor: localFileDescriptorInput, closeOnEndOfFile: false, consumer: remoteWriter)
      // Cancelling this wait stops the reader instead of throwing, so the cancellation is reported
      // once teardown is done.
      _ = await inputReader.finished()
      await Self.stopForwarding(inputReader: inputReader, remoteReader: remoteReader, remoteWriter: remoteWriter, localSocket: localSocket, logger: device.logger)
      try Task.checkCancellation()
    }
  }

  /// How long to wait for a reader to finish naturally before stopping it.
  private static let teardownDrainTimeout: TimeInterval = 4

  // The reader dispatch io channel must relinquish localSocket before it is
  // closed: closing a descriptor that a dispatch source still monitors
  // crashes libdispatch with EV_VANISHED. The writer is wound down first so
  // outbound bytes flush before responses stop being read; its channel closes
  // its own duplicated descriptor. Reader drains are time-bounded.
  private static func stopForwarding(
    inputReader: DescriptorReader,
    remoteReader: DescriptorReader,
    remoteWriter: any DataConsumer & DataConsumerLifecycle,
    localSocket: Int32,
    logger: (any ControlCoreLogger)?
  ) async {
    remoteWriter.consumeEndOfFile()
    try? await remoteWriter.awaitFinishedConsuming()
    _ = await inputReader.finished(within: teardownDrainTimeout)
    _ = await remoteReader.finished(within: teardownDrainTimeout)
    logger?.log("Closing local socket \(localSocket)")
    close(localSocket)
  }

  private static func openLocalSocket(toRemotePort remotePort: Int, on device: any DeviceCommands, logger: (any ControlCoreLogger)?) throws -> Int32 {
    guard (1...65535).contains(remotePort) else { throw DeviceSocketForwardingError.invalidPort(remotePort) }
    guard let getConnectionID = device.calls.GetConnectionID else {
      throw DeviceSocketForwardingError.callUnavailable(function: "GetConnectionID")
    }
    let connectionID = getConnectionID(device.amDeviceRef)
    if connectionID <= 0 {
      throw DeviceSocketForwardingError.connectionIDUnavailable
    }
    logger?.log("Got connection ID \(connectionID), for device. Connecting to remote port \(remotePort)")
    var localSocket: Int32 = 0
    guard let usbMuxConnect = device.calls.USBMuxConnectByPort else {
      throw DeviceSocketForwardingError.callUnavailable(function: "USBMuxConnectByPort")
    }
    let status = usbMuxConnect(connectionID, Int32(UInt16(remotePort).bigEndian), &localSocket)
    if status != 0 {
      throw DeviceSocketForwardingError.remoteConnectionFailed(remotePort: remotePort)
    }
    logger?.log("Got local socket \(localSocket) for remote port \(remotePort)")
    return localSocket
  }
}
