/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import Foundation
import MobileDeviceAPI

public final class DeviceSet: TargetSet, TargetSetDelegate, CustomStringConvertible {
  // Loaded once per process; a failed load is cached and rethrown by every init rather than
  // aborting the process.
  private static let _amDeviceCalls: Result<AMDCalls, Error> = Result {
    let loader = DeviceControlFrameworkLoader()
    try loader.loadPrivateFrameworks(ControlCoreGlobalConfiguration.defaultLogger)
    return try loader.amDeviceCalls
  }

  private let amDeviceManager: AMDeviceManager
  private let restorableDeviceManager: AMRestorableDeviceManager
  private let storage: DeviceStorage<Device>
  private let notifications = DeviceNotificationQueue()
  public let logger: any ControlCoreLogger
  public weak var delegate: (any TargetSetDelegate)?

  public convenience init(logger: any ControlCoreLogger, delegate: (any TargetSetDelegate)?, ecidFilter: String?) throws {
    let calls = try Self._amDeviceCalls.get()
    let workQueue = DispatchQueue.main
    let asyncQueue = DispatchQueue.global(qos: .userInitiated)
    let amDeviceManager = AMDeviceManager(calls: calls, work: workQueue, asyncQueue: asyncQueue, ecidFilter: ecidFilter, logger: logger)
    let restorableDeviceManager = AMRestorableDeviceManager(calls: calls, work: workQueue, asyncQueue: asyncQueue, ecidFilter: ecidFilter, logger: logger)
    self.init(amDeviceManager: amDeviceManager, restorableDeviceManager: restorableDeviceManager, logger: logger, delegate: delegate)
    try amDeviceManager.startListening()
    try restorableDeviceManager.startListening()
  }

  init(amDeviceManager: AMDeviceManager, restorableDeviceManager: AMRestorableDeviceManager, logger: any ControlCoreLogger, delegate: (any TargetSetDelegate)?) {
    self.amDeviceManager = amDeviceManager
    self.restorableDeviceManager = restorableDeviceManager
    self.logger = logger
    self.delegate = delegate
    self.storage = DeviceStorage<Device>(logger: logger)
    subscribeToDeviceNotifications()
  }

  deinit {
    unsubscribeFromDeviceNotifications()
  }

  public var description: String {
    "DeviceSet: \(CollectionInformation.oneLineDescription(from: allDevices))"
  }

  // MARK: - Querying

  public func target(withUDID udid: String) -> (any TargetInfo)? {
    device(withUDID: udid)
  }

  public func device(withUDID udid: String) -> Device? {
    allDevices.first { $0.udid == udid }
  }

  public var allTargetInfos: [any TargetInfo] {
    allDevices
  }

  public var allDevices: [Device] {
    storage.attached.sorted { $0.key < $1.key }.map(\.value)
  }

  private func subscribeToDeviceNotifications() {
    amDeviceManager.delegate = self
    restorableDeviceManager.delegate = self
    for amDevice in amDeviceManager.currentDeviceList {
      targetAdded(amDevice, in: amDeviceManager)
    }
    for restorableDevice in restorableDeviceManager.currentDeviceList {
      targetAdded(restorableDevice, in: restorableDeviceManager)
    }
  }

  private func unsubscribeFromDeviceNotifications() {
    amDeviceManager.delegate = nil
    restorableDeviceManager.delegate = nil
  }

  private func amDeviceAdded(_ amDevice: MobileDevice) {
    let identifier = amDevice.uniqueIdentifier
    let device: Device
    if let existing = storage.device(forKey: identifier) {
      device = existing
      device.amDevice = amDevice
    } else {
      device = Device(amDevice: amDevice, restorableDevice: nil, logger: logger)
    }
    storage.deviceAttached(device, forKey: identifier)
    delegate?.targetAdded(device, in: self)
  }

  private func amDeviceRemoved(identifier: String) {
    guard let device = storage.device(forKey: identifier) else {
      logger.log("AMDevice \(identifier) was removed, but there's no active device for it")
      return
    }
    device.amDevice = nil
    if device.restorableDevice != nil {
      delegate?.targetUpdated(device, in: self)
    } else {
      storage.deviceDetached(forKey: identifier)
      delegate?.targetRemoved(device, in: self)
    }
  }

  private func restorableDeviceAdded(_ restorableDevice: RestorableDevice) {
    let identifier = restorableDevice.uniqueIdentifier
    let device: Device
    if let existing = storage.device(forKey: identifier) {
      device = existing
      device.restorableDevice = restorableDevice
    } else {
      device = Device(amDevice: nil, restorableDevice: restorableDevice, logger: logger)
    }
    storage.deviceAttached(device, forKey: identifier)
    delegate?.targetAdded(device, in: self)
  }

  private func restorableDeviceRemoved(identifier: String) {
    guard let device = storage.device(forKey: identifier) else {
      logger.log("RestorableDevice \(identifier) was removed, but there's no active device for it")
      return
    }
    device.restorableDevice = nil
    if device.amDevice != nil {
      delegate?.targetUpdated(device, in: self)
    } else {
      storage.deviceDetached(forKey: identifier)
      delegate?.targetRemoved(device, in: self)
    }
  }

  // MARK: - TargetSetDelegate

  public func targetAdded(_ targetInfo: any TargetInfo, in targetSet: any TargetSet) {
    if let amDevice = targetInfo as? MobileDevice {
      let view = amDevice.notificationView()
      notifications.enqueue { [weak self] in self?.amDeviceAdded(view) }
    } else if let restorableDevice = targetInfo as? RestorableDevice {
      let view = restorableDevice.notificationView()
      notifications.enqueue { [weak self] in self?.restorableDeviceAdded(view) }
    } else {
      logger.log("Ignoring \(targetInfo) as it is not a valid target type")
    }
  }

  public func targetRemoved(_ targetInfo: any TargetInfo, in targetSet: any TargetSet) {
    if targetInfo is MobileDevice {
      let identifier = targetInfo.uniqueIdentifier
      notifications.enqueue { [weak self] in self?.amDeviceRemoved(identifier: identifier) }
    } else if targetInfo is RestorableDevice {
      let identifier = targetInfo.uniqueIdentifier
      notifications.enqueue { [weak self] in self?.restorableDeviceRemoved(identifier: identifier) }
    } else {
      logger.log("Ignoring \(targetInfo) as it is not a valid target type")
    }
  }

  public func targetUpdated(_ targetInfo: any TargetInfo, in targetSet: any TargetSet) {
    let view: any TargetInfo
    if let amDevice = targetInfo as? MobileDevice {
      view = amDevice.notificationView()
    } else if let restorableDevice = targetInfo as? RestorableDevice {
      view = restorableDevice.notificationView()
    } else {
      assertionFailure("No existing device to update for \(targetInfo)")
      return
    }
    notifications.enqueue { [weak self] in self?.processTargetUpdated(view) }
  }

  private func processTargetUpdated(_ targetInfo: any TargetInfo) {
    let identifier = targetInfo.uniqueIdentifier
    guard let device = storage.device(forKey: identifier) else {
      assertionFailure("No existing device to update for \(identifier)")
      return
    }
    if let amDevice = targetInfo as? MobileDevice {
      device.amDevice = amDevice
    } else if let restorableDevice = targetInfo as? RestorableDevice {
      device.restorableDevice = restorableDevice
    } else {
      assertionFailure("No existing device to update for \(identifier)")
      return
    }
    delegate?.targetUpdated(device, in: self)
  }
}
