/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreImage
import FBControlCore
import Foundation
import IOSurface

/// A render of a simulator surface, and the size of the surface it was cut from.
public struct SurfaceImage: Sendable {
  public let image: CGImage
  /// The surface's size in pixels, before any crop or scale was applied.
  public let sourceSize: CGSize
}

/// Renders the latest simulator IOSurface to a `CGImage`. Not thread-safe by itself: it is owned and
/// confined by the `SimulatorImage` actor, which serializes `updateSurface` and `image()`.
public final class SurfaceImageGenerator {

  private static let screenshotColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
  private let logger: (any ControlCoreLogger)?
  /// Created once and reused across renders: CIContext construction is expensive (it builds a GPU
  /// pipeline) and the context carries no per-image state.
  private let context = CIContext(options: nil)

  private var surface: IOSurface?

  public convenience init(purpose: String, logger: (any ControlCoreLogger)?) {
    let namedLogger = logger?.withName("\(logger?.name ?? "")_\(purpose)")
    self.init(logger: namedLogger)
  }

  private init(logger: (any ControlCoreLogger)?) {
    self.logger = logger
  }

  deinit {
    surface?.decrementUseCount()
  }

  /// Renders the whole surface at its native resolution.
  public func image() throws -> CGImage? {
    try image(configuration: ScreenshotConfiguration(), screenScale: nil)?.image
  }

  /// Renders the current surface with `configuration` applied inside the Core Image pipeline, so a scaled
  /// screenshot is never materialised at full resolution. The plan is resolved here, against the surface
  /// being rendered: a surface can be replaced (e.g. by rotation) between a caller reading its size and
  /// asking for an image, and a crop resolved against the old size would silently name the wrong region.
  public func image(configuration: ScreenshotConfiguration, screenScale: Double?, display: SimulatorDisplay? = nil) throws -> SurfaceImage? {
    guard let surface = self.surface else {
      return nil
    }
    guard let colorSpace = Self.screenshotColorSpace else {
      throw ScreenshotRenderError.colorSpaceCreationFailed
    }
    // CoreSimulator screenshots interpret framebuffer samples as sRGB, even when the surface is tagged P3.
    var source = unsafe CIImage(ioSurface: unsafeBitCast(surface, to: IOSurfaceRef.self), options: [.colorSpace: colorSpace])
    if let display {
      guard source.extent == display.bounds else { throw SimulatorDisplayError.changed }
      source = source.oriented(forExifOrientation: display.rotation.exifOrientation)
    }
    let sourceSize = source.extent.size
    let plan = try ScreenshotGeometry.plan(for: configuration, sourceSize: sourceSize, screenScale: screenScale)
    guard let image = render(source, plan: plan) else {
      return nil
    }
    return SurfaceImage(image: image, sourceSize: sourceSize)
  }

  // MARK: - Rendering

  /// Applies `plan` to `source`, then reads the result out at exactly the planned size.
  private func render(_ source: CIImage, plan: ScreenshotPlan) -> CGImage? {
    var image = source
    if let cropRect = plan.cropRect {
      image = image.cropped(to: Self.flipped(cropRect, in: source.extent))
    }
    // Move the region to the origin, so that neither the scale below nor the read-out at the end has
    // to account for where in the surface it came from.
    image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    if image.extent.size != plan.outputSize {
      guard let scaled = Self.scaled(image, from: image.extent.size, to: plan.outputSize) else {
        return nil
      }
      image = scaled
    }
    // Read out the planned size rather than the extent. The plan has already rounded each side to a
    // whole pixel, and the filter only reproduces that to within floating point.
    return context.createCGImage(image, from: CGRect(origin: .zero, size: plan.outputSize))
  }

  /// Core Image measures from the bottom left. A plan's crop rect, like every other rect a target
  /// deals in, is in top-left pixels, so it names the same region only once flipped onto the extent.
  private static func flipped(_ rect: CGRect, in extent: CGRect) -> CGRect {
    CGRect(x: extent.minX + rect.minX, y: extent.maxY - rect.maxY, width: rect.width, height: rect.height)
  }

  /// Both sizes are guarded: a zero side would become an infinite/NaN scale the filter accepts silently.
  private static func scaled(_ image: CIImage, from size: CGSize, to outputSize: CGSize) -> CIImage? {
    guard size.width > 0, size.height > 0, outputSize.width > 0, outputSize.height > 0,
      let filter = CIFilter(name: "CILanczosScaleTransform")
    else {
      return nil
    }
    // The filter scales y by `inputScale` and x by `inputScale * inputAspectRatio`. Both are derived
    // from the planned output size rather than taken from the plan's scale factor, so the extent
    // lands on the whole pixels the plan already committed to instead of half a pixel either side.
    let yScale = outputSize.height / size.height
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(yScale, forKey: "inputScale")
    filter.setValue((outputSize.width / size.width) / yScale, forKey: "inputAspectRatio")
    return filter.outputImage
  }

  public func updateSurface(_ surface: IOSurface?) {
    if let oldSurface = self.surface {
      logger?.info().log("Removing old surface \(oldSurface)")
      oldSurface.decrementUseCount()
      self.surface = nil
    }
    if let surface {
      surface.incrementUseCount()
      logger?.info().log("Received IOSurface from Framebuffer Service \(surface)")
      self.surface = surface
    }
  }
}
