/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
import FBControlCore
@testable import FBSimulatorControl
import Foundation
import Testing
import os

// MARK: - Test Doubles
//
// The simulator reaches its device by Objective-C message send, having been handed one of these
// in place of a real `SimDevice`, so the doubles are `@objc` `NSObject` subclasses whose
// property names match the selectors the simulator sends.

@objc final class TestSimDeviceType: NSObject {
  @objc var productFamilyID: Int32 = 1
  @objc var mainScreenSize: CGSize = CGSize(width: 750, height: 1334)
  @objc var mainScreenScale: Float = 2.0
  @objc var name: String = "iPhone 14"
}

@objc final class TestSimRuntime: NSObject {
  @objc var root: String = "/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot"
  @objc var name: String = "iOS 17.0"
}

@objc final class TestSimDeviceSet: NSObject {
  @objc var setPath: String = ("~/Library/Developer/CoreSimulator/Devices" as NSString).expandingTildeInPath
}

@objc final class TestSimDevice: NSObject {
  @objc var UDID: NSUUID = NSUUID()
  @objc var name: String = "TestSimulator"
  @objc var state: UInt = UInt(TargetState.booted.rawValue)
  @objc var dataPath: String = "/tmp/test-sim-data"
  @objc var deviceType = TestSimDeviceType()
  @objc var runtime = TestSimRuntime()
  @objc var deviceSet = TestSimDeviceSet()
  @objc var lookupPort: mach_port_t = mach_port_t(MACH_PORT_NULL)
  @objc var lookupShouldFail = false

  @objc(lookup:error:)
  func lookup(_ name: String, error: NSErrorPointer) -> mach_port_t {
    if lookupShouldFail {
      error?.pointee = NSError(
        domain: "FBSimulatorTestDomain",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Port not found"])
      return mach_port_t(MACH_PORT_NULL)
    }
    return lookupPort
  }
}

// MARK: - Test Class

@Suite
struct SimulatorTests {

  private let stubDevice: TestSimDevice
  private let simulator: Simulator

  init() {
    stubDevice = TestSimDevice()
    simulator = Self.createSimulator(with: stubDevice)
  }

  private static func createSimulator(with device: TestSimDevice) -> Simulator {
    SimulatorTestSupport.testableSimulator(withDevice: device)
  }

  // MARK: - Product Family

  @Test
  func productFamily_WhenFamilyIDIs1_ReturnsiPhone() {
    stubDevice.deviceType.productFamilyID = 1
    let sim = Self.createSimulator(with: stubDevice)
    #expect(sim.productFamily == .iPhone, "productFamilyID 1 should map to iPhone")
  }

  @Test
  func productFamily_WhenFamilyIDIs2_ReturnsiPad() {
    stubDevice.deviceType.productFamilyID = 2
    let sim = Self.createSimulator(with: stubDevice)
    #expect(sim.productFamily == .iPad, "productFamilyID 2 should map to iPad")
  }

  @Test
  func productFamily_WhenFamilyIDIs3_ReturnsAppleTV() {
    stubDevice.deviceType.productFamilyID = 3
    let sim = Self.createSimulator(with: stubDevice)
    #expect(sim.productFamily == .appleTV, "productFamilyID 3 should map to AppleTV")
  }

  @Test
  func productFamily_WhenFamilyIDIs4_ReturnsAppleWatch() {
    stubDevice.deviceType.productFamilyID = 4
    let sim = Self.createSimulator(with: stubDevice)
    #expect(sim.productFamily == .appleWatch, "productFamilyID 4 should map to AppleWatch")
  }

  @Test
  func productFamily_WhenFamilyIDIsUnknown_ReturnsUnknown() {
    stubDevice.deviceType.productFamilyID = 99
    let sim = Self.createSimulator(with: stubDevice)
    #expect(sim.productFamily == .unknown, "Unrecognized productFamilyID should map to Unknown")
  }

  // MARK: - Custom Device Set Path

  @Test
  func customDeviceSetPath_WhenDefaultPath_ReturnsNil() {
    stubDevice.deviceSet.setPath = ("~/Library/Developer/CoreSimulator/Devices" as NSString).expandingTildeInPath
    let sim = Self.createSimulator(with: stubDevice)
    #expect(sim.customDeviceSetPath == nil, "customDeviceSetPath should be nil when using the default device set path")
  }

  @Test
  func customDeviceSetPath_WhenCustomPath_ReturnsPath() {
    let customPath = "/custom/simulator/devices"
    stubDevice.deviceSet.setPath = customPath
    let sim = Self.createSimulator(with: stubDevice)
    #expect(
      sim.customDeviceSetPath == customPath,
      "customDeviceSetPath should return the custom path when not using the default")
  }

  // MARK: - Screen Info

  @Test
  func screenInfo_ReturnsDeviceTypeScreenDimensions() throws {
    stubDevice.deviceType.mainScreenSize = CGSize(width: 1170, height: 2532)
    stubDevice.deviceType.mainScreenScale = 3.0
    let sim = Self.createSimulator(with: stubDevice)

    let screenInfo = try #require(sim.screenInfo, "screenInfo should not be nil")

    #expect(screenInfo.widthPixels == 1170, "widthPixels should match device type mainScreenSize.width")
    #expect(screenInfo.heightPixels == 2532, "heightPixels should match device type mainScreenSize.height")
    #expect(abs(screenInfo.scale - 3.0) <= 0.001, "scale should match device type mainScreenScale")
  }

  // MARK: - Equality and Hashing

  @Test
  func isEqual_WhenSameDevice_ReturnsYES() {
    let sim1 = Self.createSimulator(with: stubDevice)
    let sim2 = Self.createSimulator(with: stubDevice)
    #expect(sim1 == sim2, "Two simulators wrapping the same device should be equal")
  }

  @Test
  func isEqual_WhenDifferentDevice_ReturnsNO() {
    let sim2 = Self.createSimulator(with: TestSimDevice())
    #expect(simulator != sim2, "Two simulators wrapping different devices should not be equal")
  }

  @Test
  func hash_DelegatesToDevice() {
    let sim1 = Self.createSimulator(with: stubDevice)
    let sim2 = Self.createSimulator(with: stubDevice)
    #expect(sim1.hashValue == sim2.hashValue, "Simulators wrapping the same device should hash identically")
    #expect(Set([sim1, sim2]).count == 1, "A set should collapse simulators wrapping the same device")
  }

  // MARK: - Temporary Directory (Lazy Init)

  /// Every ephemeral directory is a direct child of the root a `TemporaryDirectory` manages.
  private func root(of directory: TemporaryDirectory) -> URL {
    directory.ephemeralTemporaryDirectory().deletingLastPathComponent()
  }

  @Test
  func temporaryDirectory_ReturnsSameInstanceOnSubsequentAccess() {
    let first = simulator.temporaryDirectory
    let second = simulator.temporaryDirectory
    #expect(root(of: first) == root(of: second), "temporaryDirectory should return the same cached directory on subsequent access")
  }

  @Test
  func temporaryDirectory_ConcurrentFirstAccess() {
    let collected = OSAllocatedUnfairLock<[TemporaryDirectory]>(initialState: [])
    DispatchQueue.concurrentPerform(iterations: 64) { _ in
      let directory = simulator.temporaryDirectory
      collected.withLock { $0.append(directory) }
    }
    let directories = collected.withLock { $0 }
    #expect(directories.count == 64)
    #expect(directories.allSatisfy { root(of: $0) == root(of: directories[0]) })
  }

  // MARK: - Healthcheck Helpers

  @Test
  func lookupBootstrapPortNamed_WhenPortExists_ReturnsPortNumber() throws {
    stubDevice.lookupPort = 12345
    stubDevice.lookupShouldFail = false
    let sim = Self.createSimulator(with: stubDevice)

    let port = try sim.bootstrapPorts.lookup(named: "com.apple.testservice")

    #expect(port == 12345, "Returned port number should match the looked-up port")
  }

  // Both no-port paths throw: the device's own error when it reported one, and a synthesized
  // `SimulatorPortLookupError` when it did not. They are told apart by the error's domain.
  @Test
  func lookupBootstrapPortNamed_WhenPortIsNull_ProducesNoPort() throws {
    stubDevice.lookupPort = mach_port_t(MACH_PORT_NULL)
    stubDevice.lookupShouldFail = false
    let sim = Self.createSimulator(with: stubDevice)

    let error = try #require(#expect(throws: (any Error).self, "No port should be produced when MACH_PORT_NULL is returned") { try sim.bootstrapPorts.lookup(named: "com.apple.nonexistent") })
    #expect(
      (error as NSError).domain != "FBSimulatorTestDomain",
      "A null port is not a lookup failure - the device reported no error of its own")
  }

  @Test
  func lookupBootstrapPortNamed_WhenLookupFails_ReturnsNilWithError() throws {
    stubDevice.lookupShouldFail = true
    let sim = Self.createSimulator(with: stubDevice)

    let error = try #require(#expect(throws: (any Error).self, "Error should be populated when lookup fails") { try sim.bootstrapPorts.lookup(named: "com.apple.failing") })
    #expect((error as NSError).domain == "FBSimulatorTestDomain", "The device's own lookup error should surface")
  }
}
