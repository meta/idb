/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBControlCore
@testable import FBDeviceHID
import Foundation
import Testing

@Suite
struct DeviceHIDPreparationTests {
  @Test(arguments: ["642.15", "651.13.5", "652.0.0"])
  func preparesButtonIdentityWithoutDisplayQuery(version: String) async throws {
    let (details, displays) = try metadata(orientation: "landscapeLeft", version: version)
    try await withTemporaryRoot { root in
      let launcher = MetadataLauncher(result: .success, details: details, displays: displays, includeDisplays: false)
      let prepared = try await DeviceHIDPreparation.prepare(udid: "test-phone", button: .home, duration: 0.15, on: launcher, temporaryRoot: root)
      #expect(prepared.deviceIdentifier.uuidString == "00000000-0000-0000-0000-000000000001")
      #expect(prepared.button == .home)
      #expect(prepared.duration == 0.15)
      let (paths, pids) = await launcher.requests()
      #expect(paths.count == 1)
      try await checkCleanup(root: root, paths: paths, pids: pids)
    }
  }

  @Test func rejectsButtonIdentityAndTimingSkew() throws {
    let (details, _) = try metadata()
    #expect(throws: DeviceHIDError.self) {
      try DeviceHIDPreparation.decodeButton(details: details, udid: "other-phone", button: .home, duration: nil)
    }
    for duration in [-1.0, Double.nan, .infinity, 5] {
      #expect(throws: DeviceHIDError.self) {
        try DeviceHIDPreparation.decodeButton(details: details, udid: "test-phone", button: .home, duration: duration)
      }
    }
    let (missingProducer, _) = try metadata(version: "")
    #expect(throws: DeviceHIDError.self) {
      try DeviceHIDPreparation.decodeButton(details: missingProducer, udid: "test-phone", button: .home, duration: nil)
    }
  }

  @Test func normalizesEveryTouchPositionFromOneSnapshot() throws {
    let (details, displays) = try metadata()
    let sequence = try DeviceHIDTouchSequence([.down(x: 100, y: 200), .delay(0.1), .move(x: 300, y: 400), .up(x: 300, y: 400)])
    let prepared = try DeviceHIDPreparation.decodeTouch(details: details, displays: displays, udid: "test-phone", sequence: sequence)
    #expect(abs(prepared.start.point.x - 100.0 / 393) < 1e-12)
    #expect(abs(prepared.positions[0].point.x - 300.0 / 393) < 1e-12)
    #expect(abs(prepared.positions[0].point.y - 400.0 / 852) < 1e-12)
    let outside = try DeviceHIDTouchSequence([.down(x: 100, y: 200), .move(x: 393, y: 400), .up(x: 393, y: 400)])
    #expect(throws: DeviceHIDError.self) {
      try DeviceHIDPreparation.decodeTouch(details: details, displays: displays, udid: "test-phone", sequence: outside)
    }
  }

  @Test(arguments: ["portrait", "faceUp"])
  func normalizesDisplayPoints(orientation: String) throws {
    let (details, displays) = try metadata(orientation: orientation)
    let prepared = try DeviceHIDPreparation.decode(
      details: details, displays: displays, udid: "test-phone", x: 100, y: 200,
      duration: 0.15)
    #expect(abs(prepared.point.x - 100.0 / 393) < 1e-12)
    #expect(abs(prepared.point.y - 200.0 / 852) < 1e-12)
    #expect(prepared.duration == 0.15)
    #expect(prepared.deviceIdentifier.uuidString == "00000000-0000-0000-0000-000000000001")
  }

  @Test
  func rejectsIdentityAndMetadataSkew() throws {
    let (details, displays) = try metadata()
    #expect(throws: (any Error).self) { try decode(details, displays, udid: "different-phone") }
    for arguments in [["--device", "different-phone"], ["--device", "test-phone", "--device", "test-phone"], ["--device=test-phone"]] {
      let (_, mismatched) = try metadata(arguments: arguments)
      #expect(throws: (any Error).self) { try decode(details, mismatched) }
    }
    for (version, jsonVersion, outcome) in [("", 5, "success"), ("652.0.0", 4, "success"), ("652.0.0", 6, "success"), ("652.0.0", 5, "failure")] {
      let (wrongDetails, wrongDisplays) = try metadata(version: version, jsonVersion: jsonVersion, outcome: outcome)
      #expect(throws: (any Error).self) { try decode(wrongDetails, displays) }
      #expect(throws: (any Error).self) { try decode(details, wrongDisplays) }
    }
  }

  @Test(arguments: ["642.15", "651.13.5", "651.13.6", "652.0.0", "700.0.0"])
  func acceptsSchemaCompatibleProducerVersions(version: String) throws {
    let (details, displays) = try metadata(version: version)
    let (otherDetails, otherDisplays) = try metadata(version: "701.0.0")
    let preparedDetails = try decode(details, otherDisplays)
    let preparedDisplays = try decode(otherDetails, displays)
    #expect(preparedDetails.deviceIdentifier == preparedDisplays.deviceIdentifier)
    #expect(abs(preparedDetails.point.x - 100.0 / 393) < 1e-12)
    #expect(abs(preparedDisplays.point.y - 200.0 / 852) < 1e-12)
  }

  @Test
  func rejectsMalformedMetadataEnvelopes() throws {
    let (details, displays) = try metadata(version: "652.0.0")
    for (key, value) in [
      ("version", nil), ("version", NSNull()), ("version", 652),
      ("commandType", "devicectl.device.info.other"), ("jsonVersion", "5"),
    ] as [(String, Any?)] {
      let wrongDetails = try replacingInfo(details, key: key, value: value)
      let wrongDisplays = try replacingInfo(displays, key: key, value: value)
      #expect(throws: (any Error).self) { try decode(wrongDetails, displays) }
      #expect(throws: (any Error).self) { try decode(details, wrongDisplays) }
    }
  }

  @Test
  func rejectsAmbiguousDisplaysAndUnsupportedGeometry() throws {
    for (count, primaryCount, width, height, scale) in [
      (0, 0, 1179.0, 2556.0, 3.0), (2, 2, 1179, 2556, 3),
      (65, 1, 1179, 2556, 3), (1, 1, 0, 2556, 3),
      (1, 1, 2556, 1179, 3), (1, 1, 1179.5, 2556, 3),
      (1, 1, 1179, 2556, 0), (1, 1, 1179, 2556, -1),
    ] {
      let (details, displays) = try metadata(count: count, primaryCount: primaryCount, width: width, height: height, scale: scale)
      #expect(throws: (any Error).self) { try decode(details, displays) }
    }
    let (details, duplicates) = try metadata(count: 2, duplicateIDs: true)
    #expect(throws: (any Error).self) { try decode(details, duplicates) }
  }

  @Test(arguments: ["unknown", "faceDown", "landscapeLeft", "portraitUpsideDown"])
  func rejectsUnverifiedOrientation(orientation: String) throws {
    let (details, displays) = try metadata(orientation: orientation)
    #expect(throws: (any Error).self) { try decode(details, displays) }
  }

  @Test
  func rejectsOutsidePointsAndInvalidDurations() throws {
    let (details, displays) = try metadata()
    for (x, y) in [(-1.0, 0.0), (393, 0), (0, 852), (.nan, 0), (0, .infinity)] {
      #expect(throws: (any Error).self) { try decode(details, displays, x: x, y: y) }
    }
    for duration in [-1.0, Double.nan, .infinity] {
      #expect(throws: (any Error).self) { try decode(details, displays, duration: duration) }
    }
    let nilHold = try decode(details, displays, duration: nil)
    let zeroHold = try decode(details, displays, duration: 0)
    #expect(nilHold.duration == nil)
    #expect(zeroHold.duration == 0)
  }

  @Test(arguments: QueryResult.allCases)
  func preparesUsingOwnedProcesses(result: QueryResult) async throws {
    let (details, displays) = try metadata()
    try await withTemporaryRoot { root in
      let launcher = MetadataLauncher(result: result, details: details, displays: displays)
      do {
        let prepared = try await DeviceHIDPreparation.prepare(
          udid: "test-phone", x: 100, y: 200, duration: 0.15,
          on: launcher, queryTimeout: result == .timeout ? 0 : 10, temporaryRoot: root)
        #expect(result == .success)
        #expect(abs(prepared.point.x - 100.0 / 393) < 1e-12)
        #expect(abs(prepared.point.y - 200.0 / 852) < 1e-12)
      } catch {
        switch result {
        case .success:
          throw error
        case .missing, .missingAfterDirectoryRemoval:
          #expect((error as NSError).domain == NSCocoaErrorDomain)
          #expect((error as NSError).code == NSFileNoSuchFileError)
        case .cancelledAfterDirectoryRemoval:
          #expect(error is CancellationError)
        case .malformed:
          #expect(error is DecodingError)
        case .oversized:
          #expect(error.localizedDescription.contains("exceeds the 1 MiB limit"))
        case .nonzero:
          #expect(error.localizedDescription.contains("devicectl details failed"))
          #expect(error.localizedDescription.hasSuffix("diagnostic-tail"))
          #expect(!error.localizedDescription.contains("discarded-prefix"))
          #expect(error.localizedDescription.utf8.count < Subprocess.errorMessageLength + 150)
        case .timeout:
          #expect(error.localizedDescription.contains("timed out"))
        }
      }
      let (paths, pids) = await launcher.requests()
      #expect(paths.count == 2)
      try await checkCleanup(root: root, paths: paths, pids: pids)
    }
  }

  @Test
  func metadataQueriesOverlapBeforeEitherCanComplete() async throws {
    let (details, displays) = try metadata()
    try await withTemporaryRoot { root in
      let launcher = MetadataLauncher(result: .success, details: details, displays: displays, controlled: true)
      async let preparation = DeviceHIDPreparation.prepare(udid: "test-phone", x: 100, y: 200, duration: nil, on: launcher, temporaryRoot: root)
      try await launcher.events.waitFor("details")
      try await launcher.events.waitFor("displays")
      let (_, running) = await launcher.requests()
      #expect(running.count == 2)
      for pid in running { #expect(kill(pid, 0) == 0) }
      try await launcher.release("details")
      try await launcher.release("displays")
      let prepared = try await preparation
      #expect(abs(prepared.point.x - 100.0 / 393) < 1e-12)
      let (paths, pids) = await launcher.requests()
      try await checkCleanup(root: root, paths: paths, pids: pids)
    }
  }

  @Test
  func metadataFailureReapsBlockedSiblingBeforeRemovingDirectory() async throws {
    let (details, displays) = try metadata()
    try await withTemporaryRoot { root in
      let launcher = MetadataLauncher(result: .success, details: details, displays: displays, controlled: true, failingOperation: "details")
      async let preparation = DeviceHIDPreparation.prepare(udid: "test-phone", x: 100, y: 200, duration: nil, on: launcher, temporaryRoot: root)
      try await launcher.events.waitFor("details")
      try await launcher.events.waitFor("displays")
      try await launcher.release("details")
      do {
        _ = try await preparation
        Issue.record("Failed metadata query was accepted")
      } catch DeviceHIDError.preparationFailed(let message) {
        #expect(message.contains("devicectl details failed"))
        #expect(message.hasSuffix("diagnostic-tail"))
      }
      let (paths, pids) = await launcher.requests()
      #expect(pids.count == 2)
      try await checkCleanup(root: root, paths: paths, pids: pids)
    }
  }

  @Test
  func cancellationReapsBothOwnedProcessesBeforeCleanup() async throws {
    let (details, displays) = try metadata()
    try await withTemporaryRoot { root in
      let launcher = MetadataLauncher(result: .success, details: details, displays: displays, controlled: true)
      let task = Task {
        try await DeviceHIDPreparation.prepare(
          udid: "test-phone", x: 100, y: 200, duration: nil,
          on: launcher, temporaryRoot: root)
      }
      do {
        try await launcher.events.waitFor("details")
        try await launcher.events.waitFor("displays")
      } catch {
        task.cancel()
        _ = await task.result
        throw error
      }
      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
      let (paths, pids) = await launcher.requests()
      #expect(pids.count == 2)
      #expect(paths.count == 2)
      try await checkCleanup(root: root, paths: paths, pids: pids)
    }
  }

  @Test
  func cancellationBeforePreparationDoesNotLaunch() async throws {
    let (details, displays) = try metadata()
    try await withTemporaryRoot { root in
      let launcher = MetadataLauncher(result: .success, details: details, displays: displays)
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await DeviceHIDPreparation.prepare(
          udid: "test-phone", x: 100, y: 200, duration: nil,
          on: launcher, temporaryRoot: root)
      }
      await #expect(throws: CancellationError.self) { try await task.value }
      let (paths, pids) = await launcher.requests()
      #expect(paths.isEmpty)
      #expect(pids.isEmpty)
      try await checkCleanup(root: root, paths: paths, pids: pids)
    }
  }

  enum QueryResult: CaseIterable, Sendable {
    case success, missing, missingAfterDirectoryRemoval, cancelledAfterDirectoryRemoval, malformed, oversized, nonzero, timeout
  }

  private actor MetadataLauncher: SubprocessLauncher {
    nonisolated let supportsStandardInput = true
    nonisolated let events = DeviceHIDTestRecorder()
    private let result: QueryResult
    private let details: Data
    private let displays: Data
    private let controlled: Bool
    private let failingOperation: String?
    private let includeDisplays: Bool
    private var paths: [URL] = []
    private var pids: [pid_t] = []

    init(result: QueryResult, details: Data, displays: Data, controlled: Bool = false, failingOperation: String? = nil, includeDisplays: Bool = true) {
      self.result = result
      self.details = details
      self.displays = displays
      self.controlled = controlled
      self.failingOperation = failingOperation
      self.includeDisplays = includeDisplays
    }

    func requests() -> ([URL], [pid_t]) { (paths, pids) }

    func release(_ operation: String) async throws {
      let path = try #require(paths.first { $0.deletingPathExtension().lastPathComponent == operation })
      try await DeviceHIDPreparationTests().fileIO {
        let handle = try FileHandle(forWritingTo: path.appendingPathExtension("fifo"))
        try handle.write(contentsOf: Data("continue\n".utf8))
        try handle.close()
      }
    }

    func spawn(
      _ subprocess: Subprocess, standardInput: Int32?, standardOutput: Int32?,
      standardError: Int32?, logger: (any ControlCoreLogger)?
    ) async throws -> LaunchedProcess {
      #expect(subprocess.executable == "/usr/bin/xcrun")
      #expect(Array(subprocess.arguments.prefix(3)) == ["devicectl", "device", "info"])
      try #require(subprocess.arguments.count == 8)
      let operation = subprocess.arguments[3]
      let outputIndex = try #require(subprocess.arguments.firstIndex(of: "--json-output"))
      try #require(outputIndex + 1 < subprocess.arguments.count)
      let path = URL(fileURLWithPath: subprocess.arguments[outputIndex + 1])
      try await DeviceHIDPreparationTests().fileIO {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
      }
      paths.append(path)
      events.record("requested-\(operation)")
      if includeDisplays {
        let sibling = operation == "details" ? "displays" : "details"
        try await events.waitFor("requested-\(sibling)")
      }
      let command: Subprocess
      switch result {
      case .success:
        let data = operation == "details" ? details : displays
        if controlled {
          let fifo = path.appendingPathExtension("fifo")
          try await DeviceHIDPreparationTests().fileIO {
            guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.EIO) }
          }
          command = Subprocess(
            executable: "/bin/sh",
            arguments: [
              "-c", "IFS= read -r gate < \"$1\"; if [ \"$4\" = fail ]; then printf diagnostic-tail >&2; exit 7; fi; printf '%s' \"$2\" > \"$3\"",
              "metadata-fixture", fifo.path, String(decoding: data, as: UTF8.self), path.path, operation == failingOperation ? "fail" : "success",
            ])
        } else {
          command = Subprocess(executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$1\" > \"$2\"", "metadata-fixture", String(decoding: data, as: UTF8.self), path.path])
        }
      case .missing:
        command = Subprocess(executable: "/usr/bin/true")
      case .missingAfterDirectoryRemoval:
        command =
          operation == "details"
          ? Subprocess(executable: "/bin/rmdir", arguments: [path.deletingLastPathComponent().path])
          : Subprocess(executable: "/usr/bin/true")
      case .cancelledAfterDirectoryRemoval:
        if operation == "details" {
          try await DeviceHIDPreparationTests().fileIO {
            try FileManager.default.removeItem(at: path.deletingLastPathComponent())
          }
          events.record("directoryRemoved")
        } else {
          try await events.waitFor("directoryRemoved")
        }
        throw CancellationError()
      case .malformed:
        command = Subprocess(executable: "/bin/sh", arguments: ["-c", "printf 'not json' > \"$1\"", "metadata-fixture", path.path])
      case .oversized:
        command = Subprocess(executable: "/bin/sh", arguments: ["-c", "printf '%1048577s' ' ' > \"$1\"", "metadata-fixture", path.path])
      case .nonzero:
        command = Subprocess(executable: "/bin/sh", arguments: ["-c", "printf 'discarded-prefix%0512d\\377diagnostic-tail' 0 >&2; exit 7"])
      case .timeout:
        let fifo = path.appendingPathExtension("fifo")
        try await DeviceHIDPreparationTests().fileIO {
          guard mkfifo(fifo.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
        }
        command = Subprocess(executable: "/bin/cat", arguments: [fifo.path])
      }
      let process = try await HostSubprocessLauncher().spawn(
        command, standardInput: standardInput, standardOutput: standardOutput,
        standardError: standardError, logger: logger)
      pids.append(process.processIdentifier)
      events.record(operation)
      return process
    }
  }

  private func withTemporaryRoot(_ body: @Sendable (URL) async throws -> Void) async throws {
    let root = try await fileIO {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      try Data("unrelated".utf8).write(to: root.appendingPathComponent("sentinel"))
      return root
    }
    let result: Result<Void, any Error>
    do {
      try await body(root)
      result = .success(())
    } catch {
      result = .failure(error)
    }
    try await fileIO { try FileManager.default.removeItem(at: root) }
    try result.get()
  }

  private func checkCleanup(root: URL, paths: [URL], pids: [pid_t]) async throws {
    try await fileIO {
      let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
      let sentinel = try Data(contentsOf: root.appendingPathComponent("sentinel"))
      #expect(entries == ["sentinel"])
      #expect(sentinel == Data("unrelated".utf8))
      for path in paths {
        #expect(!FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
      }
      for pid in pids {
        let status = kill(pid, 0)
        let code = errno
        #expect(status == -1)
        #expect(code == ESRCH)
      }
    }
  }

  private func fileIO<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      Thread.detachNewThread { continuation.resume(with: Result(catching: body)) }
    }
  }

  private func decode(_ details: Data, _ displays: Data, udid: String = "test-phone", x: Double = 100, y: Double = 200, duration: Double? = 0.15) throws -> DeviceHIDPreparedTap {
    try DeviceHIDPreparation.decode(details: details, displays: displays, udid: udid, x: x, y: y, duration: duration)
  }

  private func replacingInfo(_ data: Data, key: String, value: Any?) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var info = try #require(object["info"] as? [String: Any])
    info[key] = value
    object["info"] = info
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func metadata(
    orientation: String = "portrait", arguments: [String] = ["--device", "test-phone"],
    version: String = "651.13.5", jsonVersion: Int = 5, outcome: String = "success",
    count: Int = 1, primaryCount: Int = 1, width: Double = 1179, height: Double = 2556,
    scale: Double = 3, duplicateIDs: Bool = false
  ) throws -> (Data, Data) {
    func info(_ operation: String) -> [String: Any] {
      ["arguments": arguments, "commandType": "devicectl.device.info.\(operation)", "jsonVersion": jsonVersion, "outcome": outcome, "version": version]
    }
    let details: [String: Any] = [
      "info": info("details"),
      "result": ["identifier": "00000000-0000-0000-0000-000000000001", "properties": ["hardware": ["udid": "test-phone", "reality": "physical", "deviceType": "iPhone", "platform": "iOS"]]],
    ]
    let candidates: [[String: Any]] = (0..<count).map { index in
      [
        "displayId": duplicateIDs ? 1 : index + 1, "primary": index < primaryCount,
        "type": ["integrated": [String: String]()], "bounds": [[0, 0], [width, height]],
        "nativeSize": [width, height], "pointScale": scale, "currentOrientation": "rot0", "nativeOrientation": "rot0",
      ]
    }
    let displays: [String: Any] = [
      "info": info("displays"),
      "result": ["displays": candidates, "orientation": ["currentDeviceOrientation": orientation, "currentDeviceNonFlatOrientation": "portrait"]],
    ]
    return (try JSONSerialization.data(withJSONObject: details), try JSONSerialization.data(withJSONObject: displays))
  }
}
