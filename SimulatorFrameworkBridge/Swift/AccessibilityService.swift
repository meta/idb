/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreFoundation
import CoreGraphics
import Darwin
import FBSimulatorBridgeProtocol
import Foundation

#if canImport(SimulatorFrameworkBridgeRuntime)
internal import SimulatorFrameworkBridgeRuntime
#endif

private let axElementType = BridgeAXWire.Node.elementType.rawValue
private let axElementBaseType = BridgeAXWire.Node.elementBaseType.rawValue
private let axLabel = BridgeAXWire.Node.label.rawValue
private let axValue = BridgeAXWire.Node.value.rawValue
private let axIdentifier = BridgeAXWire.Node.identifier.rawValue
private let axFrame = BridgeAXWire.Node.frame.rawValue
private let axAutomationType = BridgeAXWire.Node.automationType.rawValue
private let axChildren = BridgeAXWire.Node.children.rawValue
private let axWindowDisplayID = BridgeAXWire.Node.windowDisplayID.rawValue

private enum AXDisplayScopeError: Error {
  case missingWindowIdentity
}
// Both answered as CGPoint. `VisiblePoint` reads `(-1, -1)` when the server believes no touch reaches the
// element; carried verbatim, sentinel included — deciding what unreachable means is the host's job.
private let axVisiblePoint = BridgeAXWire.Node.visiblePoint.rawValue
private let axCenterPoint = BridgeAXWire.Node.centerPoint.rawValue
// Whether the server can name a point at which a touch reaches the element; the walk uses it to pick
// nodes worth explaining.
private let axisVisible = BridgeAXWire.Node.isVisible.rawValue
private let requestVerb = BridgeAXWire.Request.verb.rawValue
private let requestPid = BridgeAXWire.Request.pid.rawValue
private let requestMaxDepth = BridgeAXWire.Request.maxDepth.rawValue
private let requestMaxNodes = BridgeAXWire.Request.maxNodes.rawValue
// The attributes fetched per element. Optional: absent means `FBAXBridgeDefaultFetchList()`. Named per
// request so an attribute nobody asked for stays off the wire entirely.
private let requestAttributes = BridgeAXWire.Request.attributes.rawValue
// Whether this read wants the device in accessibility automation mode. Tri-state on purpose: **absent**
// means observe and report without touching the device, which is what a host that does not know about
// this field gets; `true` and `false` each assert that state. Absent and `false` are not the same thing —
// one leaves the device alone and the other actively turns the mode off.
private let requestAutomationMode = BridgeAXWire.Request.automationMode.rawValue
// Asks the walk to explain each element the accessibility server reports unreachable, by hit-testing that
// element's centre and reporting whatever answered. Optional and off by default: it costs an extra AX
// round trip per unreachable element, and only a caller that intends to use the answer should pay.
private let requestExplainUnreachable = BridgeAXWire.Request.explainUnreachable.rawValue
// Reads through the translator's vocabulary instead of XCTest's. Off by default; the two disagree on
// some screens.
private let requestTraversal = BridgeAXWire.Request.traversal.rawValue
private let requestClientType = BridgeAXWire.Request.clientType.rawValue
// Reads the whole subtree in one call, through `userTestingSnapshotForElement:options:error:`, instead
// of one call per node. Selected by the host's `single-fetch` traversal; the per-node walk is still the
// default.
// Reader-derived keys (below) are spelled in the reader's own namespace, not `XC_kAXXC*`, so the two
// kinds stay distinguishable on the wire.
private let nodeExplainedBy = BridgeAXWire.Node.explainedBy.rawValue
// The translator's own `enabled` answer; XCTest's vocabulary has no counterpart. Only a translator read
// carries this.
private let nodeIsEnabled = BridgeAXWire.Node.isEnabled.rawValue
// The translator's `role`, carried as its raw integer for the host to map. Not folded into `elementType`,
// which carries `XCUIElementType` names.
private let nodeTranslatorRole = BridgeAXWire.Node.translatorRole.rawValue
// The translator's `subrole`, as its raw integer; it refines the role rather than replacing it.
private let nodeTranslatorSubrole = BridgeAXWire.Node.translatorSubrole.rawValue
// The `UIAccessibilityTraits` bitmask, carried raw. Decoding it needs the trait constants, which live in
// a macOS-only header this binary cannot import — so the number rides the wire and the host names it.
private let nodeTraits = BridgeAXWire.Node.traits.rawValue
// A per-element identity from the translator, so two reads can be compared element by element.
private let nodeElementIdentity = BridgeAXWire.Node.elementIdentity.rawValue
// Present only on a node where at least one attribute failed to read, mapping the attribute's key to the
// reason.
private let nodeAttributeReadFailures = BridgeAXWire.Node.attributeReadFailures.rawValue
private let requestDisplayID = BridgeAXWire.Request.displayID.rawValue
private let requestX = BridgeAXWire.Request.x.rawValue
private let requestY = BridgeAXWire.Request.y.rawValue
// Selects how a fused frontmost read (a `describe` with no pid) resolves the foreground app. Optional;
// defaults to `window-server` (the authoritative query).
private let requestMethod = BridgeAXWire.Request.method.rawValue
// The semantic action a `perform` asks for, and the string a `setvalue` writes.
private let requestAction = BridgeAXWire.Request.action.rawValue
private let requestValue = BridgeAXWire.Request.value.rawValue
// Device-wide accessibility setting name and requested state.
private let requestSetting = BridgeAXWire.Request.setting.rawValue
private let requestEnabled = BridgeAXWire.Request.enabled.rawValue
// What the element at the point must still be for the write to go ahead: one node attribute key and the
// value it has to equal. Optional, and only meaningful together.
private let requestAssertKey = BridgeAXWire.Request.assertKey.rawValue
private let requestAssertValue = BridgeAXWire.Request.assertValue.rawValue
private let requestBusyThresholdMs = BridgeAXWire.Request.busyThresholdMs.rawValue
private let requestQuietWindowMs = BridgeAXWire.Request.quietWindowMs.rawValue
private let responseOk = BridgeAXWire.Envelope.ok.rawValue
private let responseEnabled = BridgeAXWire.Envelope.enabled.rawValue
private let responseTree = BridgeAXWire.Envelope.tree.rawValue
private let responseError = BridgeAXWire.Envelope.error.rawValue
// A successful hit-test that found no element at the point: `{ok:true, empty:true}` — distinct from a
// reader failure (`{ok:false, error:...}`), so the host can tell empty space from a broken reader.
private let responseEmpty = BridgeAXWire.Envelope.empty.rawValue
// A closed-vocabulary failure kind, so the host picks a remedy structurally rather than by matching the
// free-text `error`. Absent kind = plain reader failure; a host must treat an unknown kind the same way,
// so adding a value here degrades an older host's precision rather than breaking it.
private let responseErrorKind = BridgeAXWire.Envelope.errorKind.rawValue
// On a failed write, whether anything was sent to the application.
private let responseEffect = BridgeAXWire.Envelope.effect.rawValue
private let effectNone = BridgeAXWire.Effect.none.rawValue
private let effectUnknown = BridgeAXWire.Effect.unknown.rawValue
// The named process has no accessibility server: a dead pid, or a process that is not an application.
private let errorKindApplicationUnavailable = BridgeAXWire.ErrorKind.applicationUnavailable.rawValue
// The named process has one and it did not answer in time — alive but busy, suspended or wedged.
private let errorKindApplicationNotResponding = BridgeAXWire.ErrorKind.applicationNotResponding.rawValue
// How long it was given, in seconds, sent with every `application_not_responding` failure.
private let responseTimeoutSeconds = BridgeAXWire.Envelope.timeoutSeconds.rawValue
private let responseOutstanding = BridgeAXWire.Envelope.outstanding.rawValue
// The selected frontmost strategy could not name an application, for a reason that is about the strategy
// rather than about any one application.
private let errorKindFrontmostUnresolved = BridgeAXWire.ErrorKind.frontmostUnresolved.rawValue
// The reader could not bind the private frameworks it reads through, so no request can be served. The
// `error` names what was missing and what else about the runtime has moved.
private let errorKindReaderUnavailable = BridgeAXWire.ErrorKind.readerUnavailable.rawValue
// The request itself was malformed — an unknown verb, or a missing or wrongly-typed argument.
private let errorKindBadRequest = BridgeAXWire.ErrorKind.badRequest.rawValue
// A write was refused before it was attempted: the element found at the point is not the one the caller
// named. Held apart from `bad_request` because the request was well-formed — the screen moved.
private let errorKindAssertionFailed = BridgeAXWire.ErrorKind.assertionFailed.rawValue
// The runtime reported an error none of the kinds above name, with its AXError in `ax_error` when it gave one.
private let errorKindRuntimeFailed = BridgeAXWire.ErrorKind.runtimeFailed.rawValue
// The guest cannot do what was asked on this simulator, such as discover displays.
private let errorKindCapabilityUnavailable = BridgeAXWire.ErrorKind.capabilityUnavailable.rawValue
private let responseAXError = BridgeAXWire.Envelope.axError.rawValue
// A whole-tree read whose walk was cut short by the depth cap or the node budget: the returned tree is
// a partial view, so the host can warn rather than pass it off as complete. Absent or `false` means the
// walk visited every element within the bounds.
private let responseTruncated = BridgeAXWire.Envelope.truncated.rawValue
// The resolved foreground pid and the mechanism that resolved it. The pid also tags the owning element
// of a hit-test result.
private let responsePid = BridgeAXWire.Envelope.pid.rawValue
private let responseMethod = BridgeAXWire.Envelope.method.rawValue
// The automation mode this read ran under, and whether this read changed it. Reported on every describe:
// a tree read with subtree collapsing on is a different answer from the same tree read with it off.
private let responseAutomation = BridgeAXWire.Envelope.automation.rawValue
// Where the guest spent its time and how many round trips it took. Reported on every describe (a handful
// of clock reads). Guest-side JSON encoding is not included — it falls into the host's residual.
private let responsePhases = BridgeAXWire.Envelope.phases.rawValue
private let phaseTraverse = BridgeAXWire.Phase.traverse.rawValue
private let phaseMachRoundTrips = BridgeAXWire.Phase.machRoundTrips.rawValue
private let kAutomationEnabled = BridgeAXWire.Automation.enabled.rawValue
private let kAutomationAsserted = BridgeAXWire.Automation.asserted.rawValue
// A fullscreen modal/alert descriptor added to a describe response when one is detected in the tree.
// Host-facing enrichment on the wire; the host does not put it in the serialized CLI output.
private let responseModal = BridgeAXWire.Envelope.modal.rawValue
private let modalKind = BridgeAXModal.CodingKeys.kind.stringValue
private let modalKindSystem = BridgeAXModal.Kind.system.rawValue
private let modalKindApp = BridgeAXModal.Kind.app.rawValue
private let modalElementType = BridgeAXModal.CodingKeys.elementType.stringValue
private let modalLabel = BridgeAXModal.CodingKeys.label.stringValue
// Concrete accessibility element classes that mark a modal: a SpringBoard system alert window, and the
// UIKit alert controller view (matched by prefix — the concrete class varies by idiom/OS).
private let systemAlertWindowClass = "SBAlertItemWindow"
private let alertControllerClassPrefix = "_UIAlertController"
private typealias AccessibilityVerb = BridgeAXWire.Verb

private typealias AccessibilityAction = BridgeAXWire.Action

private extension BridgeAXWire.Action {
  var runtimeValue: FBAXAction {
    switch self {
    case .press: return .press
    case .scrollUp: return .scrollUp
    case .scrollDown: return .scrollDown
    case .scrollLeft: return .scrollLeft
    case .scrollRight: return .scrollRight
    case .scrollToVisible: return .scrollToVisible
    }
  }
}

enum AccessibilityDeviceSetting: String {
  case reduceMotion = "reduce-motion"
  case reduceTransparency = "reduce-transparency"
  case buttonShapes = "button-shapes"
  case voiceOver = "voiceover"
  case increaseContrast = "increase-contrast"

  var runtimeValue: FBAXDeviceSetting {
    switch self {
    case .reduceMotion: return .reduceMotion
    case .reduceTransparency: return .reduceTransparency
    case .buttonShapes: return .buttonShapes
    case .voiceOver: return .voiceOver
    case .increaseContrast: return .increaseContrast
    }
  }
}

private typealias FrontmostMethod = BridgeAXFrontmostMethod

private enum AccessibilityFailure {
  case plain(message: String)
  case tagged(message: String, kind: BridgeAXWire.ErrorKind, pid: pid_t?)
  case runtime(message: String, axError: NSNumber?, pid: pid_t?)
  case notResponding(message: String, pid: pid_t?)
  case outstanding(pid: pid_t)

  var failure: BridgeAXFailure {
    switch self {
    case let .plain(message):
      return BridgeAXFailure(message: message)
    case let .tagged(message, kind, pid):
      return BridgeAXFailure(message: message, kind: kind, pid: pid)
    case let .runtime(message, axError, pid):
      return BridgeAXFailure(message: message, kind: .runtimeFailed, pid: pid, axError: axError?.int32Value)
    case let .notResponding(message, pid):
      return BridgeAXFailure(message: message, kind: .applicationNotResponding, pid: pid, timeoutSeconds: Double(FBAXMessagingTimeoutSeconds))
    case let .outstanding(pid):
      var failure = AccessibilityFailure.notResponding(
        message: "pid \(pid) is still working on an earlier read it did not respond to before it timed out; nothing larger was sent to it",
        pid: pid
      ).failure
      failure.outstanding = true
      return failure
    }
  }
}

private struct TraversalContext {
  var remainingNodes = 0
  // The process the read is for. 0 when the read names none.
  var processIdentifier: pid_t = 0
  // Other processes that draw part of the tree and did not answer in time. A read sent to one queues
  // behind the one it missed, so the walk skips their elements.
  var unansweredProcesses: Set<pid_t> = []
  // How many boundary continuations one read may fetch. Depth and node budget already bound the recursion
  // — a continuation replaces a node at its own depth and never re-triggers on its own root, so every
  // further boundary sits at least one level deeper — but each continuation is fetched before the node it
  // replaces is counted, and this caps what a pathological ownership graph can spend on fetches. Screens
  // measured so far carry one or two boundaries; a read that hits the cap reports `truncated`.
  var remainingBoundaryFetches = 64
  // The client the read's translator requests claim. Only the translator vocabulary asks through the
  // translator, so only a semantic walk sends it.
  var clientType: BridgeAXClientType = .noClient
  var truncated = false
  var roundTrips: Int64 = 0
  // UIKit lists some elements under more than one parent (a table header's search field sits under its
  // container and again directly under the table), in both the per-element and the snapshot walk. The first
  // parent reached depth-first is the view parent.
  var emitted: Set<NSObject> = []
}

/// A node the walk read, or the runtime's outcome for one it could not.
private enum AccessibilityNodeRead {
  case read(BridgeAXNode)
  case unread(FBAXReadOutcome)

  var status: FBAXReadStatus {
    switch self {
    case .read: FBAXReadStatus.read
    case let .unread(outcome): outcome.status
    }
  }

  var node: BridgeAXNode? {
    guard case let .read(node) = self else { return nil }
    return node
  }

  var error: (any Error)? {
    guard case let .unread(outcome) = self else { return nil }
    return outcome.error
  }

  var axError: NSNumber? {
    guard case let .unread(outcome) = self else { return nil }
    return outcome.axError
  }
}

// MARK: - Plain values to typed fields

// A string or number; null and a non-finite number, which JSON cannot carry, are no value.
private func FBAXBridgeScalar(_ value: Any?) -> BridgeAXScalar? {
  switch value {
  case let string as String:
    return .string(string)
  case let number as NSNumber:
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      return .bool(number.boolValue)
    }
    if CFNumberIsFloatType(number) {
      return number.doubleValue.isFinite ? .number(number.doubleValue) : nil
    }
    return .integer(number.int64Value)
  default:
    return nil
  }
}

// An integral number, booleans excluded: a flag is not an identity or a bitmask.
private func FBAXBridgeInteger(_ value: Any?) -> Int64? {
  guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
  if CFNumberIsFloatType(number) {
    return Int64(exactly: number.doubleValue)
  }
  return number.int64Value
}

// A boolean, as the runtime answers it: a boolean or a number.
private func FBAXBridgeFlag(_ value: Any?) -> Bool? {
  (value as? NSNumber)?.boolValue
}

private func FBAXBridgeCoordinate(_ value: Any?) -> Double? {
  guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
  return number.doubleValue
}

// A `CGRect` dictionary representation; a non-finite edge is nil, which the model sends as null.
private func FBAXBridgeRect(_ value: Any?) -> BridgeAXRect? {
  guard let rect = value as? [String: Any] else { return nil }
  return BridgeAXRect(
    x: FBAXBridgeCoordinate(rect["X"]), y: FBAXBridgeCoordinate(rect["Y"]), width: FBAXBridgeCoordinate(rect["Width"]),
    height: FBAXBridgeCoordinate(rect["Height"]))
}

private func FBAXBridgePoint(_ value: Any?) -> BridgeAXPoint? {
  guard let point = value as? [String: Any] else { return nil }
  return BridgeAXPoint(x: FBAXBridgeCoordinate(point["X"]), y: FBAXBridgeCoordinate(point["Y"]))
}

private final class AccessibilityRequest {
  // MARK: - AX client setup

  // Kept short: read once per unreachable element.
  fileprivate func FBAXBridgeExplanationFetchList() -> [String] {
    [axElementType, axLabel, axIdentifier, axFrame, axAutomationType]
  }

  // The attributes a read fetches when the request names none. Membership *and* order are part of the wire
  // contract, mirrored host-side by `AXWire.Node.defaultFetchList`.
  fileprivate func FBAXBridgeDefaultFetchList() -> [String] {
    BridgeAXWire.Node.defaultFetchList
  }

  // Names are forwarded unfiltered — the vocabulary is far wider than the constants here. The children key
  // is always appended: the walk recurses on it, and omitting it would flatten the tree to its root.
  //
  // Hazard: the framework drops any name it has no number for, then fails the whole read on the count
  // mismatch — one unknown key costs every attribute for that node, not just itself.
  fileprivate func FBAXBridgeFetchList(attributes requested: [String]?, displayID: UInt32?) -> [String] {
    var attributes = requested ?? FBAXBridgeDefaultFetchList()
    if !attributes.contains(axChildren) { attributes.append(axChildren) }
    if displayID != nil, !attributes.contains(axWindowDisplayID) {
      attributes.append(axWindowDisplayID)
    }
    return attributes
  }

  private func treeOnDisplay(_ tree: BridgeAXNode, displayID: UInt32, isRoot: Bool = true) throws -> BridgeAXNode? {
    let identity = tree.windowDisplayID
    if let identity, identity > 0 {
      guard identity == displayID else { return nil }
    } else if !isRoot {
      throw AXDisplayScopeError.missingWindowIdentity
    }
    var scoped = tree
    if let children = tree.children {
      scoped.children = try children.compactMap { try treeOnDisplay($0, displayID: displayID, isRoot: false) }
    }
    if isRoot, identity == nil || identity == 0, scoped.children?.isEmpty != false { return nil }
    return scoped
  }

  // Counted rather than inferred from node count, which would undercount by up to 2x (the translator walk
  // makes two requests per node; explaining an unreachable element adds two more).
  private var traversal = TraversalContext()
  fileprivate func FBAXBridgeCountRoundTrip() {
    traversal.roundTrips += 1
  }

  // An outcome whose status and payload disagree. Unreachable through the factories; reported as a response
  // rather than raised because the guest serves a long-lived connection.
  fileprivate func FBAXBridgeInvariantError(description: String) -> any Error {
    NSError(domain: "FBAXBridgeInvariant", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
  }

  // MARK: - JSON coercion

  // A geometry value none of a coercion's branches recognises. Answered as null — the same answer a
  // missing attribute gets — never as a zeroed dictionary, which is well-formed geometry at the screen
  // origin and indistinguishable from a real answer.
  fileprivate func FBAXBridgeRejectedGeometry(kind: String, value: Any) -> Any {
    NSLog("[AccessibilityService] unexpected %@ value class: %@", kind, String(describing: type(of: value)))
    return NSNull()
  }

  // The frame arrives from `attributesForElement:` as an `NSValue`-wrapped `CGRect` (or, tolerantly, an
  // existing dictionary representation). Emit the CGRect dictionary representation the host consumes via
  // `CGRectMakeWithDictionaryRepresentation`.
  fileprivate func FBAXBridgeFrameDictionary(
    client: FBAXClient,
    frameValue: Any
  ) throws -> Any? {
    var rect: CGRect = .zero
    if let frameValue = frameValue as? NSDictionary {
      guard let snapshot = try client.snapshotRectangle(frameValue).value else {
        return FBAXBridgeRejectedGeometry(kind: "frame", value: frameValue)
      }
      return snapshot
    }
    let result = try client.rectangle(fromValue: frameValue)
    guard let geometry = result.value else {
      return FBAXBridgeRejectedGeometry(kind: "frame", value: frameValue)
    }
    geometry.getValue(&rect, size: MemoryLayout.size(ofValue: rect))
    return CGRectCreateDictionaryRepresentation(rect) as NSDictionary
  }

  // Keyed on the attribute name, as the frame is, so a value that merely looks like an X/Y pair is never
  // reinterpreted as a coordinate.
  fileprivate func FBAXBridgeIsPointAttribute(key: String) -> Bool {
    key == axVisiblePoint || key == axCenterPoint
  }

  // Emit the `CGPoint` dictionary representation the host consumes, as the frame's coercion does. Rejection
  // matters more here than for the frame: the host taps these points and `{0,0}` is a plausible target.
  fileprivate func FBAXBridgePointDictionary(
    client: FBAXClient,
    pointValue: Any
  ) throws -> Any? {
    var point: CGPoint = .zero
    if let pointValue = pointValue as? NSDictionary {
      guard let snapshot = try client.snapshotPoint(pointValue).value else {
        return FBAXBridgeRejectedGeometry(kind: "point", value: pointValue)
      }
      return snapshot
    }
    let result = try client.point(fromValue: pointValue)
    guard let geometry = result.value else {
      return FBAXBridgeRejectedGeometry(kind: "point", value: pointValue)
    }
    geometry.getValue(&point, size: MemoryLayout.size(ofValue: point))
    return CGPointCreateDictionaryRepresentation(point) as NSDictionary
  }

  // Coerce an attribute value to a JSON-serializable form. Strings and numbers pass through; the frame
  // becomes a dictionary; anything else is stringified so the payload never fails serialization.
  fileprivate func FBAXBridgeJSONSafeValue(
    client: FBAXClient,
    value: Any?,
    key: String
  ) throws -> Any? {
    guard let value, !(value is NSNull) else {
      return NSNull()
    }
    if key == axFrame {
      return try FBAXBridgeFrameDictionary(client: client, frameValue: value)
    }
    if FBAXBridgeIsPointAttribute(key: key) {
      return try FBAXBridgePointDictionary(client: client, pointValue: value)
    }
    if value is String || value is NSNumber {
      return value
    }
    // The framework reports a failed attribute by returning the error in place of the value, so an error
    // arrives in the same shape as an answer. Stringifying it would describe the element as having that
    // string as the attribute — a label of "Error Domain=..." reads as a real label to anything matching on
    // one. Absent a value, the honest answer is that there is none; `kNodeAttributeReadFailures` carries
    // which keys failed and why.
    guard value is NSError else {
      return try client.description(ofValue: value).value
    }
    return NSNull()
  }

  // MARK: - Typed nodes

  // Sets the node's field for `key` from an attribute value `FBAXBridgeJSONSafeValue` has already coerced: a string, a
  // number, a geometry dictionary or null. The value is copied out under the runtime guard first, so a value that
  // raises when read fails the request rather than the guest. A key the shared model does not name is not carried, and
  // the children, explanation and read failures are set by the walk itself.
  fileprivate func FBAXBridgeAssign(_ value: Any?, forKey key: String, to node: inout BridgeAXNode) throws {
    guard let value, let field = BridgeAXWire.Node(rawValue: key) else { return }
    let plain = try FBAXWireValue.plainValue(of: value)
    switch field {
    case .elementType: node.elementType = FBAXBridgeScalar(plain)
    case .elementBaseType: node.elementBaseType = FBAXBridgeScalar(plain)
    case .label: node.label = FBAXBridgeScalar(plain)
    case .value: node.value = FBAXBridgeScalar(plain)
    case .identifier: node.identifier = FBAXBridgeScalar(plain)
    case .automationType: node.automationType = FBAXBridgeScalar(plain)
    case .frame: node.frame = FBAXBridgeRect(plain)
    case .visiblePoint: node.visiblePoint = FBAXBridgePoint(plain)
    case .centerPoint: node.centerPoint = FBAXBridgePoint(plain)
    case .xcTraits: node.xcTraits = FBAXBridgeInteger(plain).flatMap { UInt64(exactly: $0) }
    case .traits: node.traits = FBAXBridgeInteger(plain).flatMap { UInt64(exactly: $0) }
    case .elementIdentity: node.elementIdentity = FBAXBridgeInteger(plain).flatMap { UInt64(exactly: $0) }
    case .windowDisplayID: node.windowDisplayID = FBAXBridgeInteger(plain).flatMap { UInt32(exactly: $0) }
    case .translatorRole: node.translatorRole = FBAXBridgeInteger(plain).flatMap { Int(exactly: $0) }
    case .translatorSubrole: node.translatorSubrole = FBAXBridgeInteger(plain).flatMap { Int(exactly: $0) }
    case .isVisible: node.isVisible = FBAXBridgeFlag(plain)
    case .userInteractionEnabled: node.userInteractionEnabled = FBAXBridgeFlag(plain)
    case .isEnabled: node.isEnabled = FBAXBridgeFlag(plain)
    case .children, .explainedBy, .attributeReadFailures: return
    }
  }

  // MARK: - Tree walk

  // Whether the accessibility server said this node is reachable. Absent or non-boolean counts as
  // reachable, so an explanation is never attempted for a node the caller did not ask visibility about.
  fileprivate func FBAXBridgeNodeIsUnreachable(node: BridgeAXNode) -> Bool {
    node.isVisible == false
  }

  // The element a display-wide hit-test finds at `point`, described by the explanation fetch list, or nil.
  // Display-wide on purpose: an element covered by another process's chrome is covered whoever drew it.
  fileprivate func FBAXBridgeExplanationAtPoint(
    client: FBAXClient,
    point: CGPoint
  ) throws -> BridgeAXNode? {
    FBAXBridgeCountRoundTrip()
    let hit = try client.hitTest(at: point, processIdentifier: 0)
    if hit.status != FBAXHitTestStatus.hit {
      return nil
    }
    let hitElement = hit.element
    guard let hitElement else {
      return nil
    }
    FBAXBridgeCountRoundTrip()
    let read = try client.readAttributes(FBAXBridgeExplanationFetchList(), of: hitElement)
    guard read.status == FBAXReadStatus.read, let attributes = read.attributes else {
      return nil
    }
    var explanation = BridgeAXNode()
    // An explanation is the one element that answered; like a node of the walk, it carries no children.
    for key in attributes.keys where key != axChildren {
      try FBAXBridgeAssign(FBAXBridgeJSONSafeValue(client: client, value: attributes[key], key: key), forKey: key, to: &explanation)
    }
    return explanation
  }

  // Read from the node rather than derived from the frame, so it matches what the server measured
  // reachability against.
  fileprivate func FBAXBridgeNodeCentre(node: BridgeAXNode) -> CGPoint? {
    guard let x = node.centerPoint?.x, let y = node.centerPoint?.y else {
      return nil
    }
    return CGPoint(x: x, y: y)
  }

  // One mach round-trip per node: read the element's attributes, coerce them to JSON, then recurse into
  // its children (replacing the child `XCAccessibilityElement`s with their read dictionaries in place).
  //
  // A child that fails to read is dropped from the tree rather than failing the whole read, except one
  // that did not answer in time: its process is still working on that read, so every later read sent to
  // it would queue behind that work and time out in turn. When that process is the one the read is for,
  // or cannot be told apart from it, the child's outcome becomes the whole walk's. Another process drawing
  // part of the tree is only skipped for the rest of the walk.
  fileprivate func FBAXBridgeBuildNode(
    client: FBAXClient,
    element: FBAXElement,
    fetchList: [String],
    explainUnreachable: Bool,
    depth: Int,
    maxDepth: Int
  ) throws -> AccessibilityNodeRead {
    FBAXBridgeCountRoundTrip()
    let outcome = try client.readAttributes(fetchList, of: element)
    switch outcome.status {
    case FBAXReadStatus.applicationUnavailable:
      return .unread(FBAXReadOutcome.applicationUnavailable())
    case FBAXReadStatus.applicationNotResponding:
      let owner = depth > 0 ? try client.owningProcessIdentifier(of: element).int32Value : 0
      guard owner != 0, traversal.processIdentifier != 0, owner != traversal.processIdentifier else {
        return .unread(FBAXReadOutcome.applicationNotResponding())
      }
      traversal.unansweredProcesses.insert(owner)
      return .unread(FBAXReadOutcome.failed(outcome.error))
    case FBAXReadStatus.read:
      break
    case FBAXReadStatus.failed:
      fallthrough
    @unknown default:
      return .unread(FBAXReadOutcome.failed(outcome.error))
    }
    let attributes = outcome.attributes
    guard let attributes else {
      return .unread(FBAXReadOutcome.failed(FBAXBridgeInvariantError(description: "a read reported success but returned no attributes")))
    }

    var node = BridgeAXNode()
    var readFailures: [String: String]?
    for key in attributes.keys {
      if key == axChildren {
        continue
      }
      let value = attributes[key]
      if let value = value as? NSError {
        if readFailures == nil {
          readFailures = [:]
        }
        var description = try client.localizedDescription(ofError: value)
        if description.value == nil {
          description = try client.description(ofValue: value)
        }
        readFailures?[key] = description.value as String?
      }
      try FBAXBridgeAssign(FBAXBridgeJSONSafeValue(client: client, value: value, key: key), forKey: key, to: &node)
    }
    node.attributeReadFailures = readFailures

    var children: [BridgeAXNode] = []
    let childElements = try outcome.children()
    if depth < maxDepth {
      for child in childElements {
        if !traversal.emitted.insert(child).inserted {
          continue
        }
        if !traversal.unansweredProcesses.isEmpty,
          try traversal.unansweredProcesses.contains(client.owningProcessIdentifier(of: child).int32Value)
        {
          continue
        }
        if traversal.remainingNodes <= 0 {
          traversal.truncated = true
          break
        }
        traversal.remainingNodes -= 1
        let childOutcome = try FBAXBridgeBuildNode(
          client: client,
          element: child,
          fetchList: fetchList,
          explainUnreachable: explainUnreachable,
          depth: depth + 1,
          maxDepth: maxDepth
        )
        if childOutcome.status == FBAXReadStatus.applicationNotResponding {
          return childOutcome
        }
        if let child = childOutcome.node {
          children.append(child)
        }
      }
    } else if !childElements.isEmpty {
      traversal.truncated = true
    }
    node.children = children

    if explainUnreachable, FBAXBridgeNodeIsUnreachable(node: node), let centre = FBAXBridgeNodeCentre(node: node) {
      node.explainedBy = try FBAXBridgeExplanationAtPoint(client: client, point: centre)
    }
    return .read(node)
  }

  // MARK: - Translator vocabulary

  // What a translator node reads in its one request. Children are read separately, below.
  private var translatorNodeAttributes: [BridgeAXTranslatorAttribute] {
    [.label, .frame, .identifier, .value, .isVisible, .isEnabled, .role, .subrole, .visiblePoint, .traits, .memoryAddress]
  }

  // Builds a node through the translator's vocabulary, keyed the same way the XCTest walk keys it where the
  // two vocabularies agree, so the serializer above needs no knowledge of which one produced a tree. The two
  // attributes XCTest has no counterpart for — `enabled` and the translator's own `role` — are keyed in the
  // reader's namespace instead; see `kNodeIsEnabled` and `kNodeTranslatorRole`.
  fileprivate func FBAXBridgeBuildTranslatorNode(
    client: FBAXClient,
    element: FBAXElement,
    displayID: UInt32?,
    depth: Int,
    maxDepth: Int
  ) throws -> BridgeAXNode? {
    if traversal.remainingNodes <= 0 {
      traversal.truncated = true
      return nil
    }
    traversal.remainingNodes -= 1

    FBAXBridgeCountRoundTrip()
    let read = try client.translatorAttributes(
      translatorNodeAttributes.map { NSNumber(value: $0.rawValue) },
      of: element,
      clientType: UInt(traversal.clientType.rawValue)
    )
    // Nil is "could not read", not "empty element": building a node from it would report a failed bind as a
    // healthy application with no content.
    guard let values = BridgeAXTranslatorAnswer(resultData: read.value) else {
      return nil
    }
    var node = BridgeAXNode()
    if displayID != nil {
      FBAXBridgeCountRoundTrip()
      let identity = try client.readAttributes([axWindowDisplayID], of: element)
      try FBAXBridgeAssign(identity.attributes?[axWindowDisplayID], forKey: axWindowDisplayID, to: &node)
    }
    if values[.label] != nil {
      try FBAXBridgeAssign(values[.label], forKey: axLabel, to: &node)
    }
    if values[.identifier] != nil {
      try FBAXBridgeAssign(values[.identifier], forKey: axIdentifier, to: &node)
    }
    if values[.value] != nil {
      try FBAXBridgeAssign(
        FBAXBridgeJSONSafeValue(
          client: client,
          value: values[.value],
          key: axValue
        ), forKey: axValue, to: &node)
    }
    if values[.frame] != nil {
      try FBAXBridgeAssign(
        FBAXBridgeJSONSafeValue(
          client: client,
          value: values[.frame],
          key: axFrame
        ), forKey: axFrame, to: &node)
    }
    if values[.isVisible] != nil {
      try FBAXBridgeAssign(values[.isVisible], forKey: axisVisible, to: &node)
    }
    if values[.isEnabled] != nil {
      try FBAXBridgeAssign(values[.isEnabled], forKey: nodeIsEnabled, to: &node)
    }
    if values[.role] != nil {
      try FBAXBridgeAssign(values[.role], forKey: nodeTranslatorRole, to: &node)
    }
    if values[.subrole] != nil {
      try FBAXBridgeAssign(values[.subrole], forKey: nodeTranslatorSubrole, to: &node)
    }
    if values[.traits] != nil {
      try FBAXBridgeAssign(values[.traits], forKey: nodeTraits, to: &node)
    }
    if values[.memoryAddress] != nil {
      try FBAXBridgeAssign(values[.memoryAddress], forKey: nodeElementIdentity, to: &node)
    }
    // Keyed as XCTest names it, because the host derives `interactable` from that key and the two answer
    // the same question. Without it the derivation has hittability and no point, which is the shape it
    // reports as no verdict at all.
    if values[.visiblePoint] != nil {
      try FBAXBridgeAssign(
        FBAXBridgeJSONSafeValue(
          client: client,
          value: values[.visiblePoint],
          key: axVisiblePoint
        ), forKey: axVisiblePoint, to: &node)
    }

    var children: [BridgeAXNode] = []
    // Children are a separate request (the handler special-cases the attribute out of the batch). Asked even
    // at the depth cap, because `truncated` needs to know whether this node has children.
    FBAXBridgeCountRoundTrip()
    let childElements = try client.translatorElements(
      BridgeAXTranslatorAttribute.children.rawValue,
      of: element,
      clientType: UInt(traversal.clientType.rawValue)
    )
    if depth < maxDepth {
      for child in childElements {
        let built = try FBAXBridgeBuildTranslatorNode(
          client: client,
          element: child,
          displayID: displayID,
          depth: depth + 1,
          maxDepth: maxDepth
        )
        if let built {
          children.append(built)
        }
      }
    } else if !childElements.isEmpty {
      traversal.truncated = true
    }
    node.children = children
    return node
  }

  // MARK: - Modal detection

  // Recursively scans a built node for the concrete alert classes. `SBAlertItemWindow` (a SpringBoard
  // system alert window) sets `hasSystemAlertWindow`; the first `_UIAlertController*` view captures the
  // alert's element type and label (its title). Reads the same fields the tree carries on the wire.
  fileprivate func FBAXBridgeScanForAlert(
    node: BridgeAXNode,
    hasSystemAlertWindow: inout Bool,
    alertElementType: inout String?,
    alertLabel: inout String?
  ) {
    if case let .string(elementType)? = node.elementType {
      if elementType == systemAlertWindowClass {
        hasSystemAlertWindow = true
      }
      if alertElementType == nil && elementType.hasPrefix(alertControllerClassPrefix) {
        alertElementType = elementType
        if case let .string(label)? = node.label, !label.isEmpty {
          alertLabel = label
        }
      }
    }
    for child in node.children ?? [] {
      FBAXBridgeScanForAlert(node: child, hasSystemAlertWindow: &hasSystemAlertWindow, alertElementType: &alertElementType, alertLabel: &alertLabel)
    }
  }

  // A fullscreen-modal descriptor for a built tree, or nil when none is present. `kind` is `system` when
  // a SpringBoard alert window is present (a system/permission alert), otherwise `app` (an in-app UIKit
  // alert). Host-facing enrichment: the host reads this to detect a modal without geometry.
  fileprivate func FBAXBridgeModalDescriptor(tree: BridgeAXNode) -> BridgeAXModal? {
    var hasSystemAlertWindow = false
    var alertElementType: String?
    var alertLabel: String?
    FBAXBridgeScanForAlert(
      node: tree,
      hasSystemAlertWindow: &hasSystemAlertWindow,
      alertElementType: &alertElementType,
      alertLabel: &alertLabel
    )
    guard hasSystemAlertWindow || alertElementType != nil else {
      return nil
    }
    return BridgeAXModal(
      kind: hasSystemAlertWindow ? .system : .app,
      elementType: alertElementType ?? systemAlertWindowClass,
      label: alertLabel
    )
  }

  // MARK: - Frontmost resolution

  // Only a display-scoped hit-test asks through the translator, so only it carries `clientType`.
  fileprivate func FBAXBridgeHitTest(
    client: FBAXClient,
    at point: CGPoint,
    processIdentifier pid: pid_t,
    displayID: UInt32?,
    clientType: BridgeAXClientType
  ) throws -> FBAXElementHit {
    guard let displayID else { return try client.hitTest(at: point, processIdentifier: pid) }
    return try client.hitTest(at: point, processIdentifier: pid, displayIdentifier: displayID, clientType: UInt(clientType.rawValue))
  }

  // Bounds a descent against an accessibility tree that loops back on itself.
  private let hitTestMaxDescent = 64

  // Apple's hit-test answers with the element VoiceOver would focus, which can be a container whose
  // children a tree walk lists separately: a header that is one accessibility element over its own
  // buttons. Descends from it through the last-drawn child whose frame contains the point, so a hit-test
  // names the same element a tree walk shows there. Stops at a control or at an element with no child
  // under the point. The hit-test has already answered by the time this runs, so a read that fails or
  // raises never costs it that answer: a child that cannot be read is skipped, as a tree walk drops it, and
  // an element whose own read fails ends the descent there.
  fileprivate func FBAXBridgeDescendHit(client: FBAXClient, from element: FBAXElement, at point: CGPoint) -> FBAXElement {
    var current = element
    for _ in 0..<hitTestMaxDescent {
      FBAXBridgeCountRoundTrip()
      guard let read = try? client.readAttributes([axAutomationType, axChildren], of: current),
        read.status == FBAXReadStatus.read, let children = try? read.children()
      else {
        return current
      }
      if let automationType = read.attributes?[axAutomationType] as? NSNumber,
        client.elementType(forAutomationType: automationType.uintValue).isHitTestControl
      {
        return current
      }
      var next: FBAXElement?
      for child in children.reversed() {
        FBAXBridgeCountRoundTrip()
        guard let childRead = try? client.readAttributes([axFrame], of: child),
          childRead.status == FBAXReadStatus.read, let frameValue = childRead.attributes?[axFrame],
          let frame = (try? FBAXBridgeFrameDictionary(client: client, frameValue: frameValue)) as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: frame), rect.contains(point)
        else {
          continue
        }
        next = child
        break
      }
      guard let next else { return current }
      current = next
    }
    return current
  }

  // Resolves the frontmost application positionally: a system-wide hit-test at the caller's screen anchor
  // reads whichever element owns that point, and its owning pid is the frontmost app.
  //
  // A *positional* proxy for frontmost: agrees with the window server for a fullscreen app or the home
  // screen, but a centred element owned by another process (e.g. a system modal) answers that process.
  fileprivate func FBAXBridgeCenterPointFrontmost(
    client: FBAXClient,
    anchor: CGPoint,
    displayID: UInt32?
  ) throws -> FBAXFrontmostOutcome {
    FBAXBridgeCountRoundTrip()
    // Resolution asks which application is in front, not for its tree, so it claims no client.
    let outcome = try FBAXBridgeHitTest(client: client, at: anchor, processIdentifier: 0, displayID: displayID, clientType: .noClient)
    switch outcome.status {
    case FBAXHitTestStatus.hit:
      return FBAXFrontmostOutcome.resolved(outcome.owningProcessIdentifier)
    case FBAXHitTestStatus.empty:
      return FBAXFrontmostOutcome.unresolved(String(format: "system-wide hit-test at (%.1f, %.1f) found no element", anchor.x, anchor.y))
    case FBAXHitTestStatus.applicationUnavailable:
      return FBAXFrontmostOutcome.applicationUnavailable(String(format: "no accessibility server responded to the system-wide hit-test at (%.1f, %.1f)", anchor.x, anchor.y))
    case FBAXHitTestStatus.applicationNotResponding:
      return FBAXFrontmostOutcome.applicationNotResponding(String(format: "the application at (%.1f, %.1f) did not respond to the system-wide hit-test before it timed out", anchor.x, anchor.y))
    case FBAXHitTestStatus.failed:
      fallthrough
    @unknown default:
      return FBAXFrontmostOutcome.unresolved(outcome.failureReason ?? "the system-wide hit-test failed")
    }
  }

  // `center-point` is the positional hit-test at `anchor`; `window-server` (default) is the in-guest
  // AXPTranslator query; `runningboard` reads RunningBoard's visibility endowment. No fallback between
  // them: a caller who asked for the authoritative answer is not served by silently getting the proxy.
  fileprivate func FBAXBridgeResolveFrontmost(
    client: FBAXClient,
    method: FrontmostMethod,
    anchor: CGPoint,
    displayID: UInt32?
  ) throws -> FBAXFrontmostOutcome {
    switch method {
    case .centerPoint:
      return try FBAXBridgeCenterPointFrontmost(client: client, anchor: anchor, displayID: displayID)
    case .windowServer:
      guard let displayID else { return try client.windowServerFrontmost() }
      return try client.windowServerFrontmost(onDisplay: displayID)
    case .runningBoard:
      guard displayID == nil else { return FBAXFrontmostOutcome.unresolved("RunningBoard does not support display-specific frontmost lookup") }
      return try client.runningBoardFrontmost()
    }
  }

  // MARK: - Request handling

  fileprivate func FBAXBridgeErrorResponse(message: String) -> BridgeAXFailure {
    AccessibilityFailure.plain(message: message).failure
  }

  // A failure the host can act on: the message says what happened, the kind says what class of thing it
  // was, and the pid names the process it was about when there is one. A display-wide hit-test that nothing
  // answers has no pid to name, so it is optional rather than a sentinel the host has to know to ignore.
  fileprivate func FBAXBridgeTaggedErrorResponse(
    message: String,
    kind: BridgeAXWire.ErrorKind,
    pid: pid_t?
  ) -> BridgeAXFailure {
    AccessibilityFailure.tagged(message: message, kind: kind, pid: pid).failure
  }

  fileprivate func FBAXBridgeRuntimeFailureResponse(
    message: String,
    axError: NSNumber?,
    pid: pid_t?
  ) -> BridgeAXFailure {
    AccessibilityFailure.runtime(message: message, axError: axError, pid: pid).failure
  }

  fileprivate func FBAXBridgeNotRespondingResponse(message: String, pid: pid_t?) -> BridgeAXFailure {
    AccessibilityFailure.notResponding(message: message, pid: pid).failure
  }

  // The response a failed read answers with, or nil when it succeeded. Only the XCTest read produces these
  // statuses, which is why the translator path spends a round trip to obtain one.
  fileprivate func FBAXBridgeReadFailureResponse(
    client: FBAXClient,
    status: FBAXReadStatus,
    readError: (any Error)?,
    axError: NSNumber?,
    pid: pid_t
  ) throws -> BridgeAXFailure? {
    switch status {
    case FBAXReadStatus.read:
      return nil
    case FBAXReadStatus.applicationUnavailable:
      return FBAXBridgeTaggedErrorResponse(
        message: "pid \(pid) has no accessibility server",
        kind: .applicationUnavailable,
        pid: pid
      )
    case FBAXReadStatus.applicationNotResponding:
      return FBAXBridgeNotRespondingResponse(
        message: "pid \(pid) did not respond to the read of its element tree before it timed out",
        pid: pid
      )
    case FBAXReadStatus.failed:
      fallthrough
    @unknown default:
      let description = try client.localizedDescription(ofError: readError)
      return FBAXBridgeRuntimeFailureResponse(
        message: "failed to read the element tree for pid \(pid): \(description.value ?? "the accessibility runtime reported no error")",
        axError: axError,
        pid: pid
      )
    }
  }

  // Maps a snapshot lazily so the caller's budgets also bound cross-process continuations.
  // A continuation failure leaves the stub childless; an exception aborts the whole request.
  fileprivate func FBAXBridgeNodeFromSnapshot(
    client: FBAXClient,
    snapshotNode: FBAXSnapshotNode,
    fetchList: [String],
    ownerPid: pid_t,
    depth: Int,
    maxDepth: Int
  ) throws -> BridgeAXNode? {
    let valid = try snapshotNode.valid()
    guard valid.boolValue else {
      return nil
    }
    if traversal.remainingNodes <= 0 {
      traversal.truncated = true
      return nil
    }

    let nesting = try snapshotNode.children()
    if ownerPid != 0 && nesting.isEmpty {
      let processIdentifier = try client.snapshots.processIdentifier(for: snapshotNode)
      let elementPid = processIdentifier.int32Value
      if elementPid != 0 && elementPid != ownerPid {
        if depth >= maxDepth || traversal.remainingBoundaryFetches <= 0 {
          // A bound stopped the continuation, so the subtree is missing for the same reason one below the
          // depth cap is — and is reported the same way.
          traversal.truncated = true
        } else {
          traversal.remainingBoundaryFetches -= 1
          FBAXBridgeCountRoundTrip()
          let continuation = try client.snapshots.readContinuation(snapshotNode, attributeNames: fetchList)
          if let root = continuation.root {
            return try FBAXBridgeNodeFromSnapshot(
              client: client,
              snapshotNode: root,
              fetchList: fetchList,
              ownerPid: elementPid,
              depth: depth,
              maxDepth: maxDepth
            )
          }
          // Fall through and map the stub: absence, not an error, is also the walk's answer at a boundary
          // it cannot cross.
        }
      }
    }
    traversal.remainingNodes -= 1

    let attributes = try snapshotNode.attributes()
    var node = BridgeAXNode()
    for attribute in attributes {
      try FBAXBridgeAssign(
        FBAXBridgeJSONSafeValue(client: client, value: attribute.value, key: attribute.name), forKey: attribute.name, to: &node)
    }

    if depth >= maxDepth {
      if !nesting.isEmpty {
        traversal.truncated = true
      }
      return node
    }

    var children: [BridgeAXNode] = []
    for child in nesting {
      if !traversal.emitted.insert(child).inserted {
        continue
      }
      let built = try FBAXBridgeNodeFromSnapshot(
        client: client,
        snapshotNode: child,
        fetchList: fetchList,
        ownerPid: ownerPid,
        depth: depth + 1,
        maxDepth: maxDepth
      )
      if let built {
        children.append(built)
      }
    }
    node.children = children
    return node
  }

  // Answers `hittest`: one round trip reading only the element at the point. With no pid it is
  // display-wide, so the host learns the owning app without a separate frontmost query.
  fileprivate func FBAXBridgeHitTest(
    client: FBAXClient,
    point: CGPoint,
    pid: Int32?,
    attributes: [String]?,
    displayID: UInt32?,
    clientType: BridgeAXClientType
  ) throws -> BridgeAXOutcome<BridgeAXHitTestResponse> {

    FBAXBridgeCountRoundTrip()

    let outcome = try FBAXBridgeHitTest(client: client, at: point, processIdentifier: pid ?? 0, displayID: displayID, clientType: clientType)
    switch outcome.status {
    case FBAXHitTestStatus.hit:
      break
    case FBAXHitTestStatus.applicationUnavailable:
      return .failure(
        FBAXBridgeTaggedErrorResponse(
          message: pid != nil ? "pid \(pid ?? 0) has no accessibility server to hit-test" : "no accessibility server responded to the system-wide hit-test",
          kind: .applicationUnavailable,
          pid: pid
        ))
    case FBAXHitTestStatus.applicationNotResponding:
      return .failure(
        FBAXBridgeNotRespondingResponse(
          message: pid != nil ? "pid \(pid ?? 0) did not respond to the hit-test before it timed out" : "the application at the hit-test point did not respond before it timed out",
          pid: pid
        ))
    case FBAXHitTestStatus.empty:
      return .success(.empty)
    case FBAXHitTestStatus.failed:
      fallthrough
    @unknown default:
      return .failure(FBAXBridgeRuntimeFailureResponse(message: outcome.failureReason ?? "the hit-test failed", axError: outcome.axError, pid: pid))
    }

    traversal.remainingNodes = 1
    traversal.truncated = false
    // maxDepth 0 reads just the hit element's own attributes (no child recursion).
    guard let reported = outcome.element else {
      return .failure(FBAXBridgeErrorResponse(message: "the hit-test reported an element but returned none"))
    }
    let hitElement = FBAXBridgeDescendHit(client: client, from: reported, at: point)
    let read = try FBAXBridgeBuildNode(
      client: client,
      element: hitElement,
      fetchList: FBAXBridgeFetchList(attributes: attributes, displayID: displayID),
      explainUnreachable: false,
      depth: 0,
      maxDepth: 0
    )
    switch read.status {
    case FBAXReadStatus.read:
      break
    case FBAXReadStatus.applicationUnavailable:
      return .failure(
        FBAXBridgeTaggedErrorResponse(
          message: "pid \(outcome.owningProcessIdentifier) has no accessibility server",
          kind: .applicationUnavailable,
          pid: outcome.owningProcessIdentifier
        ))
    case FBAXReadStatus.applicationNotResponding:
      return .failure(
        FBAXBridgeNotRespondingResponse(
          message: "pid \(outcome.owningProcessIdentifier) did not respond to the read of the hit element before it timed out",
          pid: outcome.owningProcessIdentifier
        ))
    case FBAXReadStatus.failed:
      fallthrough
    @unknown default:
      return .failure(FBAXBridgeRuntimeFailureResponse(message: "failed to read the hit element", axError: read.axError, pid: outcome.owningProcessIdentifier))
    }
    let node = read.node
    guard let node else {
      return .failure(FBAXBridgeErrorResponse(message: "the hit element read reported success but returned no attributes"))
    }
    return .success(.element(node, pid: outcome.owningProcessIdentifier))
  }

  // MARK: - Writes

  // Compared in the coerced wire form: the host derived the assertion from a tree it read off this wire.
  fileprivate func FBAXBridgeAttributeMatches(
    client: FBAXClient,
    actual: Any?,
    expected: String
  ) throws -> Bool {
    try client.matches(actual, expected: expected).boolValue
  }

  fileprivate func FBAXBridgeWriteArgumentError(request: BridgeAXWriteRequest) -> BridgeAXFailure? {
    // Only a fetched attribute can be asserted on: the host built the assertion from a node it read, so a
    // key this request does not fetch cannot have come from there.
    guard let assertKey = request.assertion?.key.rawValue,
      !FBAXBridgeFetchList(attributes: request.attributes, displayID: request.displayID).contains(assertKey)
    else {
      return nil
    }
    return FBAXBridgeUnassertableKeyResponse(assertKey)
  }

  fileprivate func FBAXBridgeUnassertableKeyResponse(_ key: String) -> BridgeAXFailure {
    FBAXBridgeTaggedErrorResponse(message: "\(key) is not an attribute a write can assert on", kind: .badRequest, pid: nil)
  }

  // Between the host's read and this hit-test the element under the point can have changed (occlusion, a
  // non-rectangular element, a screen that moved on). Checking one attribute of what is actually there is
  // what stops the action landing somewhere else.
  fileprivate func FBAXBridgeResolveWriteTarget(
    client: FBAXClient,
    request: BridgeAXWriteRequest,
    element: inout FBAXElement?,
    pid: inout pid_t
  ) throws -> FBAXWriteOutcome? {
    let assertKey = request.assertion?.key.rawValue
    let assertValue = request.assertion?.value

    FBAXBridgeCountRoundTrip()
    let hit = try FBAXBridgeHitTest(
      client: client, at: CGPoint(x: request.x, y: request.y), processIdentifier: request.pid ?? 0, displayID: request.displayID,
      clientType: .noClient)
    switch hit.status {
    case FBAXHitTestStatus.hit:
      break
    case FBAXHitTestStatus.empty:
      return FBAXWriteOutcome.empty()
    case FBAXHitTestStatus.applicationUnavailable:
      return FBAXWriteOutcome.applicationUnavailable()
    case FBAXHitTestStatus.applicationNotResponding:
      return FBAXWriteOutcome.applicationNotResponding()
    case FBAXHitTestStatus.failed:
      fallthrough
    @unknown default:
      return FBAXWriteOutcome.failed(hit.failureReason ?? "the hit-test failed", axError: hit.axError)
    }
    let hitElement = hit.element
    guard let hitElement else {
      return FBAXWriteOutcome.failed("the hit-test reported an element but returned none")
    }
    pid = hit.owningProcessIdentifier

    if let assertKey {
      FBAXBridgeCountRoundTrip()
      let read = try client.readAttributes([assertKey], of: hitElement)
      switch read.status {
      case FBAXReadStatus.read:
        break
      case FBAXReadStatus.applicationUnavailable:
        return FBAXWriteOutcome.applicationUnavailable()
      case FBAXReadStatus.applicationNotResponding:
        return FBAXWriteOutcome.applicationNotResponding()
      // An assertion that cannot be read is not an assertion that failed — the caller is owed the
      // difference between "the screen moved" and "the element could not be inspected".
      case FBAXReadStatus.failed:
        fallthrough
      @unknown default:
        return FBAXWriteOutcome.failed("could not read \(assertKey) to check the assertion", axError: read.axError)
      }
      let actual = try FBAXBridgeJSONSafeValue(
        client: client,
        value: read.attributes?[assertKey],
        key: assertKey
      )
      let matches = try FBAXBridgeAttributeMatches(
        client: client,
        actual: actual,
        expected: assertValue ?? ""
      )
      if !matches {
        let description = try client.description(ofValue: actual)
        return FBAXWriteOutcome.assertionFailed(String(format: "the element at (%.1f, %.1f) has %@ %@, expected %@", request.x, request.y, assertKey, description.value ?? "(null)", assertValue ?? ""))
      }
    }

    element = hitElement
    return nil
  }

  // The envelope a write outcome is reported in. Total over the status, so every way a write can end has one
  // answer decided in one place rather than per verb.
  fileprivate func FBAXBridgeWriteResponse(outcome: FBAXWriteOutcome, pid: pid_t, sent: Bool) -> BridgeAXOutcome<BridgeAXWriteResponse> {
    let response = FBAXBridgeWriteOutcomeResponse(outcome: outcome, pid: pid)
    guard case var .failure(failure) = response else {
      return response
    }
    failure.effect = sent ? .unknown : BridgeAXWire.Effect.none
    return .failure(failure)
  }

  fileprivate func FBAXBridgeWriteOutcomeResponse(outcome: FBAXWriteOutcome, pid: pid_t) -> BridgeAXOutcome<BridgeAXWriteResponse> {
    switch outcome.status {
    case FBAXWriteStatus.written:
      return .success(.written(pid: pid))
    case FBAXWriteStatus.empty:
      return .success(.empty)
    case FBAXWriteStatus.assertionFailed:
      return .failure(BridgeAXFailure(message: outcome.failureReason ?? "the element at the point is not the one named", kind: .assertionFailed))
    case FBAXWriteStatus.applicationUnavailable:
      return .failure(
        FBAXBridgeTaggedErrorResponse(
          message: pid > 0 ? "pid \(pid) has no accessibility server to accept the write" : "no accessibility server responded to the write",
          kind: .applicationUnavailable,
          pid: pid > 0 ? pid : nil
        ))
    case FBAXWriteStatus.applicationNotResponding:
      return .failure(
        FBAXBridgeNotRespondingResponse(
          message: pid > 0 ? "pid \(pid) did not respond to the write before it timed out" : "the application did not respond to the write before it timed out",
          pid: pid > 0 ? pid : nil
        ))
    case FBAXWriteStatus.failed:
      fallthrough
    @unknown default:
      return .failure(FBAXBridgeRuntimeFailureResponse(message: outcome.failureReason ?? "the write failed", axError: outcome.axError, pid: pid > 0 ? pid : nil))
    }
  }

  // Answers `perform`. No pre-check that the element accepts the action — see
  // `+[FBAXWriteOutcome outcomeForWriteError:]`.
  fileprivate func FBAXBridgePerform(
    client: FBAXClient,
    request: BridgeAXWriteRequest,
    action requested: AccessibilityAction
  ) throws -> BridgeAXOutcome<BridgeAXWriteResponse> {
    let name = requested.rawValue
    let action = requested.runtimeValue
    let argumentError = FBAXBridgeWriteArgumentError(request: request)
    if let argumentError {
      return .failure(argumentError)
    }

    var element: FBAXElement?
    var pid: pid_t = 0
    var sent = false
    var outcome = try FBAXBridgeResolveWriteTarget(
      client: client,
      request: request,
      element: &element,
      pid: &pid
    )
    if outcome == nil, let element {
      FBAXBridgeCountRoundTrip()
      NSLog("%@", "[AccessibilityService] perform \(name) on pid \(pid): sending action once")
      sent = true
      let written = try client.perform(action, on: element)
      outcome = written
      NSLog("%@", "[AccessibilityService] perform \(name) on pid \(pid): status \(written.status.rawValue)")
    }
    guard let outcome else {
      throw FBAXBridgeInvariantError(description: "the write resolved no target or outcome")
    }
    return FBAXBridgeWriteResponse(outcome: outcome, pid: pid, sent: sent)
  }

  // Answers `setvalue`. Nothing an element reports says whether its value is writable, so — as with a
  // `perform` — the runtime's own answer is the only judgement.
  fileprivate func FBAXBridgeSetValue(
    client: FBAXClient,
    request: BridgeAXWriteRequest,
    value requestedValue: String
  ) throws -> BridgeAXOutcome<BridgeAXWriteResponse> {
    let argumentError = FBAXBridgeWriteArgumentError(request: request)
    if let argumentError {
      return .failure(argumentError)
    }

    var element: FBAXElement?
    var pid: pid_t = 0
    var sent = false
    var outcome = try FBAXBridgeResolveWriteTarget(
      client: client,
      request: request,
      element: &element,
      pid: &pid
    )
    if outcome == nil, let element {
      FBAXBridgeCountRoundTrip()
      NSLog("%@", "[AccessibilityService] setvalue on pid \(pid): sending write once")
      sent = true
      let written = try client.setValue(requestedValue, on: element)
      outcome = written
      NSLog("%@", "[AccessibilityService] setvalue on pid \(pid): status \(written.status.rawValue)")
      if outcome?.status == FBAXWriteStatus.applicationNotResponding {
        // A keyboard transition can outlast the first confirmation. Two attempts bound recovery
        // to ten seconds of AX reply waits without repeating the write.
        for attempt in 1...2 {
          if attempt > 1 {
            Thread.sleep(forTimeInterval: 0.1)
          }
          do {
            FBAXBridgeCountRoundTrip()
            let read = try client.readAttributes([axValue], of: element)
            NSLog("%@", "[AccessibilityService] setvalue confirmation \(attempt) on pid \(pid): status \(read.status.rawValue)")
            if read.status == FBAXReadStatus.read {
              if try FBAXWireValue.matchesString(read.attributes?[axValue], expected: requestedValue).boolValue {
                outcome = FBAXWriteOutcome.written()
                break
              }
            } else if read.status != FBAXReadStatus.applicationNotResponding {
              break
            }
          } catch {
            NSLog("%@", "[AccessibilityService] setvalue confirmation \(attempt) on pid \(pid) failed: \(error)")
            break
          }
        }
      }
    }
    guard let outcome else {
      throw FBAXBridgeInvariantError(description: "the write resolved no target or outcome")
    }
    return FBAXBridgeWriteResponse(outcome: outcome, pid: pid, sent: sent)
  }

  /// Reads the setting when `enabled` is nil, and writes it otherwise.
  fileprivate func FBAXBridgeDeviceSetting(
    client: FBAXClient,
    name requestedName: String,
    enabled: Bool?
  ) throws -> BridgeAXOutcome<BridgeAXSettingResponse> {
    guard let setting = AccessibilityDeviceSetting(rawValue: requestedName)?.runtimeValue else {
      return .failure(
        FBAXBridgeTaggedErrorResponse(
          message: "unsupported device setting: \(requestedName)",
          kind: .badRequest,
          pid: nil
        ))
    }
    let outcome = try enabled.map { try client.setEnabled($0, for: setting) } ?? client.enabledState(for: setting)
    switch outcome.status {
    case FBAXDeviceSettingStatus.resolved:
      return .success(BridgeAXSettingResponse(enabled: outcome.isEnabled))
    case FBAXDeviceSettingStatus.unavailable:
      return .failure(
        FBAXBridgeTaggedErrorResponse(
          message: outcome.failureReason ?? "device setting \(requestedName) is unavailable",
          kind: .capabilityUnavailable,
          pid: nil
        ))
    case FBAXDeviceSettingStatus.failed:
      fallthrough
    @unknown default:
      return .failure(
        FBAXBridgeTaggedErrorResponse(
          message: outcome.failureReason ?? "device setting \(requestedName) failed",
          kind: .readerUnavailable,
          pid: nil
        ))
    }
  }

  // A request that did not decode, answered in the words and kinds every other failure uses.
  fileprivate func FBAXBridgeDecodeFailureResponse(_ error: BridgeAXRequestError) -> BridgeAXFailure {
    func badRequest(_ message: String) -> BridgeAXFailure {
      FBAXBridgeTaggedErrorResponse(message: message, kind: .badRequest, pid: nil)
    }
    // The frame is JSON from the client, so an unrecognised verb or action can be of any type.
    func describe(_ value: BridgeAXRequestError.Found?) -> String {
      switch value {
      case nil: "(nil)"
      case let .string(string): string
      case let .integer(integer): String(integer)
      case let .number(number): String(number)
      case let .bool(bool): String(bool)
      case .null: "null"
      case .array: "an array"
      case .object: "an object"
      }
    }
    switch error {
    case let .unsupportedVerb(value):
      return badRequest("unsupported verb: \(describe(value))")
    case let .nonPositivePid(pid):
      return FBAXBridgeTaggedErrorResponse(message: "pid \(pid) names no application", kind: .applicationUnavailable, pid: pid)
    case .invalidDisplayID:
      return badRequest("displayID must be a positive 32-bit integer")
    case .missingPoint(.describe):
      return badRequest("describe requires either a numeric pid or the frontmost anchor (x, y)")
    case .missingPoint(.hitTest):
      return badRequest("hittest requires numeric x and y")
    case .missingPoint:
      return badRequest("a write requires numeric x and y")
    case let .unsupportedAction(value):
      return badRequest("unsupported action: \(describe(value))")
    case .missingValue:
      return badRequest("setvalue requires a string value")
    case .unpairedAssertion:
      return badRequest("\(requestAssertKey) and \(requestAssertValue) are only meaningful together")
    case let .unassertableKey(key):
      return FBAXBridgeUnassertableKeyResponse(key)
    case .missingSetting:
      return badRequest("device settings require a setting name")
    case .missingEnabled:
      return badRequest("settings-set requires a boolean enabled value")
    case let .unsupportedFrontmostMethod(method):
      return FBAXBridgeTaggedErrorResponse(message: "unsupported frontmost method: \(method)", kind: .frontmostUnresolved, pid: nil)
    case let .negativeTunable(key, value):
      return badRequest("\(key.key) must not be negative, got \(value)")
    case let .malformedFlag(key):
      return badRequest("\(key.key) must be a boolean")
    case let .clientTypeNeedsSemanticTraversal(traversal):
      return badRequest("a client type applies only to the semantic traversal: \(traversal.rawValue) makes no translator request")
    case let .unsupportedClientType(value):
      guard let value else {
        return badRequest("a read or hit-test requires a client type: an integer from 0 to \(BridgeAXClientType.allCases.count - 1)")
      }
      return badRequest("unsupported client type: \(describe(value)); expected an integer from 0 to \(BridgeAXClientType.allCases.count - 1)")
    case let .undecodable(reason):
      return badRequest("the request does not decode: \(reason)")
    case let .unsupportedTraversal(value):
      let traversals = BridgeAXTraversal.allCases.map(\.rawValue).joined(separator: ", ")
      guard let value else {
        return badRequest("a read requires a traversal: one of \(traversals)")
      }
      return badRequest("unsupported traversal: \(describe(value)); expected one of \(traversals)")
    }
  }

  fileprivate func FBAXBridgeDispatchRequest(request: BridgeAXRequest) throws -> BridgeAXAnswer {
    if request.verb == .quiet || request.verb == .settingsObserve {
      return .failure(
        FBAXBridgeTaggedErrorResponse(
          message: "\(request.verb.rawValue) streams its answer, so it is only served over a serve connection or the one-shot CLI",
          kind: .badRequest,
          pid: nil
        ))
    }

    let client: FBAXClient
    do {
      client = try FBAXClientProvider.client()
    } catch {
      return .failure(
        FBAXBridgeTaggedErrorResponse(
          message: error.localizedDescription,
          kind: .readerUnavailable,
          pid: nil
        ))
    }

    switch request {
    case .quiescence, .deviceSettingChanges:
      throw FBAXBridgeInvariantError(description: "\(request.verb.rawValue) was answered before the reader was bound")
    case .displays:
      let outcome = client.displayInventory()
      switch outcome.status {
      case .available:
        let inventory = BridgeAXDisplayInventory(
          displayScopedInteractions: true,
          displayScopedTrees: true,
          displayScopedQuiescence: true,
          displays: outcome.displays.map { BridgeAXDisplayInventory.Display(uniqueID: $0.uniqueID, displayID: $0.displayID) }
        )
        return .displays(inventory)
      case .unavailable:
        return .failure(
          FBAXBridgeTaggedErrorResponse(
            message: outcome.failureReason ?? "Accessibility display inventory is unavailable",
            kind: .capabilityUnavailable, pid: nil))
      case .failed:
        return .failure(
          FBAXBridgeTaggedErrorResponse(
            message: outcome.failureReason ?? "Accessibility display inventory failed",
            kind: .readerUnavailable, pid: nil))
      @unknown default:
        return .failure(
          FBAXBridgeTaggedErrorResponse(
            message: "Unknown accessibility display inventory outcome",
            kind: .readerUnavailable, pid: nil))
      }

    case let .deviceSettingRead(name):
      return BridgeAXAnswer(try FBAXBridgeDeviceSetting(client: client, name: name, enabled: nil), BridgeAXAnswer.setting)
    case let .deviceSettingWrite(name, enabled):
      return BridgeAXAnswer(try FBAXBridgeDeviceSetting(client: client, name: name, enabled: enabled), BridgeAXAnswer.setting)
    // `hittest` is self-contained: with a pid it hit-tests that app; with no pid it hit-tests display-wide
    // — the app owning the point, resolved in-guest, with no frontmost pid query.
    case let .hitTest(x, y, attributes, clientType, displayID, pid):
      return BridgeAXAnswer(
        try FBAXBridgeHitTest(
          client: client, point: CGPoint(x: x, y: y), pid: pid, attributes: attributes, displayID: displayID, clientType: clientType), BridgeAXAnswer.hitTest)
    // Writes are point-addressed: a one-shot guest exits between requests, so an element handle cannot
    // survive one.
    case let .write(write):
      switch write.kind {
      case let .perform(action):
        return BridgeAXAnswer(try FBAXBridgePerform(client: client, request: write, action: action), BridgeAXAnswer.write)
      case let .setValue(value):
        return BridgeAXAnswer(try FBAXBridgeSetValue(client: client, request: write, value: value), BridgeAXAnswer.write)
      }
    case let .read(pid, options, displayID):
      return BridgeAXAnswer(try FBAXBridgeDescribe(client: client, pid: pid, frontmost: nil, options: options, displayID: displayID), BridgeAXAnswer.tree)
    case let .readFrontmost(x, y, method, options, displayID):
      return BridgeAXAnswer(try FBAXBridgeDescribe(client: client, pid: 0, frontmost: (method, CGPoint(x: x, y: y)), options: options, displayID: displayID), BridgeAXAnswer.tree)
    }
  }

  // `describe`: an explicit `pid` names the app directly; with no pid it is a fused frontmost read — the
  // guest resolves the frontmost app in-guest (via the selected method, anchored at `x`/`y`) and reads
  // its tree in this one call, with no separate pid round-trip.
  fileprivate func FBAXBridgeDescribe(
    client: FBAXClient,
    pid requestedPid: pid_t,
    frontmost: (method: FrontmostMethod, anchor: CGPoint)?,
    options: BridgeAXReadOptions,
    displayID: UInt32?
  ) throws -> BridgeAXOutcome<BridgeAXTreeResponse> {
    var pid = requestedPid
    // Automation mode determines the structure visible to both frontmost discovery and traversal.
    var automationAsserted = false
    var automation = try client.automationModeEnabled()
    var automationEnabled = automation.boolValue
    if let wanted = options.automationMode {
      // Only write when it would change something. A no-op write is still a preference write, and
      // reporting `asserted` for one would tell a caller this read altered a device it left alone.
      if wanted != automationEnabled {
        automation = try client.setAutomationModeEnabled(wanted)
        automationEnabled = automation.boolValue
        // True only if the write took; a preference write can be accepted and not apply.
        automationAsserted = automationEnabled == wanted
      }
    }

    if let frontmost {
      let resolved = try FBAXBridgeResolveFrontmost(
        client: client,
        method: frontmost.method,
        anchor: frontmost.anchor,
        displayID: displayID
      )
      switch resolved.status {
      case FBAXFrontmostStatus.resolved:
        break
      case FBAXFrontmostStatus.applicationUnavailable:
        return .failure(
          FBAXBridgeTaggedErrorResponse(
            message: resolved.failureReason ?? "nothing frontmost has an accessibility server",
            kind: .applicationUnavailable,
            pid: nil
          ))
      case FBAXFrontmostStatus.applicationNotResponding:
        return .failure(
          FBAXBridgeNotRespondingResponse(
            message: resolved.failureReason ?? "the frontmost application did not respond before it timed out",
            pid: nil
          ))
      case FBAXFrontmostStatus.unresolved:
        fallthrough
      @unknown default:
        return .failure(
          FBAXBridgeTaggedErrorResponse(
            message: resolved.failureReason ?? "could not resolve the frontmost application pid",
            kind: .frontmostUnresolved,
            pid: nil
          ))
      }
      pid = resolved.processIdentifier
    }

    let application = try client.applicationElement(forProcessIdentifier: pid)
    let root = application.value
    guard let root else {
      return .failure(FBAXBridgeErrorResponse(message: "no application element for pid \(pid)"))
    }
    // A tree read the application did not answer is still running there, and another sent now would queue
    // behind it: every caller that retries on a timeout adds a whole serialization to a main thread already
    // behind. One attribute read, which queues behind the same work, asks whether it has finished; its own
    // timeout bounds the wait. Only when it has does the application get another tree to build.
    if FBAXClientProvider.hasUnansweredRead(forProcessIdentifier: pid) {
      let probe = try client.readAttributes([axElementType], of: root)
      if probe.status == FBAXReadStatus.applicationNotResponding {
        return .failure(AccessibilityFailure.outstanding(pid: pid).failure)
      }
      FBAXClientProvider.setHasUnansweredRead(false, forProcessIdentifier: pid)
    }

    let maxDepth = options.maxDepth
    let nodeBudget = options.maxNodes

    var tree: BridgeAXNode?
    traversal = TraversalContext(remainingNodes: nodeBudget, processIdentifier: pid, clientType: options.clientType)
    let traverseStarted = CFAbsoluteTimeGetCurrent()
    if options.traversal == .singleFetch {
      let names = FBAXBridgeFetchList(attributes: options.attributes, displayID: displayID)
      let snapshot = try client.snapshots.read(root, attributeNames: names)
      guard let snapshotRoot = snapshot.root else {
        // The snapshot reports no reason a timeout can be told apart by, so any failure counts as one: a
        // wrong guess costs the next read one attribute probe.
        FBAXClientProvider.setHasUnansweredRead(true, forProcessIdentifier: pid)
        let description = try client.localizedDescription(ofError: snapshot.error)
        return .failure(
          FBAXBridgeNotRespondingResponse(
            message: (description.value as String?) ?? "the single-fetch read returned no tree",
            pid: pid
          ))
      }
      // One fetch for the whole tree, counted up-front so the boundary continuations the mapper fetches
      // land on top of it.
      traversal.roundTrips = 1
      // The owner every node's element is compared against, read from the snapshot's own root element
      // rather than taken from the request: the two agree on a live runtime, and a runtime that cannot
      // attribute elements answers 0, which disables boundary continuation rather than mistargeting it.
      let processIdentifier = try client.snapshots.processIdentifier(for: snapshotRoot)
      let ownerPid = processIdentifier.int32Value
      tree = try FBAXBridgeNodeFromSnapshot(
        client: client,
        snapshotNode: snapshotRoot,
        fetchList: names,
        ownerPid: ownerPid,
        depth: 0,
        maxDepth: maxDepth
      )
      if tree == nil {
        return .failure(FBAXBridgeErrorResponse(message: "the single-fetch read returned a shape with no root node"))
      }
    } else if options.traversal == .semantic {
      // Whether the application is there at all is a question only the XCTest read answers. The runtime
      // vends an application element for any pid, including one that names no process, and the translator
      // answers against it with synthesized defaults rather than failing — so without this check the read
      // would report a healthy tree for a dead process. One extra round trip, on the opt-in path only.
      let availability = try client.readAttributes([axElementType], of: root)
      if availability.status == FBAXReadStatus.applicationNotResponding {
        FBAXClientProvider.setHasUnansweredRead(true, forProcessIdentifier: pid)
      }
      let unavailable = try FBAXBridgeReadFailureResponse(
        client: client,
        status: availability.status,
        readError: availability.error,
        axError: availability.axError,
        pid: pid
      )
      if let unavailable {
        return .failure(unavailable)
      }
      tree = try FBAXBridgeBuildTranslatorNode(
        client: client,
        element: root,
        displayID: displayID,
        depth: 0,
        maxDepth: maxDepth
      )
      if tree == nil {
        return .failure(FBAXBridgeErrorResponse(message: "the translator vocabulary returned no attributes for this element"))
      }
    } else {
      let read = try FBAXBridgeBuildNode(
        client: client,
        element: root,
        fetchList: FBAXBridgeFetchList(attributes: options.attributes, displayID: displayID),
        explainUnreachable: options.explainUnreachable,
        depth: 0,
        maxDepth: maxDepth
      )
      if read.status == FBAXReadStatus.applicationNotResponding {
        FBAXClientProvider.setHasUnansweredRead(true, forProcessIdentifier: pid)
      }
      let failure = try FBAXBridgeReadFailureResponse(
        client: client,
        status: read.status,
        readError: read.error,
        axError: read.axError,
        pid: pid
      )
      if let failure {
        return .failure(failure)
      }
      tree = read.node
      if tree == nil {
        return .failure(FBAXBridgeErrorResponse(message: "the tree read reported success but returned no attributes"))
      }
    }
    // Closed before the response is assembled, so it measures the walk and not the bookkeeping after it.
    let traverseDuration = CFAbsoluteTimeGetCurrent() - traverseStarted

    // Always report the pid read, so the host tags elements with it — for a fused frontmost read the host
    // does not know the pid until now. `method` rides along when the pid was resolved in-guest.
    guard var tree else {
      throw FBAXBridgeInvariantError(description: "the tree read reported success but returned no attributes")
    }
    if let displayID {
      guard let scoped = try treeOnDisplay(tree, displayID: displayID) else {
        return .failure(
          FBAXBridgeTaggedErrorResponse(
            message: "Application has no window on the requested display", kind: .applicationUnavailable, pid: pid))
      }
      tree = scoped
    }
    return .success(
      BridgeAXTreeResponse(
        tree: tree,
        pid: pid,
        truncated: traversal.truncated,
        automation: BridgeAXAutomationState(enabled: automationEnabled, asserted: automationAsserted),
        phases: BridgeAXGuestPhases(traverseMilliseconds: traverseDuration * 1000, machRoundTrips: traversal.roundTrips),
        method: frontmost?.method,
        // A fullscreen-modal descriptor when one is present in the tree, so the host can detect it without geometry.
        modal: FBAXBridgeModalDescriptor(tree: tree)))
  }

  // MARK: - Quiescence

  fileprivate func FBAXBridgeQuiescenceStream(
    pid: Int32?,
    busyThresholdMs: Int?,
    quietWindowMs: Int?,
    displayID: UInt32?,
    method: FrontmostMethod,
    anchor: CGPoint
  ) -> QuiescenceStream {
    QuiescenceStream(
      target: pid.map { .pid($0) } ?? .frontmost,
      busyThreshold: TimeInterval(busyThresholdMs ?? BridgeAXWire.Quiescence.defaultBusyThresholdMs) / 1000,
      quietWindow: TimeInterval(quietWindowMs ?? BridgeAXWire.Quiescence.defaultQuietWindowMs) / 1000,
      resolveFrontmost: { client in try AccessibilityRequest().FBAXBridgeResolveFrontmost(client: client, method: method, anchor: anchor, displayID: displayID) }
    )
  }

  // MARK: - Testing

  fileprivate func FBAXBridgeWireConstantsForTesting() -> [String: String] {
    [
      "node.elementType": axElementType, "node.elementBaseType": axElementBaseType, "node.label": axLabel, "node.value": axValue, "node.identifier": axIdentifier, "node.frame": axFrame, "node.automationType": axAutomationType, "node.children": axChildren, "node.windowDisplayID": axWindowDisplayID, "request.verb": requestVerb, "request.pid": requestPid, "request.maxDepth": requestMaxDepth, "request.maxNodes": requestMaxNodes, "request.automationMode": requestAutomationMode, "request.attributes": requestAttributes, "request.traversal": requestTraversal, "request.clientType": requestClientType, "request.explainUnreachable": requestExplainUnreachable, "node.explainedBy": nodeExplainedBy, "node.isEnabled": nodeIsEnabled, "node.translatorRole": nodeTranslatorRole, "node.translatorSubrole": nodeTranslatorSubrole, "node.traits": nodeTraits, "node.elementIdentity": nodeElementIdentity, "request.displayID": requestDisplayID, "request.x": requestX, "request.y": requestY, "request.method": requestMethod, "request.action": requestAction, "request.value": requestValue, "request.setting": requestSetting, "request.enabled": requestEnabled, "request.assertKey": requestAssertKey, "request.assertValue": requestAssertValue, "envelope.ok": responseOk, "envelope.enabled": responseEnabled, "envelope.tree": responseTree, "envelope.error": responseError, "envelope.empty": responseEmpty, "envelope.errorKind": responseErrorKind, "envelope.errorKindApplicationUnavailable": errorKindApplicationUnavailable, "envelope.errorKindApplicationNotResponding": errorKindApplicationNotResponding, "envelope.errorKindFrontmostUnresolved": errorKindFrontmostUnresolved, "envelope.errorKindCapabilityUnavailable": BridgeAXWire.ErrorKind.capabilityUnavailable.rawValue, "envelope.errorKindReaderUnavailable": errorKindReaderUnavailable, "envelope.errorKindBadRequest": errorKindBadRequest, "envelope.errorKindAssertionFailed": errorKindAssertionFailed, "envelope.truncated": responseTruncated,
      "envelope.pid": responsePid,
      "envelope.method": responseMethod, "envelope.modal": responseModal,
      "envelope.automation": responseAutomation,
      "envelope.phases": responsePhases,
      "phases.traverse": phaseTraverse,
      "phases.machRoundTrips": phaseMachRoundTrips, "automation.enabled": kAutomationEnabled, "automation.asserted": kAutomationAsserted, "modal.kind": modalKind, "modal.kindSystem": modalKindSystem, "modal.kindApp": modalKindApp, "modal.elementType": modalElementType, "modal.label": modalLabel, "modal.systemAlertWindowClass": systemAlertWindowClass, "modal.alertControllerClassPrefix": alertControllerClassPrefix, "verb.displays": AccessibilityVerb.displays.rawValue, "verb.describe": AccessibilityVerb.describe.rawValue, "verb.hittest": AccessibilityVerb.hitTest.rawValue, "verb.perform": AccessibilityVerb.perform.rawValue, "verb.setvalue": AccessibilityVerb.setValue.rawValue, "verb.settingsGet": AccessibilityVerb.settingsGet.rawValue, "verb.settingsSet": AccessibilityVerb.settingsSet.rawValue, "verb.settingsObserve": AccessibilityVerb.settingsObserve.rawValue, "verb.quiet": AccessibilityVerb.quiet.rawValue, "request.busyThresholdMs": requestBusyThresholdMs, "request.quietWindowMs": requestQuietWindowMs, "action.press": AccessibilityAction.press.rawValue, "action.scrollUp": AccessibilityAction.scrollUp.rawValue, "action.scrollDown": AccessibilityAction.scrollDown.rawValue, "action.scrollLeft": AccessibilityAction.scrollLeft.rawValue, "action.scrollRight": AccessibilityAction.scrollRight.rawValue, "action.scrollToVisible": AccessibilityAction.scrollToVisible.rawValue, "method.centerPoint": FrontmostMethod.centerPoint.rawValue, "method.windowServer": FrontmostMethod.windowServer.rawValue, "method.runningBoard": FrontmostMethod.runningBoard.rawValue,
    ]
  }

}

// Objective-C runtime clients convert private-framework exceptions to NSError before returning here.
// Answer those errors on the shared dispatcher path so the serve connection can handle later requests.
public enum AccessibilityService {

  /// The answer to the request `payload` spells as flat parameters.
  public static func answer(_ payload: [String: Any]) -> BridgeAXAnswer {
    do {
      return handleRequest(try request(payload))
    } catch {
      return .failure(failure(error))
    }
  }

  /// Reads a request from the flat parameters the JSON object `parameters` spells, and answers it.
  public static func handleRequest(parameters: Data) -> BridgeAXAnswer {
    do {
      return handleRequest(try AccessibilityParameters.request(json: parameters))
    } catch {
      return .failure(failure(error))
    }
  }

  /// The answer to a request that did not decode, in the words and kind every other failure uses.
  public static func failure(_ error: BridgeAXRequestError) -> BridgeAXFailure {
    AccessibilityRequest().FBAXBridgeDecodeFailureResponse(error)
  }

  /// Answers `request`, refusing one that means nothing however it arrived.
  public static func handleRequest(_ request: BridgeAXRequest) -> BridgeAXAnswer {
    do {
      try request.validate()
    } catch {
      return .failure(failure(error))
    }
    do {
      return try AccessibilityRequest().FBAXBridgeDispatchRequest(request: request)
    } catch AXDisplayScopeError.missingWindowIdentity {
      return .failure(BridgeAXFailure(message: "Cannot scope accessibility: a window has no valid display identity", kind: .capabilityUnavailable))
    } catch {
      return .failure(BridgeAXFailure(message: "the reader raised while answering: \(error.localizedDescription)"))
    }
  }

  /// The accessibility stream named by `request`, or nil for a unary verb.
  static func stream(_ request: BridgeAXRequest) -> AccessibilityStreamStart? {
    guard request.verb == .quiet || request.verb == .settingsObserve else { return nil }
    do {
      try request.validate()
    } catch {
      return .failure(failure(error))
    }
    return quiescence(request) ?? settings(request)
  }

  private static func quiescence(_ request: BridgeAXRequest) -> AccessibilityStreamStart? {
    guard case let .quiescence(pid, busyThresholdMs, quietWindowMs, displayID, method, x, y) = request else { return nil }
    return .stream(
      AccessibilityRequest().FBAXBridgeQuiescenceStream(
        pid: pid, busyThresholdMs: busyThresholdMs, quietWindowMs: quietWindowMs, displayID: displayID, method: method,
        anchor: CGPoint(x: x, y: y)))
  }

  /// The request flat parameters built in process spell. They are JSON by construction; a value that is not reaches
  /// the reader as no field at all.
  private static func request(_ payload: [String: Any]) throws(BridgeAXRequestError) -> BridgeAXRequest {
    try AccessibilityParameters.request(payload.filter { JSONSerialization.isValidJSONObject([$0.value]) })
  }

  /// The fullscreen modal in `tree`, as a frontmost read reports it.
  public static func modal(in tree: BridgeAXNode) -> BridgeAXModal? {
    AccessibilityRequest().FBAXBridgeModalDescriptor(tree: tree)
  }

  public static func wireConstantsForTesting() -> [String: String] {
    AccessibilityRequest().FBAXBridgeWireConstantsForTesting()
  }

  public static func handleAction(_ action: String, arguments: [String], writeResponse: (Data) -> Bool) -> Int32 {
    let request: BridgeAXRequest
    do {
      request = try Self.request(AXBridgeArguments.request(action: action, arguments: arguments))
    } catch {
      _ = writeResponse(BridgeAXAnswer.failure(failure(error)).encoded())
      return 1
    }
    // A streaming action writes one event per line until its source ends or the process is killed.
    if let start = stream(request) {
      switch start {
      case let .stream(stream):
        var lostOutput = false
        withoutActuallyEscaping(writeResponse) { writeResponse in
          stream.run { answer in
            lostOutput = !writeResponse(answer.encoded())
            return !lostOutput
          }
        }
        return stream.failed || lostOutput ? 1 : 0
      case let .failure(failure):
        _ = writeResponse(BridgeAXAnswer.failure(failure).encoded())
        return 1
      }
    }
    let answer = handleRequest(request)
    _ = writeResponse(answer.encoded())
    return answer.succeeded ? 0 : 1
  }
}

// MARK: - FBXCUIElementType

extension FBXCUIElementType {
  // Whether a hit-test descent stops here, so a hit on a button names the button rather than the text
  // inside it. Cells are not controls: a hit on a cell should still reach the control inside it.
  var isHitTestControl: Bool {
    switch self {
    case .button, .radioButton, .checkBox, .disclosureTriangle, .popUpButton, .key, .slider, .segmentedControl,
      .picker, .pickerWheel, .switch, .toggle, .link, .searchField, .textField, .secureTextField, .textView,
      .menuItem, .stepper, .tab:
      return true
    case .any, .other:
      return false
    @unknown default:
      return false
    }
  }
}
