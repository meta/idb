/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import FBSimulatorAX
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift

/// Translates an `accessibility_action` request to a checked `Action`. Rejects shapes no action accepts
/// (a missing target, a drag onto its own source, a negative duration).
enum AccessibilityActionRequestTranslation {

  /// A request that has been checked, with every endpoint and option resolved.
  enum Action: Equatable {
    case wait(query: AccessibilityElementQuery, backend: UIAutomationBackend, timeout: Double, pollInterval: Double)
    case tap(query: AccessibilityElementQuery, backend: UIAutomationBackend, expectedValue: String?, expectedKey: AXSearchableKey)
    case scroll(query: AccessibilityElementQuery, backend: UIAutomationBackend, direction: AccessibilityScrollDirection)
    case setValue(query: AccessibilityElementQuery, backend: UIAutomationBackend, value: String)
    case drag(
      source: AccessibilityElementQuery, destination: AccessibilityElementQuery, backend: UIAutomationBackend,
      options: DragOptions)
  }

  static func action(from request: Idb_AccessibilityActionRequest) throws -> Action {
    let backend = try backend(from: request)
    switch request.action {
    case let .wait(wait):
      guard case .marker = request.target, !request.marker.isEmpty else {
        throw RPCError(code: .invalidArgument, message: "wait requires a nonempty marker")
      }
      guard !request.ignoreCase else {
        throw RPCError(code: .invalidArgument, message: "wait does not support ignore_case")
      }
      guard wait.timeout.isFinite, wait.timeout >= 0, wait.pollInterval.isFinite, wait.pollInterval > 0, wait.pollInterval * 1_000_000_000 < Double(UInt64.max) else {
        throw RPCError(code: .invalidArgument, message: "wait requires a finite nonnegative timeout and a finite positive poll_interval")
      }
      return .wait(
        query: try requiredQuery(from: request, action: "wait"),
        backend: backend,
        timeout: wait.timeout, pollInterval: wait.pollInterval)
    case let .tap(tap):
      return .tap(
        query: try requiredQuery(from: request, action: "tap"),
        backend: backend,
        expectedValue: tap.checkExpectedValue ? tap.expectedValue : nil,
        expectedKey: try searchableKey(from: tap.expectedKey))
    case let .scroll(scroll):
      return .scroll(
        query: try targetedQuery(from: request) ?? .frontmost,
        backend: backend,
        direction: try scrollDirection(from: scroll.direction))
    case let .setValue(setValue):
      return .setValue(
        query: try requiredQuery(from: request, action: "set_value"), backend: backend, value: setValue.value)
    case let .drag(drag):
      return try dragAction(request: request, drag: drag, backend: backend)
    case .none:
      // Also what an action this companion is too old to know reads as: proto3 deserializes an
      // unrecognized oneof member as unset. Say so, rather than reporting an empty request.
      throw RPCError(
        code: .invalidArgument,
        message: "accessibility_action requires an action this companion supports — none was set, "
          + "or the client sent one added after this companion was built")
    }
  }

  static func waitResponse(operation: () async throws -> Void) async throws -> Idb_AccessibilityActionResponse {
    var wait = Idb_AccessibilityActionResponse.WaitResponse()
    do {
      try await operation()
      wait.result = .found
    } catch let error as UIAutomationError {
      guard case let .timedOut(_, _, _, _, diagnostics) = error else {
        throw error
      }
      wait.result = .timedOut
      wait.message = error.localizedDescription
      if let diagnostics {
        wait.diagnostics = .with {
          $0.unmatchedValues = diagnostics.unmatchedValues
          $0.truncated = diagnostics.truncated || diagnostics.readTruncated == true
          if let readTruncated = diagnostics.readTruncated {
            $0.readTruncated = readTruncated
          }
          $0.sampleTruncated = diagnostics.truncated
          $0.readError = diagnostics.readError ?? ""
        }
      }
    }
    return .with {
      $0.waitResult = wait.result
      $0.wait = wait
    }
  }

  // MARK: - Backend

  /// The backend serving the request. `Wait` carries a deprecated backend of its own, read only when
  /// the request-level field is unset, so a client older than that field still selects one for wait.
  private static func backend(from request: Idb_AccessibilityActionRequest) throws -> UIAutomationBackend {
    if case .UNRECOGNIZED = request.backend {
      throw RPCError(code: .invalidArgument, message: "unknown accessibility backend")
    }
    guard case .unspecified = request.backend else {
      return AccessibilityInfoRequestTranslation.backend(from: request.backend)
    }
    guard case let .wait(wait) = request.action else {
      return .accessibility
    }
    if case .UNRECOGNIZED = wait.backend {
      throw RPCError(code: .invalidArgument, message: "unknown wait backend")
    }
    return AccessibilityInfoRequestTranslation.backend(from: wait.backend)
  }

  // MARK: - Drag

  private static func dragAction(
    request: Idb_AccessibilityActionRequest,
    drag: Idb_AccessibilityActionRequest.Drag,
    backend: UIAutomationBackend
  ) throws -> Action {
    guard let source = try targetedQuery(from: request) else {
      throw RPCError(code: .invalidArgument, message: "accessibility_action drag requires a marker or point source")
    }
    guard let destination = try dragDestination(drag, ignoresCase: request.ignoreCase) else {
      throw RPCError(code: .invalidArgument, message: "accessibility_action drag requires a marker or point destination")
    }
    guard source != destination else {
      throw RPCError(code: .invalidArgument, message: "accessibility_action drag source and destination are the same element")
    }
    let options = try dragOptions(drag)
    if case let .point(from) = source, case let .point(to) = destination {
      // Only checkable for two coordinates; a marker endpoint is resolved by the backend. A delta at
      // or above the distance samples the path once, which iOS reads as a flick rather than a drag.
      let distance = hypot(to.x - from.x, to.y - from.y)
      guard options.delta < Double(distance) else {
        throw RPCError(
          code: .invalidArgument,
          message: "accessibility_action drag delta (\(options.delta)) must be smaller than the distance dragged (\(distance))")
      }
    }
    return .drag(source: source, destination: destination, backend: backend, options: options)
  }

  private static func dragDestination(_ drag: Idb_AccessibilityActionRequest.Drag, ignoresCase: Bool) throws -> AccessibilityElementQuery? {
    switch drag.destination {
    case let .marker(marker):
      return .marker(
        value: marker, key: try searchableKey(from: drag.destinationMatchKey), depth: UInt(drag.destinationDepth), ignoresCase: ignoresCase)
    case let .point(point):
      return .point(CGPoint(x: point.x, y: point.y))
    case .none:
      return nil
    }
  }

  /// The wire's zero value means "server default", the same rule the swipe and pinch fields follow —
  /// a proto3 scalar cannot distinguish unset from zero, and none of these are useful at zero.
  private static func dragOptions(_ drag: Idb_AccessibilityActionRequest.Drag) throws -> DragOptions {
    let defaults = DragOptions()
    for (name, value) in [
      ("press_duration", drag.pressDuration), ("duration", drag.duration),
      ("release_duration", drag.releaseDuration), ("delta", drag.delta),
    ] where value < 0 {
      throw RPCError(code: .invalidArgument, message: "accessibility_action drag \(name) must not be negative, got \(value)")
    }
    return DragOptions(
      pressDuration: drag.pressDuration > 0 ? drag.pressDuration : defaults.pressDuration,
      duration: drag.duration > 0 ? drag.duration : defaults.duration,
      releaseDuration: drag.releaseDuration > 0 ? drag.releaseDuration : defaults.releaseDuration,
      delta: drag.delta > 0 ? drag.delta : defaults.delta)
  }

  // MARK: - Targets

  private static func requiredQuery(from request: Idb_AccessibilityActionRequest, action: String) throws -> AccessibilityElementQuery {
    guard let query = try targetedQuery(from: request) else {
      throw RPCError(code: .invalidArgument, message: "accessibility_action \(action) requires a marker or point target")
    }
    return query
  }

  // Returns nil when no target is set, which callers map to the frontmost app
  // (or reject, for actions that require an explicit element).
  private static func targetedQuery(from request: Idb_AccessibilityActionRequest) throws -> AccessibilityElementQuery? {
    switch request.target {
    case let .marker(marker):
      return .marker(
        value: marker, key: try searchableKey(from: request.matchKey), depth: UInt(request.depth), ignoresCase: request.ignoreCase)
    case let .point(point):
      return .point(CGPoint(x: point.x, y: point.y))
    case .none:
      return nil
    }
  }

  private static func scrollDirection(from direction: Idb_AccessibilityActionRequest.Scroll.Direction) throws -> AccessibilityScrollDirection {
    switch direction {
    case .up:
      return .up
    case .down:
      return .down
    case .left:
      return .left
    case .right:
      return .right
    case .visible:
      return .visible
    case .UNRECOGNIZED:
      throw RPCError(code: .invalidArgument, message: "unknown scroll direction")
    }
  }

  private static func searchableKey(from key: Idb_AccessibilityActionRequest.SearchableKey) throws -> AXSearchableKey {
    guard let searchableKey = AXSearchableKey(key) else {
      throw RPCError(code: .invalidArgument, message: "unrecognized accessibility key")
    }
    return searchableKey
  }

}

extension AXSearchableKey {
  /// Nil for a key this companion does not recognize; each request decides what that means.
  init?(_ key: Idb_AccessibilityActionRequest.SearchableKey) {
    switch key {
    case .label:
      self = .label
    case .uniqueID:
      self = .uniqueID
    case .value:
      self = .value
    case .title:
      self = .title
    case .role:
      self = .role
    case .roleDescription:
      self = .roleDescription
    case .subrole:
      self = .subrole
    case .help:
      self = .help
    case .placeholder:
      self = .placeholder
    case .UNRECOGNIZED:
      return nil
    }
  }
}
