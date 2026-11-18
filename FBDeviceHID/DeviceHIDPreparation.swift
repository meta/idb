/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
internal import FBControlCore
import Foundation

struct DeviceHIDPreparedTap: Sendable {
  let deviceIdentifier: UUID
  let point: CGPoint
  let duration: TimeInterval?
}

enum DeviceHIDPreparation {
  static func prepare(
    udid: String, x: Double, y: Double, duration: TimeInterval?,
    on launcher: any SubprocessLauncher = HostSubprocessLauncher(),
    queryTimeout: TimeInterval = 10,
    temporaryRoot: URL = FileManager.default.temporaryDirectory
  ) async throws -> DeviceHIDPreparedTap {
    let snapshot = try await snapshot(udid: udid, on: launcher, queryTimeout: queryTimeout, temporaryRoot: temporaryRoot)
    let prepared = try decode(details: snapshot.details, displays: snapshot.requiredDisplays(), udid: udid, x: x, y: y, duration: duration)
    try Task.checkCancellation()
    return prepared
  }

  static func prepare(udid: String, sequence: DeviceHIDTouchSequence) async throws -> DeviceHIDPreparedTouch {
    let snapshot = try await snapshot(udid: udid, on: HostSubprocessLauncher(), queryTimeout: 10, temporaryRoot: FileManager.default.temporaryDirectory)
    let prepared = try decodeTouch(details: snapshot.details, displays: snapshot.requiredDisplays(), udid: udid, sequence: sequence)
    try Task.checkCancellation()
    return prepared
  }

  static func prepare(udid: String, button: DeviceHIDButton, duration: TimeInterval?, on launcher: any SubprocessLauncher = HostSubprocessLauncher(), queryTimeout: TimeInterval = 10, temporaryRoot: URL = FileManager.default.temporaryDirectory) async throws -> DeviceHIDPreparedButton {
    let snapshot = try await snapshot(udid: udid, on: launcher, queryTimeout: queryTimeout, temporaryRoot: temporaryRoot, includeDisplays: false)
    let prepared = try decodeButton(details: snapshot.details, udid: udid, button: button, duration: duration)
    try Task.checkCancellation()
    return prepared
  }

  static func decodeButton(details: Data, udid: String, button: DeviceHIDButton, duration: TimeInterval?) throws -> DeviceHIDPreparedButton {
    guard duration.map({ $0.isFinite && $0 >= 0 && $0 < 5 }) ?? true else {
      throw DeviceHIDError.preparationFailed("Button hold must be finite, nonnegative, and less than five seconds")
    }
    let details = try JSONDecoder().decode(Details.self, from: details)
    let identifier = try validate(details: details, udid: udid)
    return DeviceHIDPreparedButton(deviceIdentifier: identifier, button: button, duration: duration)
  }

  private struct Snapshot {
    let details: Data
    let displays: Data?

    func requiredDisplays() throws -> Data {
      guard let displays else { throw DeviceHIDError.preparationFailed("Touch preparation requires display metadata") }
      return displays
    }
  }

  private static func snapshot(udid: String, on launcher: any SubprocessLauncher, queryTimeout: TimeInterval, temporaryRoot: URL, includeDisplays: Bool = true) async throws -> Snapshot {
    try Task.checkCancellation()
    guard queryTimeout.isFinite, queryTimeout >= 0 else {
      throw DeviceHIDError.preparationFailed("Metadata query timeout must be finite and nonnegative")
    }
    let directory = try await fileIO {
      let directory = temporaryRoot.appendingPathComponent("idb-input-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      return directory
    }
    let snapshot: Snapshot
    do {
      async let details = metadata("details", udid: udid, directory: directory, on: launcher, timeout: queryTimeout)
      async let displays: Data? = includeDisplays ? metadata("displays", udid: udid, directory: directory, on: launcher, timeout: queryTimeout) : nil
      snapshot = try await Snapshot(details: details, displays: displays)
    } catch let failure {
      do {
        try await fileIO { try FileManager.default.removeItem(at: directory) }
      } catch let cleanupFailure {
        ControlCoreGlobalConfiguration.defaultLogger.error().log("Could not remove input metadata at \(directory.path) after preparation failed: \(cleanupFailure.localizedDescription)")
      }
      throw failure
    }
    try await fileIO { try FileManager.default.removeItem(at: directory) }
    try Task.checkCancellation()
    return snapshot
  }

  private static func metadata(
    _ operation: String, udid: String, directory: URL,
    on launcher: any SubprocessLauncher, timeout: TimeInterval
  ) async throws -> Data {
    let path = directory.appendingPathComponent(operation).appendingPathExtension("json")
    let command = Subprocess(
      executable: "/usr/bin/xcrun",
      arguments: ["devicectl", "device", "info", operation, "--device", udid, "--json-output", path.path])
    try await run(command, named: "devicectl \(operation)", on: launcher, timeout: timeout)
    return try await readMetadata(path)
  }

  private static func run(_ command: Subprocess, named name: String, on launcher: any SubprocessLauncher, timeout: TimeInterval) async throws {
    let logger = ControlCoreGlobalConfiguration.defaultLogger
    let stderr = AccumulatingBuffer(capacity: Subprocess.errorMessageLength)
    let consumer = CompositeDataConsumer(consumers: [stderr, LoggingDataConsumer(logger: logger)])
    let status = try await command.withRunning(on: launcher, output: .nullDevice, error: .consumer(consumer), gracePeriod: 1) { running in
      try await running.terminationStatus(within: timeout)
    }
    let diagnostic = String(decoding: stderr.data(), as: UTF8.self).trimmingCharacters(in: .newlines)
    guard let status else {
      throw DeviceHIDError.preparationFailed("\(name) timed out; its owned process was terminated. \(diagnostic)")
    }
    guard status == .exited(0) else {
      throw DeviceHIDError.preparationFailed("\(name) failed (\(status)): \(diagnostic)")
    }
  }

  private static func readMetadata(_ path: URL) async throws -> Data {
    try await fileIO {
      let handle = try FileHandle(forReadingFrom: path)
      var data = Data()
      do {
        while data.count <= 1_048_576 {
          let chunk = try handle.read(upToCount: min(65_536, 1_048_577 - data.count)) ?? Data()
          if chunk.isEmpty { break }
          data.append(chunk)
        }
      } catch let failure {
        do {
          try handle.close()
        } catch let closeFailure {
          ControlCoreGlobalConfiguration.defaultLogger.error().log("Could not close input metadata at \(path.path) after reading failed: \(closeFailure.localizedDescription)")
        }
        throw failure
      }
      try handle.close()
      guard data.count <= 1_048_576 else {
        throw DeviceHIDError.preparationFailed("devicectl metadata exceeds the 1 MiB limit")
      }
      return data
    }
  }

  private static func fileIO<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      Thread.detachNewThread {
        do {
          continuation.resume(returning: try operation())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  static func decode(
    details: Data, displays: Data, udid: String, x: Double, y: Double,
    duration: TimeInterval?
  ) throws -> DeviceHIDPreparedTap {
    let geometry = try decodeGeometry(details: details, displays: displays, udid: udid)
    if let duration, !duration.isFinite || duration < 0 {
      throw DeviceHIDError.preparationFailed("Tap duration must be finite and nonnegative")
    }
    return DeviceHIDPreparedTap(deviceIdentifier: geometry.identifier, point: try geometry.normalize(CGPoint(x: x, y: y)), duration: duration)
  }

  static func decodeTouch(details: Data, displays: Data, udid: String, sequence: DeviceHIDTouchSequence) throws -> DeviceHIDPreparedTouch {
    let geometry = try decodeGeometry(details: details, displays: displays, udid: udid)
    let positions = try sequence.positions.map { DeviceHIDPosition(point: try geometry.normalize($0.point), delay: $0.delay) }
    guard let first = positions.first else { throw DeviceHIDError.preparationFailed("A touch sequence must contain a down") }
    return DeviceHIDPreparedTouch(
      start: DeviceHIDPreparedTap(deviceIdentifier: geometry.identifier, point: first.point, duration: first.delay),
      positions: Array(positions.dropFirst()))
  }

  private struct Geometry {
    let identifier: UUID
    let width: Double
    let height: Double
    let scale: Double

    func normalize(_ point: CGPoint) throws -> CGPoint {
      let x = Double(point.x)
      let y = Double(point.y)
      guard x.isFinite, y.isFinite, x >= 0, y >= 0, x * scale < width, y * scale < height else {
        throw DeviceHIDError.preparationFailed("Tap coordinates must be inside the display's point bounds")
      }
      return CGPoint(x: x * scale / width, y: y * scale / height)
    }
  }

  private static func decodeGeometry(details: Data, displays: Data, udid: String) throws -> Geometry {
    let decoder = JSONDecoder()
    let details = try decoder.decode(Details.self, from: details)
    let displays = try decoder.decode(Displays.self, from: displays)
    let identifier = try validate(details: details, udid: udid)
    try displays.info.validate(command: "displays", udid: udid, identifier: identifier)
    let candidates = displays.result.displays
    let primary = candidates.filter(\.primary)
    guard candidates.count <= 64, Set(candidates.map(\.displayId)).count == candidates.count,
      primary.count == 1, let display = primary.first,
      display.type.count == 1, display.type["integrated"]?.isEmpty == true, display.displayId > 0
    else {
      throw DeviceHIDError.preparationFailed("Expected complete, unique display metadata with one primary integrated display")
    }
    guard display.currentOrientation == "rot0", display.nativeOrientation == "rot0",
      displays.result.orientation.currentDeviceNonFlatOrientation == "portrait",
      displays.result.orientation.currentDeviceOrientation == "portrait"
        || displays.result.orientation.currentDeviceOrientation == "faceUp"
    else {
      throw DeviceHIDError.preparationFailed("Physical taps require a portrait display basis")
    }
    guard display.bounds.count == 2, display.bounds.allSatisfy({ $0.count == 2 }),
      display.bounds[0] == [0, 0], display.nativeSize.count == 2
    else {
      throw DeviceHIDError.preparationFailed("Invalid display bounds")
    }
    let width = display.bounds[1][0]
    let height = display.bounds[1][1]
    let scale = display.pointScale
    guard width.isFinite, height.isFinite, scale.isFinite,
      width >= 1, height >= width, width.rounded() == width, height.rounded() == height,
      scale > 0, (width / scale).isFinite, (height / scale).isFinite,
      width / scale >= 1, height / scale >= 1, display.nativeSize == [width, height]
    else {
      throw DeviceHIDError.preparationFailed("Expected matching pixel bounds/native size and a positive point scale")
    }
    return Geometry(identifier: identifier, width: width, height: height, scale: scale)
  }

  private static func validate(details: Details, udid: String) throws -> UUID {
    guard !udid.isEmpty, details.result.properties.hardware.udid == udid else {
      throw DeviceHIDError.preparationFailed("Metadata does not match the selected device UDID")
    }
    let identifier = details.result.identifier
    try details.info.validate(command: "details", udid: udid, identifier: identifier)
    let hardware = details.result.properties.hardware
    guard hardware.reality == "physical", hardware.deviceType == "iPhone", hardware.platform == "iOS" else {
      throw DeviceHIDError.preparationFailed("Input requires metadata for a physical iPhone")
    }
    return identifier
  }

  private struct Info: Decodable {
    let arguments: [String]
    let commandType: String
    let jsonVersion: Int
    let outcome: String
    let version: String

    func validate(command: String, udid: String, identifier: UUID) throws {
      guard jsonVersion == 5, !version.isEmpty, outcome == "success",
        commandType == "devicectl.device.info.\(command)"
      else {
        throw DeviceHIDError.preparationFailed("Expected successful devicectl \(command) JSONv5 with a producer version; observed version=\(version), jsonVersion=\(jsonVersion), outcome=\(outcome), commandType=\(commandType)")
      }
      let selectors = arguments.indices.filter { arguments[$0] == "--device" }
      guard selectors.count == 1, let index = selectors.first, index + 1 < arguments.count,
        !arguments.contains(where: { $0.hasPrefix("--device=") })
      else {
        throw DeviceHIDError.preparationFailed("Ambiguous metadata device selector")
      }
      let selected = arguments[index + 1]
      guard selected == udid || UUID(uuidString: selected) == identifier else {
        throw DeviceHIDError.preparationFailed("Metadata queries selected different devices")
      }
    }
  }

  private struct Details: Decodable {
    let info: Info
    let result: Result
    struct Result: Decodable {
      let identifier: UUID
      let properties: Properties
    }
    struct Properties: Decodable { let hardware: Hardware }
    struct Hardware: Decodable {
      let udid: String
      let reality: String
      let deviceType: String
      let platform: String
    }
  }

  private struct Displays: Decodable {
    let info: Info
    let result: Result
    struct Result: Decodable {
      let displays: [Display]
      let orientation: Orientation
    }
    struct Orientation: Decodable {
      let currentDeviceOrientation: String
      let currentDeviceNonFlatOrientation: String
    }
    struct Display: Decodable {
      let displayId: Int
      let primary: Bool
      let type: [String: [String: String]]
      let bounds: [[Double]]
      let nativeSize: [Double]
      let pointScale: Double
      let currentOrientation: String
      let nativeOrientation: String
    }
  }
}
