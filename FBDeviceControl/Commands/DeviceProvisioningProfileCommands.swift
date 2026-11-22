/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import Foundation
import MobileDeviceAPI

public enum DeviceProvisioningProfileError: Error {
  case copyFailed
  case removeFailed(uuid: String, message: String)
  case constructionFailed(dataDescription: String)
  case installFailed(profileDescription: String, message: String)
  case payloadUnavailable(profileDescription: String)
}

extension DeviceProvisioningProfileError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .copyFailed:
      return "Failed to copy provisioning profiles"
    case let .removeFailed(uuid, message):
      return "Failed to remove profile \(uuid): \(message)"
    case let .constructionFailed(dataDescription):
      return "Could not construct profile from data \(dataDescription)"
    case let .installFailed(profileDescription, message):
      return "Failed to install profile \(profileDescription): \(message)"
    case let .payloadUnavailable(profileDescription):
      return "Failed to get payload of \(profileDescription)"
    }
  }
}

public final class DeviceProvisioningProfileCommands: ProvisioningProfileCommands {
  let device: Device

  public init(device: Device) {
    self.device = device
  }

  // MARK: - ProvisioningProfileCommands

  public func all() async throws -> [[String: Any]] {
    return try await device.withConnectedDevice(purpose: "list_provisioning_profiles") { connectedDevice in
      guard let profiles = connectedDevice.calls.CopyProvisioningProfiles?(connectedDevice.amDeviceRef)?.takeRetainedValue() as? [Any] else {
        throw DeviceProvisioningProfileError.copyFailed
      }
      var allProfiles: [[String: Any]] = []
      for profile in profiles {
        let payloadRef = connectedDevice.calls.ProvisioningProfileCopyPayload?(profile as CFTypeRef)
        var payload = payloadRef?.takeRetainedValue() as? [String: Any]
        if let p = payload {
          payload = CollectionOperations.recursiveFilteredJSONSerializableRepresentation(of: p)
        }
        if let payload {
          allProfiles.append(payload)
        }
      }
      return allProfiles
    }
  }

  public func remove(uuid: String) async throws -> [String: Any] {
    return try await device.withConnectedDevice(purpose: "remove_provisioning_profile") { connectedDevice in
      let status = connectedDevice.calls.RemoveProvisioningProfile?(connectedDevice.amDeviceRef, uuid as CFString) ?? -1
      if status != 0 {
        let errRef = connectedDevice.calls.ProvisioningProfileCopyErrorStringForCode?(status)
        let errorDescription = errRef?.takeRetainedValue() as String? ?? "Unknown error"
        throw DeviceProvisioningProfileError.removeFailed(uuid: uuid, message: errorDescription)
      }
      return [:]
    }
  }

  public func install(_ profileData: Data) async throws -> [String: Any] {
    return try await device.withConnectedDevice(purpose: "install_provisioning_profile") { connectedDevice in
      guard let profileUnmanaged = connectedDevice.calls.ProvisioningProfileCreateWithData?(profileData as CFData) else {
        throw DeviceProvisioningProfileError.constructionFailed(dataDescription: String(describing: profileData))
      }
      let profile = profileUnmanaged.takeRetainedValue()
      let status = connectedDevice.calls.InstallProvisioningProfile?(connectedDevice.amDeviceRef, profile) ?? -1
      if status != 0 {
        let errRef = connectedDevice.calls.ProvisioningProfileCopyErrorStringForCode?(status)
        let errorDescription = errRef?.takeRetainedValue() as String? ?? "Unknown error"
        throw DeviceProvisioningProfileError.installFailed(profileDescription: String(describing: profile), message: errorDescription)
      }
      let payloadRef = connectedDevice.calls.ProvisioningProfileCopyPayload?(profile)
      var payload = payloadRef?.takeRetainedValue() as? [String: Any]
      if let p = payload {
        payload = CollectionOperations.recursiveFilteredJSONSerializableRepresentation(of: p)
      }
      guard let payload else {
        throw DeviceProvisioningProfileError.payloadUnavailable(profileDescription: String(describing: profile))
      }
      return payload
    }
  }
}
