/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
@testable import FBSimulatorControl
import Foundation
import Testing

@Suite("Simulator registry")
struct SimulatorRegistryTests {

  private static func makeDevice() -> SimDeviceDouble {
    let deviceType = SimDeviceTypeDouble()
    deviceType.name = "iPhone 8"
    let runtime = SimDeviceRuntimeDouble()
    runtime.name = "iOS 15.0"
    runtime.versionString = "15.0"
    let device = SimDeviceDouble()
    device.name = "iPhone 8"
    device.deviceType = deviceType
    device.runtime = runtime
    return device
  }

  private static func makeSet(_ devices: [SimDeviceDouble]) -> SimulatorSet {
    let deviceSet = SimDeviceSetDouble()
    deviceSet.devices = devices
    return createSimulatorSet(configuration: SimulatorControlConfiguration(deviceSetPath: nil, logger: nil), fakeDeviceSet: deviceSet)
  }

  @Test func directConstructionInfersTheConfiguration() {
    let device = Self.makeDevice()
    let simulator = Simulator.fromSimDevice(SimulatorTestSupport.asDevice(device))
    #expect(simulator.udid == device.UDID.uuidString)
    #expect(simulator.deviceType.model.rawValue == "iPhone 8")
    #expect(simulator.osVersion.name.rawValue == "iOS 15.0")
  }

  @Test func repeatedDirectConstructionReturnsTheSameInstance() {
    let device = SimulatorTestSupport.asDevice(Self.makeDevice())
    #expect(Simulator.fromSimDevice(device) === Simulator.fromSimDevice(device))
  }

  @Test func directConstructionReturnsTheInstanceASetVended() {
    let device = Self.makeDevice()
    let set = Self.makeSet([device])
    let vended = set.simulator(withUDID: device.UDID.uuidString)
    #expect(vended != nil)
    #expect(Simulator.fromSimDevice(SimulatorTestSupport.asDevice(device)) === vended)
  }

  @Test func setReturnsTheInstanceConstructedDirectly() {
    let device = Self.makeDevice()
    let direct = Simulator.fromSimDevice(SimulatorTestSupport.asDevice(device))
    let set = Self.makeSet([device])
    #expect(set.simulator(withUDID: device.UDID.uuidString) === direct)
  }

  @Test func releasedSimulatorIsRebuilt() {
    let device = SimulatorTestSupport.asDevice(Self.makeDevice())
    weak var released: Simulator?
    autoreleasepool {
      released = Simulator.fromSimDevice(device)
    }
    #expect(released == nil)
    #expect(Simulator.fromSimDevice(device).udid == device.udid.uuidString)
  }
}
