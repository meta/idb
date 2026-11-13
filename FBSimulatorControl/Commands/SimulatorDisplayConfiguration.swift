/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// A simulator's displays, numbered so that a consumer can tell whether anything that maps touches or
/// shapes frames has changed since it last looked.
public struct SimulatorDisplayConfiguration: Equatable, Sendable {

  public enum Phase: Equatable, Sendable {
    case settled
    /// Layout has moved to a display whose backlight has not caught up, as during a hinge change.
    /// `displays` and `active` are the outgoing configuration, and input should wait for `.settled`.
    /// `incoming` is the integrated display the layout has moved to, when the runtime names exactly one; it
    /// already draws, so a consumer of frames can move to it before the transition settles.
    case transitioning(incoming: SimulatorDisplay?)
  }

  /// The display interactions target: the sole integrated display, or the active one of several.
  public enum ActiveDisplay: Equatable, Sendable {
    case identified(SimulatorDisplay)
    /// The sole integrated display of a runtime that does not identify its displays.
    case unidentified(SimulatorDisplayGeometry)
    /// No integrated display is active, or several are. A later configuration may settle on one.
    case unresolved
    /// The runtime cannot say which display interactions target: it reports an integrated display's activity
    /// as `unknown`, or several integrated displays without identifying them.
    case unknown
  }

  /// Increases whenever a display appears or disappears, or any display's activity or geometry changes,
  /// including its interface rotation. A transition that settles back where it started keeps its generation.
  /// Generations are per simulator, start at 1, and may skip values. A change reverted before anything reads
  /// the displays goes unnumbered unless a `configurations()` stream is following them.
  public let generation: UInt64
  /// Every identified display. Empty on runtimes that do not identify their displays.
  public let displays: [SimulatorDisplay]
  public let active: ActiveDisplay
  public let phase: Phase

  /// The identified display interactions target, or why the configuration has none.
  public func activeDisplay() throws -> SimulatorDisplay {
    switch try settledActive() {
    case let .identified(display):
      return display
    case .unidentified:
      throw SimulatorDisplayInteractionError.unsupportedCapability("an identified integrated display")
    case .unresolved:
      throw unresolved
    case .unknown:
      throw SimulatorDisplayInteractionError.unsupportedCapability("one active integrated display")
    }
  }

  /// The geometry of the display interactions target, whether or not the runtime identifies it.
  public func activeGeometry() throws -> SimulatorDisplayGeometry {
    switch try settledActive() {
    case let .identified(display):
      return display.geometry
    case let .unidentified(geometry):
      return geometry
    case .unresolved:
      throw unresolved
    case .unknown:
      throw SimulatorDisplayInteractionError.unsupportedCapability("one integrated display")
    }
  }

  private func settledActive() throws -> ActiveDisplay {
    switch phase {
    case .settled: active
    case .transitioning: throw SimulatorDisplayError.transitioning
    }
  }

  private var unresolved: SimulatorDisplayError {
    let identities = displays.filter { $0.isIntegrated && $0.isActive }.map(\.uniqueID)
    return identities.isEmpty ? .noActiveIntegratedDisplay : .ambiguousActiveDisplays(identities)
  }
}

/// A display report, numbered by when its read began.
struct DisplayRead: Sendable {
  fileprivate let sequence: UInt64
  let report: SimulatorDisplayReport
}

/// Assigns generations to display reports. Every read of a simulator's displays passes through one tracker,
/// so all readers agree on the generation of a configuration. Reads can overlap and finish in any order, so a
/// read that began before the newest one observed cannot replace it.
// SAFETY: Every access to the stored configuration and read sequence holds the lock.
// patternlint-disable-next-line unchecked-sendable
package final class DisplayConfigurationTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var current: (configuration: SimulatorDisplayConfiguration, basis: [SimulatorInteractionDisplay])?
  private var newest: (sequence: UInt64, configuration: SimulatorDisplayConfiguration, resolution: SimulatorDisplayResolution)?
  private var sequence: UInt64 = 0
  let follower = DisplayConfigurationFollower()

  /// The most recently observed configuration, if any read has succeeded.
  package var latest: SimulatorDisplayConfiguration? {
    lock.lock()
    defer { lock.unlock() }
    return current?.configuration
  }

  /// Numbers the read before it begins, so that it is ordered by when it began rather than when it finished.
  func read(_ report: () async throws -> SimulatorDisplayReport) async rethrows -> DisplayRead {
    let sequence = next()
    return DisplayRead(sequence: sequence, report: try await report())
  }

  /// A report that arrived without being read, such as a push, is numbered as it arrives.
  func arrived(_ report: SimulatorDisplayReport) -> DisplayRead {
    DisplayRead(sequence: next(), report: report)
  }

  private func next() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    sequence += 1
    return sequence
  }

  /// Throws a failed read's error, which says nothing about the configuration. A read overtaken by a newer one
  /// returns the newer configuration.
  func observe(_ read: DisplayRead) throws -> SimulatorDisplayConfiguration {
    try observation(of: read).configuration.get()
  }

  /// Where interactions route for `read`, numbered alongside its configuration. A failed read falls back to the
  /// main display rather than throwing.
  func resolution(of read: DisplayRead) -> SimulatorDisplayResolution {
    observation(of: read).resolution
  }

  private func observation(
    of read: DisplayRead
  ) -> (configuration: Result<SimulatorDisplayConfiguration, SimulatorCoreDeviceError>, resolution: SimulatorDisplayResolution) {
    let resolution = SimulatorDisplayResolution(read.report)
    lock.lock()
    defer { lock.unlock() }
    if case let .failed(error) = read.report {
      return (.failure(error), resolution)
    }
    if let newest, newest.sequence > read.sequence {
      return (.success(newest.configuration), newest.resolution)
    }
    let configuration = configuration(of: read.report, resolution: resolution)
    // Offered under the lock so subscribers see configurations in the order they were numbered. The follower never
    // takes this lock, so the order is always this lock, then the follower's.
    if case let .success(observed) = configuration {
      newest = (read.sequence, observed, resolution)
      follower.offer(observed)
    }
    return (configuration, resolution)
  }

  private func configuration(
    of report: SimulatorDisplayReport, resolution: SimulatorDisplayResolution
  ) -> Result<SimulatorDisplayConfiguration, SimulatorCoreDeviceError> {
    switch report {
    case let .failed(error):
      return .failure(error)
    case let .transitioning(incoming):
      guard let current else {
        return .success(SimulatorDisplayConfiguration(generation: 1, displays: [], active: .unresolved, phase: .transitioning(incoming: incoming)))
      }
      let previous = current.configuration
      return .success(
        SimulatorDisplayConfiguration(
          generation: previous.generation, displays: previous.displays, active: previous.active, phase: .transitioning(incoming: incoming)))
    case let .displays(displays):
      return .success(settle(displays: displays, basis: displays.map { .identified($0) }, active: Self.active(in: resolution)))
    case let .legacy(integrated):
      return .success(settle(displays: [], basis: integrated.map { .legacy($0) }, active: Self.active(in: resolution)))
    }
  }

  private func settle(
    displays: [SimulatorDisplay], basis: [SimulatorInteractionDisplay], active: SimulatorDisplayConfiguration.ActiveDisplay
  ) -> SimulatorDisplayConfiguration {
    let generation: UInt64 =
      switch current {
      case nil: 1
      case let (previous, previousBasis)?:
        previousBasis.count == basis.count && zip(previousBasis, basis).allSatisfy { $0.hasSameConfiguration(as: $1) }
          ? previous.generation : previous.generation + 1
      }
    let configuration = SimulatorDisplayConfiguration(generation: generation, displays: displays, active: active, phase: .settled)
    current = (configuration, basis)
    return configuration
  }

  /// Only called for reports that list displays, so neither an unreadable report nor a transition reaches here.
  private static func active(in resolution: SimulatorDisplayResolution) -> SimulatorDisplayConfiguration.ActiveDisplay {
    switch resolution {
    case let .target(.selected(display)), let .target(.sole(.identified(display))): .identified(display)
    case let .target(.sole(.legacy(geometry))): .unidentified(geometry)
    case .fallback(.noActiveIntegratedDisplay), .fallback(.ambiguousActiveDisplays), .transitioning: .unresolved
    case .fallback(.legacyIntegratedDisplays), .fallback(.unknownActivity), .fallback(.unreadable), .fallback(.noIntegratedDisplay):
      .unknown
    }
  }
}
