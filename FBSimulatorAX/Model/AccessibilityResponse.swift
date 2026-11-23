/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorBridgeProtocol
import Foundation

/// Where a translator-backed read spent its time.
///
/// Disjoint from `AXBridgeProfile` because the backends measure different phases. Their common fields
/// use the same names so callers can compare backend performance without flattening the two models.
public struct AccessibilityProfilingData: Sendable, Equatable, Encodable {

  // MARK: - The core, spelled identically in every backend's profile

  /// Elements in the serialized read.
  public let elementCount: Int64
  /// Wall time for the whole read: the number a caller waited.
  public let totalDuration: CFAbsoluteTime
  /// Getting into a position to read at all — the translation object, and the platform element made
  /// from it.
  public let acquireDuration: CFAbsoluteTime
  /// Pulling the tree out of the application. For this backend that is the walk's XPC wait: attributes are
  /// fetched one round trip at a time, and the waiting is the pulling.
  public let readDuration: CFAbsoluteTime
  /// Turning what was read into what the caller asked for — the walk's time less what it spent waiting.
  public let serializeDuration: CFAbsoluteTime

  // MARK: - What only a translator-backed read has

  /// The number of attribute fetches made on accessibility elements. Each
  /// property access (accessibilityLabel, accessibilityFrame, etc.) counts as one.
  public let attributeFetchCount: Int64

  /// The number of XPC calls made to the simulator's accessibility service.
  public let xpcCallCount: Int64

  /// The time spent in performWithTranslator (getting the translation object). A component of
  /// `acquireDuration`.
  public let translationDuration: CFAbsoluteTime

  /// The time spent converting the translation object to a platform element. The other component of
  /// `acquireDuration`.
  public let elementConversionDuration: CFAbsoluteTime

  /// The total time spent in XPC calls, across the whole read. Larger than `readDuration` by whatever
  /// acquisition itself spent on XPC, which is reported there as wall time instead.
  public let totalXPCDuration: CFAbsoluteTime

  /// The set of keys that were fetched during serialization.
  public let fetchedKeys: Set<String>

  public init(
    elementCount: Int64,
    totalDuration: CFAbsoluteTime,
    acquireDuration: CFAbsoluteTime,
    readDuration: CFAbsoluteTime,
    serializeDuration: CFAbsoluteTime,
    attributeFetchCount: Int64,
    xpcCallCount: Int64,
    translationDuration: CFAbsoluteTime,
    elementConversionDuration: CFAbsoluteTime,
    totalXPCDuration: CFAbsoluteTime,
    fetchedKeys: Set<String>
  ) {
    self.elementCount = elementCount
    self.totalDuration = totalDuration
    self.acquireDuration = acquireDuration
    self.readDuration = readDuration
    self.serializeDuration = serializeDuration
    self.attributeFetchCount = attributeFetchCount
    self.xpcCallCount = xpcCallCount
    self.translationDuration = translationDuration
    self.elementConversionDuration = elementConversionDuration
    self.totalXPCDuration = totalXPCDuration
    self.fetchedKeys = fetchedKeys
  }

  enum CodingKeys: String, CodingKey {
    case elementCount = "element_count"
    case totalDurationMs = "total_duration_ms"
    case acquireDurationMs = "acquire_duration_ms"
    case readDurationMs = "read_duration_ms"
    case serializeDurationMs = "serialize_duration_ms"
    case attributeFetchCount = "attribute_fetch_count"
    case xpcCallCount = "xpc_call_count"
    case translationDurationMs = "translation_duration_ms"
    case elementConversionDurationMs = "element_conversion_duration_ms"
    case totalXpcDurationMs = "total_xpc_duration_ms"
  }

  /// `fetchedKeys` is a diagnostic, not part of the reported profile, so it is not encoded.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(elementCount, forKey: .elementCount)
    try container.encode(totalDuration * 1000, forKey: .totalDurationMs)
    try container.encode(acquireDuration * 1000, forKey: .acquireDurationMs)
    try container.encode(readDuration * 1000, forKey: .readDurationMs)
    try container.encode(serializeDuration * 1000, forKey: .serializeDurationMs)
    try container.encode(attributeFetchCount, forKey: .attributeFetchCount)
    try container.encode(xpcCallCount, forKey: .xpcCallCount)
    try container.encode(translationDuration * 1000, forKey: .translationDurationMs)
    try container.encode(elementConversionDuration * 1000, forKey: .elementConversionDurationMs)
    try container.encode(totalXPCDuration * 1000, forKey: .totalXpcDurationMs)
  }
}

extension AccessibilityProfilingData: CustomStringConvertible {
  public var description: String {
    String(
      format: "<AccessibilityProfilingData: elements=%lld, total=%.2fms, acquire=%.2fms, read=%.2fms, serialize=%.2fms>",
      elementCount,
      totalDuration * 1000,
      acquireDuration * 1000,
      readDuration * 1000,
      serializeDuration * 1000
    )
  }
}

/// A fullscreen modal / alert over the read target, carried on the SimulatorFrameworkBridge ->
/// FBSimulatorControl wire. Surfaced only by the `complete` format; the legacy envelope stays
/// byte-stable.
public struct AccessibilityModalInfo: Sendable, Equatable, Encodable {

  /// Who owns the modal: the system shell (SpringBoard — a system/permission alert) or the app itself
  /// (an in-app `UIAlertController`).
  public enum Kind: String, Sendable, Encodable {
    case system
    case app
  }

  public let kind: Kind

  /// The concrete accessibility element class of the alert, e.g. `SBAlertItemWindow` (system) or
  /// `_UIAlertControllerPhoneTVMacView` (UIKit alert).
  public let elementType: String

  /// The alert's title / primary label, when the guest could read one.
  public let label: String?

  public init(kind: Kind, elementType: String, label: String?) {
    self.kind = kind
    self.elementType = elementType
    self.label = label
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case elementType = "element_type"
    case label
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(elementType, forKey: .elementType)
    try container.encode(label, forKey: .label)
  }
}

extension AccessibilityModalInfo {
  /// The modal as the guest described it on the wire.
  public init(_ modal: BridgeAXModal) {
    let kind: Kind =
      switch modal.kind {
      case .system: .system
      case .app: .app
      }
    self.init(kind: kind, elementType: modal.elementType, label: modal.label)
  }
}

/// Response object containing accessibility elements and optional profiling data.
public struct AccessibilityElementsResponse: Sendable {

  /// The accessibility elements: an object (single element) or an array (flat/nested tree).
  public let elements: AccessibilityElementPayload

  /// Where the read spent its time, when the backend measured it. `.translator` and `.guestBridge`
  /// measure disjoint phases; `backend` says which to expect.
  public let profilingData: AccessibilityProfile?

  /// How much of the screen the read's element frames cover, or `nil` when coverage was not requested.
  public let coverage: AccessibilityCoverage?

  /// A fullscreen modal / alert over the read target, when detected. Emitted only by the `complete`
  /// document; the legacy envelope is byte-stable and must not gain it.
  public let modal: AccessibilityModalInfo?

  /// Whether the read's tree walk was cut short by a depth or node bound, so the elements are a
  /// partial view. Only the `complete` document surfaces this.
  public private(set) var truncated: Bool

  /// The bounds the element frames are relative to, when the read knows them.
  public private(set) var screen: AccessibilityScreenInfo?

  /// Which backend produced the read.
  public private(set) var backend: UIAutomationBackendName?

  /// What the read was asked for.
  public private(set) var target: AccessibilityTargetDescriptor?

  /// The device's accessibility automation mode for this read, when the backend reported it.
  public let automation: AccessibilityAutomationState?

  /// What narrowed the read and how much survived, for a read that could narrow. Nil for the
  /// single-element reads, which select an element rather than narrow a list.
  public private(set) var narrowing: AccessibilityNarrowing?

  /// The client the read's translator requests claimed to come from, when the read named one.
  public private(set) var client: AccessibilityClientReport?

  /// How a translator-backed read went, whether or not the caller asked for a profile. Never encoded:
  /// it is for the reader's own telemetry, not the document.
  public let translatorMetrics: AccessibilityTranslatorReadMetrics?

  public init(
    elements: AccessibilityElementPayload,
    profilingData: AccessibilityProfile? = nil,
    coverage: AccessibilityCoverage? = nil,
    modal: AccessibilityModalInfo? = nil,
    truncated: Bool = false,
    screen: AccessibilityScreenInfo? = nil,
    backend: UIAutomationBackendName? = nil,
    target: AccessibilityTargetDescriptor? = nil,
    automation: AccessibilityAutomationState? = nil,
    narrowing: AccessibilityNarrowing? = nil,
    client: AccessibilityClientReport? = nil,
    translatorMetrics: AccessibilityTranslatorReadMetrics? = nil
  ) {
    self.elements = elements
    self.profilingData = profilingData
    self.coverage = coverage
    self.modal = modal
    self.truncated = truncated
    self.screen = screen
    self.backend = backend
    self.target = target
    self.automation = automation
    self.narrowing = narrowing
    self.client = client
    self.translatorMetrics = translatorMetrics
  }

  /// A copy carrying the read's provenance; a `nil` argument leaves the existing value in place.
  public func withProvenance(
    backend: UIAutomationBackendName? = nil,
    target: AccessibilityTargetDescriptor? = nil,
    screen: AccessibilityScreenInfo? = nil,
    truncated: Bool? = nil
  ) -> AccessibilityElementsResponse {
    var copy = self
    if let truncated { copy.truncated = truncated }
    if let screen { copy.screen = screen }
    if let backend { copy.backend = backend }
    if let target { copy.target = target }
    return copy
  }

  /// A copy reporting the client the read named; nil leaves the read reporting none.
  public func withClient(_ client: AccessibilityClientReport?) -> AccessibilityElementsResponse {
    var copy = self
    copy.client = client
    return copy
  }

  /// A copy reporting what narrowed the read.
  public func withNarrowing(_ narrowing: AccessibilityNarrowing) -> AccessibilityElementsResponse {
    var copy = self
    copy.narrowing = narrowing
    return copy
  }

  /// A copy whose screen bounds are replaced, including with `nil` when a read has no screen context.
  public func replacingScreen(_ screen: AccessibilityScreenInfo?) -> AccessibilityElementsResponse {
    var copy = self
    copy.screen = screen
    return copy
  }

  /// The `complete` output format for this read.
  public var document: AccessibilityDocument {
    let reported = elements.elements.map { $0.reportingChildren() }
    return AccessibilityDocument(
      elements: reported,
      modal: modal,
      truncated: truncated,
      screen: screen,
      backend: backend,
      target: target,
      profile: profilingData,
      coverage: coverage,
      interaction: AccessibilityInteractionSummary(elements: reported),
      frames: AccessibilityFrameSummary(elements: reported),
      automation: automation,
      narrowing: narrowing,
      client: client
    )
  }

}

extension AccessibilityElementsResponse: CustomStringConvertible {
  public var description: String {
    "<AccessibilityElementsResponse: elements=\(Swift.type(of: elements)), profiling=\(String(describing: profilingData)), coverage=\(String(describing: coverage)), modal=\(String(describing: modal))>"
  }
}

/// The cost of one translator-backed read, collected on every read rather than only a profiled one.
public struct AccessibilityTranslatorReadMetrics: Sendable, Equatable {
  public let elementCount: Int64
  /// Round trips to the simulator's accessibility service, acquisition included.
  public let roundTrips: Int64
  public let readDuration: CFAbsoluteTime
  public let totalDuration: CFAbsoluteTime
  public let transport: AXTranslationTransportKind
  /// Resolving the root, before the walk.
  public let acquireDuration: CFAbsoluteTime
  /// Checking that SpringBoard answers for a frontmost root; zero for any other read.
  public let springBoardCheckDuration: CFAbsoluteTime
  /// Requests made before the walk: resolving the root and checking it.
  public let acquireRoundTrips: Int64
  /// The longest request the read made.
  public let slowestRequest: AccessibilityTranslatorRequestTiming?
  /// Requests sent while one abandoned earlier, by this read or another, was still unanswered.
  public let requestsBehindAbandoned: Int64
  /// The time the stall probe held the read's thread: watching its requests, and reading the target and the host
  /// when one was slow. Nil when no request was watched.
  public let probeDuration: CFAbsoluteTime?

  public init(
    elementCount: Int64,
    roundTrips: Int64,
    readDuration: CFAbsoluteTime,
    totalDuration: CFAbsoluteTime,
    transport: AXTranslationTransportKind,
    acquireDuration: CFAbsoluteTime = 0,
    springBoardCheckDuration: CFAbsoluteTime = 0,
    acquireRoundTrips: Int64 = 0,
    slowestRequest: AccessibilityTranslatorRequestTiming? = nil,
    requestsBehindAbandoned: Int64 = 0,
    probeDuration: CFAbsoluteTime? = nil
  ) {
    self.elementCount = elementCount
    self.roundTrips = roundTrips
    self.readDuration = readDuration
    self.totalDuration = totalDuration
    self.transport = transport
    self.acquireDuration = acquireDuration
    self.springBoardCheckDuration = springBoardCheckDuration
    self.acquireRoundTrips = acquireRoundTrips
    self.slowestRequest = slowestRequest
    self.requestsBehindAbandoned = requestsBehindAbandoned
    self.probeDuration = probeDuration
  }
}

/// How an accessibility read ended, as telemetry spells it.
public enum AccessibilityReadOutcome: String, Sendable {
  /// The read returned, every request answered.
  case complete
  /// The read stopped at a request the service did not answer within the element timeout.
  case abortedUnanswered = "aborted_unanswered"
  /// The read stopped when the query ran out of its timeout.
  case abortedDeadline = "aborted_deadline"
  /// The read stopped because whoever awaited it went away.
  case cancelled

  /// How a read that failed with `error` ended, when the failure is one of the read's own timing.
  public init?(failure error: any Error) {
    switch error {
    case AccessibilityError.serviceNotAnswering(.request, _, _):
      self = .abortedUnanswered
    case AccessibilityError.serviceNotAnswering(.query, _, _):
      self = .abortedDeadline
    case is CancellationError:
      self = .cancelled
    default:
      return nil
    }
  }
}
