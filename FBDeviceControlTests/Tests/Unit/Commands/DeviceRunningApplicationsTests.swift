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

/// Running applications are the device's process list, from the trace relay, matched by process
/// name against the installed applications' executables.
@MainActor
// Serialized: the fake device's queues are the main queue, so parallel tests would interleave on it.
@Suite(.serialized)
struct DeviceRunningApplicationsTests {

  private let amDevice = FakeAMDevice()

  private func device(processes: [Int32: String], installed: [String: String]) -> Device {
    let device = amDevice.makeDevice()
    let relay = amDevice.service("com.apple.os_trace_relay")
    relay.readBuffer = Data([0])
    let payload = Dictionary(uniqueKeysWithValues: processes.map { (NSNumber(value: $0.key), ["ProcessName": $0.value]) })
    relay.messageReplies = [["Status": "RequestSuccessful", "Payload": payload] as NSDictionary]
    amDevice.installedApplications = installed.mapValues { [ApplicationInstallInfoKey.bundleName.rawValue: $0] }
    return device
  }

  @Test
  func runningApplicationsAreKeyedByBundleIdentifierWithTheirProcessIdentifier() async throws {
    let device = device(
      processes: [42: "MyApp", 7: "SpringBoard"],
      installed: ["com.example.myapp": "MyApp", "com.example.other": "Other"])

    #expect(try await device.application.running() == ["com.example.myapp": 42])
  }

  @Test
  func processesAreMatchedByExecutableWhenTheRelayKeysThemByDecimalString() async throws {
    let device = amDevice.makeDevice()
    let relay = amDevice.service("com.apple.os_trace_relay")
    relay.readBuffer = Data([0])
    let payload: NSDictionary = ["940": ["ProcessName": "Preferences"], "7": ["ProcessName": "SpringBoard"]]
    relay.messageReplies = [["Status": "RequestSuccessful", "Payload": payload] as NSDictionary]
    amDevice.installedApplications = [
      "com.apple.Preferences": [ApplicationInstallInfoKey.bundleName.rawValue: "Settings", "CFBundleExecutable": "Preferences"],
      "com.example.other": [ApplicationInstallInfoKey.bundleName.rawValue: "Other", "CFBundleExecutable": "Other"],
    ]

    #expect(try await device.application.running() == ["com.apple.Preferences": 940])
  }

  @Test
  func anUnsuccessfulProcessListFails() async throws {
    let device = amDevice.makeDevice()
    let relay = amDevice.service("com.apple.os_trace_relay")
    relay.readBuffer = Data([0])
    relay.messageReplies = [["Status": "Failed"] as NSDictionary]

    await #expect(throws: (any Error).self) {
      _ = try await device.application.running()
    }
  }
}
