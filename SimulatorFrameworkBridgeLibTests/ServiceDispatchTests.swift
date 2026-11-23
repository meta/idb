/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import SimulatorFrameworkBridgeSupport
import XCTest

final class ServiceDispatchTests: XCTestCase {
  private var services = CommandLineServices()

  override func setUp() {
    super.setUp()
    // What the delivered reader answers depends on the store it reads, so point it at an empty
    // directory of this suite's own: these assertions are about which service a verb reaches.
    // The delivered verb reaches a real notification center on a simulator that has one, and
    // these assertions are about routing rather than about what it answers. Without a short
    // timeout, a center that does not come back spends the default 30s in a routing test.
    services = CommandLineServices(
      deliveredNotificationsDirectory: (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString),
      deliveredNotificationsTimeout: 0.05)
  }

  private func dispatchService(_ service: String, _ action: String, _ arguments: [String]) -> Int32 {
    BridgeCommandLine.dispatch(service: service, action: action, arguments: arguments, services: services)
  }

  // MARK: - Unknown service

  func testUnknownServiceReturnsFailure() {
    XCTAssertEqual(dispatchService("unknown", "clear", []), 1)
  }

  // MARK: - Contacts routing

  func testDispatchContactsUnknownAction() {
    XCTAssertEqual(dispatchService("contacts", "unknown", []), 1)
  }

  // MARK: - Photos routing

  func testDispatchPhotosUnknownAction() {
    XCTAssertEqual(dispatchService("photos", "unknown", []), 1)
  }

  // MARK: - Notifications routing

  func testDispatchNotificationsRoutes() {
    XCTAssertEqual(dispatchService("notifications", "approve", ["com.test"]), 0)
  }

  func testDispatchNotificationsPassesBundleID() {
    XCTAssertEqual(dispatchService("notifications", "check", ["com.test"]), 0)
  }

  func testDispatchNotificationsNoBundleID() {
    // "list" with no arguments — bundleID is nil, so every section is reported
    XCTAssertEqual(dispatchService("notifications", "list", []), 0)
  }

  func testDispatchNotificationsDeliveredRoutesToTheReader() {
    // The settings service has no "delivered" action and would answer 1, so a 0 here is
    // the delivered reader answering.
    XCTAssertEqual(dispatchService("notifications", "delivered", ["com.test"]), 0)
  }

  // MARK: - Proxy routing

  func testDispatchProxyMissingArgsRoutes() {
    // "set" with no args → insufficient arguments error
    XCTAssertEqual(dispatchService("proxy", "set", []), 1)
  }

  func testDispatchProxyUnknownAction() {
    XCTAssertEqual(dispatchService("proxy", "unknown", []), 1)
  }

  // MARK: - DNS routing

  func testDispatchDnsMissingArgsRoutes() {
    XCTAssertEqual(dispatchService("dns", "set", []), 1)
  }

  func testDispatchDnsUnknownAction() {
    XCTAssertEqual(dispatchService("dns", "unknown", []), 1)
  }

  // MARK: - Dynamic store routing

  func testDispatchDynamicStoreUnknownAction() {
    XCTAssertEqual(dispatchService("dynamic-store", "unknown", ["dns"]), 1)
  }

  func testDispatchDynamicStoreMissingKeyRoutes() {
    XCTAssertEqual(dispatchService("dynamic-store", "snapshot", []), 1)
  }

  // The key reaches the service as its first argument: an unknown name is refused by the service
  // rather than by the dispatcher, which knows nothing about keys.
  func testDispatchDynamicStorePassesTheKey() {
    XCTAssertEqual(dispatchService("dynamic-store", "snapshot", ["not a key"]), 1)
  }

  // MARK: - Health routing

  func testDispatchHealthRoutes() {
    // "list" for this bundle ID answers 1
    XCTAssertEqual(dispatchService("health", "list", ["com.test"]), 1)
  }

  func testDispatchHealthNoBundleID() {
    // "list" with no arguments — bundleID is nil, which answers 1
    XCTAssertEqual(dispatchService("health", "list", []), 1)
  }
}
