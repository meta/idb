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
import Foundation
import Testing

@Suite(.serialized)
struct FrontmostApplicationObservationTests {
  private let display = SimulatorDisplay(
    uniqueID: "screen", name: "Screen", activity: .active, isPrimary: true, isIntegrated: true,
    bounds: CGRect(x: 0, y: 0, width: 780, height: 1688), scale: 2, rotation: .upright)

  private func observe(
    pid: pid_t = 12345, displays: any DisplayCommands,
    check: (FrontmostApplicationObservation, AccessibilityTestFixture) throws -> Void
  ) async throws {
    let fixture = AccessibilityTestFixture.bootedSimulator()
    let child = AccessibilityTestElementBuilder.button(withLabel: "Not read", identifier: "child", frame: .zero)
    let root = AccessibilityTestElementBuilder.application(
      withLabel: "App", frame: CGRect(x: 0, y: 0, width: 390, height: 844), children: [child])
    fixture.rootElement = root
    try fixture.setUp()
    defer { fixture.tearDown() }
    let resolvedRoot = try #require(fixture.translator.frontmostApplicationResult)
    resolvedRoot.pid = pid
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: fixture.device)
    let dispatcher = Simulator.createAccessibilityTranslationDispatcher(withTranslator: fixture.translator)
    simulator.commandCache.register(
      SimulatorAccessibilityCommands(
        simulator: simulator, translationDispatcher: dispatcher,
        transport: CoreSimulatorAXTranslationTransport(device: simulator.device), displays: displays),
      as: SimulatorAccessibilityCommands.self)

    let observation = try await simulator.observeFrontmostApplication(
      timing: SimulatorAccessibilityTiming(elementTimeout: 0.5, queryTimeout: 1))
    try check(observation, fixture)
    #expect(!root.accessedProperties.contains("accessibilityChildren"))
    #expect(!child.accessedProperties.contains("accessibilityLabel"))
  }

  @Test func onlyTheForegroundRootIsRead() async throws {
    try await observe(displays: DisplayCommandsDouble(.sole(.identified(display)))) { observation, fixture in
      #expect(observation.processIdentifier == 12345)
      #expect(observation.displayID == "screen")
      #expect(fixture.translator.rawLookups == [.frontmostApplication])
    }
  }

  @Test func unidentifiedDisplaysAreRejected() async {
    do {
      try await observe(displays: DisplayCommandsDouble(.sole(.legacy(display.geometry)))) { _, _ in
        Issue.record("An unidentified display must not produce an observation")
      }
      Issue.record("Expected an unidentified-display error")
    } catch {
      guard case SimulatorDisplayError.noActiveIntegratedDisplay = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
  }

  @Test func missingProcessIdentifiersAreRejected() async {
    do {
      try await observe(pid: 0, displays: DisplayCommandsDouble(.sole(.identified(display)))) { _, _ in
        Issue.record("A zero PID must not produce an observation")
      }
      Issue.record("Expected a missing-process error")
    } catch {
      guard case AccessibilityError.noTranslationObject(.frontmost) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
  }

  @Test func cancellationIsNotAnUnavailableObservation() async {
    do {
      try await observe(displays: DisplayCommandsDouble([.failure(CancellationError())])) { _, _ in
        Issue.record("Cancellation must not produce an observation")
      }
      Issue.record("Expected cancellation")
    } catch {
      #expect(error is CancellationError)
    }
  }
}
