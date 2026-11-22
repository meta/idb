/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorAX
import FBSimulatorBridgeProtocol
@testable import FBSimulatorControl
import XCTest

/// Reads a real accessibility tree out of the provided simulator through the axbridge backend —
/// the `SimulatorFrameworkBridge` `serve` guest, reached over its unix socket. The
/// doubles-backed suites cover the envelope and the serialization; nothing else starts the guest
/// or walks a live tree.
///
/// Reads are anchored on an explicit pid: `.frontmost` asks the window server which application is
/// in front, which has no answer on a simulator booted headless.
final class AXBridgeSmokeTests: ProvidedSimulatorTestCase {

  private static let bundleID = "com.apple.Preferences"

  private func launchedApplicationPID() async throws -> pid_t {
    let simulator = self.simulator!
    let configuration = ApplicationLaunchConfiguration(
      bundleID: Self.bundleID,
      bundleName: nil,
      arguments: [],
      environment: [:],
      waitForDebugger: false,
      launchMode: .foregroundIfRunning)
    let launched = try await simulator.application.launch(configuration)
    addTeardownBlock {
      // Leased-resource discipline: this suite may not own the simulator, so it leaves behind only
      // what it found.
      try? await simulator.application.kill(bundleID: Self.bundleID)
    }
    return launched.processIdentifier
  }

  /// Retries only a not-responding application, while its accessibility server starts. An
  /// unreachable guest, a broken handshake or a malformed response throw on the first attempt.
  private func describeApplication(pid: pid_t, retries: Int = 4) async throws -> AccessibilityElementsResponse {
    let automation = try simulator.uiAutomation(
      backend: .axBridge(persistence: .shared, frontmostMethod: .windowServer, automationMode: true))
    let options = AccessibilityRequestOptions()
    for attempt in 0...retries {
      do {
        return try await skippingIfGuestServiceSpawnUnavailable {
          try await automation.describe(.application(pid: pid), options: options)
        }
      } catch let error as UIAutomationError {
        guard case .applicationNotResponding = error, attempt < retries else {
          throw error
        }
        try await Task.sleep(nanoseconds: 5 * NSEC_PER_SEC)
      }
    }
    preconditionFailure("The retry loop returns or throws")
  }

  func testGuestServesElementTreeOverTheSocket() async throws {
    let pid = try await launchedApplicationPID()
    let response = try await describeApplication(pid: pid)

    let elements = response.elements.elements
    XCTAssertFalse(elements.isEmpty, "The application should serialize at least one element")
    XCTAssertEqual(response.backend, .axBridgePersistent)

    let types = elements.compactMap { $0.type ?? nil }
    XCTAssertTrue(
      types.contains { $0.contains("Application") },
      "Expected an application element in the tree, got types: \(Set(types).sorted().prefix(10))")

    // The geometry survived serialization: the read states the screen it was taken against, and
    // something on it covers a real area.
    let screen = try XCTUnwrap(response.screen, "A tree read should report the screen it was taken against")
    XCTAssertGreaterThan(screen.width, 0)
    XCTAssertGreaterThan(screen.height, 0)
    let frames = elements.compactMap { $0.frame ?? nil }
    XCTAssertFalse(frames.isEmpty, "Elements should carry frames")
    XCTAssertTrue(
      frames.contains { ($0.width ?? 0) > 0 && ($0.height ?? 0) > 0 },
      "At least one element should cover a non-empty area")

    // The shared guest is held for no longer than a round trip, so a second read has to adopt the
    // one left warm — the path a second reader of this simulator takes.
    let adopted = try await describeApplication(pid: pid)
    XCTAssertFalse(adopted.elements.elements.isEmpty, "A second read should adopt the warm guest and return a tree")
    XCTAssertEqual(adopted.backend, .axBridgePersistent)
  }
}
