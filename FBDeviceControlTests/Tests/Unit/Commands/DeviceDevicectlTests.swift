/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
@testable import FBDeviceControl
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Devices on iOS 17 and later are operated through `devicectl`, run once per operation.
@MainActor
// Serialized: the fake device's queues are the main queue, so parallel tests would interleave on it.
@Suite(.serialized)
struct DeviceDevicectlTests {

  private let amDevice = FakeAMDevice()

  private func launchConfiguration(arguments: [String] = [], environment: [String: String] = [:]) -> ApplicationLaunchConfiguration {
    ApplicationLaunchConfiguration(
      bundleID: "com.example.app",
      bundleName: nil,
      arguments: arguments,
      environment: environment,
      waitForDebugger: false,
      launchMode: .failIfRunning)
  }

  @Test
  func launchReturnsTheProcessIdentifierDevicectlReports() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.json(#"{"result":{"process":{"processIdentifier":4242}}}"#)])
    let device = amDevice.makeDevice(devicectlLauncher: launcher)

    let launched = try await device.application.launch(launchConfiguration(arguments: ["--flag"]))

    #expect(launched.processIdentifier == 4242)
    #expect(await launcher.executables == ["/usr/bin/xcrun"])
    let invocation = try #require(await launcher.invocations.first)
    let output = FakeDevicectlLauncher.value(of: "--json-output", in: invocation)
    #expect(invocation == ["devicectl", "device", "process", "launch", "--timeout", "60", "--device", "fake-udid", "--terminate-existing", "--json-output", output, "com.example.app", "--flag"])
  }

  @Test
  func aFailedLaunchReportsDevicectlsError() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.fail(code: 1, message: "The application could not be launched")])
    let device = amDevice.makeDevice(devicectlLauncher: launcher)

    let error = await #expect(throws: DevicectlError.self) {
      _ = try await device.application.launch(launchConfiguration())
    }
    #expect(error?.localizedDescription.contains("The application could not be launched") == true)
  }

  private func device(running processes: [String: String], launcher: FakeDevicectlLauncher) -> Device {
    let device = amDevice.makeDevice(devicectlLauncher: launcher)
    let relay = amDevice.service("com.apple.os_trace_relay")
    relay.readBuffer = Data([0])
    let payload = NSDictionary(dictionary: processes.mapValues { ["ProcessName": $0] })
    relay.messageReplies = [["Status": "RequestSuccessful", "Payload": payload] as NSDictionary]
    amDevice.installedApplications = ["com.example.app": [ApplicationInstallInfoKey.bundleName.rawValue: "Example", "CFBundleExecutable": "ExampleApp"]]
    return device
  }

  @Test
  func killSendsSIGKILLToTheAppsProcessThroughDevicectl() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.succeed])
    let device = device(running: ["940": "ExampleApp"], launcher: launcher)

    try await device.application.kill(bundleID: "com.example.app")

    #expect(await launcher.invocations == [["devicectl", "device", "process", "terminate", "--timeout", "60", "--device", "fake-udid", "--pid", "940", "--kill"]])
  }

  @Test
  func aFailedKillIsReported() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.fail(code: 1, message: "The process could not be terminated")])
    let device = device(running: ["940": "ExampleApp"], launcher: launcher)

    let error = await #expect(throws: DevicectlError.self) {
      try await device.application.kill(bundleID: "com.example.app")
    }
    #expect(error?.localizedDescription.contains("The process could not be terminated") == true)
  }

  @Test
  func killingAnAppThatIsNotRunningRunsNothing() async throws {
    let launcher = FakeDevicectlLauncher(replies: [])
    let device = device(running: ["7": "SpringBoard"], launcher: launcher)

    await #expect(throws: DeviceApplicationError.self) {
      try await device.application.kill(bundleID: "com.example.app")
    }
    #expect(await launcher.invocations.isEmpty)
  }

  // MARK: - Apps that share an executable name

  /// Two installed apps whose executables are both named `Runner`, with one `Runner` process.
  private func deviceWithTwoRunners(launcher: FakeDevicectlLauncher) -> Device {
    let device = amDevice.makeDevice(devicectlLauncher: launcher)
    let relay = amDevice.service("com.apple.os_trace_relay")
    relay.readBuffer = Data([0])
    relay.messageReplies = [["Status": "RequestSuccessful", "Payload": ["42": ["ProcessName": "Runner"]] as NSDictionary] as NSDictionary]
    amDevice.installedApplications = [
      "com.example.a": [
        ApplicationInstallInfoKey.bundleName.rawValue: "A", "CFBundleExecutable": "Runner",
        ApplicationInstallInfoKey.path.rawValue: "/private/var/containers/Bundle/Application/AAAA/A.app",
      ],
      "com.example.b": [
        ApplicationInstallInfoKey.bundleName.rawValue: "B", "CFBundleExecutable": "Runner",
        ApplicationInstallInfoKey.path.rawValue: "/private/var/containers/Bundle/Application/BBBB/B.app",
      ],
    ]
    return device
  }

  private static let runnerAProcesses =
    #"{"result":{"runningProcesses":[{"processIdentifier":42,"executable":"file:///private/var/containers/Bundle/Application/AAAA/A.app/Runner"}]}}"#

  @Test
  func aSharedExecutableNameIsSettledByTheProcessesExecutablePath() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.json(Self.runnerAProcesses)])
    let device = deviceWithTwoRunners(launcher: launcher)

    #expect(try await device.application.running() == ["com.example.a": 42])
  }

  @Test
  func killingTheAppThatIsNotRunningNeverKillsTheOneThatIs() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.json(Self.runnerAProcesses)])
    let device = deviceWithTwoRunners(launcher: launcher)

    let error = await #expect(throws: DeviceApplicationError.self) {
      try await device.application.kill(bundleID: "com.example.b")
    }
    #expect(error?.localizedDescription == "No pid for com.example.b")
    #expect(await launcher.invocations.allSatisfy { !$0.contains("terminate") })
  }

  @Test
  func anExecutableNameNoPathSettlesIsAttributedToNeitherApp() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.fail(code: 1, message: "processes unavailable")])
    let device = deviceWithTwoRunners(launcher: launcher)

    #expect(try await device.application.running() == [:])
  }

  @Test
  func killingAnAppWhoseRunningExecutableCannotBeAttributedFailsWithoutKillingAnything() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.fail(code: 1, message: "processes unavailable")])
    let device = deviceWithTwoRunners(launcher: launcher)

    let error = await #expect(throws: DeviceApplicationError.self) {
      try await device.application.kill(bundleID: "com.example.b")
    }
    #expect(error?.localizedDescription.hasPrefix("Cannot tell whether com.example.b is running: a process named Runner is running") == true)
    #expect(await launcher.invocations.allSatisfy { !$0.contains("terminate") })
  }

  @Test
  func terminatingALaunchedAppKillsTheProcessDevicectlLaunched() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.json(#"{"result":{"process":{"processIdentifier":4242}}}"#), .succeed])
    let device = amDevice.makeDevice(devicectlLauncher: launcher)

    let launched = try await device.application.launch(launchConfiguration())
    try await launched.terminate()

    #expect(await launcher.invocations.last == ["devicectl", "device", "process", "terminate", "--timeout", "60", "--device", "fake-udid", "--pid", "4242", "--kill"])
  }

  @Test
  func aKillRunsToCompletionWhenItsCallerIsCancelled() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let delivered = directory.appending(component: "kill-delivered")
    // The fake kill holds until its caller has been cancelled, then completes.
    let release = directory.appending(component: "release")
    let launcher = FakeDevicectlLauncher(replies: [
      .json(#"{"result":{"process":{"processIdentifier":4242}}}"#),
      .init(script: "while [ ! -e '\(release.path())' ]; do /bin/sleep 0.05; done; /usr/bin/touch '\(delivered.path())'"),
    ])
    let device = amDevice.makeDevice(devicectlLauncher: launcher)
    let launched = try await device.application.launch(launchConfiguration())
    let stop = Task { try await launched.terminate() }
    _ = await launcher.processIdentifier(ofInvocation: 1)

    stop.cancel()
    try Data().write(to: release)
    try await stop.value

    #expect(FileManager.default.fileExists(atPath: delivered.path()))
  }

  @Test
  func aScreenshotIsThePNGDevicectlCaptures() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let png = try Self.png(width: 3, height: 5)
    let source = directory.appending(component: "capture.png")
    try png.write(to: source)
    let launcher = FakeDevicectlLauncher(replies: [.copyToDestination(source.path())])
    let device = amDevice.makeDevice(devicectlLauncher: launcher)

    let result = try await device.screenshot.take(configuration: ScreenshotConfiguration())

    #expect(result.imageData == png)
    #expect(result.size == CGSize(width: 3, height: 5))
    let invocation = try #require(await launcher.invocations.first)
    let destination = FakeDevicectlLauncher.value(of: "--destination", in: invocation)
    #expect(invocation == ["devicectl", "device", "capture", "screenshot", "--timeout", "60", "--device", "fake-udid", "--destination", destination])
    #expect(!FileManager.default.fileExists(atPath: destination))
  }

  @Test
  func aFailedScreenshotIsReported() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.fail(code: 1, message: "Unable to capture the screen")])
    let device = amDevice.makeDevice(devicectlLauncher: launcher)

    let error = await #expect(throws: DevicectlError.self) {
      _ = try await device.screenshot.take(configuration: ScreenshotConfiguration())
    }
    #expect(error?.localizedDescription.contains("Unable to capture the screen") == true)
  }

  private static func png(width: Int, height: Int) throws -> Data {
    let context = try #require(
      CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }

  // MARK: - Bounded runs

  private static let connectingDeviceList =
    #"{"result":{"devices":[{"hardwareProperties":{"udid":"fake-udid"},"connectionProperties":{"pairingState":"paired","transportType":"localNetwork","tunnelState":"connecting"}}]}}"#

  @Test
  func aRunDevicectlAbandonsReportsTheDevicesTunnelState() async throws {
    let launcher = FakeDevicectlLauncher(replies: [
      .fail(code: 2, message: "ERROR: Command timeout of 60.0 seconds exceeded. Assuming command got stuck and aborting."),
      .json(Self.connectingDeviceList),
    ])
    let device = amDevice.makeDevice(devicectlLauncher: launcher)

    let error = await #expect(throws: DevicectlError.self) {
      _ = try await device.application.launch(launchConfiguration())
    }
    let description = try #require(error?.localizedDescription)
    #expect(description.hasPrefix("devicectl did not finish within 60s, so it was stopped. CoreDevice reports the device's tunnel state as 'connecting' (pairing state 'paired', transport 'localNetwork')."))
    let stateQuery = try #require(await launcher.invocations.last)
    #expect(Array(stateQuery.prefix(5)) == ["devicectl", "list", "devices", "--timeout", "10"])
  }

  @Test
  func aRunThatOutlivesTheHostDeadlineIsStoppedAndReported() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.hang, .json(Self.connectingDeviceList)])
    let device = amDevice.makeDevice(devicectlLauncher: launcher)

    let error = await #expect(throws: DevicectlError.self) {
      _ = try await AppleDevicectlCommandExecutor(device: device, timeout: 0).launchApplication(configuration: launchConfiguration())
    }
    #expect(error?.localizedDescription.contains("tunnel state as 'connecting'") == true)
    let hung = try #require(await launcher.processIdentifiers.first)
    #expect(kill(hung, 0) == -1 && errno == ESRCH)
  }

  @Test
  func cancellingARunStopsDevicectl() async throws {
    let launcher = FakeDevicectlLauncher(replies: [.hang])
    let device = amDevice.makeDevice(devicectlLauncher: launcher)
    let launch = Task { try await device.application.launch(launchConfiguration()) }
    let hung = await launcher.processIdentifier(ofInvocation: 0)

    launch.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await launch.value
    }
    #expect(kill(hung, 0) == -1 && errno == ESRCH)
  }
}
