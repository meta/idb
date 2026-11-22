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
@testable import FBSimulatorServices
import Foundation
import Testing

@Suite
struct UIAutomationTests {

  @Test
  func anchorPointIsScreenCentreInPoints() {
    let anchor = AXBridgeUIAutomation.anchorPoint(widthPixels: 828, heightPixels: 1792, scale: 2)
    #expect(abs(anchor.x - 207) <= 0.001)
    #expect(abs(anchor.y - 448) <= 0.001)
  }

  @Test
  func anchorPointGuardsAgainstZeroScale() {
    let anchor = AXBridgeUIAutomation.anchorPoint(widthPixels: 400, heightPixels: 800, scale: 0)
    #expect(abs(anchor.x - 200) <= 0.001)
    #expect(abs(anchor.y - 400) <= 0.001)
  }

  // Which transport instance a reader is vended with decides whether the guest `serve` process is
  // shared across reads or spawned for each one. Constructing the axbridge backends touches no
  // device, so this needs no booted simulator.

  private static func backend(_ persistence: AXBridgePersistence) -> UIAutomationBackend {
    .axBridge(persistence: persistence, frontmostMethod: .windowServer, automationMode: true)
  }

  private func transport(
    _ simulator: Simulator, _ persistence: AXBridgePersistence
  ) throws -> SimulatorFrameworkBridgePersistentTransport {
    let reader = try simulator.uiAutomation(backend: Self.backend(persistence))
    let bridgeReader = try #require(reader as? AXBridgeUIAutomation)
    return try #require(bridgeReader.transport as? SimulatorFrameworkBridgePersistentTransport)
  }

  @Test
  func everySharedBackendCallSharesOneTransport() throws {
    let simulator = SimulatorTestSupport.testableSimulator()
    #expect(try transport(simulator, .shared) === (try transport(simulator, .shared)))
  }

  @Test
  func everyExclusiveBackendCallSharesOneTransport() throws {
    let simulator = SimulatorTestSupport.testableSimulator()
    #expect(try transport(simulator, .exclusive) === (try transport(simulator, .exclusive)))
  }

  // The two scopes reach different guests, so memoization is keyed by persistence, not just by simulator.
  @Test
  func sharedAndExclusiveDoNotShareATransport() throws {
    let simulator = SimulatorTestSupport.testableSimulator()
    #expect(try transport(simulator, .shared) !== (try transport(simulator, .exclusive)))
  }

  @Test
  func transportsAreNotSharedAcrossSimulators() throws {
    let first = try transport(SimulatorTestSupport.testableSimulator(), .shared)
    let second = try transport(SimulatorTestSupport.testableSimulator(), .shared)
    #expect(first !== second)
  }

  @Test
  func readersDifferingOnlyInReaderOptionsShareOneTransport() throws {
    let simulator = SimulatorTestSupport.testableSimulator()
    let shared = try transport(simulator, .shared)
    let otherOptions = UIAutomationBackend.axBridge(
      persistence: .shared, frontmostMethod: .centerPoint, automationMode: nil
    )
    let reader = try #require(try simulator.uiAutomation(backend: otherOptions) as? AXBridgeUIAutomation)
    // `frontmostMethod` and `automationMode` are the reader's, not the transport's, so differing on
    // them must not cost a second guest.
    #expect((reader.transport as? SimulatorFrameworkBridgePersistentTransport) === shared)
  }

  @Test
  func eachOneShotBackendCallBuildsAOneShotTransport() throws {
    let simulator = SimulatorTestSupport.testableSimulator()
    let backend = UIAutomationBackend.axBridge(
      persistence: .oneShot, frontmostMethod: .windowServer, automationMode: true
    )
    // Two calls: the one-shot transport must be built per call, never memoized.
    for _ in 0..<2 {
      let reader = try #require(try simulator.uiAutomation(backend: backend) as? AXBridgeUIAutomation)
      #expect(reader.transport is AXBridgeOneshotTransport)
    }
  }

  @Test
  func theAccessibilityBackendRefusesToSelectADisplay() {
    let simulator = SimulatorTestSupport.testableSimulator()
    let error = #expect(throws: (any Error).self) {
      try simulator.uiAutomation(backend: .accessibility, display: .display(uniqueID: "cover"))
    }
    guard let error, case UIAutomationError.operationUnsupported(backend: .accessibility, _) = error else {
      Issue.record("\(String(describing: error))")
      return
    }
  }
}
