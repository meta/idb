/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import Foundation

/// An opaque accessibility element with a managed token lifecycle.
///
/// The element's translation token remains registered as long as the element is
/// open, allowing serialization (attribute reads go through XPC callbacks routed
/// by token). Actions (tap, scroll) go through the translator's platform element,
/// built from the handle when acting. Call `close()` when done to deregister the
/// token; after close, serialization fails.
final class AccessibilityElement {

  private let handle: any AXTranslationReference
  private let request: AXTranslationRequest
  private let dispatcher: AXTranslationDispatcher
  private weak var simulator: Simulator?
  private var closed: Bool = false

  /// The frame of the root this element was found under; `nil` for an element read directly. The
  /// serializer takes screen bounds from the element it is handed, so a descendant needs its root's
  /// frame carried in.
  let rootBounds: CGRect?

  init(
    handle: any AXTranslationReference,
    request: AXTranslationRequest,
    dispatcher: AXTranslationDispatcher,
    simulator: Simulator,
    rootBounds: CGRect? = nil
  ) {
    self.handle = handle
    self.request = request
    self.dispatcher = dispatcher
    self.simulator = simulator
    self.rootBounds = rootBounds
  }

  deinit {
    close()
  }

  /// Close the element, deregistering the token. Called automatically on dealloc
  /// as a safety net. After close, serialization fails.
  func close() {
    if !closed {
      closed = true
      dispatcher.popRequest(request)
    }
  }

  // MARK: - Serialization

  /// Serialize the element to a full response (preserves profiling/coverage data).
  func serialize(with options: AccessibilityRequestOptions) async throws -> AccessibilityElementsResponse {
    if closed {
      throw AccessibilityError.closedElement(operation: "serialize")
    }
    let request = self.request
    let handle = self.handle
    let isMarkerMatch = self.isMarkerMatch
    if let stallObserver = options.stallObserver {
      request.stallObserver = stallObserver
    }
    return try await dispatcher.performUnserialized(cancelling: request.cancellation) {
      try request.run(handle, options: options, isMarkerMatch: isMarkerMatch)
    }
  }

  /// Whether this handle names the one element the caller asked for, rather than the tree its request
  /// resolved. True exactly for a marker match: `findElement` sets `rootBounds` only on that path.
  private var isMarkerMatch: Bool {
    rootBounds != nil
  }

  /// Read the string value of a searchable accessibility key from this element.
  func stringValue(forSearchableKey key: AXSearchableKey) async throws -> String {
    if closed {
      throw AccessibilityError.closedElement(operation: "read from")
    }
    let snapshot = try await read(AXReadPlan(searching: key, depth: .limited(0)))
    guard let value = snapshot.searchableValue(for: key) else {
      throw AccessibilityError.noStringValue(key: key.rawValue)
    }
    return value
  }

  /// Reads this element against `plan`, off the translator's work queue: a read never touches it.
  private func read(_ plan: AXReadPlan) async throws -> AXElementSnapshot {
    let handle = self.handle
    let request = self.request
    return try await dispatcher.performUnserialized(cancelling: request.cancellation) {
      try request.snapshot(of: handle, plan: plan)
    }
  }

  /// Runs `action` on this element's platform element, built from its handle on the translator's work queue.
  private func act<T>(_ action: @escaping (any AXWritableElement) throws -> T) async throws -> T {
    let handle = self.handle
    let request = self.request
    return try await dispatcher.performSerialized {
      guard let element = request.element(for: handle) else {
        throw AccessibilityError.noTranslationObject(nil)
      }
      return try action(element)
    }
  }

  // MARK: - Actions

  /// Perform an unconditional accessibility tap (AXPress) without any label verification.
  func tap() async throws {
    if closed {
      throw AccessibilityError.closedElement(operation: "tap")
    }
    try await act { element in
      let actionNames = element.axActionNames()
      guard actionNames.contains("AXPress") else {
        throw AccessibilityError.pressUnsupported(supportedActions: CollectionInformation.oneLineDescription(from: actionNames))
      }
      guard element.axPerformPress() else {
        throw AccessibilityError.pressFailed
      }
    }
  }

  /// Performs the named custom accessibility action advertised by the element.
  func performCustomAction(named name: String) async throws {
    if closed {
      throw AccessibilityError.closedElement(operation: "perform a custom action on")
    }
    try await act { element in
      let customActions = element.axCustomActionNames()
      let matches = customActions.filter { $0 == name }
      guard !matches.isEmpty else {
        throw AccessibilityError.customActionUnsupported(
          name: name,
          supportedActions: CollectionInformation.oneLineDescription(from: customActions)
        )
      }
      guard matches.count == 1 else {
        throw AccessibilityError.customActionAmbiguous(name: name, count: matches.count)
      }
      guard element.axPerformCustomAction(named: name) else {
        throw AccessibilityError.customActionFailed(name: name)
      }
    }
  }

  /// Perform an accessibility scroll on the element.
  func scroll(with direction: AccessibilityScrollDirection) async throws {
    if closed {
      throw AccessibilityError.closedElement(operation: "scroll")
    }
    try await act { $0.axScroll(direction) }
  }

  /// Set the accessibility value of the element (e.g., text field content, slider position).
  func setValue(_ value: String) async throws {
    if closed {
      throw AccessibilityError.closedElement(operation: "set value on")
    }
    try await act { $0.axSetValue(value) }
  }

  // MARK: - Geometry

  /// The element's frame in screen points. The element must be open.
  func frame() async throws -> CGRect {
    if closed {
      throw AccessibilityError.closedElement(operation: "read the frame of")
    }
    return try await read(AXReadPlan(attributes: [], depth: .limited(0))).frame
  }

  /// The pid of the backing translation object (0 when absent); reading it performs no serialization.
  var processIdentifier: pid_t {
    handle.pid
  }

  // MARK: - Descendant search (ownership-transferring)

  /// Searches the accessibility tree rooted at this element for a descendant
  /// matching the given value/key. If found, ownership of the request token is
  /// transferred to a new handle wrapping the found element, and the receiver is
  /// closed without popping. If not found, the receiver is closed and an error
  /// is thrown.
  func findElement(
    withValue value: String,
    forKey key: AXSearchableKey,
    depth: UInt,
    ignoresCase: Bool = false,
    matchExactly: Bool = false
  ) async throws -> AccessibilityElement {
    let result = try await searchElement(
      withValue: value,
      forKey: key,
      depth: depth,
      ignoresCase: ignoresCase,
      matchExactly: matchExactly
    )
    guard let match = result.match else {
      throw AccessibilityError.elementNotFound(key: key.rawValue, value: value, depth: depth)
    }
    return match
  }

  /// Consumes this root handle, transferring its request to the match or closing it on a miss.
  /// Nonmatching values come from the same traversal and never require another attribute read.
  func searchElement(
    withValue value: String,
    forKey key: AXSearchableKey,
    depth: UInt,
    ignoresCase: Bool = false,
    matchExactly: Bool = false
  ) async throws -> AccessibilitySearchResult<AccessibilityElement> {
    if closed {
      throw AccessibilityError.closedElement(operation: "search")
    }
    // The whole tree is read to `depth` before matching; the root's frame comes from the same read, before
    // ownership passes to a matching descendant.
    let root = try await read(AXReadPlan(searching: key, depth: .limited(depth)))
    var diagnostics = AccessibilitySearchDiagnostics()
    guard let found = Self.preferredMatch(withValue: value, forKey: key, in: root, ignoresCase: ignoresCase, matchExactly: matchExactly, diagnostics: &diagnostics),
      let handle = found.handle
    else {
      close()
      return AccessibilitySearchResult(match: nil, diagnostics: diagnostics)
    }
    guard let simulator else {
      throw WeakTargetError.simulator
    }
    let newHandle = AccessibilityElement(
      handle: handle, request: request, dispatcher: dispatcher, simulator: simulator, rootBounds: root.frame
    )
    closed = true
    return AccessibilitySearchResult(match: newHandle, diagnostics: diagnostics)
  }

  // MARK: - Private helpers

  /// The snapshot a marker names, depth first: the first whose `key` value equals `value`, otherwise the
  /// first that contains it — the rule axbridge applies over its serialized tree, so a marker names the
  /// same element on either backend. Records the nonmatching values visited before the first containing
  /// element.
  private static func preferredMatch(
    withValue value: String,
    forKey key: AXSearchableKey,
    in root: AXElementSnapshot,
    ignoresCase: Bool,
    matchExactly: Bool,
    diagnostics: inout AccessibilitySearchDiagnostics
  ) -> AXElementSnapshot? {
    let predicate = AccessibilityMatch(value: value, key: key, ignoresCase: ignoresCase)
    var firstContaining: AXElementSnapshot?
    var pending = [root]
    while let snapshot = pending.popLast() {
      pending.append(contentsOf: snapshot.children.reversed())
      guard let candidate = snapshot.searchableValue(for: key) else {
        continue
      }
      if matchExactly {
        if ignoresCase ? candidate.caseInsensitiveCompare(value) == .orderedSame : candidate == value {
          return snapshot
        }
        diagnostics.record(candidate)
        continue
      }
      // An empty marker matches every element carrying the key, so the first of them wins.
      guard let predicate else {
        return snapshot
      }
      guard predicate.matches(candidate) else {
        if firstContaining == nil {
          diagnostics.record(candidate)
        }
        continue
      }
      if isEqual(candidate, to: predicate) {
        return snapshot
      }
      firstContaining = firstContaining ?? snapshot
    }
    return firstContaining
  }

  private static func isEqual(_ candidate: String, to predicate: AccessibilityMatch) -> Bool {
    predicate.ignoresCase ? candidate.caseInsensitiveCompare(predicate.value) == .orderedSame : candidate == predicate.value
  }
}
