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

/// Walks an axbridge `BridgeAXNode` tree and provides marker matching and
/// frame-centre geometry. Per-node serialization is delegated to
/// `AXNodeSerializer`.
enum AXTreeWalk {

  /// Serializes a node tree into the schema, tagging each element with `pid`. The
  /// result is unfiltered so a caller can keep both the whole walk and the reported subset.
  static func describeAllElements(fromTree tree: BridgeAXNode, keys: Set<AXKeys>, nestedFormat: Bool, pid: pid_t) -> [AccessibilityDocumentElement] {
    AXNodeSerializer.recursiveDescription(
      fromSnapshot: snapshot(fromTree: tree, pid: pid), serialization: AXSerialization(keys: keys, nested: nestedFormat),
      collector: nil, seenPids: nil)
  }

  /// The snapshot a serialization consumes, decoded from a node tree the guest has already fetched.
  static func snapshot(fromTree tree: BridgeAXNode, pid: pid_t) -> AXElementSnapshot {
    AXBridgeSnapshotDecoder.snapshot(fromTree: tree, pid: pid)
  }

  /// The bounds a whole-tree read's frames are relative to, taken from the root node's own frame — for
  /// an application read the root is the application element, which spans the screen. `nil` when the
  /// root reports no usable frame, so an unknown screen is reported as unknown rather than as zero.
  ///
  /// Decodes the frame as the serializer's snapshots do, so this cannot disagree with the frames on the
  /// elements it describes.
  static func screenInfo(fromTree tree: BridgeAXNode) -> AccessibilityScreenInfo? {
    let frame = AXBridgeSnapshotDecoder.snapshot(fromNode: tree, pid: 0).frame
    guard frame.width > 0, frame.height > 0 else {
      return nil
    }
    return AccessibilityScreenInfo(width: Double(frame.width), height: Double(frame.height))
  }

  /// The element a marker names: the first whose `key` value equals `markerValue`, otherwise the first
  /// that contains it, via `AccessibilityMatch` so a marker and `--match` agree on what "contains" means.
  static func matchingElement(
    inElements elements: [AccessibilityDocumentElement],
    markerValue: String,
    key: AXSearchableKey,
    ignoresCase: Bool = false
  ) -> AccessibilityDocumentElement? {
    preferredMatch(inElements: elements, markerValue: markerValue, key: key, ignoresCase: ignoresCase) { $0 }.resolved
  }

  /// The first match `resolve` accepts whose `key` value equals `markerValue`, otherwise the first it
  /// accepts that only contains it. `matched` is whether anything matched, accepted or not.
  private static func preferredMatch<Resolved>(
    inElements elements: [AccessibilityDocumentElement],
    markerValue: String,
    key: AXSearchableKey,
    ignoresCase: Bool,
    resolve: (AccessibilityDocumentElement) -> Resolved?
  ) -> (resolved: Resolved?, matched: Bool) {
    let predicate = AccessibilityMatch(value: markerValue, key: key, ignoresCase: ignoresCase)
    var matched = false
    var firstContaining: Resolved?
    for element in elements {
      guard let value = element.searchableValue(for: key) else {
        continue
      }
      if let predicate, !predicate.matches(value) {
        continue
      }
      matched = true
      guard let resolved = resolve(element) else {
        continue
      }
      // An empty marker matches every element carrying the key, so the first of them wins.
      guard let predicate else {
        return (resolved, true)
      }
      if isEqual(value, to: predicate) {
        return (resolved, true)
      }
      firstContaining = firstContaining ?? resolved
    }
    return (firstContaining, matched)
  }

  private static func isEqual(_ value: String, to predicate: AccessibilityMatch) -> Bool {
    guard predicate.ignoresCase else {
      return value == predicate.value
    }
    return value.caseInsensitiveCompare(predicate.value) == .orderedSame
  }

  /// Searches in order, retaining only nonmatching values of `key` visited before the first match.
  static func search(
    inElements elements: [AccessibilityDocumentElement],
    markerValue: String,
    key: AXSearchableKey,
    ignoresCase: Bool = false
  ) -> AccessibilitySearchResult<AccessibilityDocumentElement> {
    let predicate = AccessibilityMatch(value: markerValue, key: key, ignoresCase: ignoresCase)
    var diagnostics = AccessibilitySearchDiagnostics()
    for element in elements {
      guard let value = element.searchableValue(for: key) else {
        continue
      }
      // An empty marker matches every element carrying the requested key.
      if predicate?.matches(value) ?? true {
        return AccessibilitySearchResult(match: element, diagnostics: diagnostics)
      }
      diagnostics.record(value)
    }
    return AccessibilitySearchResult(match: nil, diagnostics: diagnostics)
  }

  /// The outcome of resolving a marker to a point: a match with no usable frame is distinguished from no
  /// match.
  enum MarkerResolution: Equatable {
    /// No serialized element's `key` value contains the marker.
    case notFound
    /// A matching element exists, but none has a usable frame.
    case offScreen
    /// The marker matched an element with a usable frame; its centre point.
    case resolved(x: Double, y: Double)
  }

  /// A write's target for a marker: the element it names and the centre of that element's frame.
  enum MarkerTarget {
    /// No serialized element's `key` value contains the marker.
    case notFound
    /// A matching element exists, but none has a usable frame.
    case offScreen
    case resolved(AccessibilityDocumentElement, x: Double, y: Double)
  }

  /// Resolves `markerValue` among the matching elements that have a usable frame, preferring one equal
  /// to it as `matchingElement` does, and reports whether a match without a usable frame existed so a
  /// caller can tell an off-screen element apart from an absent one. The point and the element come
  /// from one match, so a write cannot assert on one element and tap another.
  static func markerTarget(
    inElements elements: [AccessibilityDocumentElement],
    markerValue: String,
    key: AXSearchableKey,
    ignoresCase: Bool = false
  ) -> MarkerTarget {
    let (resolved, matched) = preferredMatch(inElements: elements, markerValue: markerValue, key: key, ignoresCase: ignoresCase) { element -> MarkerTarget? in
      frameCentre(of: element).map { .resolved(element, x: $0.x, y: $0.y) }
    }
    return resolved ?? (matched ? .offScreen : .notFound)
  }

  /// `markerTarget` without the element.
  static func resolveMarker(
    inElements elements: [AccessibilityDocumentElement],
    markerValue: String,
    key: AXSearchableKey,
    ignoresCase: Bool = false
  ) -> MarkerResolution {
    switch markerTarget(inElements: elements, markerValue: markerValue, key: key, ignoresCase: ignoresCase) {
    case .notFound:
      return .notFound
    case .offScreen:
      return .offScreen
    case let .resolved(_, x, y):
      return .resolved(x: x, y: y)
    }
  }

  private static func frameCentre(of element: AccessibilityDocumentElement) -> (x: Double, y: Double)? {
    // A zero-area frame counts as no frame: an element whose frame never reached the wire is normalized
    // to zero on the way in and would otherwise resolve to the origin.
    guard let frame = element.frame ?? nil,
      let x = frame.x, let y = frame.y, let width = frame.width, let height = frame.height,
      width > 0, height > 0
    else {
      return nil
    }
    return (x + width / 2, y + height / 2)
  }

  /// The centre of the first matching element with a usable frame, or `nil` when the marker matches
  /// nothing *or* every match is off-screen. A `resolveMarker` wrapper for the `wait` poll, which
  /// treats both nil cases alike (keep polling); tap/set-value call `resolveMarker` directly to tell an
  /// off-screen match from a genuine miss.
  static func frameCenter(
    inElements elements: [AccessibilityDocumentElement],
    markerValue: String,
    key: AXSearchableKey,
    ignoresCase: Bool = false
  ) -> (x: Double, y: Double)? {
    guard case let .resolved(x, y) = resolveMarker(inElements: elements, markerValue: markerValue, key: key, ignoresCase: ignoresCase) else {
      return nil
    }
    return (x, y)
  }
}
