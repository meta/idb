/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import Foundation

/// The canonical name of the backend that served a UI-automation request.
public enum UIAutomationBackendName: String, Sendable, Encodable, CaseIterable {
  case ax
  case axCoreSimulator = "ax-coresimulator"
  case axBridgeOneShot = "axbridge-oneshot"
  case axBridgePersistent = "axbridge-persistent"
  case axBridgeExclusive = "axbridge-exclusive"
}

/// The space an element frame is expressed in.
public enum AccessibilityCoordinateSpace: String, Sendable, Encodable {
  case screen
}

/// An element's on-screen rectangle. An edge is `nil` when non-finite: an off-screen element can
/// report one, and JSON cannot represent it.
public struct AccessibilityFrame: Sendable, Equatable, Encodable {

  public let x: Double?
  public let y: Double?
  public let width: Double?
  public let height: Double?

  public init(x: Double?, y: Double?, width: Double?, height: Double?) {
    self.x = Self.finite(x)
    self.y = Self.finite(y)
    self.width = Self.finite(width)
    self.height = Self.finite(height)
  }

  public init(_ rect: CGRect) {
    self.init(
      x: Double(rect.origin.x), y: Double(rect.origin.y),
      width: Double(rect.size.width), height: Double(rect.size.height)
    )
  }

  private static func finite(_ value: Double?) -> Double? {
    guard let value, value.isFinite else {
      return nil
    }
    return value
  }

  enum CodingKeys: String, CodingKey {
    case x
    case y
    case width
    case height
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(x, forKey: .x)
    try container.encode(y, forKey: .y)
    try container.encode(width, forKey: .width)
    try container.encode(height, forKey: .height)
  }
}

public extension AccessibilityFrame {
  /// The rectangle this frame describes, or `nil` when any edge was not representable.
  var rect: CGRect? {
    guard let x, let y, let width, let height else {
      return nil
    }
    return CGRect(x: x, y: y, width: width, height: height)
  }
}

/// The display configuration used to read display-relative accessibility coordinates.
public struct AccessibilityDisplayInfo: Sendable, Equatable, Encodable {
  public let uniqueID: String?
  public let scale: Double
  public let rotation: Int

  public init?(uniqueID: String?, scale: Double, rotation: Int) {
    guard scale.isFinite, scale > 0, [0, 90, 180, 270].contains(rotation),
      uniqueID.map({ !$0.isEmpty }) ?? true
    else { return nil }
    self.uniqueID = uniqueID
    self.scale = scale
    self.rotation = rotation
  }

  enum CodingKeys: String, CodingKey {
    case uniqueID = "unique_id"
    case scale
    case rotation
  }
}

/// The bounds a read's frames are relative to.
public struct AccessibilityScreenInfo: Sendable, Equatable, Encodable {

  public let width: Double
  public let height: Double
  public let coordinateSpace: AccessibilityCoordinateSpace
  public let display: AccessibilityDisplayInfo?

  /// Nil for a non-finite bound: JSON cannot represent it, and encoding it would fail the whole read.
  public init?(width: Double, height: Double, coordinateSpace: AccessibilityCoordinateSpace = .screen, display: AccessibilityDisplayInfo? = nil) {
    guard width.isFinite, height.isFinite else {
      return nil
    }
    self.width = width
    self.height = height
    self.coordinateSpace = coordinateSpace
    self.display = display
  }

  enum CodingKeys: String, CodingKey {
    case width
    case height
    case coordinateSpace = "coordinate_space"
    case display
  }
}

/// What a read was asked for, which is how a consumer tells one describe verb from another.
public struct AccessibilityTargetDescriptor: Sendable, Equatable, Encodable {

  public enum Kind: String, Sendable, Encodable {
    case frontmost
    case application
    case point
    case marker
  }

  public let kind: Kind
  /// The process the read was anchored to, for `.application`.
  public let pid: Int32?
  /// The coordinate hit-tested, for `.point`.
  public let x: Double?
  public let y: Double?
  /// The searched-for substring, for `.marker`.
  public let value: String?
  /// The element key the marker was matched against, for `.marker`.
  public let matchKey: String?

  private init(
    kind: Kind,
    pid: Int32? = nil,
    x: Double? = nil,
    y: Double? = nil,
    value: String? = nil,
    matchKey: String? = nil
  ) {
    self.kind = kind
    self.pid = pid
    self.x = x
    self.y = y
    self.value = value
    self.matchKey = matchKey
  }

  public static let frontmost = AccessibilityTargetDescriptor(kind: .frontmost)

  public static func application(pid: pid_t) -> AccessibilityTargetDescriptor {
    AccessibilityTargetDescriptor(kind: .application, pid: Int32(pid))
  }

  public static func point(_ point: CGPoint) -> AccessibilityTargetDescriptor {
    let x = Double(point.x)
    let y = Double(point.y)
    return AccessibilityTargetDescriptor(kind: .point, x: x.isFinite ? x : nil, y: y.isFinite ? y : nil)
  }

  public static func marker(value: String, matchKey: String) -> AccessibilityTargetDescriptor {
    AccessibilityTargetDescriptor(kind: .marker, value: value, matchKey: matchKey)
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case pid
    case x
    case y
    case value
    case matchKey = "match_key"
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(pid, forKey: .pid)
    try container.encode(x, forKey: .x)
    try container.encode(y, forKey: .y)
    try container.encode(value, forKey: .value)
    try container.encode(matchKey, forKey: .matchKey)
  }
}

/// How much of the screen a read's element frames cover, measured along several dimensions.
///
/// Every ratio comes from the same grid over the same single walk, differing only in which subset of
/// elements is marked into it.
public struct AccessibilityCoverage: Sendable, Equatable, Encodable {

  /// Coverage of the elements the read *reports* — what a consumer actually receives.
  public let frame: Double

  /// Coverage of the elements the read walked, before `--filter` narrowed them; equal to `frame`
  /// under the default filter. A truncated read never saw the rest of the tree, so this measures the
  /// walk, not the tree. Both low means the app is not exposing its content (e.g. a WebView).
  public let walked: Double

  /// Coverage of the walked elements a user could perceive: those carrying a label with no labelled
  /// descendant (so a labelled button wrapping an unlabelled image counts once). Measured over the
  /// walk, not the filtered result. `nil` for a flat read, which carries no `children`.
  public let content: Double?

  /// Coverage of the walked elements with no children, labelled or not. Read against `content`: a `leaf`
  /// far above `content` is unlabelled leaf area — a region the app draws but does not describe.
  /// `nil` for a flat read, for the same reason.
  public let leaf: Double?

  /// Coverage found by grid hit-testing for remote (separate-process) content, when that ran.
  public let additional: Double?

  public init(frame: Double, walked: Double, content: Double?, leaf: Double?, additional: Double?) {
    self.frame = frame
    self.walked = walked
    self.content = content
    self.leaf = leaf
    self.additional = additional
  }

  enum CodingKeys: String, CodingKey {
    case frame
    case walked
    case content
    case leaf
    case additional
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(frame, forKey: .frame)
    try container.encode(walked, forKey: .walked)
    try container.encode(content, forKey: .content)
    try container.encode(leaf, forKey: .leaf)
    try container.encode(additional, forKey: .additional)
  }
}

/// Whether an element can be acted on, and why not when it cannot.
///
/// The accessibility server's `(-1, -1)` "nothing reachable" sentinel never reaches the wire: no
/// reachable point is the absence of `.actionable`.
///
/// `.actionable` is derived from the application's own render tree, which cannot see another
/// process compositing on top of it (a system alert, SpringBoard chrome). Naming an occluder in
/// another process requires the `AXKeys.occludedBy` hit-test.
public enum AccessibilityInteractable: Sendable, Equatable {

  /// The element can be acted on, at this point. Not necessarily the frame centre: for a partially
  /// covered element the centre is exactly what fails, and this is the point that does not.
  case actionable(at: AccessibilityPoint)

  /// The element cannot be acted on. `reasons` is never empty and is ordered most specific first:
  /// `notHittable`, which observes without explaining, always sorts last.
  case blocked(reasons: [Reason])

  /// Why an element cannot be acted on.
  public enum Reason: Sendable, Equatable {
    /// `IsVisible == false` read straight through: the server found no reachable point and did not say
    /// why. Only a hit-test separates the cases this covers — a label inside a tappable control, a
    /// pass-through container, a genuinely covered element, or one transparent or clipped by an ancestor.
    case notHittable
    /// The element has a reachable point, but it is not the centre — so the centre is covered, and
    /// automation aiming there hits whatever is on top. `by` names that element when a hit-test was paid
    /// for, and is nil otherwise.
    case occluded(by: AccessibilityElementRef?)
    /// A touch aimed here is delivered to a relative — an ancestor that owns this element, or a
    /// descendant it passes through to (a label inside a button, a container around a control). Act on
    /// the named element. Requires a hit-test, so without `occludedBy` these report as `notHittable`.
    case handledBy(AccessibilityElementRef?)
    /// The view has `userInteractionEnabled` off.
    case userInteractionDisabled
    /// The element reports itself disabled.
    case disabled
    /// The element declares itself hidden from accessibility.
    case hidden
    /// The element has no area to tap.
    case zeroSize
    /// Part of the element's frame lies outside the screen bounds the document carries. Computed from
    /// geometry, never reported by the server; accumulates alongside other reasons.
    case clippedByScreen
  }
}

/// A point in the same screen space element frames are expressed in.
public struct AccessibilityPoint: Sendable, Equatable, Encodable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  /// Nil when either coordinate is non-finite, as `AccessibilityFrame` normalizes its edges.
  public init?(_ point: CGPoint) {
    guard point.x.isFinite, point.y.isFinite else {
      return nil
    }
    self.init(x: Double(point.x), y: Double(point.y))
  }
}

/// An element resolved by a hit-test — whatever actually receives a touch aimed at another element.
/// Used both for an unrelated element covering the target and for a relative of the target that takes
/// the touch on its behalf.
public struct AccessibilityElementRef: Sendable, Equatable, Encodable {
  public let type: String?
  public let identifier: String?
  public let label: String?
  public let frame: AccessibilityFrame?
  public let pid: Int64?

  public init(type: String?, identifier: String?, label: String?, frame: AccessibilityFrame?, pid: Int64?) {
    self.type = type
    self.identifier = identifier
    self.label = label
    self.frame = frame
    self.pid = pid
  }

  enum CodingKeys: String, CodingKey {
    case type
    case identifier
    case label
    case frame
    case pid
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encode(identifier, forKey: .identifier)
    try container.encode(label, forKey: .label)
    try container.encode(frame, forKey: .frame)
    try container.encode(pid, forKey: .pid)
  }
}

public extension AccessibilityInteractable.Reason {
  /// Whether this reason merely observes that the element is unreachable, without explaining it.
  var isUnexplained: Bool {
    if case .notHittable = self { return true }
    return false
  }
}

public extension Array where Element == AccessibilityInteractable.Reason {
  /// The reasons with every explaining reason ahead of `notHittable`, each group keeping the order it
  /// was derived in.
  ///
  /// Two filters, not a sort: order within each group must remain the derivation order, and
  /// Swift's sort is not stable.
  var mostSpecificFirst: [AccessibilityInteractable.Reason] {
    filter { !$0.isUnexplained } + filter { $0.isUnexplained }
  }
}

public extension AccessibilityInteractable {

  /// Internally tagged: every value is an object, discriminated by `status`.
  enum CodingKeys: String, CodingKey {
    case status
    case at
    case reasons
  }

  enum Status: String, Sendable, Encodable {
    case actionable
    case blocked
  }
}

extension AccessibilityInteractable: Encodable {
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .actionable(at):
      try container.encode(Status.actionable, forKey: .status)
      try container.encode(at, forKey: .at)
    case let .blocked(reasons):
      try container.encode(Status.blocked, forKey: .status)
      // Ordered at encode time so the wire guarantee holds however `reasons` was built.
      try container.encode(reasons.mostSpecificFirst, forKey: .reasons)
    }
  }
}

extension AccessibilityInteractable.Reason: Encodable {

  enum CodingKeys: String, CodingKey {
    case kind
    case by
  }

  /// The wire spelling; consumers branch on these tokens.
  public var kind: String {
    switch self {
    case .notHittable: return "not_hittable"
    case .occluded: return "occluded"
    case .handledBy: return "handled_by"
    case .userInteractionDisabled: return "user_interaction_disabled"
    case .disabled: return "disabled"
    case .hidden: return "hidden"
    case .zeroSize: return "zero_size"
    case .clippedByScreen: return "clipped_by_screen"
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case let .occluded(by), let .handledBy(by):
      try container.encodeIfPresent(by, forKey: .by)
    default:
      break
    }
  }
}

/// How well this read could explain the elements it found blocked.
///
/// `unexplained` counts elements whose only reason is the bare `notHittable` observation. An element
/// nothing explains is still reported as blocked: a caller acting on it needs to know it cannot act,
/// whether or not the reason is known.
public struct AccessibilityInteractionSummary: Sendable, Equatable, Encodable {

  /// Elements reported actionable.
  public let actionable: Int
  /// Elements reported blocked, for any reason.
  public let blocked: Int
  /// Of those, the ones carrying only `notHittable` — blocked with nothing that explains it.
  public let unexplained: Int
  /// `unexplained / blocked`, or nil when nothing was blocked.
  public let unexplainedRatio: Double?

  public init(actionable: Int, blocked: Int, unexplained: Int) {
    self.actionable = actionable
    self.blocked = blocked
    self.unexplained = unexplained
    self.unexplainedRatio = blocked > 0 ? Double(unexplained) / Double(blocked) : nil
  }

  /// Tallies a serialized read. Nil (not zeroes) when no element carried a verdict, so a read that did
  /// not request `interactable`, or a backend that could not answer, never reads as "nothing blocked".
  public init?(elements: [AccessibilityDocumentElement]) {
    var actionable = 0
    var blocked = 0
    var unexplained = 0
    func visit(_ element: AccessibilityDocumentElement) {
      switch element.interactable ?? nil {
      case .actionable:
        actionable += 1
      case let .blocked(reasons):
        blocked += 1
        if reasons.allSatisfy(\.isUnexplained) {
          unexplained += 1
        }
      case nil:
        break
      }
      for child in element.children ?? [] {
        visit(child)
      }
    }
    for element in elements {
      visit(element)
    }
    guard actionable > 0 || blocked > 0 else {
      return nil
    }
    self.init(actionable: actionable, blocked: blocked, unexplained: unexplained)
  }

  enum CodingKeys: String, CodingKey {
    case actionable
    case blocked
    case unexplained
    case unexplainedRatio = "unexplained_ratio"
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(actionable, forKey: .actionable)
    try container.encode(blocked, forKey: .blocked)
    try container.encode(unexplained, forKey: .unexplained)
    try container.encode(unexplainedRatio, forKey: .unexplainedRatio)
  }
}

/// How many of a read's elements carry a usable rectangle. A view out of its window reports
/// `CGRectZero` while keeping its label, so the framed-to-zero-framed split is the signal that the
/// tree degraded; what proportion is suspicious depends on the screen, so no threshold is applied.
/// `total` counts elements carrying a `frame` attribute, not things on screen. `nil` (not zeroes)
/// when the read did not carry `frame`.
public struct AccessibilityFrameSummary: Sendable, Equatable, Encodable {

  /// Elements carrying a `frame` attribute, whatever its value.
  public let total: Int
  /// Of those, the ones with a positive-area rectangle.
  public let framed: Int
  /// Of those, the ones whose rectangle has no area, or whose edges were not representable.
  public let zeroFrame: Int

  public init(total: Int, framed: Int, zeroFrame: Int) {
    self.total = total
    self.framed = framed
    self.zeroFrame = zeroFrame
  }

  /// Tallies a serialized read, or nil when no element carried a frame.
  public init?(elements: [AccessibilityDocumentElement]) {
    var total = 0
    var framed = 0
    func visit(_ element: AccessibilityDocumentElement) {
      if let frame = element.frame {
        total += 1
        // Counts as framed only with area on both axes; a frame with a missing edge (`rect == nil`)
        // falls to the zero-frame side rather than being dropped from the tally.
        if let rect = frame?.rect, rect.width > 0, rect.height > 0 {
          framed += 1
        }
      }
      for child in element.children ?? [] {
        visit(child)
      }
    }
    for element in elements {
      visit(element)
    }
    guard total > 0 else {
      return nil
    }
    self.init(total: total, framed: framed, zeroFrame: total - framed)
  }

  enum CodingKeys: String, CodingKey {
    case total
    case framed
    case zeroFrame = "zero_frame"
  }
}

/// What narrowed a read and how much survived, so an empty result reads as "matched nothing out of
/// N" rather than as a failed read. Emitted on every `complete` document; an un-narrowed read reports
/// the default filter, a null match, and equal counts.
public struct AccessibilityNarrowing: Sendable, Equatable, Encodable {

  /// The substring the read reported only the matching elements for, or nil when it did not narrow by
  /// one. A marker read leaves this null: it reports its search through `target`, not here.
  public let match: String?

  /// The element key `match` was compared against, and whether the comparison ignored case. Both nil
  /// when there was no match.
  public let matchKey: String?
  public let ignoreCase: Bool?

  /// The element filter the read applied, spelled as the CLI spells it.
  public let filter: String

  /// Elements walked before narrowing, and elements reported after it. Counted through `children`, so
  /// the pair means the same thing for a nested read as for a flat one, and equal when nothing
  /// narrowed.
  public let walked: Int
  public let matched: Int

  public init(match: String?, matchKey: String?, ignoreCase: Bool?, filter: String, walked: Int, matched: Int) {
    self.match = match
    self.matchKey = matchKey
    self.ignoreCase = ignoreCase
    self.filter = filter
    self.walked = walked
    self.matched = matched
  }

  enum CodingKeys: String, CodingKey {
    case match
    case matchKey = "match_key"
    case ignoreCase = "ignore_case"
    case filter
    case walked
    case matched
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(match, forKey: .match)
    try container.encode(matchKey, forKey: .matchKey)
    try container.encode(ignoreCase, forKey: .ignoreCase)
    try container.encode(filter, forKey: .filter)
    try container.encode(walked, forKey: .walked)
    try container.encode(matched, forKey: .matched)
  }
}

public extension AccessibilityNarrowing {
  /// The report for a read that applied `filter` and `match`, walking `walked` nodes and reporting
  /// `matched` of them.
  init(filter: AccessibilityElementFilter, match: AccessibilityMatch?, walked: Int, matched: Int) {
    self.init(
      match: match?.value,
      matchKey: match?.key.rawValue,
      ignoreCase: match.map(\.ignoresCase),
      filter: filter.rawValue,
      walked: walked,
      matched: matched)
  }

  /// The report for a read that also hit-tested remote content. Discovered elements were walked and
  /// narrowed too: they add to `walked`, and any survivors are already in `reported`.
  init(
    filter: AccessibilityElementFilter,
    match: AccessibilityMatch?,
    walked: [AccessibilityDocumentElement],
    discovered: [AccessibilityDocumentElement],
    reported: [AccessibilityDocumentElement]
  ) {
    self.init(
      filter: filter, match: match,
      walked: walked.nodeCount + discovered.nodeCount, matched: reported.nodeCount)
  }
}

public extension AccessibilityRequestOptions {
  /// The narrowing report for a read under these options that walked `walked` and reported `reported`.
  func narrowingReport(
    walked: [AccessibilityDocumentElement], reported: [AccessibilityDocumentElement]
  ) -> AccessibilityNarrowing {
    AccessibilityNarrowing(
      filter: filter, match: match, walked: walked.nodeCount, matched: reported.nodeCount)
  }
}

public extension [AccessibilityDocumentElement] {
  /// Elements in a serialized read, counted through `children`.
  ///
  /// The nested formats put a single root at the top level, so `count` would report 1 for any tree.
  var nodeCount: Int {
    reduce(0) { $0 + 1 + ($1.children ?? []).nodeCount }
  }
}

/// An accessibility element in the `complete` output format.
///
/// Each attribute is doubly optional; the synthesized encoder uses `encodeIfPresent`, so:
/// - `nil` — not requested: the key is omitted (this is what lets `--key` trim the payload).
/// - `.some(nil)` — requested, but the element has no value: an explicit `null`.
/// - `.some(value)` — the value.
///
/// Legacy `AX`-prefixed names are spelled plainly here (`AXLabel` → `label`, `AXUniqueId` →
/// `identifier`); the stringified frame and raw role are carried by `frame` and `type`.
public struct AccessibilityDocumentElement: Sendable, Equatable, Encodable {

  public var label: String??
  public var value: AccessibilityAttributeValue??
  public var identifier: String??
  public var type: String??
  public var title: String??
  public var help: String??
  public var roleDescription: String??
  public var subrole: String??
  public var placeholder: String??
  public var frame: AccessibilityFrame??
  public var enabled: Bool??
  public var contentRequired: Bool??
  public var expanded: Bool??
  public var hidden: Bool??
  public var focused: Bool??
  public var isRemote: Bool??
  /// Whether the element can be acted on, and why not when it cannot. `.some(nil)` — an explicit `null` —
  /// on a backend that cannot answer: the legacy accessibility path has no counterpart for the attributes
  /// this is derived from.
  public var interactable: AccessibilityInteractable??
  public var customActions: [String]??
  public var traits: [String]??
  public var pid: Int64??
  /// The raw role (`AXButton`) and the stringified frame. `complete` reports these through `type` and
  /// `frame` instead, so they are absent from its `CodingKeys` — they exist for the legacy spelling,
  /// which emits both.
  public var role: String??
  public var axFrame: String??
  /// What a hit-test at this element's centre found. Not part of the emitted schema (absent from
  /// `CodingKeys`): it is an input to deriving `interactable`, never emitted on its own.
  public var explainedBy: AccessibilityElementRef?
  /// The nested children, or `nil` when the read did not walk them — a flat read lists every node
  /// separately and carries no `children` key at all. Not an attribute: it comes from the traversal.
  ///
  /// A format that asks for a tree reports this on every element (see `reportingChildren()`); the flat
  /// format reports it on none.
  public var children: [AccessibilityDocumentElement]?

  /// A copy that reports `children` on every node, empty where the read walked none. Backends differ
  /// in how much subtree a single-element read walks (the guest-backed readers resolve one node from a
  /// hit-test and stop), and without this the key set would vary with `--api`.
  public func reportingChildren() -> AccessibilityDocumentElement {
    var copy = self
    copy.children = (children ?? []).map { $0.reportingChildren() }
    return copy
  }

  public init(children: [AccessibilityDocumentElement]? = nil) {
    self.children = children
  }

  enum CodingKeys: String, CodingKey {
    case label
    case value
    case identifier
    case type
    case title
    case help
    case roleDescription = "role_description"
    case subrole
    case placeholder
    case frame
    case enabled
    case contentRequired = "content_required"
    case expanded
    case hidden
    case focused
    case isRemote = "is_remote"
    case interactable
    case customActions = "custom_actions"
    case traits
    case pid
    case children
  }

}

/// An element's `value`, which the platform reports as an untyped object — usually a string,
/// sometimes a number or flag (a slider's position, a switch's state), occasionally a collection.
public enum AccessibilityAttributeValue: Sendable, Equatable, Encodable {
  case string(String)
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case array([AccessibilityAttributeValue])
  case object([String: AccessibilityAttributeValue])
  /// A null held *inside* a collection. Absence at the top level is carried by the element's own
  /// optional, so this case exists only for the position where that optional cannot reach.
  case null

  /// Classifies the platform's untyped `accessibilityValue`. Collections stay collections; an object
  /// of no recognized kind becomes its description. Fails only for `nil`/`NSNull` — see `member(_:)`.
  public init?(_ object: Any?) {
    guard let object, !(object is NSNull) else {
      return nil
    }
    switch object {
    case let value as String:
      self = .string(value)
    case let value as NSNumber:
      if CFGetTypeID(value) == CFBooleanGetTypeID() {
        self = .bool(value.boolValue)
      } else {
        let objCType = String(cString: value.objCType)
        self = (objCType == "f" || objCType == "d") ? .double(value.doubleValue) : .int(value.int64Value)
      }
    case let value as [Any]:
      self = .array(value.map(Self.member))
    case let value as [String: Any]:
      self = .object(value.mapValues(Self.member))
    default:
      self = .string(String(describing: object))
    }
  }

  /// A collection member: a failed `init?` can only mean null, which must stay in place inside a collection.
  private static func member(_ object: Any) -> AccessibilityAttributeValue {
    AccessibilityAttributeValue(object) ?? .null
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case let .string(value):
      try container.encode(value)
    case let .bool(value):
      try container.encode(value)
    case let .int(value):
      try container.encode(value)
    case let .double(value):
      // JSON cannot represent a non-finite number; report it as absent rather than fail the encode.
      try value.isFinite ? container.encode(value) : container.encodeNil()
    case let .array(value):
      try container.encode(value)
    case let .object(value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }
}

/// The `complete` output format: the elements plus everything the read learned about the state they
/// were read in.
///
/// **The key set is fixed.** Every field is always encoded; anything a verb or backend cannot supply
/// is an explicit `null`. A point read and a whole-tree read differ in their values, never in their
/// shape, and `target` says which verb produced the document. `elements` is always an array, even for
/// the single-element reads the legacy envelope emits as a bare object.
///
/// New fields are added additively and consumers ignore ones they do not know; there is no version
/// field.
public struct AccessibilityDocument: Sendable, Encodable {

  public let elements: [AccessibilityDocumentElement]
  public let modal: AccessibilityModalInfo?
  public let truncated: Bool
  public let screen: AccessibilityScreenInfo?
  public let backend: UIAutomationBackendName?
  public let target: AccessibilityTargetDescriptor?
  public let profile: AccessibilityProfile?
  public let coverage: AccessibilityCoverage?
  /// How much of what this read found blocked it could explain. Nil when `interactable` was not
  /// requested, since there is then nothing to summarize.
  public let interaction: AccessibilityInteractionSummary?
  /// How many of the read's elements carry a usable rectangle. Nil when `frame` was not requested.
  public let frames: AccessibilityFrameSummary?
  /// The device's accessibility automation mode for this read. Nil when the backend cannot report it —
  /// a single-element read, or a guest predating the field.
  public let automation: AccessibilityAutomationState?
  /// What the read was narrowed by and how much survived. Nil for a single-element read, which selects
  /// rather than narrows.
  public let narrowing: AccessibilityNarrowing?
  /// The client the read named. Unlike every other key, absent rather than null when the read named none,
  /// so a read that did not keeps exactly the document it always had.
  public let client: AccessibilityClientReport?

  public init(
    elements: [AccessibilityDocumentElement],
    modal: AccessibilityModalInfo? = nil,
    truncated: Bool = false,
    screen: AccessibilityScreenInfo? = nil,
    backend: UIAutomationBackendName? = nil,
    target: AccessibilityTargetDescriptor? = nil,
    profile: AccessibilityProfile? = nil,
    coverage: AccessibilityCoverage? = nil,
    interaction: AccessibilityInteractionSummary? = nil,
    frames: AccessibilityFrameSummary? = nil,
    automation: AccessibilityAutomationState? = nil,
    narrowing: AccessibilityNarrowing? = nil,
    client: AccessibilityClientReport? = nil
  ) {
    self.elements = elements
    self.modal = modal
    self.truncated = truncated
    self.screen = screen
    self.backend = backend
    self.target = target
    self.profile = profile
    self.coverage = coverage
    self.interaction = interaction
    self.frames = frames
    self.automation = automation
    self.narrowing = narrowing
    self.client = client
  }

  enum CodingKeys: String, CodingKey {
    case elements
    case modal
    case truncated
    case screen
    case backend
    case target
    case profile
    case coverage
    case interaction
    case frames
    case automation
    case narrowing
    case client
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(elements, forKey: .elements)
    try container.encode(modal, forKey: .modal)
    try container.encode(truncated, forKey: .truncated)
    try container.encode(screen, forKey: .screen)
    try container.encode(backend, forKey: .backend)
    try container.encode(target, forKey: .target)
    try container.encode(profile, forKey: .profile)
    try container.encode(coverage, forKey: .coverage)
    try container.encode(interaction, forKey: .interaction)
    try container.encode(frames, forKey: .frames)
    try container.encode(automation, forKey: .automation)
    try container.encode(narrowing, forKey: .narrowing)
    try container.encodeIfPresent(client, forKey: .client)
  }
}

public extension AccessibilityDocumentElement {
  /// The value a marker match reads for `key`. A marker is matched over the *serialized* element, so an
  /// attribute the read did not carry simply does not match.
  func searchableValue(for key: AXSearchableKey) -> String? {
    switch key {
    case .label: return label ?? nil
    case .uniqueID: return identifier ?? nil
    case .value:
      guard case let .string(string)? = (value ?? nil) else { return nil }
      return string
    case .title: return title ?? nil
    case .role: return role ?? nil
    case .roleDescription: return roleDescription ?? nil
    case .subrole: return subrole ?? nil
    case .help: return help ?? nil
    case .placeholder: return placeholder ?? nil
    }
  }
}
