/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

private let OrderedIdentifiers = "OrderedIdentifiers"
private let ProfileMetadata = "ProfileMetadata"
private let PayloadUUID = "PayloadUUID"
private let PayloadVersion = "PayloadVersion"

public enum ManagedConfigError: Error {
  case invalidWallpaperName(name: String)
  case orderedIdentifiersMissing(key: String)
  case orderedIdentifiersNotStrings(key: String)
  case profileNotInstalled(profileName: String, identifiers: [String])
  case removeFailed(response: String)
}

extension ManagedConfigError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .invalidWallpaperName(name):
      return "\(name) is not a valid Wallpaper Name"
    case let .orderedIdentifiersMissing(key):
      return "\(key) is not present in response"
    case let .orderedIdentifiersNotStrings(key):
      return "\(key) is not an Array<String>"
    case let .profileNotInstalled(profileName, identifiers):
      return "\(profileName) is not one of \(CollectionInformation.oneLineDescription(from: identifiers))"
    case let .removeFailed(response):
      return "Status is Error: \(response)"
    }
  }
}

class ManagedConfigClient {
  private let connection: LockdownServiceConnection
  private let queue: DispatchQueue
  private let logger: any ControlCoreLogger

  // MARK: - Constants

  static let serviceName: String = "com.apple.mobile.MCInstall"

  private static let wallpaperWhereForName: [String: NSNumber] = [
    WallpaperName.homescreen.rawValue: 0,
    WallpaperName.lockscreen.rawValue: 1,
  ]

  // MARK: - Initializers

  convenience init(connection: LockdownServiceConnection, logger: any ControlCoreLogger) {
    let queue = DispatchQueue(label: "com.facebook.FBDeviceControl.managed_config")
    self.init(connection: connection, queue: queue, logger: logger)
  }

  init(
    connection: LockdownServiceConnection,
    queue: DispatchQueue,
    logger: any ControlCoreLogger
  ) {
    self.connection = connection
    self.queue = queue
    self.logger = logger
  }

  // MARK: - Async

  func cloudConfiguration() async throws -> [String: Any] {
    try await queue.perform { [connection] in
      let result = try connection.sendAndReceiveMessage(["RequestType": "GetCloudConfiguration"])
      guard let resultDict = result as? [String: Any] else {
        return [:]
      }
      return CollectionOperations.recursiveFilteredJSONSerializableRepresentation(of: resultDict) as [String: Any]
    }
  }

  func changeWallpaper(name: String, data: Data) async throws {
    guard let whereNumber = ManagedConfigClient.wallpaperWhereForName[name] else {
      throw ManagedConfigError.invalidWallpaperName(name: name)
    }
    try await changeSettings(settings: [["Item": "Wallpaper", "Image": data, "Where": whereNumber]])
  }

  func profileList() async throws -> [String] {
    return try await queue.perform { [connection] in
      let result = try connection.sendAndReceiveMessage(["RequestType": "GetProfileList"])
      guard let resultDict = result as? [String: Any] else {
        return []
      }
      guard let orderedIdentifiers = resultDict[OrderedIdentifiers] as? [Any] else {
        throw ManagedConfigError.orderedIdentifiersMissing(key: OrderedIdentifiers)
      }
      guard let identifiers = orderedIdentifiers as? [String] else {
        throw ManagedConfigError.orderedIdentifiersNotStrings(key: OrderedIdentifiers)
      }
      return identifiers
    }
  }

  func installProfile(_ payload: Data) async throws -> [String: Any] {
    return try await queue.perform { [connection, payload] in
      let result = try connection.sendAndReceiveMessage(["RequestType": "InstallProfile", "Payload": payload])
      guard let resultDict = result as? [String: Any] else {
        return [:]
      }
      let filtered = CollectionOperations.recursiveFilteredJSONSerializableRepresentation(of: resultDict) as [String: Any]
      return filtered
    }
  }

  func removeProfile(_ profileName: String) async throws {
    try await queue.perform { [connection] in
      let result = try connection.sendAndReceiveMessage(["RequestType": "GetProfileList"])
      guard let resultDict = result as? [String: Any] else {
        return
      }
      guard let metadata = resultDict[ProfileMetadata] as? [String: Any],
        let profileMetadata = metadata[profileName] as? [String: Any]
      else {
        let identifiers = (resultDict[OrderedIdentifiers] as? [Any] ?? []).map { String(describing: $0) }
        throw ManagedConfigError.profileNotInstalled(profileName: profileName, identifiers: identifiers)
      }
      let profileIdentifier: [String: Any] = [
        "PayloadType": "Configuration",
        "PayloadIdentifier": profileName,
        PayloadUUID: profileMetadata[PayloadUUID] as Any,
        PayloadVersion: profileMetadata[PayloadVersion] as Any,
      ]
      let payload = try PropertyListSerialization.data(fromPropertyList: profileIdentifier, format: .binary, options: 0)
      let removeResult = try connection.sendAndReceiveMessage(["RequestType": "RemoveProfile", "ProfileIdentifier": payload])
      guard let removeResultDict = removeResult as? [String: Any] else {
        return
      }
      if (removeResultDict["Status"] as? String) == "Error" {
        throw ManagedConfigError.removeFailed(response: String(describing: removeResultDict))
      }
    }
  }

  // MARK: - Private Methods

  private func changeSettings(settings: [[String: Any]]) async throws {
    try await queue.perform { [connection, settings] in
      _ = try connection.sendAndReceiveMessage(["RequestType": "Settings", "Settings": settings])
    }
  }
}
