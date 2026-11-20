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

/// Uninstalling reports a bundle ID that is not installed, which the device itself does not.
@MainActor
// Serialized: the fake device's queues are the main queue, so parallel tests would interleave on it.
@Suite(.serialized)
struct DeviceUninstallTests {

  private let amDevice = FakeAMDevice()

  @Test
  func anInstalledApplicationIsUninstalled() async throws {
    let device = amDevice.makeDevice()
    amDevice.installedApplications = ["com.example.app": [ApplicationInstallInfoKey.bundleName.rawValue: "Example"]]

    try await device.application.uninstall(bundleID: "com.example.app")

    #expect(amDevice.events.contains("uninstall:com.example.app"))
  }

  @Test
  func uninstallingABundleIDThatIsNotInstalledFailsWithoutAskingTheDevice() async throws {
    let device = amDevice.makeDevice()
    amDevice.installedApplications = ["com.example.other": [ApplicationInstallInfoKey.bundleName.rawValue: "Other"]]

    let error = await #expect(throws: DeviceApplicationError.self) {
      try await device.application.uninstall(bundleID: "com.example.app")
    }
    #expect(error?.localizedDescription == "Cannot uninstall com.example.app: no application with this bundle ID is installed")
    #expect(!amDevice.events.contains { $0.hasPrefix("uninstall:") })
  }

  @Test
  func aFailedUninstallIsReported() async throws {
    let device = amDevice.makeDevice()
    amDevice.installedApplications = ["com.example.app": [ApplicationInstallInfoKey.bundleName.rawValue: "Example"]]
    amDevice.uninstallStatus = -402653103

    await #expect(throws: DeviceApplicationError.self) {
      try await device.application.uninstall(bundleID: "com.example.app")
    }
  }
}
