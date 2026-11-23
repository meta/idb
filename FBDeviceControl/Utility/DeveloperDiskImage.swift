/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

private let ExtraDeviceSupportDirEnv = "IDB_EXTRA_DEVICE_SUPPORT_DIR"

private func scoreVersions(_ current: OperatingSystemVersion, _ target: OperatingSystemVersion) -> Int {
  let major = abs((current.majorVersion - target.majorVersion) * 10)
  let minor = abs(current.minorVersion - target.minorVersion)
  return major + minor
}

enum DeveloperDiskImageError: Error {
  case symbolsNotFound(buildVersion: String, searched: [String])
  case noImagesProvided
  case noSuitableImage(bestDescription: String, majorVersion: Int, minorVersion: Int)
  case imageMissing(path: String)
  case signatureLoadFailed(path: String)
}

extension DeveloperDiskImageError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .symbolsNotFound(buildVersion, searched):
      return "Could not find the Symbols for \(buildVersion) in any of \(CollectionInformation.oneLineDescription(from: searched))"
    case .noImagesProvided:
      return "No disk images provided"
    case let .noSuitableImage(bestDescription, majorVersion, minorVersion):
      return "The best match \(bestDescription) is not suitable for \(majorVersion).\(minorVersion)"
    case let .imageMissing(path):
      return "Disk image does not exist at expected path \(path)"
    case let .signatureLoadFailed(path):
      return "Failed to load signature at \(path)"
    }
  }
}

/// The developer disk images available on this host.
public protocol DeveloperDiskImageProviding {
  var availableDiskImages: [DeveloperDiskImage] { get }
}

/// The default: the images in the device support directories of the selected Xcode, plus any in
/// `IDB_EXTRA_DEVICE_SUPPORT_DIR`.
public struct InstalledDeveloperDiskImages: DeveloperDiskImageProviding {
  public init() {}

  /// Scanned once per process. The directories do not change under a running companion, and the
  /// scan stats every candidate directory and reads a signature from each.
  public var availableDiskImages: [DeveloperDiskImage] {
    Self.scanned
  }

  private static let scanned: [DeveloperDiskImage] = {
    let xcodeVersion = XcodeConfiguration.xcodeVersion
    let logger = ControlCoreGlobalConfiguration.defaultLogger
    let searchPath = (XcodeConfiguration.developerDirectory as NSString).appendingPathComponent("Platforms/iPhoneOS.platform/DeviceSupport")
    var found = InstalledDeveloperDiskImages.images(inDirectory: searchPath, xcodeVersion: xcodeVersion, logger: logger)
    if let extraPath = ProcessInfo.processInfo.environment[ExtraDeviceSupportDirEnv] {
      found += InstalledDeveloperDiskImages.images(inDirectory: extraPath, xcodeVersion: xcodeVersion, logger: logger)
    }
    return found
  }()

  private static func images(
    inDirectory searchPath: String,
    xcodeVersion: OperatingSystemVersion,
    logger: any ControlCoreLogger
  ) -> [DeveloperDiskImage] {
    var images: [DeveloperDiskImage] = []
    logger.log("Attempting to find Disk Images at path \(searchPath)")
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: searchPath)) ?? []
    for fileName in contents {
      let resolvedPath = (searchPath as NSString).appendingPathComponent(fileName)
      do {
        images.append(try diskImage(atPath: resolvedPath, xcodeVersion: xcodeVersion))
      } catch {
        logger.log("\(error) does not contain a valid disk image")
      }
    }
    return images.sorted { $0.compare($1) == .orderedAscending }
  }

  private static func diskImage(atPath path: String, xcodeVersion: OperatingSystemVersion) throws -> DeveloperDiskImage {
    let diskImagePath = (path as NSString).appendingPathComponent("DeveloperDiskImage.dmg")
    if !FileManager.default.fileExists(atPath: diskImagePath) {
      throw DeveloperDiskImageError.imageMissing(path: diskImagePath)
    }
    let signaturePath = diskImagePath + ".signature"
    guard let signature = try? Data(contentsOf: URL(fileURLWithPath: signaturePath)) else {
      throw DeveloperDiskImageError.signatureLoadFailed(path: signaturePath)
    }
    let version = OSVersion.operatingSystemVersion(fromName: (path as NSString).lastPathComponent)
    return DeveloperDiskImage(diskImagePath: diskImagePath, signature: signature, version: version, xcodeVersion: xcodeVersion)
  }
}

public struct DeveloperDiskImage: Sendable, CustomStringConvertible {

  // MARK: - Properties

  public let diskImagePath: String
  public let signature: Data
  public let version: OperatingSystemVersion
  public let xcodeVersion: OperatingSystemVersion

  public init(diskImagePath: String, signature: Data, version: OperatingSystemVersion, xcodeVersion: OperatingSystemVersion) {
    self.diskImagePath = diskImagePath
    self.signature = signature
    self.version = version
    self.xcodeVersion = xcodeVersion
  }

  // MARK: - Initializers

  public static func unknownDiskImage(withSignature signature: Data) -> DeveloperDiskImage {
    let unknownVersion = OperatingSystemVersion(majorVersion: 0, minorVersion: 0, patchVersion: 0)
    return DeveloperDiskImage(diskImagePath: "unknown.dmg", signature: signature, version: unknownVersion, xcodeVersion: unknownVersion)
  }

  // MARK: - Public

  public static func developerSymbolsPath(forBuildVersion buildVersion: String, logger: any ControlCoreLogger) throws -> String {
    let searchPaths = [
      (NSHomeDirectory() as NSString).appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport"),
      (XcodeConfiguration.developerDirectory as NSString).appendingPathComponent("Platforms/iPhoneOS.platform/DeviceSupport"),
    ]
    logger.log("Attempting to find Symbols directory by build version \(buildVersion)")
    var paths: [String] = []
    for searchPath in searchPaths {
      guard let supportPaths = try? FileManager.default.contentsOfDirectory(atPath: searchPath) else {
        continue
      }
      for supportName in supportPaths {
        let supportPath = (searchPath as NSString).appendingPathComponent(supportName)
        var isDirectory: ObjCBool = false
        if unsafe !FileManager.default.fileExists(atPath: supportPath, isDirectory: &isDirectory) {
          continue
        }
        if !isDirectory.boolValue {
          continue
        }
        let symbolsPath = (supportPath as NSString).appendingPathComponent("Symbols")
        if unsafe !FileManager.default.fileExists(atPath: symbolsPath, isDirectory: &isDirectory) {
          continue
        }
        if !isDirectory.boolValue {
          continue
        }
        paths.append(symbolsPath)
      }
    }
    for path in paths {
      if path.contains(buildVersion) {
        return path
      }
    }
    throw DeveloperDiskImageError.symbolsNotFound(buildVersion: buildVersion, searched: paths)
  }

  public static func bestImage(forImages images: [DeveloperDiskImage], targetVersion: OperatingSystemVersion, logger: (any ControlCoreLogger)?) throws -> DeveloperDiskImage {
    if images.isEmpty {
      throw DeveloperDiskImageError.noImagesProvided
    }

    let sorted = images.sorted { left, right in
      let leftDelta = scoreVersions(left.version, targetVersion)
      let rightDelta = scoreVersions(right.version, targetVersion)
      return leftDelta < rightDelta
    }

    let best = sorted[0]
    let bestVersion = best.version
    if bestVersion.majorVersion == targetVersion.majorVersion && bestVersion.minorVersion == targetVersion.minorVersion {
      logger?.log("Found the best match for \(targetVersion.majorVersion).\(targetVersion.minorVersion) at \(best)")
      return best
    }
    if bestVersion.majorVersion == targetVersion.majorVersion {
      logger?.log("Found the closest match for \(targetVersion.majorVersion).\(targetVersion.minorVersion) at \(best)")
      return best
    }
    throw DeveloperDiskImageError.noSuitableImage(bestDescription: String(describing: best), majorVersion: targetVersion.majorVersion, minorVersion: targetVersion.minorVersion)
  }

  public var description: String {
    "\(diskImagePath): \(version.majorVersion).\(version.minorVersion)"
  }

  public func compare(_ other: DeveloperDiskImage) -> ComparisonResult {
    let lhs = (version.majorVersion, version.minorVersion, version.patchVersion)
    let rhs = (other.version.majorVersion, other.version.minorVersion, other.version.patchVersion)
    if lhs == rhs { return .orderedSame }
    return lhs < rhs ? .orderedAscending : .orderedDescending
  }

}
