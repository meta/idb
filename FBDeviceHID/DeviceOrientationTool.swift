/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

internal import FBControlCore
import Foundation

struct DeviceOrientationTool: Sendable {
  var launcher: any SubprocessLauncher = HostSubprocessLauncher()
  var timeout: TimeInterval = 10
  var temporaryRoot: URL = FileManager.default.temporaryDirectory

  func perform(udid: String, setting orientation: DeviceOrientation?, beforeSet: @Sendable () throws -> Void) async throws -> DeviceOrientation {
    try Task.checkCancellation()
    guard timeout.isFinite, timeout > 0, let commandTimeout = Int(exactly: timeout.rounded(.up)) else {
      throw DeviceHIDError.preparationFailed("Orientation query timeout must be finite, positive and representable in whole seconds")
    }
    let identifier = try await DeviceHIDPreparation.prepareIdentity(udid: udid, on: launcher, queryTimeout: timeout, temporaryRoot: temporaryRoot)
    let directory = try await DeviceHIDPreparation.fileIO {
      let directory = temporaryRoot.appendingPathComponent("idb-orientation-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      return directory
    }
    let result: DeviceOrientation
    do {
      let current = try await run(udid: udid, identifier: identifier, setting: nil, directory: directory, commandTimeout: commandTimeout)
      if let orientation {
        guard !current.deviceIsOrientationLocked else { throw DeviceHIDError.orientationLocked }
        try Task.checkCancellation()
        try beforeSet()
        let receipt = try await run(udid: udid, identifier: identifier, setting: orientation, directory: directory, commandTimeout: commandTimeout)
        guard receipt.deviceOrientation == orientation, receipt.deviceOrientationNonFlat == orientation else {
          throw DeviceHIDError.preparationFailed("Orientation receipt does not match the requested physical orientation")
        }
        result = receipt.deviceOrientation
      } else {
        result = current.deviceOrientation
      }
    } catch let failure {
      do {
        try await remove(directory)
      } catch let cleanupFailure {
        ControlCoreGlobalConfiguration.defaultLogger.error().log("Could not remove orientation metadata at \(directory.path) after orientation failed: \(cleanupFailure.localizedDescription)")
      }
      throw failure
    }
    do {
      try await remove(directory)
    } catch let cleanupFailure {
      ControlCoreGlobalConfiguration.defaultLogger.error().log("Could not remove orientation metadata at \(directory.path): \(cleanupFailure.localizedDescription)")
    }
    try Task.checkCancellation()
    return result
  }

  private func remove(_ directory: URL) async throws {
    try await DeviceHIDPreparation.fileIO { try FileManager.default.removeItem(at: directory) }
  }

  private func run(udid: String, identifier: UUID, setting orientation: DeviceOrientation?, directory: URL, commandTimeout: Int) async throws -> Receipt {
    let operation = orientation == nil ? "get" : "set"
    let path = directory.appendingPathComponent(operation).appendingPathExtension("json")
    var arguments = ["devicectl", "device", "orientation", operation, "--device", udid, "--timeout", String(commandTimeout), "--json-output", path.path]
    if let orientation { arguments.append(orientation.rawValue) }
    let command = Subprocess(executable: "/usr/bin/xcrun", arguments: arguments)
    try await DeviceHIDPreparation.run(command, named: "devicectl orientation \(operation)", on: launcher, timeout: timeout)
    let data = try await DeviceHIDPreparation.readMetadata(path)
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.info.commandType == "devicectl.device.orientation.\(operation)",
      envelope.info.jsonVersion == 5, envelope.info.outcome == "success", !envelope.info.version.isEmpty,
      envelope.info.arguments == arguments, envelope.result.deviceIdentifier == identifier
    else {
      throw DeviceHIDError.preparationFailed("Orientation receipt has an unexpected command, schema, outcome, producer or device identity")
    }
    return envelope.result
  }

  private struct Envelope: Decodable {
    let info: Info
    let result: Receipt
  }

  private struct Info: Decodable {
    let arguments: [String]
    let commandType: String
    let jsonVersion: Int
    let outcome: String
    let version: String
  }

  private struct Receipt: Decodable {
    let deviceIdentifier: UUID
    let deviceIsOrientationLocked: Bool
    let deviceOrientation: DeviceOrientation
    let deviceOrientationNonFlat: DeviceOrientation
  }
}
