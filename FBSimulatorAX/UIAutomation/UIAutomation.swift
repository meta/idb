/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import FBSimulatorBridgeProtocol
import FBSimulatorControl
import Foundation

/// Which guest a `.axBridge` read runs against: a fresh spawn of its own, the simulator's shared one,
/// or a private one held for the caller's lifetime.
public enum AXBridgePersistence: Sendable, Hashable {
  /// A fresh guest spawn per read. Stateless and free to reconstruct per call — for a single one-shot
  /// read.
  case oneShot
  /// A guest on the simulator's well-known socket, shared with any other process reading the same
  /// target. Discoverable, so a read can adopt one somebody else already warmed, and held no longer than
  /// a round trip so it is never taken out from under anyone.
  case shared
  /// A guest of the caller's own, on a socket whose name nobody else knows. Never discovered and never
  /// shared, so the caller may hold it for as long as it likes without denying anyone. For a process
  /// that owns the simulator for its lifetime.
  case exclusive
}

/// Selects the backend a UI-automation element operation runs against.
public enum UIAutomationBackend: Sendable, Equatable {
  /// The host's accessibility translation, sending its translator requests over idb's own connection to
  /// CoreSimulatorBridge, or through CoreSimulator's client when that service cannot be reached.
  case accessibility
  /// The host's accessibility translation, always sending its translator requests through CoreSimulator's
  /// own client.
  case coreSimulatorAccessibility
  /// The guest AX reader: the `SimulatorFrameworkBridge` `accessibility` service spawned in the
  /// simulator. `persistence` picks which guest; `frontmostMethod` is how it resolves the foreground
  /// app; `automationMode` is `true` to assert automation mode, `false` to assert it off, `nil` to
  /// leave the device untouched.
  case axBridge(
    persistence: AXBridgePersistence,
    frontmostMethod: AXBridgeFrontmostMethod,
    automationMode: Bool?
  )
}

public extension UIAutomationBackend {
  /// The backend name reported in the `complete` output document.
  var name: UIAutomationBackendName {
    switch self {
    case .accessibility:
      return .ax
    case .coreSimulatorAccessibility:
      return .axCoreSimulator
    case let .axBridge(persistence, _, _):
      switch persistence {
      case .oneShot:
        return .axBridgeOneShot
      case .shared:
        return .axBridgePersistent
      case .exclusive:
        return .axBridgeExclusive
      }
    }
  }

  /// Builds the resolved backend represented by `name`.
  init(
    resolvedName name: UIAutomationBackendName,
    frontmostMethod: AXBridgeFrontmostMethod = .windowServer,
    automationMode: Bool? = true
  ) {
    switch name {
    case .ax:
      self = .accessibility
    case .axCoreSimulator:
      self = .coreSimulatorAccessibility
    case .axBridgeOneShot:
      self = .axBridge(persistence: .oneShot, frontmostMethod: frontmostMethod, automationMode: automationMode)
    case .axBridgePersistent:
      self = .axBridge(
        persistence: .shared, frontmostMethod: frontmostMethod, automationMode: automationMode)
    case .axBridgeExclusive:
      self = .axBridge(
        persistence: .exclusive, frontmostMethod: frontmostMethod, automationMode: automationMode)
    }
  }
}

/// Options for a `tap`: an optional hold duration and an optional pre-tap value assertion. Both default
/// off, so `TapOptions()` is an instantaneous, unconditional tap and `tap(_ query)` covers the common
/// case without constructing one.
public struct TapOptions: Sendable, Equatable {

  /// A pre-tap value assertion: read `key` on the resolved element and tap only if it equals `value`,
  /// else throw `UIAutomationError.valueMismatch`.
  public struct Assertion: Sendable, Equatable {
    public var key: AXSearchableKey
    public var value: String

    public init(key: AXSearchableKey, value: String) {
      self.key = key
      self.value = value
    }
  }

  /// Requests a long-press; a backend whose press is instantaneous rejects it rather than downgrading to
  /// a tap. `nil` is an instantaneous tap.
  public var duration: TimeInterval?
  /// The pre-tap value assertion, or `nil` to tap unconditionally. See `Assertion`.
  public var assertion: Assertion?

  public init(duration: TimeInterval? = nil, assertion: Assertion? = nil) {
    self.duration = duration
    self.assertion = assertion
  }
}

/// Options for a `drag`: the three phase durations and the sampling interval. Every value defaults to
/// what the gesture uses when a caller does not choose, so `DragOptions()` is the documented drag.
public struct DragOptions: Sendable, Equatable {

  /// The hold at the source before travel starts. This is the phase that makes the gesture a drag
  /// rather than a flick: iOS begins a drag session only once the press clears its long-press
  /// threshold.
  public var pressDuration: TimeInterval
  /// The travel time, spread evenly over the interpolated samples.
  public var duration: TimeInterval
  /// The hold at the destination before the touch lifts, so a drop target can settle.
  public var releaseDuration: TimeInterval
  /// The distance in screen points between interpolated samples.
  public var delta: Double

  public init(
    pressDuration: TimeInterval = 0.5,
    duration: TimeInterval = 0.5,
    releaseDuration: TimeInterval = 0.1,
    delta: Double = SimulatorHIDEvent.defaultSwipeDelta
  ) {
    self.pressDuration = pressDuration
    self.duration = duration
    self.releaseDuration = releaseDuration
    self.delta = delta
  }
}

/// What a drag endpoint names, once the queries that name no single element are refused.
enum DragEndpoint: Equatable {
  case point(CGPoint)
  case marker(value: String, key: AXSearchableKey, depth: UInt)

  /// The verb named in the refusal.
  static let operation = "A drag endpoint"

  /// `.frontmost` and `.application` name a tree. Resolving one would drag from the middle of the
  /// application's own rectangle, which is somewhere the caller never named.
  init(_ query: AccessibilityElementQuery, backend: UIAutomationBackend) throws {
    switch query {
    case let .point(point):
      self = .point(point)
    case let .marker(value, key, depth, _):
      self = .marker(value: value, key: key, depth: depth)
    case .frontmost, .application:
      throw UIAutomationError.pointOrMarkerRequired(backend: backend, operation: Self.operation)
    }
  }
}

/// The converged UI-automation surface: element reads and element-targeted
/// actions, expressed once against an `AccessibilityElementQuery` target and run by the selected
/// backend. `Simulator.uiAutomation(backend:)` vends the backend that implements it.
public protocol UIAutomation: Sendable {

  /// Reads the element(s) named by `query` and serializes them to the shared accessibility schema.
  /// `.point`/`.marker` yield a single element; `.frontmost` yields the whole tree.
  func describe(
    _ query: AccessibilityElementQuery,
    options: AccessibilityRequestOptions
  ) async throws -> AccessibilityElementsResponse

  /// Reads the element at `point` — a targeted hit-test — serialized to the shared schema, or `nil`
  /// when no element sits at the point. Unlike `describe(.point:)`, which throws for an empty point,
  /// `hitTest` returns `nil` so a caller (e.g. a streaming hit-test around a tap) can tell empty space
  /// from a reader failure, which still throws.
  func hitTest(
    at point: CGPoint,
    options: AccessibilityRequestOptions
  ) async throws -> AccessibilityElementsResponse?

  /// Taps the element named by `query`. `.point` taps the coordinate; `.marker` taps the element's
  /// centre. `options.assertion` checks the element's value for its key before tapping.
  /// `options.duration` asks for a long-press; a backend whose press is instantaneous rejects it rather
  /// than downgrading to a tap.
  func tap(
    _ query: AccessibilityElementQuery,
    options: TapOptions
  ) async throws

  /// Performs the named custom accessibility action advertised by the element.
  func performCustomAction(
    named name: String,
    on query: AccessibilityElementQuery
  ) async throws

  /// Sets `value` on the element named by `query`. `.point`/`.marker` targets only.
  func setValue(
    _ value: String,
    for query: AccessibilityElementQuery
  ) async throws

  /// Polls until the element named by a `.marker` query appears, or throws when `timeout` elapses.
  /// `.point`/`.frontmost` are not waitable.
  func wait(
    _ query: AccessibilityElementQuery,
    timeout: TimeInterval,
    pollInterval: TimeInterval
  ) async throws

  /// Scrolls the element named by `query` in `direction`.
  func scroll(
    _ query: AccessibilityElementQuery,
    direction: AccessibilityScrollDirection
  ) async throws

  /// The frame (in screen points) of the element named by `query`. A geometry-only read for callers
  /// that need an element's position or size without a full serialization.
  func frame(_ query: AccessibilityElementQuery) async throws -> CGRect

  /// Presses `source`, drags to `destination`, and releases. `.point` endpoints are the coordinate
  /// itself; a `.marker` endpoint is the centre of the element it names. `.frontmost`/`.application`
  /// are not endpoints.
  ///
  /// Delivered as synthesized input on every backend, because no accessibility action expresses a
  /// drag. The backends differ only in how a marker endpoint is resolved and which transport carries
  /// the events.
  func drag(
    from source: AccessibilityElementQuery,
    to destination: AccessibilityElementQuery,
    options: DragOptions
  ) async throws

  /// Streams the quiescence of an application: `.application` names one by pid, and `.frontmost`
  /// follows whichever application is frontmost. `.point`/`.marker` name no application.
  ///
  /// Runs until the consumer stops iterating, the named application exits, or the stream fails. A
  /// backend that cannot measure quiescence throws `UIAutomationError.operationUnsupported`.
  func quiescence(
    _ query: AccessibilityElementQuery,
    parameters: QuiescenceParameters
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, any Error>
}

public extension UIAutomation {

  /// Existing conformers that do not implement custom actions decline the operation.
  func performCustomAction(named name: String, on query: AccessibilityElementQuery) async throws {
    throw UIAutomationError.operationUnsupported(backend: .accessibility, operation: "Custom actions")
  }

  /// Taps the element named by `query` with no hold duration and no value assertion.
  func tap(_ query: AccessibilityElementQuery) async throws {
    try await tap(query, options: TapOptions())
  }

  /// Drags with the default phase durations and sampling interval.
  func drag(from source: AccessibilityElementQuery, to destination: AccessibilityElementQuery) async throws {
    try await drag(from: source, to: destination, options: DragOptions())
  }

  /// What a scroll acts on, given what the caller named.
  ///
  /// A scroll is not an action on the element it names: iOS models it as `accessibilityScroll:`, which
  /// UIKit bubbles *up* from that element to the nearest scrollable container. An application element
  /// has no container above it, so scrolling one can never do anything -- which is why an untargeted
  /// scroll aims at the centre of the application instead, where its scroll view is.
  func scrollTarget(
    for query: AccessibilityElementQuery,
    backend: UIAutomationBackend
  ) async throws -> AccessibilityElementQuery {
    guard case .frontmost = query else {
      return query
    }
    let application = try await frame(.frontmost)
    guard application.width > 0, application.height > 0 else {
      throw UIAutomationError.frameUnavailable(backend: backend, query: query)
    }
    return .point(CGPoint(x: application.midX, y: application.midY))
  }
}

public extension AccessibilityElementsResponse {
  /// `default`/`nested` are written by `JSONSerialization` because their byte form is a contract
  /// consumers parse, and it differs from `JSONEncoder` on non-integral doubles (17 significant digits
  /// vs the shortest round-trip form). `complete` is encoded from its `Encodable` model.
  func formattedOutputJSON(format: AccessibilityOutputFormat) throws -> Data {
    switch format {
    case .default, .nested:
      return try JSONSerialization.data(
        withJSONObject: ["elements": elements.legacyFoundationObject], options: .sortedKeys
      )
    case .complete:
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      return try encoder.encode(document)
    }
  }

  /// The encoding of a hit-test that found nothing — a successful empty result, distinct from a failed
  /// read. `default` and `nested` emit `{"elements":null}`; `complete` emits the ordinary document with
  /// no elements, so a consumer parses one shape whether or not the point was occupied.
  static func emptyOutputJSON(
    format: AccessibilityOutputFormat,
    backend: UIAutomationBackend,
    target: AccessibilityTargetDescriptor
  ) throws -> Data {
    let response = AccessibilityElementsResponse(
      elements: .empty, backend: backend.name, target: target
    )
    return try response.formattedOutputJSON(format: format)
  }
}

public extension Simulator {

  /// Delivers one composed gesture over HID, which drains the transport once for the whole gesture
  /// rather than once per primitive event.
  internal func sendHIDGesture(_ event: SimulatorHIDEvent) async throws {
    try await hid.connect().send(event: event, logger: logger)
  }
}

extension AccessibilityRequestOptions {
  /// The client for operations that take no request options — actions, frames, waits and the reads that
  /// resolve a write's target: the one a default read resolves to.
  static var unconfiguredClientType: AXClientType {
    AccessibilityRequestOptions().resolvedClientType
  }
}
