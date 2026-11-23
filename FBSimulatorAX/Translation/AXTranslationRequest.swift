/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

internal import AccessibilityPlatformTranslation
import CoreSimulator
import FBControlCore
import FBSimulatorControl
import Foundation

extension AXTranslationDisplay {
  var screen: AccessibilityScreenInfo? {
    let uniqueID: String? =
      switch interactionDisplay {
      case let .identified(value): value.uniqueID
      case .legacy: nil
      }
    let rotation: Int =
      switch geometry.rotation {
      case .upright: 0
      case .clockwise: 90
      case .upsideDown: 180
      case .counterclockwise: 270
      }
    return AccessibilityScreenInfo(
      width: bounds.width, height: bounds.height,
      display: AccessibilityDisplayInfo(uniqueID: uniqueID, scale: geometry.scale, rotation: rotation))
  }
}

/// Reference-typed accumulator for the process ids seen during a serialization
/// traversal. Populated as the main tree is serialized and shared with the
/// remote-content phase so processes already present in the main tree are
/// skipped during grid hit-testing.
final class SeenPIDs {
  private var pids: Set<pid_t> = []
  func insert(_ pid: pid_t) { pids.insert(pid) }
  func contains(_ pid: pid_t) -> Bool { pids.contains(pid) }
}

/// A single accessibility translation request. `kind` selects how the root element is obtained and
/// how the response is serialized.
final class AXTranslationRequest {

  /// What the request resolves and how it serializes.
  enum Kind {
    /// The frontmost application's element tree, with frame-coverage calculation
    /// and remote (separate-process) content discovery.
    case frontmostApplication
    /// The single element at a screen point.
    case point(CGPoint)
    /// A specific application's element tree, anchored by process identifier — no hit-test and no
    /// frontmost resolution. Serialized like `frontmostApplication` (full tree + coverage).
    case applicationForPid(pid_t)
  }

  let kind: Kind
  /// What the caller asked for, as they asked for it.
  var query: AccessibilityElementQuery {
    switch kind {
    case .frontmostApplication: .frontmost
    case let .point(point): .point(point)
    case let .applicationForPid(pid): .application(pid: pid)
    }
  }
  let display: AXTranslationDisplay?
  /// The client every translator request for this read carries, resolved by the caller.
  let clientType: AXClientType
  let token: String
  /// Carries this read's translator requests to the simulator.
  let transport: any AXTranslationTransport
  /// Owned from construction: the dispatcher records acquisition timings before the caller reaches
  /// `serialize`.
  let collector: AccessibilityProfilingCollector
  /// Cancelled when the task awaiting this read is, which stops its requests.
  let cancellation = AXReadCancellation()
  var translator: AXPTranslator?
  /// Set when the element is resolved, so the requests resolving it are watched as well as those reading it.
  var stallObserver: (@Sendable (AccessibilityStallObservation) -> Void)?
  /// Where the reader describes requests that wait long enough to be watched.
  var stallLogger: (any ControlCoreLogger)?
  /// The simulator the read is made to.
  var stallSimulatorUDID: String?
  /// How the reader's watches read, keep time and schedule.
  var stallWatchEnvironment = AXStallWatch.Environment()

  /// How long this read may take, per element and for the whole query.
  let timing: SimulatorAccessibilityTiming

  init(
    kind: Kind, display: AXTranslationDisplay? = nil, clientType: AXClientType, transport: any AXTranslationTransport,
    timing: SimulatorAccessibilityTiming = .default
  ) {
    self.kind = kind
    self.display = display
    self.clientType = clientType
    self.transport = transport
    self.token = UUID().uuidString
    self.timing = timing
    self.collector = AccessibilityProfilingCollector()
  }

  /// Resolves the root translation object for this request's kind, in one request over the transport.
  func resolveRoot() throws -> (any AXTranslationReference)? {
    switch kind {
    case .frontmostApplication:
      return try rawReader.resolve(.frontmostApplication(displayID: displayID))
    case .point(let point):
      return try translation(at: point)
    case .applicationForPid(let pid):
      return try rawReader.resolve(.application(pid: pid))
    }
  }

  /// The translator's platform element for `reference`, which actions go through. Built locally from the
  /// translator's element cache, without a request.
  func platformElement(for reference: any AXTranslationReference) -> (any AXWritableElement)? {
    // Sent by message: the translation is typed by protocol here, so test doubles can stand in for it.
    translator?.perform(NSSelectorFromString("macPlatformElementFromTranslation:"), with: reference)?
      .takeUnretainedValue() as? any AXWritableElement
  }

  /// The platform element an action on `translation` goes through, carrying this request's token. The
  /// translator caches elements by translation and a cached element keeps the token it was built with, so the
  /// token is set every time.
  func element(for translation: any AXTranslationReference) -> (any AXWritableElement)? {
    translation.bridgeDelegateToken = token
    let element = platformElement(for: translation)
    element?.axSetBridgeDelegateToken(token)
    return element
  }

  /// Reads `translation` and serializes it. The frontmost path adds frame coverage and remote content; the
  /// point path is a single element. `isMarkerMatch` forces single-element serialization: a marker match
  /// descends from the frontmost tree, so its request's `kind` is still `.frontmostApplication`.
  func run(
    _ translation: any AXTranslationReference,
    options: AccessibilityRequestOptions,
    isMarkerMatch: Bool = false
  ) throws -> AccessibilityElementsResponse {
    let walkStart = CFAbsoluteTimeGetCurrent()
    collector.markWalkStart()
    let serialization = AXSerialization(options)
    let depth: AXReadPlan.Depth =
      readsSingleElement(isMarkerMatch: isMarkerMatch) && !serialization.nested ? .limited(0) : .unlimited
    let snapshot = try snapshot(of: translation, plan: serialization.readPlan(depth: depth))
    return try serialize(snapshot, options: options, isMarkerMatch: isMarkerMatch, walkStart: walkStart)
  }

  /// Serializes an element already read, as `run` does after reading it.
  func serialize(
    _ snapshot: AXElementSnapshot,
    options: AccessibilityRequestOptions,
    isMarkerMatch: Bool = false,
    walkStart: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
  ) throws -> AccessibilityElementsResponse {
    guard readsSingleElement(isMarkerMatch: isMarkerMatch) else {
      return try serializeTree(snapshot, options: options, walkStart: walkStart)
    }
    return serializeNamedElement(snapshot, options: options, walkStart: walkStart)
  }

  private func readsSingleElement(isMarkerMatch: Bool) -> Bool {
    switch kind {
    case .point: true
    case .frontmostApplication, .applicationForPid: isMarkerMatch
    }
  }

  /// Reads `translation` against `plan`, one request per element over this request's transport.
  func snapshot(of translation: any AXTranslationReference, plan: AXReadPlan) throws -> AXElementSnapshot {
    try rawReader.read(translation, plan: plan)
  }

  /// Sends this request's translator requests itself, over its transport.
  private var rawReader: AXRawTranslationReader {
    AXRawTranslationReader(
      transport: transport, clientType: clientType, timeout: timing.elementTimeout, collector: collector, token: token,
      queryTimeout: timing.queryTimeout, cancellation: cancellation, stallObserver: stallObserver, stallLogger: stallLogger,
      stallSimulatorUDID: stallSimulatorUDID, stallWatchEnvironment: stallWatchEnvironment)
  }

  // MARK: - A single named element

  /// Serializes the one element a caller named — by point, or by a marker match. The element itself is
  /// always reported; only its descendants are subject to the filter.
  private func serializeNamedElement(
    _ snapshot: AXElementSnapshot, options: AccessibilityRequestOptions, walkStart: CFAbsoluteTime
  ) -> AccessibilityElementsResponse {
    let serialization = AXSerialization(options)
    var elements = AXNodeSerializer.formattedDescription(ofSnapshot: snapshot, serialization: serialization, collector: collector)
    if let children = elements.children {
      elements.children = options.filter.apply(to: children, screen: nil)
    }
    // Without a display snapshot, marker callers can recover legacy bounds from the root.
    return buildResponse(elements: .single(elements), walkStart: walkStart, coverage: nil, screen: display?.screen, options: options)
  }

  // MARK: - Frontmost Application

  private func serializeTree(
    _ snapshot: AXElementSnapshot, options: AccessibilityRequestOptions, walkStart: CFAbsoluteTime
  ) throws -> AccessibilityElementsResponse {
    let serialization = AXSerialization(options)
    let screen = AXReadScreen(display: display, rootFrame: snapshot.frame)
    let seenPids = SeenPIDs()

    let tree = TranslatedTree(
      description: AccessibilityTreeDescription(
        walked: AXNodeSerializer.recursiveDescription(
          fromSnapshot: snapshot, serialization: serialization, collector: collector, seenPids: seenPids),
        options: options, screenBounds: screen.bounds),
      pid: snapshot.pid, seenPids: seenPids)

    // The grid stays live: remote-content discovery reads it to skip covered points and marks its hits
    // into it.
    let grid: AccessibilityCoverageGrid? =
      options.collectFrameCoverage ? AccessibilityCoverageGrid(screenBounds: screen.bounds) : nil
    grid?.markFilled(withElements: tree.description.reported)

    guard let remoteOptions = options.remoteContentOptions else {
      return buildResponse(
        elements: .tree(tree.description.reported),
        walkStart: walkStart,
        coverage: tree.description.coverage(),
        screen: screen.info,
        options: options,
        narrowing: tree.description.narrowingReport()
      )
    }

    return try processRemoteContent(
      tree: tree,
      screen: screen,
      grid: grid,
      plan: AXRemoteContentPlan(remoteOptions, screenBounds: screen.bounds),
      options: options,
      walkStart: walkStart
    )
  }

  /// The frontmost application's described tree, the application's pid, and every pid seen on the way.
  private struct TranslatedTree {
    let description: AccessibilityTreeDescription
    let pid: pid_t
    let seenPids: SeenPIDs
  }

  // MARK: - Remote content

  private func discoverRemoteElements(
    beyond tree: TranslatedTree,
    grid: AccessibilityCoverageGrid?,
    plan: AXRemoteContentPlan,
    keys: Set<AXKeys>
  ) throws -> [AccessibilityDocumentElement] {
    var discoveredElements: [AccessibilityDocumentElement] = []
    var discoveredFrames = Set<String>()

    // Always include AXFrame for hit-tested elements (needed for nesting and coverage).
    var keysWithFrame = keys
    keysWithFrame.insert(.frame)

    var visited: UInt = 0
    for point in plan.points {
      if plan.isExhausted(afterVisiting: visited) {
        break
      }
      if let grid, grid.isFilled(at: point) {
        continue
      }
      visited += 1

      // A caller's region can reach past the routed display, where no point translates.
      let translated: (any AXTranslationReference)?
      do {
        translated = try translation(at: point)
      } catch SimulatorDisplayInteractionError.invalidPoint {
        translated = nil
      }
      guard let hitTranslation = translated else {
        continue
      }
      hitTranslation.bridgeDelegateToken = token
      let hitPid = hitTranslation.pid
      if tree.seenPids.contains(hitPid) || hitPid <= 0 || hitPid == tree.pid {
        continue
      }
      // One read serves both the duplicate check and the serialization.
      let hit = try snapshot(of: hitTranslation, plan: AXReadPlan(keys: keysWithFrame, depth: .limited(0)))
      let hitFrame = hit.frame
      let hitFrameKey = "\(hitFrame.origin.x),\(hitFrame.origin.y),\(hitFrame.size.width),\(hitFrame.size.height)"
      if discoveredFrames.contains(hitFrameKey) {
        continue
      }
      discoveredFrames.insert(hitFrameKey)
      grid?.markFilled(with: hitFrame)

      discoveredElements.append(
        AXNodeSerializer.decoratedElement(
          forSnapshot: hit, keys: keysWithFrame, collector: collector, seenPids: nil, isRemote: true))
    }
    return discoveredElements
  }

  private func processRemoteContent(
    tree: TranslatedTree,
    screen: AXReadScreen,
    grid: AccessibilityCoverageGrid?,
    plan: AXRemoteContentPlan,
    options: AccessibilityRequestOptions,
    walkStart: CFAbsoluteTime
  ) throws -> AccessibilityElementsResponse {
    let coverageBefore = grid?.coverageRatio() ?? 0

    let discoveredElements = try discoverRemoteElements(
      beyond: tree, grid: grid, plan: plan, keys: options.serializationKeys)

    var additionalFrameCoverage: Double?
    if let grid, !discoveredElements.isEmpty {
      let additionalCoverage = grid.coverageRatio() - coverageBefore
      if additionalCoverage > 0 {
        additionalFrameCoverage = Double(additionalCoverage)
      }
    }

    // Discovered elements honour the same filter and match as the main tree. `additionalFrameCoverage`
    // is measured before narrowing: it reports what hit-testing found that the tree did not expose.
    let keptDiscovered = AccessibilityElementRetention.narrowing(
      discoveredElements, filter: options.filter, match: options.match, screen: screen.bounds
    )
    var elements = tree.description.reported
    if !keptDiscovered.isEmpty {
      if options.nestedFormat, var applicationElement = elements.first {
        applicationElement.children = (applicationElement.children ?? []) + keptDiscovered
        elements[0] = applicationElement
      } else {
        elements.append(contentsOf: keptDiscovered)
      }
    }

    return buildResponse(
      elements: .tree(elements),
      walkStart: walkStart,
      coverage: tree.description.coverage(additional: additionalFrameCoverage),
      screen: screen.info,
      options: options,
      narrowing: tree.description.narrowingReport(reporting: elements, discovered: discoveredElements)
    )
  }

  /// The display the translator resolves against; 0 is the main display, which needs no name.
  private var displayID: UInt32 {
    display?.accessibilityID ?? 0
  }

  private func translation(at point: CGPoint) throws -> (any AXTranslationReference)? {
    let unrotated = try display?.geometry.unrotatedPoint(from: point) ?? point
    return try rawReader.resolve(.point(unrotated, displayID: displayID))
  }

  // MARK: - Helpers

  // `truncated` is always false: this path walks the live tree with no depth or node bound.
  private func buildResponse(
    elements: AccessibilityElementPayload,
    walkStart: CFAbsoluteTime,
    coverage: AccessibilityCoverage?,
    screen: AccessibilityScreenInfo?,
    options: AccessibilityRequestOptions,
    narrowing: AccessibilityNarrowing? = nil
  ) -> AccessibilityElementsResponse {
    let walkDuration = CFAbsoluteTimeGetCurrent() - walkStart
    // Collected always (cheap) and kept as metrics on every read; reported as a profile only when
    // profiling was requested.
    let profile = collector.finalize(withWalkDuration: walkDuration)
    let metrics = AccessibilityTranslatorReadMetrics(
      elementCount: profile.elementCount,
      roundTrips: profile.xpcCallCount,
      readDuration: profile.readDuration,
      totalDuration: profile.totalDuration,
      transport: transport.kind,
      acquireDuration: profile.acquireDuration,
      springBoardCheckDuration: collector.springBoardCheckDuration,
      acquireRoundTrips: collector.acquireRoundTrips,
      slowestRequest: collector.slowestRequest,
      requestsBehindAbandoned: collector.requestsBehindAbandoned,
      probeDuration: collector.probeDuration)
    return AccessibilityElementsResponse(
      elements: elements,
      profilingData: options.enableProfiling ? .translator(profile) : nil,
      coverage: coverage,
      truncated: false,
      screen: screen,
      narrowing: narrowing,
      translatorMetrics: metrics
    )
  }
}
