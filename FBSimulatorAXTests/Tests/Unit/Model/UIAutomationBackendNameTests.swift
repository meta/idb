/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorAX
import FBSimulatorBridgeProtocol
import Foundation
import Testing

/// The backend names that decide which guest a UI automation reads through.
@Suite
struct UIAutomationBackendNameTests {
  @Test
  func everyResolvedBackendNameRoundTrips() {
    let cases: [(AXBridgePersistence, UIAutomationBackendName)] = [
      (.oneShot, .axBridgeOneShot), (.shared, .axBridgePersistent), (.exclusive, .axBridgeExclusive),
    ]
    for (persistence, name) in cases {
      let backend = UIAutomationBackend.axBridge(
        persistence: persistence, frontmostMethod: .windowServer, automationMode: true)
      #expect(backend.name == name)
      #expect(UIAutomationBackend(resolvedName: name) == backend)
    }
  }

  @Test
  func theOneShotCaseHasAnExplicitWireName() {
    #expect(UIAutomationBackendName.axBridgeOneShot.rawValue == "axbridge-oneshot")
  }

  @Test
  func theSharedCaseKeepsTheExistingWireName() {
    #expect(UIAutomationBackendName.axBridgePersistent.rawValue == "axbridge-persistent")
  }

  @Test
  func theExclusiveCaseHasItsOwnWireName() {
    #expect(UIAutomationBackendName.axBridgeExclusive.rawValue == "axbridge-exclusive")
  }
}
