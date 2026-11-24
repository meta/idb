/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBDeviceControl
import Foundation
import Testing

/// Capture identity without a connected device or an AVFoundation session.
@Suite
struct DeviceVideoTests {
  private struct Candidate: Equatable {
    let uniqueID: String
    let name: String
  }

  private let phoneA = "phone-a"
  private let screen = Candidate(uniqueID: "independent-screen-id", name: "iPhone")

  private func device(
    identifier: String = "core-device-a", udid: String = "phone-a", name: String = "iPhone", transport: String? = "wired"
  ) -> CoreDeviceEntry {
    CoreDeviceEntry(
      identifier: identifier, deviceProperties: .init(name: name), hardwareProperties: .init(udid: udid),
      connectionProperties: transport.map { .init(transportType: $0) })
  }

  private func select(_ candidates: [Candidate], coreDevices: [CoreDeviceEntry]) -> Candidate? {
    DeviceVideo.CaptureIdentity(udid: phoneA, coreDevices: coreDevices)
      .match(among: candidates, uniqueID: \.uniqueID, localizedName: \.name)
  }

  @Test
  func picksTheDeviceListedUnderItsCoreDeviceIdentifier() {
    let screenA = Candidate(uniqueID: "CORE-DEVICE-A", name: "iPhone")
    let screenB = Candidate(uniqueID: "CORE-DEVICE-B", name: "iPhone")
    #expect(select([screenB, screenA], coreDevices: [device(), device(identifier: "core-device-b", udid: "phone-b")]) == screenA)
    #expect(select([screenB, screenA], coreDevices: [device(transport: nil)]) == screenA)
  }

  @Test
  func picksTheOnlyWiredDeviceWithItsName() {
    let offline = device(identifier: "offline", udid: "offline", transport: nil)
    let wireless = device(identifier: "wireless", udid: "wireless", transport: "localNetwork")
    #expect(select([screen], coreDevices: [device(), offline, wireless]) == screen)
  }

  @Test(arguments: [nil, "localNetwork", "unknown"] as [String?])
  func doesNotMatchTheNameOfANonWiredTarget(_ transport: String?) {
    #expect(select([screen], coreDevices: [device(transport: transport)]) == nil)
  }

  @Test
  func missingTransportInAConnectionDoesNotAuthorizeAMatchByName() {
    let missingTransport = CoreDeviceEntry(
      identifier: "core-device-a", deviceProperties: .init(name: "iPhone"), hardwareProperties: .init(udid: phoneA),
      connectionProperties: .init(transportType: nil))
    #expect(select([screen], coreDevices: [missingTransport]) == nil)
  }

  @Test
  func doesNotPickASameNamedWiredDeviceWhoseScreenIsListedFirst() {
    let identity = DeviceVideo.CaptureIdentity(udid: phoneA, coreDevices: [device(), device(identifier: "core-device-b", udid: "phone-b")])
    #expect(identity.match(among: [screen], uniqueID: \.uniqueID, localizedName: \.name) == nil)
    #expect(identity.nameAmbiguity?.contains("2 wired devices are named 'iPhone'") == true)
    let exact = Candidate(uniqueID: "core-device-a", name: "iPhone")
    #expect(identity.match(among: [screen, exact], uniqueID: \.uniqueID, localizedName: \.name) == exact)
  }

  @Test
  func picksNothingWithoutAProvableMatch() {
    let twins = [Candidate(uniqueID: "A1", name: "iPhone"), Candidate(uniqueID: "B2", name: "iPhone")]
    #expect(select(twins, coreDevices: [device()]) == nil)
    #expect(select([screen], coreDevices: []) == nil)
    #expect(select([screen], coreDevices: [device(), device(identifier: "duplicate")]) == nil)
    #expect(select([Candidate(uniqueID: "A1", name: "")], coreDevices: [device(name: "")]) == nil)
  }
}

@Suite
struct DevicectlDeviceListTests {
  private static let listing = """
    {"info": {"outcome": "success"}, "result": {"devices": [
      {"identifier": "core-device-a", "deviceProperties": {"name": "iPhone"},
       "hardwareProperties": {"udid": "phone-a"}, "connectionProperties": {"transportType": "wired", "tunnelState": "disconnected"}},
      {"identifier": "wireless", "deviceProperties": {"name": "iPhone"}, "connectionProperties": {"transportType": "localNetwork"}},
      {"identifier": "offline", "deviceProperties": {"name": "iPhone"}, "connectionProperties": {"tunnelState": "unavailable"}},
      {"identifier": "missing"}
    ]}}
    """
  private let logger = ControlCoreGlobalConfiguration.systemLogger(writingToStderr: false, debugLogging: false)

  private struct Launcher: SubprocessLauncher {
    let script: String
    let started = AsyncEvent<URL>()
    var supportsStandardInput: Bool { false }

    func spawn(
      _ subprocess: Subprocess, standardInput: Int32?, standardOutput: Int32?, standardError: Int32?, logger: (any ControlCoreLogger)?
    ) async throws -> LaunchedProcess {
      #expect(subprocess.executable == "/usr/bin/xcrun")
      #expect(Array(subprocess.arguments.prefix(4)) == ["devicectl", "list", "devices", "--timeout"])
      #expect(subprocess.arguments.dropFirst(4).first.flatMap(Int.init).map { $0 > 0 } == true)
      let path = try #require(subprocess.arguments.last)
      let fixture = Subprocess(executable: "/bin/sh", arguments: ["-c", script, "fixture", path, DevicectlDeviceListTests.listing])
      let launched = try await HostSubprocessLauncher().spawn(
        fixture, standardInput: standardInput, standardOutput: standardOutput, standardError: standardError, logger: logger)
      started.happen(URL(fileURLWithPath: path).deletingLastPathComponent())
      return launched
    }
  }

  @Test
  func decodesIdentityAndTransportAndCleansUpTheTemporaryDirectory() async throws {
    let launcher = Launcher(script: #"printf '%s' "$2" > "$1""#)
    let devices = try await AppleDevicectlCommandExecutor.listDevices(logger: logger, launcher: launcher)
    #expect(devices.map(\.identifier) == ["core-device-a", "wireless", "offline", "missing"])
    #expect(devices.map(\.udid) == ["phone-a", nil, nil, nil])
    #expect(devices.map(\.name) == ["iPhone", "iPhone", "iPhone", nil])
    #expect(devices.map(\.isWired) == [true, false, false, false])
    let temporaryDirectory = try await launcher.started.wait()
    #expect(!FileManager.default.fileExists(atPath: temporaryDirectory.path()))
  }

  @Test
  func nonzeroExitIncludesStandardErrorAndCleansUpTheTemporaryDirectory() async throws {
    let launcher = Launcher(script: "printf 'fixture stdout'; printf 'fixture stderr' >&2; exit 7")
    let error = await #expect(throws: DevicectlError.self) {
      try await AppleDevicectlCommandExecutor.listDevices(logger: logger, launcher: launcher)
    }
    #expect(error?.localizedDescription.contains("exit code 7") == true)
    #expect(error?.localizedDescription.contains("fixture stdout") == true)
    #expect(error?.localizedDescription.contains("fixture stderr") == true)
    let temporaryDirectory = try await launcher.started.wait()
    #expect(!FileManager.default.fileExists(atPath: temporaryDirectory.path()))
  }

  @Test(arguments: ["printf 'malformed' > \"$1\"", ":"])
  func missingOrMalformedJSONNamesTheFileAndCleansUp(_ writeJSON: String) async throws {
    let launcher = Launcher(script: "\(writeJSON); printf 'fixture stderr' >&2")
    let error = await #expect(throws: DevicectlError.self) {
      try await AppleDevicectlCommandExecutor.listDevices(logger: logger, launcher: launcher)
    }
    let temporaryDirectory = try await launcher.started.wait()
    guard case let .unreadableJSON(path, _, stderr, _)? = error else {
      Issue.record("Expected unreadable devicectl JSON, got \(String(describing: error))")
      return
    }
    #expect(URL(filePath: path).deletingLastPathComponent() == temporaryDirectory)
    #expect(stderr.contains("fixture stderr"))
    #expect(!FileManager.default.fileExists(atPath: temporaryDirectory.path()))
  }

  @Test
  func hostDeadlineStopsAStalledListingAndCleansUpTheTemporaryDirectory() async throws {
    let launcher = Launcher(script: "exec /bin/sleep 60")
    let error = await #expect(throws: DevicectlError.self) {
      try await AppleDevicectlCommandExecutor.listDevices(logger: logger, hostTimeoutMilliseconds: 100, launcher: launcher)
    }
    guard case .timedOut? = error else {
      Issue.record("Expected the host deadline to stop the listing, got \(String(describing: error))")
      return
    }
    let temporaryDirectory = try await launcher.started.wait()
    #expect(!FileManager.default.fileExists(atPath: temporaryDirectory.path()))
  }

  @Test
  func cancellationStopsAStalledListingAndCleansUpTheTemporaryDirectory() async throws {
    let launcher = Launcher(script: "exec /bin/sleep 60")
    let listing = Task { try await AppleDevicectlCommandExecutor.listDevices(logger: logger, launcher: launcher) }
    let temporaryDirectory = try await launcher.started.wait(timeout: 5, waitingFor: "fixture launch")
    listing.cancel()
    await #expect(throws: CancellationError.self) { try await listing.value }
    #expect(!FileManager.default.fileExists(atPath: temporaryDirectory.path()))
  }
}

@MainActor
@Suite(.serialized)
struct DevicectlJSONLaunchTests {
  private func configuration() -> ApplicationLaunchConfiguration {
    ApplicationLaunchConfiguration(
      bundleID: "com.example.app", bundleName: nil, arguments: ["--flag"], environment: ["EXAMPLE": "value"],
      waitForDebugger: true, stdOut: .nullDevice, stdErr: .nullDevice, launchMode: .failIfRunning)
  }

  @Test
  func launchUsesTheDeviceLauncherAndCleansUpItsJSONDirectory() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.json(#"{"result":{"process":{"processIdentifier":4242}}}"#)])
    let device = FakeAMDevice().makeDevice(devicectlLauncher: launcher)
    let pid = try await AppleDevicectlCommandExecutor(device: device).launchApplication(configuration: configuration())
    #expect(pid == 4242)
    let invocation = try #require(await launcher.invocations.first)
    #expect(Array(invocation.prefix(6)) == ["devicectl", "device", "process", "launch", "--timeout", "60"])
    let output = URL(filePath: FakeDevicectlLauncher.value(of: "--json-output", in: invocation))
    #expect(!FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path()))
    #expect(FakeDevicectlLauncher.value(of: "--environment-variables", in: invocation) == #"{"EXAMPLE":"value"}"#)
    #expect(Array(invocation.suffix(3)) == ["--start-stopped", "com.example.app", "--flag"])
  }

  @Test
  func malformedLaunchJSONNamesItsPathAndCleansUp() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.json("malformed")])
    let device = FakeAMDevice().makeDevice(devicectlLauncher: launcher)
    let error = await #expect(throws: DevicectlError.self) {
      _ = try await AppleDevicectlCommandExecutor(device: device).launchApplication(configuration: configuration())
    }
    guard case let .unreadableJSON(path, _, _, _)? = error else {
      Issue.record("Expected unreadable launch JSON, got \(String(describing: error))")
      return
    }
    #expect(!FileManager.default.fileExists(atPath: URL(filePath: path).deletingLastPathComponent().path()))
  }
}
