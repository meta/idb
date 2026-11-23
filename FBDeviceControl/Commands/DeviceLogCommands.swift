/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

private let syslogRelayService = "com.apple.syslog_relay"

// MARK: - DeviceLogOperation

public final class DeviceLogOperation: LogOperation {
  public let consumer: any DataConsumer
  private let connection: LockdownServiceConnection
  private let service: String
  private let logger: any ControlCoreLogger

  init(
    consumer: any DataConsumer,
    connection: LockdownServiceConnection,
    service: String,
    logger: any ControlCoreLogger
  ) {
    self.consumer = consumer
    self.connection = connection
    self.service = service
    self.logger = logger
  }

  // MARK: - LogOperation

  /// Never returns of its own accord: the device reaching the end of its log is not the end of the
  /// tail, and only the caller decides that. Cancelling is what invalidates the connection.
  public func waitUntilCompleted() async throws {
    do {
      try await AsyncEvent<Void>().wait()
    } catch {
      await MobileDevice.invalidateServiceConnection(connection, service: service, logger: logger)
      throw error
    }
  }
}

// MARK: - DeviceLogCommands

public struct DeviceLogCommands: LogCommands {
  private let device: Device

  public init(device: Device) {
    self.device = device
  }

  // MARK: - LogCommands

  public func tail(arguments: [String], consumer: any DataConsumer) async throws -> any LogOperation {
    if !arguments.isEmpty {
      let unsupportedArgumentsMessage = "[DeviceLogCommands][rdar://38452839] Unsupported arguments: \(arguments)"
      if let data = unsupportedArgumentsMessage.data(using: .utf8) {
        consumer.consumeData(data)
      }
      device.logger.log(unsupportedArgumentsMessage)
    }
    let readQueue = DispatchQueue(label: "com.facebook.fbdevicecontrol.device_log_consumer")
    let connection = try await device.openServiceConnection(syslogRelayService)
    let reader = connection.readFromConnectionWriting(to: consumer, on: readQueue)
    try reader.startReading()
    return DeviceLogOperation(
      consumer: consumer,
      connection: connection,
      service: syslogRelayService,
      logger: device.logger
    )
  }
}
