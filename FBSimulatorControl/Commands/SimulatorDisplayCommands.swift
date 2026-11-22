/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import Foundation

public enum SimulatorDisplayRotation: String, Sendable, Decodable {
  case upright = "rot0"
  case clockwise = "rot90"
  case upsideDown = "rot180"
  case counterclockwise = "rot270"

  /// The EXIF orientation that turns the panel's framebuffer into the interface as it is shown.
  public var exifOrientation: Int32 {
    switch self {
    case .upright: 1
    case .clockwise: 6
    case .upsideDown: 3
    case .counterclockwise: 8
    }
  }

  /// Whether the interface's width runs along the panel's height.
  public var isQuarterTurn: Bool {
    switch self {
    case .upright, .upsideDown: false
    case .clockwise, .counterclockwise: true
    }
  }
}

/// Interface geometry, independent of accessibility and touchscreen routing identities.
public struct SimulatorDisplayGeometry: Equatable, Sendable {
  public let bounds: CGRect
  public let scale: Double
  public let rotation: SimulatorDisplayRotation

  /// The point size of the physical panel, whatever the interface rotation. The digitizer is fixed to it.
  public var unrotatedPointSize: CGSize {
    CGSize(width: bounds.width / scale, height: bounds.height / scale)
  }

  /// The pixel size of the display's framebuffer surface: the `IOSurface` a framebuffer on this display hands its
  /// consumers. Fixed to the panel whatever the interface rotation, so a consumer can prepare for a display, such
  /// as with an encoder of this size, before it switches to it.
  public var surfacePixelSize: CGSize {
    CGSize(width: bounds.width.rounded(), height: bounds.height.rounded())
  }

  public var pointSize: CGSize {
    let size = unrotatedPointSize
    switch rotation {
    case .upright, .upsideDown: return size
    case .clockwise, .counterclockwise: return CGSize(width: size.height, height: size.width)
    }
  }

  /// Converts display-relative points to the unrotated point coordinates used by accessibility hit testing.
  public func unrotatedPoint(from point: CGPoint) throws -> CGPoint {
    let size = pointSize
    guard point.x.isFinite, point.y.isFinite,
      point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height
    else { throw SimulatorDisplayInteractionError.invalidPoint(point, bounds: size) }
    let width = unrotatedPointSize.width
    let height = unrotatedPointSize.height
    switch rotation {
    case .upright: return point
    case .clockwise: return CGPoint(x: point.y, y: height - point.x)
    case .upsideDown: return CGPoint(x: width - point.x, y: height - point.y)
    case .counterclockwise: return CGPoint(x: width - point.y, y: point.x)
    }
  }

  /// A display-relative point as a fraction of the unrotated display, as the digitizer takes it.
  func normalizedPoint(_ point: CGPoint) throws -> CGPoint {
    let point = try unrotatedPoint(from: point)
    return CGPoint(x: point.x * scale / bounds.width, y: point.y * scale / bounds.height)
  }

  /// The nearest point within the display's point bounds. backboardd clamps touches to the display
  /// edge itself, so clamping here delivers the same touch while making the clamp visible to idb.
  func clampedPoint(_ point: CGPoint) -> CGPoint {
    let size = pointSize
    return CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
  }

  func unrotatedEdge(_ edge: SimulatorHIDEdge) -> SimulatorHIDEdge {
    guard edge != .none else { return .none }
    let edges: [SimulatorHIDEdge] = [.top, .right, .bottom, .left]
    let turns: Int
    switch rotation {
    case .upright: turns = 0
    case .clockwise: turns = 3
    case .upsideDown: turns = 2
    case .counterclockwise: turns = 1
    }
    guard let index = edges.firstIndex(of: edge) else { return .none }
    return edges[(index + turns) % edges.count]
  }
}

/// A legacy provider can describe its sole integrated display without identifying it.
package enum SimulatorInteractionDisplay: Equatable, Sendable {
  case identified(SimulatorDisplay)
  case legacy(SimulatorDisplayGeometry)

  func hasSameConfiguration(as other: Self) -> Bool {
    switch (self, other) {
    case let (.identified(first), .identified(second)): first.hasSameConfiguration(as: second)
    case let (.legacy(first), .legacy(second)): first == second
    case (.identified, .legacy), (.legacy, .identified): false
    }
  }

  var geometry: SimulatorDisplayGeometry {
    switch self {
    case let .identified(display): display.geometry
    case let .legacy(geometry): geometry
    }
  }

  var uniqueID: String? {
    switch self {
    case let .identified(display): display.uniqueID
    case .legacy: nil
    }
  }
}

public enum SimulatorDisplayActivity: Equatable, Sendable {
  case active
  case inactive
  /// The runtime reports a backlight state of `unknown`.
  case unknown
}

/// A current display snapshot. Activity evidence is independent of IO port power.
public struct SimulatorDisplay: Equatable, Sendable {
  public let uniqueID: String
  public let name: String
  public let activity: SimulatorDisplayActivity

  public var isActive: Bool { activity == .active }
  public let isPrimary: Bool
  public let isIntegrated: Bool
  /// Bounds in the display's unrotated pixel coordinate space.
  public let bounds: CGRect
  public let scale: Double
  public let rotation: SimulatorDisplayRotation

  init(
    uniqueID: String, name: String, activity: SimulatorDisplayActivity, isPrimary: Bool, isIntegrated: Bool,
    bounds: CGRect, scale: Double, rotation: SimulatorDisplayRotation
  ) {
    self.uniqueID = uniqueID
    self.name = name
    self.activity = activity
    self.isPrimary = isPrimary
    self.isIntegrated = isIntegrated
    self.bounds = bounds
    self.scale = scale
    self.rotation = rotation
  }

  public var geometry: SimulatorDisplayGeometry {
    SimulatorDisplayGeometry(bounds: bounds, scale: scale, rotation: rotation)
  }

  func hasSameConfiguration(as other: Self) -> Bool {
    uniqueID == other.uniqueID && activity == other.activity && isIntegrated == other.isIntegrated && geometry == other.geometry
  }

  /// Pixel dimensions after applying the current interface rotation.
  public var size: CGSize {
    switch rotation {
    case .upright, .upsideDown: bounds.size
    case .clockwise, .counterclockwise: CGSize(width: bounds.height, height: bounds.width)
    }
  }
}

extension TargetDisplayDescription {
  init(_ display: SimulatorDisplay) {
    self.init(
      uniqueID: display.uniqueID, name: display.name, isActive: display.isActive, isIntegrated: display.isIntegrated,
      widthPixels: UInt(exactly: display.size.width.rounded()) ?? 0, heightPixels: UInt(exactly: display.size.height.rounded()) ?? 0,
      scale: display.scale)
  }
}

public enum SimulatorDisplayError: Error, LocalizedError {
  case changed
  /// Layout has moved to another display whose backlight has not caught up, as after a hinge change.
  case transitioning
  /// The current snapshot reports no active display that interactions can reach: no integrated display, or on an
  /// Apple TV, no TV output. A later snapshot may recover.
  case noActiveIntegratedDisplay
  /// The current snapshot reports more than one active display that interactions can reach. A later snapshot may
  /// settle.
  case ambiguousActiveDisplays([String])
  case screensNotReported(within: TimeInterval)

  public var errorDescription: String? {
    switch self {
    case let .screensNotReported(seconds): "Simulator did not report its displays within \(seconds) seconds"
    case .changed: "Simulator display changed during the operation"
    case .transitioning: "Simulator display is still changing: layout has moved to a display that is not lit yet"
    case .noActiveIntegratedDisplay: "Simulator currently reports no active display that interactions can reach"
    case let .ambiguousActiveDisplays(identities):
      "Simulator currently reports multiple active displays that interactions can reach: \(identities.joined(separator: ", "))"
    }
  }
}

/// Memoized per `Simulator` through its command cache, so display identities learned by one
/// interaction route the next.
// SAFETY: `identities` and `configurationTracker` are lock-guarded and the weak simulator reference is only ever read.
// patternlint-disable-next-line unchecked-sendable
public final class SimulatorDisplayCommands: DisplayCommands, @unchecked Sendable {
  private weak var simulator: Simulator?
  package let identities = DisplayIdentityCache()
  package let configurationTracker: DisplayConfigurationTracker

  public init(simulator: Simulator) {
    self.simulator = simulator
    configurationTracker = DisplayConfigurationTracker { [weak simulator] in
      simulator.map { InteractionDisplayKind($0.productFamily) } ?? .integrated
    }
  }

  /// Only cancellation and a released simulator throw; every CoreDevice failure is reported.
  package func report() async throws -> SimulatorDisplayReport {
    do {
      return try await target().coreDevice.perform(
        action: SimulatorDisplayProtocol.action, service: SimulatorDisplayProtocol.service, input: CoreDeviceEmptyInput(),
        decode: SimulatorDisplayProtocol.report)
    } catch let error as SimulatorCoreDeviceError {
      return .failed(error)
    }
  }

  /// The display configuration once any transition settles. `.transitioning` only when the transition outlasts
  /// `timeout`; a hinge change has been seen to take about 4 seconds on a heavily loaded host.
  public func configuration(
    settledWithin timeout: Duration = DisplayTransitionSettling.standard.timeout
  ) async throws
    -> SimulatorDisplayConfiguration
  {
    try await settledConfiguration(within: timeout)
  }

  /// The active display once any transition settles, provided it is the one `selection` names. Throws
  /// `SimulatorDisplayInteractionError.inactiveDisplay` for a named display that is not active, and
  /// `SimulatorDisplayError.changed` for a configuration that has been replaced.
  public func activeDisplay(
    selectedBy selection: DisplaySelection, settledWithin timeout: Duration = DisplayTransitionSettling.standard.timeout
  ) async throws -> SimulatorDisplay {
    try await activeDisplay(selectedBy: selection, within: timeout)
  }

  /// The current display configuration, then each change to it, until the stream is cancelled. Follows
  /// CoreDevice's display pushes, and polls when the runtime does not push or its pushes stop. A consumer of
  /// frames can move to a transition's `incoming` display at once; input should wait for `.settled`.
  public func configurations() -> AsyncStream<SimulatorDisplayConfiguration> {
    followConfigurations()
  }

  package var logger: (any ControlCoreLogger)? { simulator?.logger }

  /// Lists connected touchscreens. Match `displayUniqueID` to a display snapshot before routing input.
  package func touchscreens() async throws -> [SimulatorTouchscreen] {
    // Universal HID can advertise a virtual digitizer even when the target has no touch display.
    let simulator = try target()
    guard simulator.productFamily.hasTouchscreen else { return [] }
    return try await simulator.coreDevice.send(
      service: SimulatorTouchscreenProtocol.service, message: SimulatorTouchscreenProtocol.request(),
      decode: SimulatorTouchscreenProtocol.touchscreens)
  }

  private func target() throws -> Simulator {
    guard let simulator else { throw WeakTargetError.simulator }
    return simulator
  }

  package func reportPushes() throws -> AsyncThrowingStream<SimulatorDisplayReport, Error> {
    let channel = UUID()
    return try target().coreDevice.subscribe(
      action: SimulatorDisplayUpdatesProtocol.action, service: SimulatorDisplayUpdatesProtocol.service,
      input: SimulatorDisplayUpdatesProtocol.StreamInput(channel: channel)
    ) { event in
      try SimulatorDisplayUpdatesProtocol.report(event, channel: channel)
    }
  }
}
