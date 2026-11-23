/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation

public struct SimulatorConfiguration: Equatable, Hashable, CustomStringConvertible, Sendable {

  public let device: DeviceType
  public let os: OSVersion
  public let deviceTypeIdentifier: String?
  public let runtimeIdentifier: String?
  public let runtimeBuildVersion: String?

  public init(
    device: DeviceType, os: OSVersion, deviceTypeIdentifier: String? = nil,
    runtimeIdentifier: String? = nil, runtimeBuildVersion: String? = nil
  ) {
    self.device = device
    self.os = os
    self.deviceTypeIdentifier = deviceTypeIdentifier
    self.runtimeIdentifier = runtimeIdentifier
    self.runtimeBuildVersion = runtimeBuildVersion
  }

  // MARK: - Equatable, Hashable

  public static func == (lhs: SimulatorConfiguration, rhs: SimulatorConfiguration) -> Bool {
    lhs.deviceIdentity == rhs.deviceIdentity && lhs.runtimeIdentity == rhs.runtimeIdentity
      && lhs.runtimeBuildVersion == rhs.runtimeBuildVersion
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(deviceIdentity)
    hasher.combine(runtimeIdentity)
    hasher.combine(runtimeBuildVersion)
  }

  private var deviceIdentity: String { deviceTypeIdentifier ?? device.model.rawValue }
  private enum RuntimeIdentity: Hashable {
    case identifier(String)
    case metadata(name: String, version: String)
  }

  private var runtimeIdentity: RuntimeIdentity {
    if let runtimeIdentifier {
      return .identifier(runtimeIdentifier)
    }
    return .metadata(name: os.name.rawValue, version: os.versionString)
  }

  public var description: String {
    "Device '\(device.model.rawValue)' | OS Version '\(os.name.rawValue)'"
  }
}

extension SimulatorConfiguration {

  public init(simDevice: SimDevice) {
    self.init(deviceType: simDevice.deviceType, runtime: simDevice.runtime)
  }

  init(deviceType: SimDeviceType?, runtime: SimRuntime?) {
    let family: ProductFamily
    switch deviceType?.productFamilyID {
    case 1: family = .iPhone
    case 2: family = .iPad
    case 3: family = .appleTV
    case 4: family = .appleWatch
    case 5: family = .mac
    default: family = .unknown
    }
    self.init(
      device: DeviceType(model: DeviceModel(rawValue: deviceType?.name ?? "unknown"), family: family),
      os: OSVersion(name: OSVersionName(rawValue: runtime?.name ?? "unknown"), versionString: runtime?.versionString ?? ""),
      deviceTypeIdentifier: deviceType?.identifier,
      runtimeIdentifier: runtime?.identifier,
      runtimeBuildVersion: runtime?.buildVersionString)
  }

  public static func availableConfigurations() throws -> [SimulatorConfiguration] {
    let snapshot = try CoreSimulatorRuntimeIndex()
    return snapshot.index.availablePairs.map {
      SimulatorConfiguration(deviceType: snapshot.deviceTypes[$0.device], runtime: snapshot.runtimes[$0.runtime])
    }
  }
}
