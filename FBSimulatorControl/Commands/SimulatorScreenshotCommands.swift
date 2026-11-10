/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import Foundation

/// Everything after the capture itself -- resolving the request against the screen, cropping, scaling,
/// encoding -- is shared with the other targets and reports `ScreenshotGeometryError` or
/// `ScreenshotRenderError`.
public enum SimulatorScreenshotError: Error {
  case captureFailed
}

extension SimulatorScreenshotError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .captureFailed:
      return "Failed to capture a screenshot"
    }
  }
}

public final class SimulatorScreenshotCommands: ScreenshotCommands {

  private weak var simulator: Simulator?
  private var image: SimulatorImage?

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  /// The crop and scale are applied by the render itself rather than to its output, so all that is
  /// left here is to encode what comes back.
  public func take(configuration: ScreenshotConfiguration) async throws -> ScreenshotResult {
    guard let simulator = self.simulator else {
      throw WeakTargetError.simulator
    }
    let displays = simulator.displays
    switch configuration.display {
    case .main:
      return try await takeMainScreen(configuration: configuration, simulator: simulator)
    case .active:
      return try await Self.capture(
        resolveDisplay: { try await Self.resolution(of: displays) },
        display: { active in
          try await self.take(active, configuration: configuration, simulator: simulator) {
            Self.activeDisplay(in: try await displays.currentDisplay()) == active
          }
        },
        mainScreen: { try await self.takeMainScreen(configuration: configuration, simulator: simulator) },
        logger: simulator.logger)
    case .display, .configuration:
      let selected = try await displays.activeDisplay(selectedBy: configuration.display, within: displays.transitionSettling.timeout)
      return try await take(selected, configuration: configuration, simulator: simulator) {
        try await displays.activeDisplay(selectedBy: configuration.display, within: .zero) == selected
      }
    }
  }

  static func resolution(of displays: any DisplayCommands) async throws -> SimulatorDisplayResolution {
    try await displays.resolveDisplay()
  }

  /// The active display improves on the main screen but is never required: whatever stops it being
  /// selected or captured, the screenshot captures the main screen instead.
  static func capture<Result>(
    resolveDisplay: () async throws -> SimulatorDisplayResolution,
    display: (SimulatorDisplay) async throws -> Result,
    mainScreen: () async throws -> Result,
    logger: any ControlCoreLogger
  ) async throws -> Result {
    do {
      let resolution = try await resolveDisplay()
      if let active = activeDisplay(in: resolution) {
        return try await display(active)
      }
      logger.log("Capturing the main screen, as no active display is identified: \(resolution)")
    } catch let error as CancellationError {
      throw error
    } catch {
      logger.log("Capturing the main screen, as the active display could not be captured: \(error)")
    }
    return try await mainScreen()
  }

  /// Only an identified, active display has a framebuffer to capture. A transition is not waited out.
  static func activeDisplay(in resolution: SimulatorDisplayResolution) -> SimulatorDisplay? {
    switch resolution {
    case let .target(.selected(display)):
      return display
    case let .target(.sole(.identified(display))):
      return display.isActive ? display : nil
    case .target(.sole(.legacy)), .fallback, .transitioning:
      return nil
    }
  }

  private func takeMainScreen(configuration: ScreenshotConfiguration, simulator: Simulator) async throws -> ScreenshotResult {
    let image = try await connectToImage()
    let screenScale = simulator.screenInfo.map { Double($0.scale) }
    guard let captured = try await image.image(configuration: configuration, screenScale: screenScale) else {
      throw SimulatorScreenshotError.captureFailed
    }
    return try ScreenshotRenderer.render(
      transformed: captured.image,
      sourceSize: captured.sourceSize,
      encoding: configuration.encoding,
      screenScale: screenScale
    )
  }

  private func take(
    _ display: SimulatorDisplay, configuration: ScreenshotConfiguration, simulator: Simulator, stillCurrent: () async throws -> Bool
  ) async throws -> ScreenshotResult {
    let framebuffer = try await FramebufferSurfaceLocator.framebuffer(for: display, simulator: simulator)
    let image = SimulatorImage(framebuffer: framebuffer, logger: simulator.logger)
    guard let captured = try await image.image(configuration: configuration, screenScale: display.scale, display: display) else {
      throw SimulatorScreenshotError.captureFailed
    }
    guard try await stillCurrent() else { throw SimulatorDisplayError.changed }
    return try ScreenshotRenderer.render(
      transformed: captured.image, sourceSize: captured.sourceSize,
      encoding: configuration.encoding, screenScale: display.scale, displayID: display.uniqueID)
  }

  private func connectToImage() async throws -> SimulatorImage {
    if let image = self.image {
      return image
    }
    guard let simulator = self.simulator else {
      throw WeakTargetError.simulator
    }
    let framebuffer = try await simulator.framebuffer.connect(display: .main)
    let image = SimulatorImage(framebuffer: framebuffer, logger: simulator.logger)
    self.image = image
    return image
  }

  /// The REPL's crop is in screen points (`ScreenshotUnit.points`).
  public func takeForRepl(cropRect: CGRect?, asPNG: Bool) async throws -> Data {
    let configuration = ScreenshotConfiguration(
      encoding: asPNG ? .png : .tiff,
      cropRect: cropRect,
      unit: .points
    )
    return try await take(configuration: configuration).imageData
  }
}
