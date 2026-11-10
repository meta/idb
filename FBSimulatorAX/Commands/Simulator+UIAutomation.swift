/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@preconcurrency import FBSimulatorControl
import FBSimulatorServices
import Foundation

// The simulator's accessibility reading and UI automation, added onto `Simulator` from outside
// `FBSimulatorControl` so that consumers with no interest in accessibility do not link it.

/// A foreground application lookup on an identified display, not an atomic screen capture.
public struct FrontmostApplicationObservation: Sendable {
  public let processIdentifier: pid_t
  public let displayID: String
}

extension Simulator {

  /// Resolves the active display's frontmost application without walking its tree or asserting automation mode.
  public func observeFrontmostApplication(timing: SimulatorAccessibilityTiming? = nil) async throws -> FrontmostApplicationObservation {
    try await accessibility.observeFrontmostApplication(timing: timing)
  }

  /// The converged UI-automation surface for `backend` — element reads and element-targeted actions
  /// over a single query-shaped API. Every call returns a fresh reader; the readers are cheap, and
  /// where a backend owns an expensive warm resource, who owns it differs by backend:
  ///
  /// - `.axBridge(persistence: .shared, …)` reads over a guest `serve` process on the simulator's
  ///   well-known socket, shared with every other process reading the same simulator. The connection is
  ///   released after each round trip so the next reader can have it, and no host ever ends the guest —
  ///   only its own idle timeout does.
  /// - `.axBridge(persistence: .exclusive, …)` reads over a guest of the caller's own, on a socket
  ///   nobody else can discover. Memoized per simulator and per persistence, and holds its connection
  ///   between reads. The guest was spawned with `--exit-on-disconnect`, so closing that connection is
  ///   what ends it — for a process that owns the simulator for its lifetime.
  /// - `.accessibility` and `.axBridge(persistence: .oneShot, …)` are stateless — they hold no warm
  ///   resource, so reconstructing them per call is free.
  ///
  /// Operations reach the display `display` selects, and fail rather than reach another. Only the AXBridge
  /// backends route to a display, so `.accessibility` refuses any selection but `.active`.
  public func uiAutomation(backend: UIAutomationBackend, display: DisplaySelection = .active) throws -> any UIAutomation {
    switch backend {
    case .accessibility, .coreSimulatorAccessibility:
      guard display == .active else {
        throw UIAutomationError.operationUnsupported(backend: backend, operation: "Selecting a display other than the active one")
      }
      return AccessibilityUIAutomation(simulator: self, transport: backend == .accessibility ? .bridge : .coreSimulator)
    case let .axBridge(persistence, frontmostMethod, automationMode):
      let transport: any AXBridgeTransport =
        switch persistence {
        case .oneShot: AXBridgeOneshotTransport(simulator: self)
        case .shared: frameworkBridgeTransport(scope: .shared)
        case .exclusive: frameworkBridgeTransport(scope: .exclusive)
        }
      return AXBridgeUIAutomation(
        simulator: self, transport: transport, persistence: persistence, frontmostMethod: frontmostMethod,
        automationMode: automationMode, displays: displays, selection: display,
        runningApplications: { [self] in try await application.running() }
      )
    }
  }

  var accessibility: SimulatorAccessibilityCommands {
    commandCache.resolve { SimulatorAccessibilityCommands(simulator: self) }
  }

  /// The accessibility commands whose reads travel over `transport`, each memoized for the simulator.
  func accessibility(through transport: AXTranslationTransportKind) -> SimulatorAccessibilityCommands {
    switch transport {
    case .bridge:
      return accessibility
    case .coreSimulator:
      return commandCache.resolve {
        CoreSimulatorClientAccessibility(
          commands: SimulatorAccessibilityCommands(simulator: self, transport: CoreSimulatorAXTranslationTransport(device: device)))
      }.commands
    }
  }
}

/// The command cache holds one value per type; this keeps CoreSimulator's-client commands apart from the
/// bridge's.
private final class CoreSimulatorClientAccessibility {
  let commands: SimulatorAccessibilityCommands

  init(commands: SimulatorAccessibilityCommands) {
    self.commands = commands
  }
}
