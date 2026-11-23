/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import SimulatorFrameworkBridgeRuntime
import SimulatorFrameworkBridgeSupport
import XCTest

final class ProxyServiceTests: XCTestCase {

  func testUnknownActionReturnsFailure() {
    XCTAssertEqual(ProxyService.handleProxyAction(action: "unknown", arguments: []), 1)
    XCTAssertEqual(ProxyService.handleProxyAction(action: "", arguments: []), 1)
    XCTAssertEqual(ProxyService.handleProxyAction(action: "remove", arguments: []), 1)
  }

  func testSetWithNoArgsReturnsFailure() {
    XCTAssertEqual(ProxyService.handleProxyAction(action: "set", arguments: []), 1)
  }

  func testSetWithOneArgReturnsFailure() {
    XCTAssertEqual(ProxyService.handleProxyAction(action: "set", arguments: ["127.0.0.1"]), 1)
  }

  // MARK: - buildHTTPProxyDict

  func testBuildHTTPProxyDictContainsHTTPKeys() {
    let dict = ProxyService.buildHTTPProxyDict(host: "10.0.0.1", port: 8080)
    XCTAssertNotNil(dict)

    XCTAssertEqual(dict["HTTPProxy"] as? String, "10.0.0.1")
    XCTAssertEqual(dict["HTTPPort"] as? NSNumber, 8080)
    XCTAssertEqual(dict["HTTPEnable"] as? NSNumber, 1)
  }

  func testBuildHTTPProxyDictContainsHTTPSKeys() {
    let dict = ProxyService.buildHTTPProxyDict(host: "proxy.example.com", port: 3128)

    XCTAssertEqual(dict["HTTPSProxy"] as? String, "proxy.example.com")
    XCTAssertEqual(dict["HTTPSPort"] as? NSNumber, 3128)
    XCTAssertEqual(dict["HTTPSEnable"] as? NSNumber, 1)
  }

  func testBuildHTTPProxyDictContainsFTPPassiveAndExceptions() {
    let dict = ProxyService.buildHTTPProxyDict(host: "127.0.0.1", port: 8080)

    XCTAssertEqual(dict["FTPPassive"] as? NSNumber, 1)
    let exceptions = dict["ExceptionsList"] as? [String]
    XCTAssertEqual(exceptions?.count ?? 0, 2)
    XCTAssertTrue(exceptions?.contains("*.local") ?? false)
    XCTAssertTrue(exceptions?.contains("169.254/16") ?? false)
  }

  // MARK: - buildSOCKSProxyDict

  func testBuildSOCKSProxyDictContainsSOCKSKeys() {
    let dict = ProxyService.buildSOCKSProxyDict(host: "10.0.0.1", port: 1080)
    XCTAssertNotNil(dict)

    XCTAssertEqual(dict["SOCKSProxy"] as? String, "10.0.0.1")
    XCTAssertEqual(dict["SOCKSPort"] as? NSNumber, 1080)
    XCTAssertEqual(dict["SOCKSEnable"] as? NSNumber, 1)
  }

  func testBuildSOCKSProxyDictDoesNotContainHTTPKeys() {
    let dict = ProxyService.buildSOCKSProxyDict(host: "10.0.0.1", port: 1080)

    XCTAssertNil(dict["HTTPProxy"])
    XCTAssertNil(dict["HTTPPort"])
    XCTAssertNil(dict["HTTPEnable"])
    XCTAssertNil(dict["HTTPSProxy"])
    XCTAssertNil(dict["HTTPSPort"])
    XCTAssertNil(dict["HTTPSEnable"])
  }

  func testBuildSOCKSProxyDictContainsFTPPassiveAndExceptions() {
    let dict = ProxyService.buildSOCKSProxyDict(host: "10.0.0.1", port: 1080)

    XCTAssertEqual(dict["FTPPassive"] as? NSNumber, 1)
    let exceptions = dict["ExceptionsList"] as? [String]
    XCTAssertEqual(exceptions?.count ?? 0, 2)
    XCTAssertTrue(exceptions?.contains("*.local") ?? false)
    XCTAssertTrue(exceptions?.contains("169.254/16") ?? false)
  }

  // MARK: - buildEmptyProxyDict

  func testBuildEmptyProxyDictContainsOnlyFTPPassive() {
    let dict = ProxyService.buildEmptyProxyDict()
    XCTAssertNotNil(dict)

    XCTAssertEqual(dict.count, 1)
    XCTAssertEqual(dict["FTPPassive"] as? NSNumber, 1)
  }

  // MARK: - handleProxyAction list

  // See the note in DnsServiceTests: a sandboxed XCTest host cannot create an SCDynamicStore,
  // so `list` reports failure here where the `simctl spawn`'d bridge would succeed.
  func testHandleProxyActionListReturnsFailureWithoutADynamicStore() throws {
    // An unhosted test bundle is not sandboxed, so it gets a store and this path cannot be reached.
    try XCTSkipIf(FBNetworkConfigurationStore.proxy() != nil, "this process can create a dynamic store")
    let result = ProxyService.handleProxyAction(action: "list", arguments: [])
    XCTAssertEqual(result, 1)
  }
}
