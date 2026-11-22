/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
@testable import FBSimulatorAX
import FBSimulatorBridgeProtocol
@testable import FBSimulatorControl
import Foundation
import Testing

/// Coverage for what a drag will accept as an endpoint. Every backend classifies its two endpoints
/// through `DragEndpoint` before resolving either, so this is the one place a drag decides which
/// queries name something to press and which do not.
///
/// The dangerous direction is a query that stops being refused: `.frontmost` resolves to the middle of
/// the application's own rectangle, so accepting one would drag from somewhere the caller never named
/// and report success.
@Suite
struct DragEndpointTests {

  private static let backends: [UIAutomationBackend] = [
    .accessibility,
    .axBridge(persistence: .oneShot, frontmostMethod: .windowServer, automationMode: true),
  ]

  @Test
  func aCoordinateIsItsOwnEndpoint() throws {
    let point = CGPoint(x: 10, y: 20)
    for backend in Self.backends {
      #expect(try DragEndpoint(.point(point), backend: backend) == .point(point), "\(backend)")
    }
  }

  // The key and depth travel with the marker rather than being defaulted here: the backend that
  // resolves it searches on the caller's key, and a silently dropped key matches on the label instead.
  @Test
  func aMarkerCarriesTheKeyAndDepthItWasNamedWith() throws {
    let query = AccessibilityElementQuery.marker(value: "Album", key: .uniqueID, depth: 5)
    for backend in Self.backends {
      #expect(
        try DragEndpoint(query, backend: backend) == .marker(value: "Album", key: .uniqueID, depth: 5),
        "\(backend)")
    }
  }

  @Test
  func wholeTreeQueriesAreNotEndpoints() {
    for backend in Self.backends {
      for query in [AccessibilityElementQuery.frontmost, .application(pid: 99)] {
        do {
          _ = try DragEndpoint(query, backend: backend)
          Issue.record("\(query) must not be accepted as a drag endpoint by \(backend)")
        } catch let error as UIAutomationError {
          guard case let .pointOrMarkerRequired(thrownBackend, operation) = error else {
            Issue.record("expected pointOrMarkerRequired, got \(error)")
            return
          }
          #expect(thrownBackend == backend, "the refusal must name the backend that refused")
          #expect(operation == "A drag endpoint", "the refusal must name the verb")
        } catch {
          Issue.record("expected an UIAutomationError, got \(error)")
        }
      }
    }
  }
}
