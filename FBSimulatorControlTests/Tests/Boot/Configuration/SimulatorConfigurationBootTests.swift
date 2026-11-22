/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
@testable import FBSimulatorControl
import XCTest

final class SimulatorConfigurationBootTests: XCTestCase {
  func testAdapterRetainsCompatibleCoreSimulatorObjects() throws {
    try SimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(ControlCoreGlobalConfiguration.defaultLogger)
    let service = try SimulatorServiceContext.sharedServiceContext()
    let deviceTypes = service.supportedDeviceTypes()
    let runtimes = service.supportedRuntimes()
    guard
      let availableRuntime = runtimes.first(where: { runtime in
        runtime.available && deviceTypes.contains(where: { runtime.supportsDeviceType($0) })
      })
    else {
      throw XCTSkip("The host has no available compatible device/runtime pairs")
    }
    let availableDevice = try XCTUnwrap(deviceTypes.first(where: { availableRuntime.supportsDeviceType($0) }))
    let request = SimulatorCreationRequest(
      device: .identifier(try XCTUnwrap(availableDevice.identifier)),
      runtime: .identifier(try XCTUnwrap(availableRuntime.identifier)))
    let snapshot = try CoreSimulatorRuntimeIndex()
    let match = try snapshot.index.resolve(request)
    let expectedDevice = snapshot.deviceTypes[match.device]
    let expectedRuntime = snapshot.runtimes[match.runtime]
    let (device, runtime) = try snapshot.resolve(request)
    XCTAssertTrue(device === expectedDevice)
    XCTAssertTrue(runtime === expectedRuntime)
    XCTAssertEqual(device.identifier, availableDevice.identifier)
    XCTAssertEqual(runtime.identifier, availableRuntime.identifier)
    XCTAssertTrue(runtime.available)
    XCTAssertTrue(runtime.supportsDeviceType(device))
    let configuration = SimulatorConfiguration(deviceType: device, runtime: runtime)
    XCTAssertEqual(configuration.os.versionString, runtime.versionString)
    XCTAssertEqual(configuration.runtimeBuildVersion, runtime.buildVersionString)
    XCTAssertEqual(configuration.device.model.rawValue, device.name)
    XCTAssertTrue(try SimulatorConfiguration.availableConfigurations().contains(configuration))
  }
}
