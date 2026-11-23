/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
@testable import FBSimulatorControl
import Foundation

/// Test double for the display reads, so routing built on them runs the real logic. Each display read
/// takes the next scripted result; the last one repeats. Pushes are unavailable unless scripted.
// SAFETY: The script and read count are guarded by the lock.
// patternlint-disable-next-line unchecked-sendable
final class DisplayCommandsDouble: DisplayCommands, @unchecked Sendable {
  let identities = DisplayIdentityCache()
  let configurationTracker: DisplayConfigurationTracker
  let transitionSettling = DisplayTransitionSettling(timeout: .milliseconds(50), interval: .milliseconds(5))
  private let lock = NSLock()
  private var results: [Result<SimulatorDisplayReport, any Error>]
  private var readCount = 0
  private var touchscreenReadCount = 0
  private let touchscreenResult: [SimulatorTouchscreen]
  private let pushes: AsyncThrowingStream<SimulatorDisplayReport, any Error>?

  init(
    _ results: [Result<SimulatorDisplayReport, any Error>], touchscreens: [SimulatorTouchscreen] = [],
    pushes: AsyncThrowingStream<SimulatorDisplayReport, any Error>? = nil, interactionDisplays: InteractionDisplayKind = .integrated
  ) {
    precondition(!results.isEmpty)
    self.configurationTracker = DisplayConfigurationTracker { interactionDisplays }
    self.results = results
    self.touchscreenResult = touchscreens
    self.pushes = pushes
  }

  convenience init(_ targets: SimulatorDisplayTarget..., touchscreens: [SimulatorTouchscreen] = []) {
    self.init(targets.map { .success(.reporting($0)) }, touchscreens: touchscreens)
  }

  var reads: Int {
    lock.lock()
    defer { lock.unlock() }
    return readCount
  }

  var touchscreenReads: Int {
    lock.lock()
    defer { lock.unlock() }
    return touchscreenReadCount
  }

  func touchscreens() async throws -> [SimulatorTouchscreen] {
    lock.withLock {
      touchscreenReadCount += 1
      return touchscreenResult
    }
  }

  func report() async throws -> SimulatorDisplayReport {
    try lock.withLock {
      readCount += 1
      return try (results.count > 1 ? results.removeFirst() : results[0]).get()
    }
  }

  func reportPushes() throws -> AsyncThrowingStream<SimulatorDisplayReport, any Error> {
    guard let pushes else { throw SimulatorCoreDeviceError.unsupported("display pushes") }
    return pushes
  }
}

extension SimulatorDisplayReport {
  /// A report that resolves to `target`. A selected display is reported beside an inactive integrated one.
  static func reporting(_ target: SimulatorDisplayTarget) -> Self {
    switch target {
    case let .sole(.identified(display)):
      return .displays([display])
    case let .sole(.legacy(geometry)):
      return .legacy(integrated: [geometry])
    case let .selected(display):
      let inactive = SimulatorDisplay(
        uniqueID: "\(display.uniqueID)-inactive", name: display.name, activity: .inactive, isPrimary: false, isIntegrated: true,
        bounds: display.bounds, scale: display.scale, rotation: display.rotation)
      return .displays([display, inactive])
    }
  }
}

/// Answers every request with the scripted accessibility display inventory.
actor InventoryTransport: AXBridgeTransport {
  private let inventory: [SimulatorAccessibilityDisplay]
  private let scopedInteractions: Bool
  private(set) var sends = 0
  /// The receive timeout of each bounded send; an unbounded send records none.
  private(set) var receiveTimeouts: [TimeInterval] = []

  init(_ inventory: [SimulatorAccessibilityDisplay], scopedInteractions: Bool = false) {
    self.inventory = inventory
    self.scopedInteractions = scopedInteractions
  }

  func send(_ request: AXBridgeRequest) async throws -> AXBridgeReply {
    sends += 1
    let inventory = BridgeAXDisplayInventory(
      displayScopedInteractions: scopedInteractions, displayScopedTrees: false, displayScopedQuiescence: false,
      displays: inventory.map { BridgeAXDisplayInventory.Display(uniqueID: $0.uniqueID, displayID: $0.displayID) })
    return try AXBridgeReply(answer: JSONEncoder().encode(BridgeAXAnswer.displays(inventory)), for: request)
  }

  func send(_ request: AXBridgeRequest, receiveTimeout: TimeInterval) async throws -> AXBridgeReply {
    receiveTimeouts.append(receiveTimeout)
    return try await send(request)
  }
}

extension DisplayConfigurationTracker {
  /// Observes `report` as a read that began just now.
  func observe(_ report: SimulatorDisplayReport) throws -> SimulatorDisplayConfiguration {
    try observe(arrived(report))
  }
}
