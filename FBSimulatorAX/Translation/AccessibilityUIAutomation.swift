/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import FBSimulatorControl
import Foundation

/// The `UIAutomation` backend over the host's accessibility translation, sending its translator requests
/// over `transport`. Resolves a query to an `AccessibilityElement` via the accessibility primitives and
/// serializes it through the shared schema.
///
// SAFETY: holds only an immutable reference to the target; each verb resolves and closes its own
// element handle, so no mutable state is shared across calls, and the target's accessibility request
// path is async IPC already safe under concurrent use. `Sendable` lets a caller hold one reader.
// patternlint-disable-next-line unchecked-sendable
final class AccessibilityUIAutomation: UIAutomation, @unchecked Sendable {

  private let simulator: Simulator
  private let transport: AXTranslationTransportKind

  private var operations: SimulatorAccessibilityCommands { simulator.accessibility(through: transport) }

  private var backend: UIAutomationBackend {
    switch transport {
    case .bridge: .accessibility
    case .coreSimulator: .coreSimulatorAccessibility
    }
  }

  init(simulator: Simulator, transport: AXTranslationTransportKind) {
    self.simulator = simulator
    self.transport = transport
  }

  func describe(
    _ query: AccessibilityElementQuery,
    options: AccessibilityRequestOptions
  ) async throws -> AccessibilityElementsResponse {
    try await translatingBackendErrors(query) {
      let element = try await operations.resolveElement(
        for: query, clientType: options.resolvedClientType, timing: options.timing, stallObserver: options.stallObserver)
      defer { element.close() }
      let response = try await element.serialize(with: options)
        .withProvenance(backend: backend.name, target: query.targetDescriptor)
        .withClient(options.clientType.map(AccessibilityClientReport.init))
      if response.screen?.display != nil { return response }
      // A point or marker resolves one element and is then serialized through the frontmost path, which
      // reads screen bounds off whatever element it is handed. For those queries that element is the
      // match rather than the application root, so the bounds it reports describe the match — they have
      // to be discarded, and replaced where the read does know better.
      switch query {
      case .point:
        return response.replacingScreen(nil)
      case .marker:
        return response.replacingScreen(element.rootBounds.flatMap(AccessibilityScreenInfo.init(bounds:)))
      case .frontmost, .application:
        return response
      }
    }
  }

  /// Re-raises the accessibility stack's "element not found" as the backend-neutral
  /// `UIAutomationError`, so a caller holding `any UIAutomation` can catch it without knowing
  /// which backend it holds. Every other accessibility failure is transport-specific and passes
  /// through untouched.
  private func translatingBackendErrors<T>(
    _ query: AccessibilityElementQuery,
    _ body: () async throws -> T
  ) async throws -> T {
    do {
      return try await body()
    } catch let error as AccessibilityError {
      guard case let .elementNotFound(key, value, _) = error else { throw error }
      throw UIAutomationError.elementNotFound(backend: backend, key: key, value: value)
    }
  }

  func hitTest(
    at point: CGPoint,
    options: AccessibilityRequestOptions
  ) async throws -> AccessibilityElementsResponse? {
    do {
      let element = try await operations.resolveElement(
        for: .point(point), clientType: options.resolvedClientType, timing: options.timing,
        stallObserver: options.stallObserver)
      defer { element.close() }
      return try await element.serialize(with: options)
        .withProvenance(backend: backend.name, target: .point(point))
        .withClient(options.clientType.map(AccessibilityClientReport.init))
    } catch let error as AccessibilityError {
      // A point that resolves to no element is a valid empty hit-test result, not a failure.
      if case .elementNotFound = error { return nil }
      throw error
    }
  }

  func tap(
    _ query: AccessibilityElementQuery,
    options: TapOptions
  ) async throws {
    // AXPress is instantaneous with nowhere to put a hold; reject `duration` rather than silently
    // downgrading a long-press to a tap.
    guard options.duration == nil else {
      throw UIAutomationError.operationUnsupported(backend: backend, operation: "A tap with a hold duration")
    }
    try await translatingBackendErrors(query) {
      let element = try await operations.resolveElement(for: query, clientType: AccessibilityRequestOptions.unconfiguredClientType)
      defer { element.close() }
      if let assertion = options.assertion {
        let actual = try await element.stringValue(forSearchableKey: assertion.key)
        guard actual == assertion.value else {
          throw UIAutomationError.valueMismatch(
            backend: backend, key: assertion.key.rawValue, expected: assertion.value, actual: actual
          )
        }
      }
      try await element.tap()
    }
  }

  func performCustomAction(named name: String, on query: AccessibilityElementQuery) async throws {
    try await translatingBackendErrors(query) {
      let element: AccessibilityElement
      switch query {
      case let .marker(value, key, depth, ignoresCase):
        let root = try await operations.resolveElement(for: .frontmost, clientType: AccessibilityRequestOptions.unconfiguredClientType)
        element = try await root.findElement(
          withValue: value,
          forKey: key,
          depth: depth,
          ignoresCase: ignoresCase,
          matchExactly: true
        )
      case .point:
        element = try await operations.resolveElement(for: query, clientType: AccessibilityRequestOptions.unconfiguredClientType)
      case .frontmost, .application:
        throw UIAutomationError.pointOrMarkerRequired(
          backend: backend,
          operation: "A custom action target"
        )
      }
      defer { element.close() }
      try await element.performCustomAction(named: name)
    }
  }

  func setValue(_ value: String, for query: AccessibilityElementQuery) async throws {
    try await translatingBackendErrors(query) {
      let element = try await operations.resolveElement(for: query, clientType: AccessibilityRequestOptions.unconfiguredClientType)
      defer { element.close() }
      try await element.setValue(value)
    }
  }

  func wait(
    _ query: AccessibilityElementQuery,
    timeout: TimeInterval,
    pollInterval: TimeInterval
  ) async throws {
    try await UIAutomationPolling.waitForMarker(
      query, backend: backend, timeout: timeout, pollInterval: pollInterval
    ) { markerValue, key, depth in
      let root = try await operations.resolveElement(for: .frontmost, clientType: AccessibilityRequestOptions.unconfiguredClientType)
      defer { root.close() }
      let result = try await root.searchElement(withValue: markerValue, forKey: key, depth: depth)
      result.match?.close()
      return result.map { _ in true }
    }
  }

  func scroll(_ query: AccessibilityElementQuery, direction: AccessibilityScrollDirection) async throws {
    let query = try await scrollTarget(for: query, backend: backend)
    try await translatingBackendErrors(query) {
      let element = try await operations.resolveElement(for: query, clientType: AccessibilityRequestOptions.unconfiguredClientType)
      defer { element.close() }
      try await element.scroll(with: direction)
    }
  }

  func frame(_ query: AccessibilityElementQuery) async throws -> CGRect {
    try await translatingBackendErrors(query) {
      let element = try await operations.resolveElement(for: query, clientType: AccessibilityRequestOptions.unconfiguredClientType)
      defer { element.close() }
      return try await element.frame()
    }
  }

  /// Synthesized over HID: there is no accessibility action for a drag.
  func drag(
    from source: AccessibilityElementQuery,
    to destination: AccessibilityElementQuery,
    options: DragOptions
  ) async throws {
    let start = try await endpoint(source)
    let end = try await endpoint(destination)
    try await simulator.sendHIDGesture(
      .drag(
        Double(start.x), yStart: Double(start.y), xEnd: Double(end.x), yEnd: Double(end.y),
        delta: options.delta, pressDuration: options.pressDuration, duration: options.duration,
        releaseDuration: options.releaseDuration
      )
    )
  }

  /// The screen point a drag endpoint names: a coordinate is itself, a marker is the centre of the
  /// element's frame.
  private func endpoint(_ query: AccessibilityElementQuery) async throws -> CGPoint {
    switch try DragEndpoint(query, backend: backend) {
    case let .point(point):
      return point
    case .marker:
      let frame = try await frame(query)
      return CGPoint(x: frame.midX, y: frame.midY)
    }
  }

  /// CoreSimulator's accessibility translation has no channel for the runtime's idle notifications.
  func quiescence(
    _ query: AccessibilityElementQuery,
    parameters: QuiescenceParameters
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, any Error> {
    throw UIAutomationError.operationUnsupported(backend: backend, operation: "Quiescence")
  }
}
