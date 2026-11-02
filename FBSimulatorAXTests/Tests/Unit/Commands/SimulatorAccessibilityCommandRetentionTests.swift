/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorAX
@testable import FBSimulatorControl
import Testing

/// Every command accessor FBSimulatorAX adds to `Simulator`.
enum SimulatorAccessibilityCommandAccessor: CaseIterable, Sendable {
  case uiAutomation
  case accessibility
  case coreSimulatorAccessibility
  case idleSync

  func resolve(on simulator: Simulator) {
    switch self {
    case .uiAutomation:
      // Every backend, since only the persistent axbridge scopes resolve a transport into the cache.
      for name in UIAutomationBackendName.allCases {
        _ = try? simulator.uiAutomation(backend: UIAutomationBackend(resolvedName: name))
      }
    case .accessibility:
      _ = simulator.accessibility
    case .coreSimulatorAccessibility:
      _ = simulator.accessibility(through: .coreSimulator)
    case .idleSync:
      _ = simulator.idleSyncHost
    }
  }
}

@Suite("Simulator accessibility command retention")
struct SimulatorAccessibilityCommandRetentionTests {
  @Test("Resolving a command does not retain the simulator", arguments: SimulatorAccessibilityCommandAccessor.allCases)
  func resolvingACommandDoesNotRetainTheSimulator(_ accessor: SimulatorAccessibilityCommandAccessor) {
    #expect(simulatorSurvives { accessor.resolve(on: $0) } == false)
  }
}

@Suite("Simulator accessibility commands per transport")
struct SimulatorAccessibilityCommandTransportTests {
  @Test("The ax-coresimulator backend's commands send through CoreSimulator's client, held apart from the bridge's")
  func theCoreSimulatorCommandsAreTheirOwn() {
    let simulator = SimulatorTestSupport.testableSimulator()
    let coreSimulator = simulator.accessibility(through: .coreSimulator)
    #expect(coreSimulator === simulator.accessibility(through: .coreSimulator), "memoized for the simulator")
    #expect(coreSimulator !== simulator.accessibility, "not the bridge's commands")
    #expect(simulator.accessibility(through: .bridge) === simulator.accessibility)
    #expect(coreSimulator.transport is CoreSimulatorAXTranslationTransport)
    #expect(simulator.accessibility.transport == nil, "the bridge's commands resolve their transport on first read")
  }
}
