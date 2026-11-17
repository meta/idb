/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency internal import AccessibilityPlatformTranslation
import AppKit
import CoreSimulator
import FBControlCore
import FBSimulatorControl
import FBSimulatorServices
import Foundation

// MARK: - Simulator (translation dispatcher construction)

extension Simulator {

  /// Builds a dispatcher for the given translator and wires it up as the
  /// translator's token delegate. `translator` is typed `Any` so tests can pass
  /// a mock `AXPTranslator`.
  static func createAccessibilityTranslationDispatcher(withTranslator translator: Any) -> AXTranslationDispatcher {
    let axTranslator = unsafeBitCast(translator as AnyObject, to: AXPTranslator.self)
    let dispatcher = AXTranslationDispatcher(translator: axTranslator)
    axTranslator.bridgeTokenDelegate = dispatcher
    return dispatcher
  }

  // Process-wide singleton: AXPTranslator is itself a singleton with a single
  // bridgeTokenDelegate slot, so exactly one dispatcher backs every simulator (it
  // disambiguates concurrent requests by token, guarded internally by a lock).
  private static let sharedAccessibilityTranslationDispatcher: AXTranslationDispatcher = {
    let translator = unsafeBitCast(AXPTranslator.sharedInstance() as AnyObject, to: AXPTranslator.self)
    return Simulator.createAccessibilityTranslationDispatcher(withTranslator: translator)
  }()

  var accessibilityTranslationDispatcher: AXTranslationDispatcher {
    Simulator.sharedAccessibilityTranslationDispatcher
  }
}

// MARK: - SimulatorAccessibilityCommands

/// Simulator implementation of the accessibility command surface. Resolves the
/// frontmost / at-point / matching accessibility element via the translation
/// dispatcher, diagnosing a restarting SpringBoard for frontmost lookups.
final class SimulatorAccessibilityCommands {

  private static let springBoardServiceName = "com.apple.SpringBoard"

  private weak var simulator: Simulator?

  private let translationDispatcher: AXTranslationDispatcher?
  /// The transport every read uses when one was given, rather than resolving the bridge's.
  let transport: (any AXTranslationTransport)?
  private let launchCtl: (any LaunchCtlCommands)?
  private let displays: (any DisplayCommands)?
  /// When a simulator process started, read from the host.
  private let processStartDate: (pid_t) -> Date?
  /// Whether a simulator process is running, read from the host.
  private let processIsRunning: (pid_t) -> Bool
  private let stallWatchEnvironment: AXStallWatch.Environment
  private let transportLock = NSLock()
  private var bridgeTransport: CoreSimulatorBridgeAXTranslationTransport?

  init(
    simulator: Simulator,
    translationDispatcher: AXTranslationDispatcher? = nil,
    transport: (any AXTranslationTransport)? = nil,
    launchCtl: (any LaunchCtlCommands)? = nil,
    displays: (any DisplayCommands)? = nil,
    processStartDate: @escaping (pid_t) -> Date? = HostProcess.startDate(of:),
    processIsRunning: @escaping (pid_t) -> Bool = HostProcess.isRunning(_:),
    stallWatchEnvironment: AXStallWatch.Environment = AXStallWatch.Environment()
  ) {
    self.simulator = simulator
    self.translationDispatcher = translationDispatcher
    self.transport = transport
    self.launchCtl = launchCtl
    self.displays = displays
    self.processStartDate = processStartDate
    self.processIsRunning = processIsRunning
    self.stallWatchEnvironment = stallWatchEnvironment
  }

  // MARK: - Translation Dispatcher

  private var resolvedDispatcher: AXTranslationDispatcher? {
    translationDispatcher ?? simulator?.accessibilityTranslationDispatcher
  }

  /// Where every translator request this simulator's reads make is sent: straight to CoreSimulatorBridge,
  /// over one connection held for the simulator, unless that cannot be reached.
  private func resolvedTransport(_ simulator: Simulator) -> any AXTranslationTransport {
    if let transport {
      return transport
    }
    transportLock.lock()
    defer { transportLock.unlock() }
    if let bridgeTransport {
      return bridgeTransport
    }
    let preferred = Self.preferredTransport(connector: .simulator(simulator), logger: simulator.logger) {
      CoreSimulatorAXTranslationTransport(device: simulator.device)
    }
    bridgeTransport = preferred as? CoreSimulatorBridgeAXTranslationTransport
    return preferred
  }

  /// The bridge's accessibility service when it can be reached, otherwise CoreSimulator's own client,
  /// which reaches the same service. A fallback is not kept, so the next read tries the bridge again.
  static func preferredTransport(
    connector: SimulatorXPCConnector,
    logger: ControlCoreLogger?,
    fallback: () -> any AXTranslationTransport
  ) -> any AXTranslationTransport {
    let bridge = CoreSimulatorBridgeAXTranslationTransport(connector: connector)
    do {
      try bridge.connect()
      return bridge
    } catch {
      logger?.log("\(CoreSimulatorBridgeAXTranslationTransport.serviceName) is unreachable (\(error)); reading through CoreSimulator's client instead")
      return fallback()
    }
  }

  private func resolvedLaunchCtl(_ simulator: Simulator) -> any LaunchCtlCommands {
    launchCtl ?? simulator.launchCtl
  }

  /// Nil when reads fall back to the main display, which accessibility reaches without naming it.
  private func readDisplay() async throws -> AXTranslationDisplay? {
    guard let simulator else { throw WeakTargetError.simulator }
    let displays = displays ?? simulator.displays
    switch try await displays.resolveDisplay() {
    case .transitioning:
      throw SimulatorDisplayError.transitioning
    case .fallback:
      return nil
    case let .target(.sole(display)):
      return .sole(display)
    case let .target(.selected(display)):
      let accessibilityID = try await displays.accessibilityID(
        for: display, transport: simulator.frameworkBridgeTransport(scope: .exclusive),
        timing: simulator.accessibilityTiming)
      return .selected(display, id: accessibilityID)
    }
  }

  // MARK: - Resolution

  func observeFrontmostApplication(timing: SimulatorAccessibilityTiming? = nil) async throws -> FrontmostApplicationObservation {
    try validateAccessibility()
    guard let simulator else { throw WeakTargetError.simulator }
    guard let display = try await readDisplay(),
      case let .identified(identified) = display.interactionDisplay,
      identified.isActive, !identified.uniqueID.isEmpty
    else { throw SimulatorDisplayError.noActiveIntegratedDisplay }
    let request = AXTranslationRequest(
      kind: .frontmostApplication, display: display, clientType: .noClient,
      transport: resolvedTransport(simulator), timing: timing ?? simulator.accessibilityTiming)
    let element = try await accessibilityElement(request: request, diagnosesSpringBoard: true)
    defer { element.close() }
    guard element.processIdentifier > 0 else { throw AccessibilityError.noTranslationObject(.frontmost) }
    return FrontmostApplicationObservation(processIdentifier: element.processIdentifier, displayID: identified.uniqueID)
  }

  /// Resolves a query to a concrete accessibility element via the point / matching / frontmost
  /// mechanism. `clientType` is carried by every translator request made for the element, from
  /// resolution through serialization, and `timing` bounds them; nil is the simulator's. Callers own the
  /// returned element and must `close()` it. `stallObserver` is told about the requests that resolve the element, a
  /// marker's search included, as well as those that later read it.
  func resolveElement(
    for query: AccessibilityElementQuery, clientType: AXClientType, timing: SimulatorAccessibilityTiming? = nil,
    stallObserver: (@Sendable (AccessibilityStallObservation) -> Void)? = nil
  ) async throws -> AccessibilityElement {
    try validateAccessibility()
    guard let simulator else {
      throw WeakTargetError.simulator
    }
    let display = try await readDisplay()
    let transport = resolvedTransport(simulator)
    let timing = timing ?? simulator.accessibilityTiming
    func request(_ kind: AXTranslationRequest.Kind) -> AXTranslationRequest {
      let request = AXTranslationRequest(
        kind: kind, display: display, clientType: clientType, transport: transport, timing: timing)
      request.stallObserver = stallObserver
      request.stallLogger = simulator.logger
      request.stallSimulatorUDID = simulator.udid
      request.stallWatchEnvironment = stallWatchEnvironment
      return request
    }
    switch query {
    case let .point(point):
      return try await accessibilityElement(request: request(.point(point)), diagnosesSpringBoard: false)
    case .frontmost:
      return try await accessibilityElement(request: request(.frontmostApplication), diagnosesSpringBoard: true)
    case let .marker(value, key, depth, ignoresCase):
      let root = try await accessibilityElement(request: request(.frontmostApplication), diagnosesSpringBoard: true)
      return try await root.findElement(withValue: value, forKey: key, depth: depth, ignoresCase: ignoresCase)
    case let .application(pid):
      // An explicit pid target: read that application directly, no SpringBoard diagnosis (that is only
      // meaningful for the frontmost read).
      return try await accessibilityElement(request: request(.applicationForPid(pid)), diagnosesSpringBoard: false)
    }
  }

  // Uses the CoreSimulator accessibility API via
  // -[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:].
  // This API requires Xcode 12+ to have been installed on the host at some point.
  private func validateAccessibility() throws {
    guard let simulator else {
      throw WeakTargetError.simulator
    }
    guard simulator.state == .booted else {
      throw AccessibilityError.simulatorNotBooted(description: "\(simulator)")
    }
    let selector = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
    guard simulator.device.responds(to: selector) else {
      throw AccessibilityError.accessibilityUnavailable
    }
    try SimulatorControlFrameworkLoader.accessibilityFrameworks.loadPrivateFrameworks(simulator.logger)
  }

  /// Resolves `request`'s root. A frontmost root that SpringBoard cannot currently answer for is reported as
  /// the precise error rather than read.
  private func accessibilityElement(request: AXTranslationRequest, diagnosesSpringBoard: Bool) async throws -> AccessibilityElement {
    guard let simulator else {
      throw WeakTargetError.simulator
    }
    guard let dispatcher = resolvedDispatcher else {
      throw AccessibilityError.dispatcherUnavailable
    }
    let root: AXTranslationReference
    do {
      root = try await dispatcher.rootHandle(withRequest: request)
    } catch let AccessibilityError.noTranslationObject(query) where diagnosesSpringBoard {
      // On the frontmost path a nil translation usually means SpringBoard (the provider of the
      // frontmost application) is down. Re-label the error when we can confirm that; a probe
      // failure or a live reading keeps the original .noTranslationObject (e.g. a genuine
      // invalid point or a transient mid-respawn).
      let springBoardRunning = (try? await resolvedLaunchCtl(simulator).serviceIsRunning(named: Self.springBoardServiceName)) ?? true
      if !springBoardRunning {
        throw AccessibilityError.springBoardNotRunning
      }
      throw AccessibilityError.noTranslationObject(query)
    }
    if diagnosesSpringBoard {
      do {
        let checkStart = CFAbsoluteTimeGetCurrent()
        defer { request.collector.springBoardCheckDuration = CFAbsoluteTimeGetCurrent() - checkStart }
        try await checkSpringBoardAnswersFor(root: root, simulator: simulator, request: request, dispatcher: dispatcher)
      } catch {
        // The request's token was pushed by the dispatcher but is not yet wrapped in an AccessibilityElement.
        dispatcher.popRequest(request)
        throw error
      }
    }
    return AccessibilityElement(handle: root, request: request, dispatcher: dispatcher, simulator: simulator)
  }

  /// Throws when the frontmost root names a process that has exited and SpringBoard is known to be why. After
  /// SpringBoard restarts, the simulator's accessibility service goes on answering for the SpringBoard that
  /// exited — a zero-framed root with nothing beneath it — until it refreshes on its own a few seconds later.
  /// Reading that root would report an empty screen as the frontmost application.
  ///
  /// Only a SpringBoard that is not running, or one that started within `springBoardRestartWindow`, is known to
  /// be the cause. A root whose process is alive, as an application's is while it launches, or one that exited
  /// while SpringBoard has been up for longer, is read as it is: it is not a SpringBoard condition.
  private func checkSpringBoardAnswersFor(
    root handle: AXTranslationReference, simulator: Simulator, request: AXTranslationRequest, dispatcher: AXTranslationDispatcher
  ) async throws {
    // A quick check: a non-zero accessibility frame indicates a healthy element.
    let root = try await dispatcher.performUnserialized(cancelling: request.cancellation) {
      try request.snapshot(of: handle, plan: AXReadPlan(attributes: [], depth: .limited(0)))
    }
    if !root.frame.equalTo(.zero) {
      return
    }
    // A zero-framed root is stale only if its process has exited. The host says so at once, where launchctl in a
    // busy simulator takes seconds. A launchctl failure is treated as live, so an unreadable diagnosis never fails
    // a read that may be healthy.
    if processIsRunning(root.pid) {
      return
    }
    guard let services = try? await resolvedLaunchCtl(simulator).listServices(), !services.values.contains(root.pid) else {
      return
    }
    guard let springBoard = services[Self.springBoardServiceName] ?? nil else {
      throw AccessibilityError.springBoardNotRunning
    }
    guard let started = processStartDate(springBoard), Date().timeIntervalSince(started) < Self.springBoardRestartWindow else {
      return
    }
    throw AccessibilityError.springBoardRestarting(exitedProcessIdentifier: root.pid, restartedAgo: Date().timeIntervalSince(started))
  }

  /// How recently SpringBoard must have started for an exited frontmost root to be put down to its restart. The
  /// accessibility service was measured to refresh about six seconds after SpringBoard restarts.
  private static let springBoardRestartWindow: TimeInterval = 30
}
