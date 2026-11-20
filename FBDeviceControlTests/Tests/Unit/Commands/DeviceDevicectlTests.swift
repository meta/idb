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
    #expect(invocation == ["devicectl", "device", "process", "launch", "--device", "fake-udid", "--terminate-existing", "--json-output", output, "com.example.app", "--flag"])
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
}
