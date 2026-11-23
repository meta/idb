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

final class AccessibilityInitializationTests: XCTestCase {
  private let request: [String: Any] = ["verb": "settings-get", "setting": "reduce-motion"]

  override func setUp() {
    super.setUp()
    FBAXClientProvider.setRuntimeForTesting(nil)
  }

  func testSuccessfulPreparationAndRequest() {
    XCTAssertEqual(
      FBAXRuntimeInitializationProbe(.success, true) { AccessibilityService.handleRequest(request) } as NSDictionary,
      [
        "preparationException": NSNull(), "calls": 2,
        "response": ["ok": true, "enabled": true],
      ] as NSDictionary)
  }

  func testInitializationFailurePreservesTheSetupMessage() {
    XCTAssertEqual(
      FBAXRuntimeInitializationProbe(.failureWithMessage, true) { AccessibilityService.handleRequest(request) } as NSDictionary,
      [
        "preparationException": NSNull(), "calls": 2,
        "response": ["ok": false, "error": "missing test framework", "error_kind": "reader_unavailable"],
      ] as NSDictionary)
  }

  func testInitializationFailureWithoutDetailsUsesTheFallback() {
    XCTAssertEqual(
      FBAXRuntimeInitializationProbe(.failureWithoutMessage, true) { AccessibilityService.handleRequest(request) } as NSDictionary,
      [
        "preparationException": NSNull(), "calls": 2,
        "response": ["ok": false, "error": "accessibility setup failed", "error_kind": "reader_unavailable"],
      ] as NSDictionary)
  }

  func testInitializationExceptionWithReason() {
    XCTAssertEqual(
      FBAXRuntimeInitializationProbe(.exceptionWithReason, true) { AccessibilityService.handleRequest(request) } as NSDictionary,
      [
        "preparationException": NSNull(), "calls": 2,
        "response": ["ok": false, "error": "accessibility initialization raised: initialization failed", "error_kind": "reader_unavailable"],
      ] as NSDictionary)
  }

  func testInitializationExceptionWithoutReason() {
    XCTAssertEqual(
      FBAXRuntimeInitializationProbe(.exceptionWithoutReason, true) { AccessibilityService.handleRequest(request) } as NSDictionary,
      [
        "preparationException": NSNull(), "calls": 2,
        "response": ["ok": false, "error": "accessibility initialization raised: NSInternalInconsistencyException", "error_kind": "reader_unavailable"],
      ] as NSDictionary)
  }

  func testInvalidPidDoesNotInitializeTheRuntime() {
    XCTAssertEqual(
      FBAXRuntimeInitializationProbe(.exceptionWithReason, false) { AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": 0]) } as NSDictionary,
      [
        "preparationException": NSNull(), "calls": 0,
        "response": ["ok": false, "error": "pid 0 names no application", "error_kind": "application_unavailable", "pid": 0],
      ] as NSDictionary)
  }
}
