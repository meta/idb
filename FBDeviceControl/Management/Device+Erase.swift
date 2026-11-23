/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import MobileDeviceAPI

private let EraseCallbackValueGood: Int32 = -10
private let DetectTimeout: TimeInterval = 10
private let APICallbackTimeout: TimeInterval = 15
private let OfflineTimeout: TimeInterval = 20
private let OnlineTimeout: TimeInterval = 300

// MARK: - DeviceEraseOperation

private final class DeviceEraseOperation: TargetSetDelegate, @unchecked Sendable {

  private let udid: String
  private let calls: AMDCalls
  private let logger: any ControlCoreLogger
  private let queue: DispatchQueue
  private let deviceManager: AMRestorableDeviceManager
  private let deviceDetected = AsyncEvent<Void>()
  private let deviceWentAway = AsyncEvent<Void>()
  private let deviceCameBack = AsyncEvent<Void>()
  private let eraseCallbackResult = AsyncEvent<Int32>()

  init(device: Device, logger: any ControlCoreLogger) {
    let queue = DispatchQueue(label: "com.facebook.fbdeviceerase")
    self.udid = device.udid
    self.calls = device.calls
    self.logger = logger
    self.queue = queue
    self.deviceManager = AMRestorableDeviceManager(
      calls: device.calls,
      work: queue,
      asyncQueue: queue,
      ecidFilter: device.uniqueIdentifier,
      logger: logger
    )
    self.deviceManager.delegate = self
  }

  // MARK: - Erase

  func erase() async throws {
    try deviceManager.startListening()
    try await deviceDetected.wait(timeout: DetectTimeout, waitingFor: "Device to be detected the first time")
    logger.log("Device has been detected, starting erase API Call")
    let eraseCallbackValue = try await startErase()
    guard eraseCallbackValue == EraseCallbackValueGood else {
      throw DeviceEraseError.badEraseCallback(value: eraseCallbackValue, expected: EraseCallbackValueGood)
    }
    logger.log("Device API call finished, waiting for device to go offline")
    try await deviceWentAway.wait(timeout: OfflineTimeout, waitingFor: "Device to go offline")
    logger.log("Device has gone offline, waiting for it to come back online")
    try await deviceCameBack.wait(timeout: OnlineTimeout, waitingFor: "Device to come back")
  }

  /// Issues `AMSEraseDevice` on the serial queue and awaits the value delivered by
  /// the C erase callback (with a timeout).
  private func startErase() async throws -> Int32 {
    queue.async { [self] in
      let selfContext = unsafe Unmanaged.passUnretained(self).toOpaque()
      _ = calls.AMSInitialize?(0)
      let status =
        unsafe calls.AMSEraseDevice?(
          udid as CFString,
          { _, progress, context in
            guard let context = unsafe context else {
              return 0
            }
            let operation = unsafe Unmanaged<DeviceEraseOperation>.fromOpaque(context).takeUnretainedValue()
            operation.logger.log("Erase Callback is \(progress)")
            operation.eraseCallbackResult.happen(progress)
            return 0
          },
          unsafe selfContext
        ) ?? -1
      logger.log("AMSEraseDevice had status \(status)")
    }
    return try await eraseCallbackResult.wait(timeout: APICallbackTimeout, waitingFor: "Device erase API call to resolve")
  }

  // MARK: - TargetSetDelegate

  func targetAdded(_ targetInfo: any TargetInfo, in targetSet: any TargetSet) {
    if !deviceDetected.hasHappened {
      logger.log("Got target \(targetInfo) added for the first time")
      deviceDetected.happen()
    } else {
      logger.log("Got target \(targetInfo) added")
      deviceCameBack.happen()
    }
  }

  func targetRemoved(_ targetInfo: any TargetInfo, in targetSet: any TargetSet) {
    logger.log("Got target \(targetInfo) removed")
    deviceWentAway.happen()
  }

  func targetUpdated(_ targetInfo: any TargetInfo, in targetSet: any TargetSet) {}
}

// MARK: - DeviceEraseError

public enum DeviceEraseError: Error {
  case badEraseCallback(value: Int32, expected: Int32)
}

extension DeviceEraseError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .badEraseCallback(value, expected):
      return "Erase callback was \(value), not \(expected). Perhaps the device is not activated?"
    }
  }
}

// MARK: - Device

extension Device {

  public func erase() async throws {
    let logger = self.logger.withName("erase_\(udid)")
    try await activate()
    let operation = DeviceEraseOperation(device: self, logger: logger)
    try await operation.erase()
    logger.log("Device erase finished successfully \(operation)")
  }
}
