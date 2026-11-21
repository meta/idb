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

/// The `UIAutomation` backend that reads via the `SimulatorFrameworkBridge` guest `accessibility`
/// service — an in-simulator accessibility client with no test bundle.
///
/// Writes are semantic accessibility actions addressed by point: a one-shot guest cannot hold an
/// element handle across requests, so a `.marker` write resolves its point host-side and carries an
/// assertion the guest re-checks before acting, so a screen that moved does not receive the write.
///
// SAFETY: stored state is immutable. Persistent transport state is actor-isolated and the one-shot
// transport is a value type.
// patternlint-disable-next-line unchecked-sendable
final class AXBridgeUIAutomation: AXBridgeTreeReader, @unchecked Sendable {

  /// `true` asserts automation mode, `false` asserts it off, `nil` observes without touching the
  /// device. Without the mode UIKit collapses subtrees and can serve cached children describing a
  /// screen no longer displayed.
  let requestedAutomationMode: Bool?

  private let simulator: Simulator
  private let routing: DisplayRouting

  /// How this reader reaches the guest.
  let transport: any AXBridgeTransport

  /// The transport lifecycle this reader was vended for. Held only so `backend` reports the case the
  /// caller selected; the injected transport already encodes the behavioural difference.
  private let persistence: AXBridgePersistence

  /// How frontmost reads resolve the foreground app. Defaults to the authoritative `.windowServer`; a
  /// caller can select the positional `.centerPoint` or `.runningBoard`.
  private let frontmostMethod: AXBridgeFrontmostMethod

  /// The simulator's running apps by bundle ID, read only to name the app behind a failure's pid. Nil
  /// names none.
  private let runningApplications: (@Sendable () async throws -> [String: pid_t])?

  /// Off while idb itself will read again, so only a failure that reaches the caller lists the apps.
  @TaskLocal private static var namesFailedApplication = true

  /// `launchctl list` has no timeout of its own, and an unnamed failure beats a late one.
  private static let runningApplicationsTimeoutNanoseconds: UInt64 = 1_000_000_000

  init(
    simulator: Simulator,
    transport: any AXBridgeTransport,
    persistence: AXBridgePersistence,
    frontmostMethod: AXBridgeFrontmostMethod = .windowServer,
    automationMode: Bool? = true,
    displays: (any DisplayCommands)? = nil,
    selection: DisplaySelection = .active,
    runningApplications: (@Sendable () async throws -> [String: pid_t])? = nil
  ) {
    self.routing = displays.map { .unresolved($0, selection) } ?? .unrouted
    self.runningApplications = runningApplications
    self.simulator = simulator
    self.transport = transport
    self.persistence = persistence
    self.frontmostMethod = frontmostMethod
    self.requestedAutomationMode = automationMode
  }

  private init(scoping reader: AXBridgeUIAutomation, routing: DisplayRouting) {
    self.simulator = reader.simulator
    self.transport = reader.transport
    self.persistence = reader.persistence
    self.frontmostMethod = reader.frontmostMethod
    self.requestedAutomationMode = reader.requestedAutomationMode
    self.runningApplications = reader.runningApplications
    self.routing = routing
  }

  /// Whether operations route to a display, and the display they are bound to once resolved.
  private enum DisplayRouting {
    case unrouted
    case unresolved(any DisplayCommands, DisplaySelection)
    /// A nil display means interactions fall back to the main display, so nothing is routed.
    case resolved(AXTranslationDisplay?, any DisplayCommands)
  }

  private var display: AXTranslationDisplay? {
    guard case let .resolved(display, _) = routing else { return nil }
    return display
  }

  private var needsDisplay: Bool {
    guard case .unresolved = routing else { return false }
    return true
  }

  /// Binds one operation to the active display, failing if the display changes before it completes.
  private func withDisplay<T>(_ body: (AXBridgeUIAutomation) async throws -> T) async throws -> T {
    guard case let .unresolved(displays, selection) = routing else { return try await body(self) }
    let display: AXTranslationDisplay?
    switch try await displays.resolveDisplay() {
    case .transitioning:
      throw SimulatorDisplayError.transitioning
    case .fallback:
      display = nil
    case let .target(.sole(sole)):
      display = .sole(sole)
    case let .target(.selected(selected)):
      let accessibilityID = try await displays.accessibilityID(
        for: selected, transport: transport, requiring: [.scopedInteractions, .scopedTrees],
        timing: simulator.accessibilityTiming)
      display = .selected(selected, id: accessibilityID)
    }
    try selection.confirm(routedTo: display?.interactionDisplay, latest: displays.configurationTracker.latest)
    let scoped = AXBridgeUIAutomation(scoping: self, routing: .resolved(display, displays))
    let result = try await body(scoped)
    try await scoped.validateCurrentDisplay()
    return result
  }

  private func validateCurrentDisplay() async throws {
    guard case let .resolved(display?, displays) = routing else { return }
    try await displays.validate(display.interactionDisplay)
  }

  // MARK: - Reads

  func describe(
    _ query: AccessibilityElementQuery,
    options: AccessibilityRequestOptions
  ) async throws -> AccessibilityElementsResponse {
    try await withDisplay { try await $0.describeTree(query, options: options) }
  }

  nonisolated var backend: UIAutomationBackend {
    .axBridge(
      persistence: persistence, frontmostMethod: frontmostMethod, automationMode: requestedAutomationMode)
  }

  /// Converts application-level bridge failures to the public UI automation errors.
  private func translatingBackendErrors<T>(_ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch let AXBridgeError.applicationUnavailable(pid) {
      throw UIAutomationError.applicationUnavailable(backend: backend, pid: pid, bundleID: await bundleID(of: pid))
    } catch let AXBridgeError.applicationNotResponding(pid) {
      throw UIAutomationError.applicationNotResponding(backend: backend, pid: pid, bundleID: await bundleID(of: pid))
    }
  }

  /// Best effort: a listing that fails or is slow leaves the failure unnamed rather than replacing or
  /// delaying it. Read after the failure, so a pid the app has since given up may name whatever took it over.
  private func bundleID(of pid: pid_t?) async -> String? {
    guard let pid, let runningApplications, Self.namesFailedApplication else {
      return nil
    }
    // A stream rather than a task group, which would wait for a listing that ignores cancellation.
    let (first, continuation) = AsyncStream<[String: pid_t]?>.makeStream()
    let listing = Task { continuation.yield(try? await runningApplications()) }
    let deadline = Task {
      try? await Task.sleep(nanoseconds: Self.runningApplicationsTimeoutNanoseconds)
      continuation.yield(nil)
    }
    defer {
      listing.cancel()
      deadline.cancel()
      continuation.finish()
    }
    for await running in first {
      return running?.first { $0.value == pid }?.key
    }
    return nil
  }

  /// One round trip to the guest, which is the whole query on this backend, so it may take no longer than the
  /// query's timeout. Running out is the same failure a host read reports.
  private func send(_ request: AXBridgeRequest, queryTimeout: TimeInterval) async throws -> AXBridgeReply {
    do {
      return try await transport.send(request, receiveTimeout: queryTimeout)
    } catch let AXBridgeError.guestNotAnswering(after) {
      throw AccessibilityError.serviceNotAnswering(.query(timeout: queryTimeout), elapsed: after, behindAbandoned: 0)
    }
  }

  /// Assembles what both sides measured; the phases come off the envelope `AXTreeRead` already parsed.
  private static func timings(
    response: AXBridgeReply, sent: CFAbsoluteTime, returned: CFAbsoluteTime, read: AXTreeRead
  ) -> AXReadTimings {
    let decoded = CFAbsoluteTimeGetCurrent()
    let phases = read.phases
    return AXReadTimings(
      roundTrip: returned - sent,
      decode: decoded - returned,
      traverse: phases.traverse,
      machRoundTrips: phases.machRoundTrips,
      responseBytes: Int64(response.frameBytes)
    )
  }

  /// A read that names a client walks the translator vocabulary, the only one a client changes. Otherwise a
  /// single fetch, except that one asking for reachability hit-tests every node and times out rather than
  /// answering, so those keys force the per-node walk.
  static func autoTraversal(for options: AccessibilityRequestOptions) -> AXTraversal {
    if options.clientType != nil {
      return .semantic
    }
    guard options.serializationKeys.isDisjoint(with: AXKeys.reachabilityKeys) else {
      return .viewHierarchy
    }
    return .singleFetch
  }

  /// `.application` reads the named pid; every other query is one fused guest call that resolves the
  /// frontmost app at the screen-centre anchor and reads its tree. `.point` goes through `hitTest`.
  func readRawTree(
    for query: AccessibilityElementQuery,
    attributes: [String]?,
    explainUnreachable: Bool,
    traversal: AXTraversal,
    clientType: AXClientType,
    queryTimeout: TimeInterval?
  ) async throws -> AXTreeRead {
    if needsDisplay {
      return try await withDisplay {
        try await $0.readRawTree(
          for: query, attributes: attributes, explainUnreachable: explainUnreachable, traversal: traversal, clientType: clientType,
          queryTimeout: queryTimeout)
      }
    }
    let queryTimeout = queryTimeout ?? simulator.accessibilityTiming.queryTimeout
    return try await translatingBackendErrors {
      if case let .application(pid) = query {
        let options = AXBridgeReadRequest(
          maxDepth: AXReadLimits.maxReadDepth,
          maxNodes: AXReadLimits.maxReadNodes,
          attributes: attributes,
          explainUnreachable: explainUnreachable,
          traversal: traversal,
          automationMode: requestedAutomationMode,
          clientType: clientType
        )
        let sent = CFAbsoluteTimeGetCurrent()
        let response = try await send(
          .read(pid: pid, options: options, displayID: display?.accessibilityID), queryTimeout: queryTimeout)
        let returned = CFAbsoluteTimeGetCurrent()
        var read = try AXTreeRead(wholeTreeResponse: response.answer, pid: pid)
        read.screen = display?.screen
        read.timings = Self.timings(response: response, sent: sent, returned: returned, read: read)
        return read
      }
      let anchor = try frontmostAnchor()
      let options = AXBridgeReadRequest(
        maxDepth: AXReadLimits.maxReadDepth,
        maxNodes: AXReadLimits.maxReadNodes,
        attributes: attributes,
        explainUnreachable: explainUnreachable,
        traversal: traversal,
        automationMode: requestedAutomationMode,
        clientType: clientType
      )
      let sent = CFAbsoluteTimeGetCurrent()
      let response = try await send(
        .readFrontmost(x: anchor.x, y: anchor.y, method: frontmostMethod, options: options, displayID: display?.accessibilityID),
        queryTimeout: queryTimeout)
      let returned = CFAbsoluteTimeGetCurrent()
      var read = try AXTreeRead(frontmostResponse: response.answer, method: frontmostMethod)
      read.screen = display?.screen
      read.timings = Self.timings(response: response, sent: sent, returned: returned, read: read)
      return read
    }
  }

  func hitTest(
    at point: CGPoint,
    options: AccessibilityRequestOptions
  ) async throws -> AccessibilityElementsResponse? {
    if needsDisplay {
      return try await withDisplay { try await $0.hitTest(at: point, options: options) }
    }
    let lookupPoint = try display?.geometry.unrotatedPoint(from: point) ?? point
    return try await translatingBackendErrors {
      let response = try await send(
        .hitTest(
          x: Double(lookupPoint.x), y: Double(lookupPoint.y),
          attributes: AXWire.Node.fetchList(for: options.serializationKeys),
          clientType: options.resolvedClientType,
          displayID: display?.accessibilityID),
        queryTimeout: options.timing?.queryTimeout ?? simulator.accessibilityTiming.queryTimeout)
      guard let hit = try AXTreeRead(hitTestResponse: response.answer) else {
        return nil
      }
      let snapshot = AXTreeWalk.snapshot(fromTree: hit.tree, pid: hit.pid)
      var formatted = AXNodeSerializer.formattedDescription(
        ofSnapshot: snapshot, serialization: AXSerialization(options), collector: nil)
      // The hit element is exempt from the filter; its descendants are not.
      if let children = formatted.children {
        formatted.children = options.filter.apply(to: children, screen: nil)
      }
      return AccessibilityElementsResponse(elements: .single(formatted))
        .withProvenance(backend: backend.name, target: .point(point), screen: display?.screen)
    }
  }

  func wait(
    _ query: AccessibilityElementQuery,
    timeout: TimeInterval,
    pollInterval: TimeInterval
  ) async throws {
    try await UIAutomationPolling.waitForMarker(
      query, backend: backend, timeout: timeout, pollInterval: pollInterval
    ) { markerValue, key, _ in
      // Re-read frontmost each poll so an app that launches mid-wait is picked up.
      do {
        // Raw read (not `describeTree`) so truncation is not warned per poll. `.viewHierarchy` because the
        // single fetch is unmeasured on a transitioning screen.
        let read = try await Self.$namesFailedApplication.withValue(false) {
          try await self.readRawTree(
            for: .frontmost, attributes: nil, explainUnreachable: false, traversal: .viewHierarchy,
            clientType: AccessibilityRequestOptions.unconfiguredClientType, queryTimeout: nil)
        }
        let elements = AXTreeWalk.describeAllElements(
          fromTree: read.tree, keys: AXKeys.defaultSet.union([key.serializationKey]), nestedFormat: false, pid: read.pid
        )
        var result = AXTreeWalk.search(inElements: elements, markerValue: markerValue, key: key)
        result.diagnostics?.readTruncated = read.truncated
        return result.map { _ in true }
      } catch let error as UIAutomationError {
        switch error {
        case .applicationUnavailable, .applicationNotResponding:
          return AccessibilitySearchResult(match: nil, diagnostics: AccessibilitySearchDiagnostics(readError: error.localizedDescription))
        case .elementNotFound, .elementNotOnScreen, .frameUnavailable, .noElementAtPoint,
          .timedOut, .markerRequired, .pointOrMarkerRequired, .invalidPollInterval,
          .operationUnsupported, .valueMismatch, .elementMoved, .writeUnconfirmed, .traversalCannotAnswer,
          .clientNeedsTranslatorVocabulary:
          throw error
        }
      } catch let error as AXBridgeError {
        guard error.isTransientDuringMarkerWait else {
          throw error
        }
        return AccessibilitySearchResult(match: nil, diagnostics: AccessibilitySearchDiagnostics(readError: error.localizedDescription))
      }
    }
  }

  // MARK: - Quiescence

  /// Needs a transport that holds its connection open: the guest streams events down it until one side
  /// hangs up.
  func quiescence(
    _ query: AccessibilityElementQuery,
    parameters: QuiescenceParameters
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, Error> {
    let pid: pid_t?
    switch query {
    case let .application(requested):
      pid = requested
    case .frontmost:
      pid = nil
    case .point, .marker:
      throw UIAutomationError.operationUnsupported(backend: backend, operation: "Quiescence of a point or marker")
    }
    guard transport is any AXBridgeStreamingTransport else {
      throw UIAutomationError.operationUnsupported(backend: backend, operation: "Quiescence")
    }
    if pid == nil, case let .unresolved(displays, selection) = routing {
      return try await frontmostQuiescence(displays: displays, selection: selection, parameters: parameters)
    }
    return forwarding(try await quiescenceFrames(pid: pid, displayID: nil, parameters: parameters), pid: pid)
  }

  private func quiescenceFrames(pid: pid_t?, displayID: UInt32?, parameters: QuiescenceParameters) async throws -> AsyncThrowingStream<BridgeAXAnswer, Error> {
    guard let transport = transport as? any AXBridgeStreamingTransport else {
      throw UIAutomationError.operationUnsupported(backend: backend, operation: "Quiescence")
    }
    return try await transport.stream(
      .quiescence(pid: pid, busyThresholdMs: parameters.busyThresholdMs, quietWindowMs: parameters.quietWindowMs, displayID: displayID))
  }

  private func forwarding(_ frames: AsyncThrowingStream<BridgeAXAnswer, Error>, pid: pid_t?) -> AsyncThrowingStream<QuiescenceEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await translatingBackendErrors {
            for try await frame in frames {
              continuation.yield(try QuiescenceEvent(axBridgeFrame: frame, pid: pid))
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// The guest follows the frontmost application of the one display it is named, so when the device
  /// switches to another display the stream is reopened there. The consumer sees one stream, with
  /// `targetChanged` when the switch lands on another application.
  private func frontmostQuiescence(
    displays: any DisplayCommands,
    selection: DisplaySelection,
    parameters: QuiescenceParameters
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, Error> {
    let selected: SimulatorDisplay
    let resolution = try await displays.resolveDisplay()
    let latest = displays.configurationTracker.latest
    switch resolution {
    case .transitioning:
      throw SimulatorDisplayError.transitioning
    case .fallback:
      try selection.confirm(routedTo: nil, latest: latest)
      return forwarding(try await quiescenceFrames(pid: nil, displayID: nil, parameters: parameters), pid: nil)
    case let .target(.sole(sole)):
      try selection.confirm(routedTo: sole, latest: latest)
      return forwarding(try await quiescenceFrames(pid: nil, displayID: nil, parameters: parameters), pid: nil)
    case let .target(.selected(display)):
      try selection.confirm(routedTo: .identified(display), latest: latest)
      selected = display
    }
    let displayID = try await displays.accessibilityID(
      for: selected, transport: transport, requiring: Self.quiescenceCapabilities,
      timing: simulator.accessibilityTiming)
    let first = try await quiescenceFrames(pid: nil, displayID: displayID, parameters: parameters)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await translatingBackendErrors {
            var frames = first
            var followed = selected.uniqueID
            var lastPid: pid_t?
            var reopened = false
            while true {
              var moved: (uniqueID: String, displayID: UInt32)?
              for try await step in following(frames, from: followed, displays: displays) {
                switch step {
                case let .frame(frame):
                  let event = try QuiescenceEvent(axBridgeFrame: frame, pid: nil)
                  if reopened, let lastPid, event.pid != lastPid, event.reportsLiveTarget {
                    continuation.yield(.targetChanged(pid: event.pid))
                  }
                  reopened = false
                  lastPid = event.pid
                  continuation.yield(event)
                case let .moved(uniqueID, displayID):
                  moved = (uniqueID, displayID)
                }
                if moved != nil { break }
              }
              guard let moved else { break }
              // Only the active display follows a hinge change; a named display or configuration has gone.
              guard selection == .active else { throw SimulatorDisplayError.changed }
              frames = try await quiescenceFrames(pid: nil, displayID: moved.displayID, parameters: parameters)
              followed = moved.uniqueID
              reopened = true
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static let quiescenceCapabilities: AXBridgeDisplayCapabilities = [.scopedInteractions, .scopedTrees, .scopedQuiescence]
  private static let displayPollInterval: Duration = .milliseconds(250)

  private enum FollowStep: Sendable {
    case frame(BridgeAXAnswer)
    case moved(uniqueID: String, displayID: UInt32)
  }

  /// Relays `frames` until they end, or until another display becomes active and resolves. A display read
  /// that fails, as one does mid-transition, leaves the stream where it is until a later read succeeds.
  private func following(
    _ frames: AsyncThrowingStream<BridgeAXAnswer, Error>,
    from uniqueID: String,
    displays: any DisplayCommands
  ) -> AsyncThrowingStream<FollowStep, Error> {
    AsyncThrowingStream { continuation in
      let relay = Task {
        do {
          for try await frame in frames {
            continuation.yield(.frame(frame))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      let poll = Task {
        for await configuration in displays.followConfigurations(polling: Self.displayPollInterval) {
          guard configuration.phase == .settled, case let .identified(next) = configuration.active, next.uniqueID != uniqueID,
            configuration.displays.filter(\.isIntegrated).count > 1,
            let displayID = try? await displays.accessibilityID(
              for: next, transport: self.transport, requiring: Self.quiescenceCapabilities,
              timing: self.simulator.accessibilityTiming),
            // The lookup can outlast a transient report; only a fresh read that still agrees moves the stream.
            (try? await displays.settledConfiguration(within: .zero))?.generation == configuration.generation
          else { continue }
          continuation.yield(.moved(uniqueID: next.uniqueID, displayID: displayID))
          return
        }
      }
      continuation.onTermination = { _ in
        relay.cancel()
        poll.cancel()
      }
    }
  }

  // MARK: - Writes

  func tap(
    _ query: AccessibilityElementQuery,
    options: TapOptions
  ) async throws {
    if needsDisplay {
      return try await withDisplay { try await $0.tap(query, options: options) }
    }
    // The AX runtime's press is instantaneous with nowhere to put a hold; reject `duration` rather
    // than silently downgrading a long-press to a tap.
    guard options.duration == nil else {
      throw UIAutomationError.operationUnsupported(backend: backend, operation: "A tap with a hold duration")
    }
    try await resolveAndWrite(.perform(.press), for: query, operation: "A tap", callerAssertion: options.assertion)
  }

  func performCustomAction(named name: String, on query: AccessibilityElementQuery) async throws {
    if needsDisplay {
      return try await withDisplay { try await $0.performCustomAction(named: name, on: query) }
    }
    throw UIAutomationError.operationUnsupported(
      backend: backend,
      operation: "Named custom accessibility actions"
    )
  }

  func setValue(_ value: String, for query: AccessibilityElementQuery) async throws {
    if needsDisplay {
      return try await withDisplay { try await $0.setValue(value, for: query) }
    }
    try await resolveAndWrite(.setValue(value), for: query, operation: "Setting a value", callerAssertion: nil)
  }

  func scroll(_ query: AccessibilityElementQuery, direction: AccessibilityScrollDirection) async throws {
    if needsDisplay {
      return try await withDisplay { try await $0.scroll(query, direction: direction) }
    }
    let scrolled = try await scrollTarget(for: query, backend: backend)
    try await resolveAndWrite(.perform(Self.action(for: direction)), for: scrolled, operation: "Scroll", callerAssertion: nil)
  }

  /// Synthesized over HID: a drag is a touch path, not an action on a single element, so the guest has
  /// no verb for it.
  func drag(
    from source: AccessibilityElementQuery,
    to destination: AccessibilityElementQuery,
    options: DragOptions
  ) async throws {
    if needsDisplay {
      return try await withDisplay { try await $0.drag(from: source, to: destination, options: options) }
    }
    let start = try await resolveWriteTarget(for: source, operation: DragEndpoint.operation, callerAssertion: nil).point
    let end = try await resolveWriteTarget(for: destination, operation: DragEndpoint.operation, callerAssertion: nil).point
    try await validateCurrentDisplay()
    try await simulator.sendHIDGesture(
      .drag(
        Double(start.x), yStart: Double(start.y), xEnd: Double(end.x), yEnd: Double(end.y),
        delta: options.delta, pressDuration: options.pressDuration, duration: options.duration,
        releaseDuration: options.releaseDuration
      )
    )
  }

  /// A marker names an element; the point it resolves to is an inference from one tree read, and the
  /// guest refuses the write when the element it hit no longer carries the asserted value. Nothing is
  /// written in that case, so the read can be taken again and the write sent once more — and only idb
  /// holds the tree the marker resolved against, so no caller could do this instead.
  private func resolveAndWrite(
    _ kind: AXBridgeWriteRequest.Kind,
    for query: AccessibilityElementQuery,
    operation: String,
    callerAssertion: TapOptions.Assertion?
  ) async throws {
    do {
      let target = try await resolveWriteTarget(for: query, operation: operation, callerAssertion: callerAssertion)
      try await write(kind, to: target, query: query)
    } catch UIAutomationError.elementMoved {
      try Task.checkCancellation()
      _ = simulator.logger.log("axbridge \(operation): the element moved before the write landed; re-reading the tree once")
      let target = try await resolveWriteTarget(for: query, operation: operation, callerAssertion: callerAssertion)
      try await write(kind, to: target, query: query)
    }
  }

  private func resolveWriteTarget(
    for query: AccessibilityElementQuery,
    operation: String,
    callerAssertion: TapOptions.Assertion?
  ) async throws -> AXWriteTarget {
    do {
      return try await Self.$namesFailedApplication.withValue(false) {
        try await writeTarget(for: query, operation: operation, callerAssertion: callerAssertion)
      }
    } catch UIAutomationError.applicationNotResponding {
      // Only target resolution is repeated. A write timeout does not establish whether it was applied.
      try Task.checkCancellation()
      _ = simulator.logger.log("axbridge \(operation): target read timed out; retrying once before sending the write")
      return try await writeTarget(for: query, operation: operation, callerAssertion: callerAssertion)
    } catch UIAutomationError.applicationUnavailable {
      // A write query names no pid, so the app came from frontmost resolution, which can name one that
      // has exited, such as mid-relaunch. Resolving again finds the app now on screen.
      try Task.checkCancellation()
      _ = simulator.logger.log("axbridge \(operation): the frontmost app was unavailable; resolving it again before sending the write")
      return try await writeTarget(for: query, operation: operation, callerAssertion: callerAssertion)
    }
  }

  /// The semantic action a scroll direction asks for.
  private static func action(for direction: AccessibilityScrollDirection) -> AXWire.Action {
    switch direction {
    case .up: .scrollUp
    case .down: .scrollDown
    case .left: .scrollLeft
    case .right: .scrollRight
    case .visible: .scrollToVisible
    }
  }

  /// A write that landed on nothing is an error, not a success; see `emptyWriteTargetError`.
  ///
  /// Any failure once the request is on its way is `writeUnconfirmed`, unless the guest reports that it
  /// sent nothing to the application.
  private func write(
    _ kind: AXBridgeWriteRequest.Kind,
    to target: AXWriteTarget,
    query: AccessibilityElementQuery
  ) async throws {
    let point = try display?.geometry.unrotatedPoint(from: target.point) ?? target.point
    try await validateCurrentDisplay()
    let request = AXBridgeWriteRequest(
      kind: kind,
      x: Double(point.x),
      y: Double(point.y),
      pid: target.pid,
      assertion: target.assertion,
      displayID: display?.accessibilityID
    )
    let response: BridgeAXAnswer
    do {
      response = try await send(.write(request), queryTimeout: simulator.accessibilityTiming.queryTimeout).answer
    } catch let error as AXBridgeError where error.retry == .willNotChange {
      // No guest could be reached, so the write never left the host.
      throw error
    } catch {
      throw UIAutomationError.writeUnconfirmed(backend: backend, idempotent: request.isIdempotent, underlying: error)
    }
    let landed: Bool
    do {
      landed = try await translatingWriteErrors(query) {
        try AXTreeRead.writeLanded(fromResponse: response)
      }
    } catch {
      guard !AXTreeRead.writeSentNothing(fromResponse: response) else {
        throw error
      }
      throw UIAutomationError.writeUnconfirmed(backend: backend, idempotent: request.isIdempotent, underlying: error)
    }
    guard landed else {
      throw emptyWriteTargetError(for: query, at: target.point)
    }
  }

  /// Adds the refused-assertion case, which only a write can meet, to the shared backend-error
  /// translation; the guest cannot know which marker sent the write.
  private func translatingWriteErrors<T>(_ query: AccessibilityElementQuery, _ body: () async throws -> T) async throws -> T {
    do {
      return try await translatingBackendErrors(body)
    } catch let AXBridgeError.assertionFailed(message) {
      guard case let .marker(value, key, _, _) = query else {
        throw AXBridgeError.assertionFailed(message)
      }
      throw UIAutomationError.elementMoved(backend: backend, key: key.rawValue, value: value)
    }
  }

  func frame(_ query: AccessibilityElementQuery) async throws -> CGRect {
    try await withDisplay { try await $0.frameFromTree(query) }
  }

  // MARK: - Frontmost anchor

  /// The screen-centre anchor, in points, for the in-guest frontmost hit-test.
  private func frontmostAnchor() throws -> (x: Double, y: Double) {
    if let display {
      let point = try display.geometry.unrotatedPoint(
        from: CGPoint(x: display.bounds.midX, y: display.bounds.midY))
      return (Double(point.x), Double(point.y))
    }
    let info = simulator.screenInfo
    return Self.anchorPoint(
      widthPixels: info?.widthPixels ?? 828, heightPixels: info?.heightPixels ?? 1792, scale: info?.scale ?? 2
    )
  }

  static func anchorPoint(widthPixels: UInt, heightPixels: UInt, scale: Float) -> (x: Double, y: Double) {
    let pointsPerPixel = scale > 0 ? Double(scale) : 1
    return (Double(widthPixels) / pointsPerPixel / 2, Double(heightPixels) / pointsPerPixel / 2)
  }

  func warnIfUnsatisfiable(_ keys: Set<AXKeys>, traversal: AXTraversal) {
    guard !keys.isEmpty else {
      return
    }
    _ = simulator.logger.log(
      "The \(traversal.rawValue) traversal cannot fetch "
        + keys.map(\.rawValue).sorted().joined(separator: ", ")
        + " for every element; a missing value may mean the attribute was unfetchable, not unset"
    )
  }

  func warnIfTruncated(_ truncated: Bool) {
    guard truncated else { return }
    _ = simulator.logger.log("axbridge read hit the bound (maxDepth \(AXReadLimits.maxReadDepth), maxNodes \(AXReadLimits.maxReadNodes)); the returned tree is truncated and incomplete.")
  }

  func profile(
    for read: AXTreeRead, elementCount: Int, serializeDuration: CFAbsoluteTime,
    traversal: AXTraversal
  ) -> AccessibilityProfile? {
    guard let timings = read.timings else {
      return nil
    }
    return .guestBridge(
      AXBridgeProfile(
        elementCount: Int64(elementCount),
        totalDuration: timings.roundTrip + timings.decode + serializeDuration,
        acquireDuration: timings.residual,
        readDuration: timings.traverse ?? 0,
        serializeDuration: serializeDuration,
        traversal: traversal,
        machRoundTrips: timings.machRoundTrips,
        hostDecodeDuration: timings.decode,
        responseBytes: timings.responseBytes
      ))
  }

  func warnIfReachabilityAcrossTree(_ keys: Set<AXKeys>) {
    guard keys.contains(.interactable) || keys.contains(.occludedBy) else { return }
    _ = simulator.logger.log(AccessibilityGuidance.reachabilityAcrossTree)
  }

  func warnIfMostElementsUnframed(_ frames: AccessibilityFrameSummary?) {
    guard let advice = AccessibilityGuidance.zeroFrameAdvice(frames), let frames else { return }
    _ = simulator.logger.log("axbridge read reported \(frames.zeroFrame) of \(frames.total) elements with no frame. \(advice)")
  }
}

/// The bounds applied to each whole-tree axbridge read.
///
/// These are authoritative. The host sends them on every request, so the guest reader truncates to
/// these rather than keeping its own copy. The guest keeps a *separate*, larger fallback pair
/// (`BridgeAXReadOptions.defaultMaxDepth` = 100 / `defaultMaxNodes` = 5000 in
/// `FBSimulatorBridgeProtocol`) that applies only when a request omits the bounds — e.g. the
/// one-shot guest front-end invoked by hand. The two
/// must not be conflated: a host-driven read always truncates at 50 / 3000.
enum AXReadLimits {
  static let maxReadDepth = 50
  static let maxReadNodes = 3000
}
