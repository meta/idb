/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import CoreGraphics
@preconcurrency import FBControlCore
import FBSimulatorAX
@preconcurrency import FBSimulatorControl
import Foundation
import IDBGRPCSwift
import SwiftProtobuf
import Testing

/// Records what the handler hands the command executor, so a test can read it without a simulator.
/// `IDBCommandExecutor` is a `public final class`; `AccessibilityActing` is the seam the handler is
/// written against, and this double stands in for it.
private final class RecordingAccessibilityActor: AccessibilityActing {
  private(set) var backend: UIAutomationBackend?
  private(set) var tapped: AccessibilityElementQuery?
  private(set) var scrolled: AccessibilityElementQuery?
  private(set) var scrolledDirection: AccessibilityScrollDirection?
  private(set) var valueSetOn: AccessibilityElementQuery?
  private(set) var valueSet: String?
  private(set) var draggedFrom: AccessibilityElementQuery?
  private(set) var draggedTo: AccessibilityElementQuery?

  func accessibilityWait(
    query: AccessibilityElementQuery,
    backend: UIAutomationBackend,
    timeout: TimeInterval,
    pollInterval: TimeInterval
  ) async throws {
    self.backend = backend
  }

  func accessibilityTap(
    query: AccessibilityElementQuery,
    backend: UIAutomationBackend,
    expectedValue: String?,
    expectedKey: AXSearchableKey
  ) async throws {
    tapped = query
    self.backend = backend
  }

  func accessibilityScroll(
    query: AccessibilityElementQuery,
    backend: UIAutomationBackend,
    direction: AccessibilityScrollDirection
  ) async throws {
    scrolled = query
    scrolledDirection = direction
    self.backend = backend
  }

  func accessibilitySetValue(
    query: AccessibilityElementQuery,
    backend: UIAutomationBackend,
    value: String
  ) async throws {
    valueSetOn = query
    valueSet = value
    self.backend = backend
  }

  func accessibilityDrag(
    from source: AccessibilityElementQuery,
    to destination: AccessibilityElementQuery,
    backend: UIAutomationBackend,
    options: DragOptions
  ) async throws {
    draggedFrom = source
    draggedTo = destination
    self.backend = backend
  }
}

/// Asserts what the *handler* hands the executor: the action it dispatches to, the endpoints it
/// resolved, and the backend the request asked for. Losing the backend here is silent -- the action
/// still runs, served by whichever backend the executor defaults to.
@Suite
struct AccessibilityActionMethodHandlerTests {

  private func respond(
    _ mutate: (inout Idb_AccessibilityActionRequest) -> Void
  ) async throws -> RecordingAccessibilityActor {
    var request = Idb_AccessibilityActionRequest()
    mutate(&request)
    let executor = RecordingAccessibilityActor()
    _ = try await AccessibilityActionMethodHandler.respond(to: request, using: executor)
    return executor
  }

  @Test
  func tapReachesTheExecutor() async throws {
    let executor = try await respond {
      $0.backend = .axbridge
      $0.marker = "GETTING STARTED"
      $0.tap = .init()
    }
    #expect(executor.tapped == .marker(value: "GETTING STARTED", key: .label, depth: 0))
    #expect(executor.backend == .guest)
  }

  @Test
  func scrollReachesTheExecutor() async throws {
    let executor = try await respond {
      $0.backend = .axbridge
      $0.marker = "Notification Center"
      $0.scroll = .with { $0.direction = .down }
    }
    #expect(executor.scrolled == .marker(value: "Notification Center", key: .label, depth: 0))
    #expect(executor.scrolledDirection == .down)
    #expect(executor.backend == .guest)
  }

  /// A scroll with no target is the common invocation, and the one the frontmost query comes from.
  @Test
  func anUntargetedScrollReachesTheExecutorAsFrontmost() async throws {
    let executor = try await respond {
      $0.backend = .axbridge
      $0.scroll = .with { $0.direction = .down }
    }
    #expect(executor.scrolled == .frontmost)
    #expect(executor.backend == .guest)
  }

  @Test
  func setValueReachesTheExecutor() async throws {
    let executor = try await respond {
      $0.backend = .axbridge
      $0.marker = "Search"
      $0.setValue = .with { $0.value = "hello" }
    }
    #expect(executor.valueSetOn == .marker(value: "Search", key: .label, depth: 0))
    #expect(executor.valueSet == "hello")
    #expect(executor.backend == .guest)
  }

  @Test
  func dragReachesTheExecutor() async throws {
    let executor = try await respond {
      $0.backend = .axbridge
      $0.point = .with { point in
        point.x = 10
        point.y = 20
      }
      $0.drag = .with { drag in
        drag.point = .with { point in
          point.x = 200
          point.y = 20
        }
      }
    }
    #expect(executor.draggedFrom == .point(CGPoint(x: 10, y: 20)))
    #expect(executor.draggedTo == .point(CGPoint(x: 200, y: 20)))
    #expect(executor.backend == .guest)
  }

  /// Wait selected a backend before the others could, through its own deprecated field. A client
  /// older than the request-level one still sends only this, so it has to keep working.
  @Test
  func waitCarriesItsOwnBackendToTheExecutor() async throws {
    let executor = try await respond {
      $0.marker = "Settings"
      $0.wait = .with {
        $0.backend = .axbridge
        $0.timeout = 10
        $0.pollInterval = 0.5
      }
    }
    #expect(executor.backend == .guest)
  }

  @Test
  func waitCarriesTheRequestLevelBackendToTheExecutor() async throws {
    let executor = try await respond {
      $0.backend = .axbridge
      $0.marker = "Settings"
      $0.wait = .with {
        $0.timeout = 10
        $0.pollInterval = 0.5
      }
    }
    #expect(executor.backend == .guest)
  }

  /// A request that names no backend is served by the executor's default, which is what an older
  /// client sends and what keeps its behaviour unchanged.
  @Test
  func anUnaskedBackendReachesTheExecutorAsTheDefault() async throws {
    let executor = try await respond {
      $0.marker = "General"
      $0.tap = .init()
    }
    #expect(executor.backend == .accessibility)
  }
}

extension UIAutomationBackend {
  fileprivate static let guest = UIAutomationBackend(resolvedName: .axBridgeExclusive)
}
