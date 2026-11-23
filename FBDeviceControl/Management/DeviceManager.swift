/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Discovery of a set of devices, shared by the AMDevice and restorable device sources.
///
/// Subclasses supply how to listen and how to turn a private device reference into a public one;
/// this class owns the registry of what is currently attached and notifies the delegate.
class DeviceManager<PublicDevice: AnyObject>: TargetSet, CustomStringConvertible {

  let logger: any ControlCoreLogger
  let storage: DeviceStorage<PublicDevice>
  let notifications = DeviceNotificationQueue(accepting: false)
  weak var delegate: (any TargetSetDelegate)?

  init(logger: any ControlCoreLogger) {
    self.logger = logger
    self.storage = DeviceStorage(logger: logger)
  }

  deinit {
    try? stopListening()
  }

  // MARK: - Implemented in Subclasses

  /// Starts listening for device notifications.
  func startListening() throws {
    throw DeviceManagerError.abstractMethod(name: "startListening")
  }

  /// Stops listening for device notifications.
  func stopListening() throws {
    throw DeviceManagerError.abstractMethod(name: "stopListening")
  }

  /// Constructs the type from the private one.
  func constructPublic(_ privateDevice: CFTypeRef, identifier: String, info: [String: Any]?) -> PublicDevice {
    fatalError("constructPublic is abstract and must be overridden")
  }

  /// Updates the type with data from the private one.
  class func updatePublicReference(
    _ publicDevice: PublicDevice,
    privateDevice: CFTypeRef,
    identifier: String,
    info: [String: Any]?
  ) {
    fatalError("updatePublicReference is abstract and must be overridden")
  }

  /// Extracts the private reference from the public one.
  class func extractPrivateReference(_ publicDevice: PublicDevice) -> Unmanaged<AnyObject>? {
    fatalError("extractPrivateReference is abstract and must be overridden")
  }

  // MARK: - Called in Subclasses

  func deviceConnected(
    _ privateDevice: CFTypeRef, identifier: String, info: [String: Any]?,
    update: ((PublicDevice) -> Void)? = nil
  ) {
    let privateAddress = unsafe Unmanaged.passUnretained(privateDevice as AnyObject).toOpaque()
    logger.log(unsafe "Device Connected \(identifier) (\(privateAddress))")

    // Pull from all known instances created by this class rather than the attached ones: consumers
    // may be holding a device that has been re-connected, and re-using the referenced instance
    // means the underlying reference is replaced beneath them. A device that is no longer
    // referenced has already left the mapping, whose values are weakly held.
    let device: PublicDevice
    if let existing = storage.device(forKey: identifier) {
      logger.info().log("Device has been re-attached \(existing)")
      device = existing
    } else {
      device = constructPublic(privateDevice, identifier: identifier, info: info)
      logger.info().log("Created a new Device instance \(device)")
    }

    let oldPrivateDevice = unsafe Self.extractPrivateReference(device)
    if let oldPrivateDevice = unsafe oldPrivateDevice {
      if unsafe oldPrivateDevice.toOpaque() != privateAddress {
        logger.log(unsafe "New '\(identifier)' (\(privateAddress)) replaces Old Device (\(oldPrivateDevice.toOpaque()))")
        Self.updatePublicReference(device, privateDevice: privateDevice, identifier: identifier, info: info)
      } else {
        logger.log(unsafe "Existing Device '\(identifier)' (\(privateAddress)) is the same as the old")
      }
    } else {
      logger.log(unsafe "New '\(identifier)' (\(privateAddress)) appeared for the first time")
      Self.updatePublicReference(device, privateDevice: privateDevice, identifier: identifier, info: info)
    }

    update?(device)
    storage.deviceAttached(device, forKey: identifier)

    if let info = device as? any TargetInfo {
      delegate?.targetAdded(info, in: self)
    }
  }

  func deviceDisconnected(_ privateDevice: CFTypeRef, identifier: String) {
    unsafe deviceDisconnected(identifier: identifier, address: Unmanaged.passUnretained(privateDevice as AnyObject).toOpaque())
  }

  func deviceDisconnected(identifier: String, address: UnsafeMutableRawPointer) {
    // The private ref may already be dead by the time a disconnect callback fires, so log it by
    // identifier and address only; never dereference it.
    let privateAddress = unsafe address
    logger.log(unsafe "Device Disconnected \(identifier) (\(privateAddress))")
    guard let device = storage.device(forKey: identifier) else {
      logger.log("No Device named \(identifier) from attached devices, nothing to remove")
      return
    }
    logger.log("Removing Device \(identifier) from attached devices")

    storage.deviceDetached(forKey: identifier)

    if let info = device as? any TargetInfo {
      delegate?.targetRemoved(info, in: self)
    }
  }

  var currentDeviceList: [PublicDevice] {
    storage.attached.sorted { $0.key < $1.key }.map(\.value)
  }

  // MARK: - TargetSet

  var allTargetInfos: [any TargetInfo] {
    currentDeviceList.compactMap { $0 as? any TargetInfo }
  }

  func target(withUDID udid: String) -> (any TargetInfo)? {
    allTargetInfos.first { $0.udid == udid }
  }

  var description: String {
    "\(type(of: self)): \(CollectionInformation.oneLineDescription(from: allTargetInfos))"
  }
}

public enum DeviceManagerError: Error, LocalizedError {
  case abstractMethod(name: String)

  public var errorDescription: String? {
    switch self {
    case let .abstractMethod(name):
      return "\(name) is abstract and must be overridden"
    }
  }
}
