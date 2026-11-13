/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// The display reads that route interactions. `SimulatorDisplayCommands` reads the simulator; the
/// routing built on these reads is shared by every conformance.
package protocol DisplayCommands: AnyObject, Sendable {

  func report() async throws -> SimulatorDisplayReport

  func touchscreens() async throws -> [SimulatorTouchscreen]

  /// Identities already learned for display UUIDs, so a routed read does not ask again.
  var identities: DisplayIdentityCache { get }

  var transitionSettling: DisplayTransitionSettling { get }

  /// Numbers every report read through the routing below.
  var configurationTracker: DisplayConfigurationTracker { get }

  /// Each display report the runtime pushes, until the stream is cancelled. Throws when the runtime does not push.
  func reportPushes() throws -> AsyncThrowingStream<SimulatorDisplayReport, Error>

  var logger: (any ControlCoreLogger)? { get }
}

/// How long one-shot resolution keeps reading while a display transition settles, and how often.
@usableFromInline
package struct DisplayTransitionSettling: Sendable {
  @usableFromInline let timeout: Duration
  let interval: Duration

  /// Live hinge changes have been seen to settle within about 4 seconds on a heavily loaded host.
  @usableFromInline static let standard = DisplayTransitionSettling(timeout: .seconds(5), interval: .milliseconds(100))
}

/// The display an interaction targets, and whether routing has to name it.
package enum SimulatorDisplayTarget: Equatable, Sendable {
  /// The only integrated display. Accessibility and input reach it without naming it.
  case sole(SimulatorInteractionDisplay)
  /// The active one of several integrated displays. Accessibility and input have to name it.
  case selected(SimulatorDisplay)

  var display: SimulatorInteractionDisplay {
    switch self {
    case let .sole(display): display
    case let .selected(display): .identified(display)
    }
  }
}

/// Whether interactions route to a display the runtime reported, or fall back to the main display.
package enum SimulatorDisplayResolution: Equatable, Sendable {
  /// The runtime cannot say which display interactions target. Accessibility and input reach the main
  /// display without naming one, as they did before runtimes reported displays.
  case fallback(SimulatorDisplayFallback)
  case target(SimulatorDisplayTarget)
  /// Layout has moved to a display whose backlight has not caught up, as after a hinge change.
  case transitioning

  /// The sole integrated display, active or not, or the active one of several.
  init(_ report: SimulatorDisplayReport) {
    switch report {
    case let .legacy(integrated):
      guard integrated.count == 1, let geometry = integrated.first else {
        self = .fallback(.legacyIntegratedDisplays(count: integrated.count))
        return
      }
      self = .target(.sole(.legacy(geometry)))
    case let .displays(displays):
      let integrated = displays.filter(\.isIntegrated)
      // An Apple TV renders only on its TV output: with no integrated display to become active, there is no
      // transition to wait out.
      if integrated.isEmpty, !displays.isEmpty {
        self = .fallback(.noIntegratedDisplay)
        return
      }
      if integrated.contains(where: { $0.activity == .unknown }) {
        self = .fallback(.unknownActivity)
        return
      }
      if integrated.count == 1, let display = integrated.first {
        self = .target(.sole(.identified(display)))
        return
      }
      let active = integrated.filter(\.isActive)
      guard let display = active.first else {
        self = .fallback(.noActiveIntegratedDisplay)
        return
      }
      guard active.count == 1 else {
        self = .fallback(.ambiguousActiveDisplays(active.map(\.uniqueID)))
        return
      }
      self = .target(.selected(display))
    case .transitioning:
      self = .transitioning
    case let .failed(error):
      self = .fallback(.unreadable(error))
    }
  }
}

/// Why interactions fell back to the main display. One-shot resolution waits out no active display, or several,
/// rather than falling back, as both pass during a hinge change.
package enum SimulatorDisplayFallback: Equatable, Sendable {
  /// The display read failed, including on runtimes that do not report displays.
  case unreadable(SimulatorCoreDeviceError)
  /// A runtime without display activity reports other than one integrated display.
  case legacyIntegratedDisplays(count: Int)
  /// The runtime reports an integrated display's backlight as `unknown`.
  case unknownActivity
  /// The runtime reports displays, none of them integrated (an Apple TV's TV output).
  case noIntegratedDisplay
  case noActiveIntegratedDisplay
  case ambiguousActiveDisplays([String])
}

/// Numeric identities keyed by display UUID. The guest assigns them per display, so one is looked up
/// again only when a display it has not seen is selected.
// SAFETY: Every access to the mapping holds the lock.
// patternlint-disable-next-line unchecked-sendable
package final class DisplayIdentityCache: @unchecked Sendable {
  private let lock = NSLock()
  private var accessibility: [String: UInt32] = [:]
  private var verified: AXBridgeDisplayCapabilities = []
  private var digitizers: [String: UInt32] = [:]

  /// Only an identity from an inventory that was checked for `capabilities` counts.
  func accessibilityID(for uniqueID: String, requiring capabilities: AXBridgeDisplayCapabilities = []) -> UInt32? {
    lock.lock()
    defer { lock.unlock() }
    guard verified.isSuperset(of: capabilities) else { return nil }
    return accessibility[uniqueID]
  }

  func remember(_ inventory: [SimulatorAccessibilityDisplay], verified capabilities: AXBridgeDisplayCapabilities = []) {
    lock.lock()
    defer { lock.unlock() }
    accessibility = Dictionary(inventory.map { ($0.uniqueID, $0.displayID) }, uniquingKeysWith: { first, _ in first })
    verified = capabilities
  }

  func digitizerTarget(for uniqueID: String) -> UInt32? {
    lock.lock()
    defer { lock.unlock() }
    return digitizers[uniqueID]
  }

  /// Keeps only displays reached by exactly one digitizer.
  func remember(_ touchscreens: [SimulatorTouchscreen]) {
    let targets = Dictionary(grouping: touchscreens.filter { $0.digitizerTarget > 0 }, by: \.displayUniqueID)
      .compactMapValues { $0.count == 1 ? $0[0].digitizerTarget : nil }
    lock.lock()
    defer { lock.unlock() }
    digitizers = targets
  }
}

extension DisplayCommands {

  package var transitionSettling: DisplayTransitionSettling { .standard }

  func reportPushes() throws -> AsyncThrowingStream<SimulatorDisplayReport, Error> {
    throw SimulatorCoreDeviceError.unsupported("display pushes")
  }

  var logger: (any ControlCoreLogger)? { nil }

  /// The display interactions target once any display transition has settled. A hinge change moves layout to
  /// the new display before its backlight follows, and can pass through no active display or several; one-shot
  /// resolution waits that out. `.transitioning` only when the transition outlasts `transitionSettling`, and throws
  /// if no single display is active by then.
  package func resolveDisplay() async throws -> SimulatorDisplayResolution {
    let deadline = ContinuousClock.now + transitionSettling.timeout
    while true {
      let resolution = configurationTracker.resolution(of: try await read())
      let expired = ContinuousClock.now >= deadline
      switch resolution {
      case .target, .fallback(.unreadable), .fallback(.legacyIntegratedDisplays), .fallback(.unknownActivity),
        .fallback(.noIntegratedDisplay):
        return resolution
      case .transitioning where expired:
        return resolution
      case .fallback(.noActiveIntegratedDisplay) where expired:
        throw SimulatorDisplayError.noActiveIntegratedDisplay
      case let .fallback(.ambiguousActiveDisplays(identities)) where expired:
        throw SimulatorDisplayError.ambiguousActiveDisplays(identities)
      case .transitioning, .fallback(.noActiveIntegratedDisplay), .fallback(.ambiguousActiveDisplays):
        try await Task.sleep(for: transitionSettling.interval)
      }
    }
  }

  /// Every identified display once any display transition has settled. A runtime that reports no display activity
  /// does not identify its displays, so none are listed.
  func describedDisplays() async throws -> TargetDetail<[TargetDisplayDescription]> {
    let configuration: SimulatorDisplayConfiguration
    do {
      configuration = try await settledConfiguration(within: transitionSettling.timeout)
    } catch let error as CancellationError {
      throw error
    } catch {
      return .failed(error)
    }
    switch configuration.phase {
    case .settled: return .read(configuration.displays.map(TargetDisplayDescription.init))
    case .transitioning: return .failed(SimulatorDisplayError.transitioning)
    }
  }

  private func read() async throws -> DisplayRead {
    try await configurationTracker.read { try await report() }
  }

  /// `.transitioning` only when the transition outlasts `timeout`. Only the returned read needs observing, as
  /// neither a transition nor a failed read changes the tracker.
  private func settledRead(within timeout: Duration) async throws -> DisplayRead {
    let deadline = ContinuousClock.now + timeout
    while true {
      let current = try await read()
      guard case .transitioning = current.report, ContinuousClock.now < deadline else { return current }
      try await Task.sleep(for: transitionSettling.interval)
    }
  }

  /// One read of the display interactions target, without waiting for a transition to settle.
  func currentDisplay() async throws -> SimulatorDisplayResolution {
    configurationTracker.resolution(of: try await read())
  }

  /// The configuration once any display transition has settled. `.transitioning` only when the transition
  /// outlasts `timeout`.
  package func settledConfiguration(within timeout: Duration) async throws -> SimulatorDisplayConfiguration {
    try configurationTracker.observe(await settledRead(within: timeout))
  }

  /// The active display once any transition has settled, provided it is the one `selection` names. Unlike the
  /// active display that interactions fall back from, a selected display is required.
  func activeDisplay(selectedBy selection: DisplaySelection, within timeout: Duration) async throws -> SimulatorDisplay {
    let configuration = try await settledConfiguration(within: timeout)
    let active = try configuration.activeDisplay()
    try selection.confirm(routedTo: .identified(active), latest: configuration)
    return active
  }

  /// The accessibility identity of a display that has to be named. The guest is asked only for a display it
  /// has not seen, and only then are `capabilities` required of it; it has `receiveTimeout` to answer.
  package func accessibilityID(
    for display: SimulatorDisplay, transport: any AXBridgeTransport, requiring capabilities: AXBridgeDisplayCapabilities = [],
    receiveTimeout: TimeInterval
  ) async throws -> UInt32 {
    if let accessibilityID = identities.accessibilityID(for: display.uniqueID, requiring: capabilities) {
      return accessibilityID
    }
    let inventory = try AXBridgeDisplayInventory.decode(
      await transport.send(.displays, receiveTimeout: receiveTimeout).answer, requiring: capabilities)
    let matches = inventory.filter { $0.uniqueID == display.uniqueID }
    guard matches.count == 1, let match = matches.first else {
      throw SimulatorDisplayInteractionError.missingMapping(display.uniqueID)
    }
    try await validate(.identified(display))
    identities.remember(inventory, verified: capabilities)
    return match.displayID
  }

  /// The digitizer that reaches a display that has to be named. Touchscreens are read only for a display not
  /// seen before.
  func digitizerTarget(for display: SimulatorDisplay) async throws -> UInt32 {
    if let digitizerTarget = identities.digitizerTarget(for: display.uniqueID) {
      return digitizerTarget
    }
    let touchscreens = try await touchscreens()
    let matches = touchscreens.filter { $0.displayUniqueID == display.uniqueID }
    guard matches.count == 1, let touchscreen = matches.first, touchscreen.digitizerTarget > 0 else {
      throw SimulatorDisplayInteractionError.unsupportedCapability("a unique touchscreen target for display \(display.uniqueID)")
    }
    try await validate(.identified(display))
    identities.remember(touchscreens)
    return touchscreen.digitizerTarget
  }

  /// Fails if the active display, or its geometry, differs from the snapshot.
  package func validate(_ display: SimulatorInteractionDisplay) async throws {
    switch try await resolveDisplay() {
    case let .target(target):
      guard target.display.hasSameConfiguration(as: display) else { throw SimulatorDisplayError.changed }
    case .fallback:
      throw SimulatorDisplayError.changed
    case .transitioning:
      throw SimulatorDisplayError.transitioning
    }
  }
}

extension DisplayCommands {

  /// The current configuration, then each change to it, until the stream is cancelled. Follows `reportPushes()`,
  /// and polls every `interval` when the runtime does not push or its pushes stop. A failed read yields nothing.
  /// Every stream shares one following per tracker, which polls at the shortest `interval` of its current streams.
  package func followConfigurations(polling interval: Duration = .milliseconds(250)) -> AsyncStream<SimulatorDisplayConfiguration> {
    configurationTracker.follower.subscribe(polling: interval) {
      Task {
        func observe(_ read: DisplayRead) {
          _ = try? configurationTracker.observe(read)
        }
        // Subscribing before the first read means a change between the two is pushed rather than missed.
        let subscription = Result { try reportPushes() }
        if let current = try? await read() {
          observe(current)
        }
        do {
          for try await pushed in try subscription.get() {
            observe(configurationTracker.arrived(pushed))
          }
          if !Task.isCancelled {
            logger?.log("Display pushes ended, polling the display configuration")
          }
        } catch {
          logger?.log("Polling the display configuration, as display pushes are unavailable: \(error)")
        }
        while !Task.isCancelled {
          if let polled = try? await read() {
            observe(polled)
          }
          try? await Task.sleep(for: configurationTracker.follower.interval ?? interval)
        }
      }
    }
  }
}
