/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

// MARK: - TargetScreenInfo

public struct TargetScreenInfo: CustomStringConvertible {

  public let widthPixels: UInt
  public let heightPixels: UInt
  public let scale: Float

  public init(widthPixels: UInt, heightPixels: UInt, scale: Float) {
    self.widthPixels = widthPixels
    self.heightPixels = heightPixels
    self.scale = scale
  }

  public var description: String {
    String(format: "Screen Pixels %lu,%lu | Scale %fX", widthPixels, heightPixels, scale)
  }
}

// MARK: - ProductFamily

/// The product family of a target. Raw values mirror CoreSimulator's `-[SimDeviceType productFamilyID]`
/// and must not be renumbered.
public enum ProductFamily: UInt, Sendable, CaseIterable {
  case unknown = 0
  case iPhone = 1
  case iPad = 2
  case appleTV = 3
  case appleWatch = 4
  case mac = 5
}

// MARK: - DeviceModel

/// An open device model name supplied by the target.
public struct DeviceModel: RawRepresentable, Hashable, Codable, Sendable {

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

// MARK: - DeviceType

public struct DeviceType: CustomStringConvertible, Sendable {

  public let model: DeviceModel
  public let family: ProductFamily

  public static func generic(withName name: String) -> DeviceType {
    DeviceType(model: DeviceModel(rawValue: name), family: .unknown)
  }

  public init(model: DeviceModel, family: ProductFamily) {
    self.model = model
    self.family = family
  }

  public var description: String {
    "Model '\(model.rawValue)'"
  }

}

// MARK: - OSVersionName

/// An open operating system name supplied by the target.
public struct OSVersionName: RawRepresentable, Hashable, Codable, Sendable {

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

// MARK: - OSVersion

public struct OSVersion: CustomStringConvertible, Sendable {

  public let name: OSVersionName
  public let versionString: String

  public static func generic(withName name: String) -> OSVersion {
    OSVersion(name: OSVersionName(rawValue: name))
  }

  public static func operatingSystemVersion(fromName name: String) -> OperatingSystemVersion {
    let components = name.components(separatedBy: CharacterSet.punctuationCharacters)
    var version = OperatingSystemVersion(majorVersion: 0, minorVersion: 0, patchVersion: 0)
    for (index, component) in components.enumerated() {
      let value = Int(component) ?? 0
      switch index {
      case 0:
        version.majorVersion = value
      case 1:
        version.minorVersion = value
      case 2:
        version.patchVersion = value
      default:
        continue
      }
    }
    return version
  }

  public init(name: OSVersionName, versionString: String? = nil) {
    self.name = name
    let derivedVersion = name.rawValue.split(whereSeparator: { $0.isWhitespace }).first(where: { $0.first?.isNumber == true })
    self.versionString = versionString ?? derivedVersion.map(String.init) ?? ""
  }

  // MARK: - Public Computed Properties

  public var version: OperatingSystemVersion {
    OSVersion.operatingSystemVersion(fromName: versionString)
  }

  public func compare(_ other: OSVersion) -> ComparisonResult {
    let left = [version.majorVersion, version.minorVersion, version.patchVersion]
    let right = [other.version.majorVersion, other.version.minorVersion, other.version.patchVersion]
    if left == right {
      return .orderedSame
    }
    return left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
  }

  public var description: String {
    "OS '\(name.rawValue)'"
  }

}

public enum TargetConfiguration {

  // MARK: - Public Methods

  public static func baseArchsToCompatibleArch(_ architectures: [Architecture]) -> Set<Architecture> {
    let mapping: [Architecture: Set<Architecture>] = [
      .arm64eX1: [.arm64eX1, .arm64e, .arm64, .armv7s, .armv7],
      .arm64e: [.arm64e, .arm64, .armv7s, .armv7],
      .arm64: [.arm64, .armv7s, .armv7],
      .armv7s: [.armv7s, .armv7],
      .armv7: [.armv7],
    ]

    var result = Set<Architecture>()
    for arch in architectures {
      if let compatible = mapping[arch] {
        result.formUnion(compatible)
      }
    }
    return result
  }
}
