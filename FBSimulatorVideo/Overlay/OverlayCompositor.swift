/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreImage
import CoreVideo
import FBSimulatorControl
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

enum OverlayCompositorError: Error, LocalizedError {
  case failedToCreateCGImage
  case failedToEncodePNG

  var errorDescription: String? {
    switch self {
    case .failedToCreateCGImage:
      return "Failed to create CGImage from pixel buffer"
    case .failedToEncodePNG:
      return "Failed to encode PNG"
    }
  }
}

/// Composites a stream's overlay over its source frames, and pads them out to the edge insets, on
/// the GPU. Produces frames at the encoder's output size — the same `VideoOutputDimensions` the
/// encoder was created for, since a frame of any other size distorts the output.
///
/// Confined to the stream actor: `configure` runs at every mount, `composite` at every push, and
/// `overlayBuffer` is set from `updateOverlayBuffer`.
final class OverlayCompositor {
  let edgeInsets: VideoStreamEdgeInsets
  /// The overlay to draw over every frame, if any. The renderer may update the buffer's contents in
  /// place between pushes.
  var overlayBuffer: CVPixelBuffer?

  private var context: CIContext?
  private var pool: CVPixelBufferPool?
  private(set) var outputWidth = 0
  private(set) var outputHeight = 0
  /// The interface rotation the source is turned by before it is scaled and padded.
  private(set) var rotation = SimulatorDisplayRotation.upright
  /// Whether the turned source has another shape than the canvas, and so is fitted into it with black around it.
  private(set) var letterboxes = false
  /// The size of a frame showing the turned source at its own shape, for a screenshot of a letterboxed source.
  private var screenWidth = 0
  private var screenHeight = 0

  /// What a composite is laid out for: its output size, whether the source is letterboxed into it, and the overlay.
  private struct Layout {
    let width: Int
    let height: Int
    let letterboxes: Bool
    let overlay: CVPixelBuffer?
  }

  private var frameLayout: Layout {
    Layout(width: outputWidth, height: outputHeight, letterboxes: letterboxes, overlay: overlayBuffer)
  }

  init(edgeInsets: VideoStreamEdgeInsets) {
    self.edgeInsets = edgeInsets
  }

  private var hasInsets: Bool {
    edgeInsets.top + edgeInsets.bottom + edgeInsets.left + edgeInsets.right > 0
  }

  /// Sizes the output for `canvas`, into which a newly mounted source, shown turned by `rotation`, is fitted. The
  /// Core Image context is created once and kept (its GPU pipeline is expensive to build); the pool is remade for the
  /// new size.
  func configure(sourceWidth: Int, sourceHeight: Int, rotation: SimulatorDisplayRotation, canvas: VideoFrameSource, scaleFactor: Double?) {
    if context == nil {
      if let device = MTLCreateSystemDefaultDevice() {
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
      } else {
        context = CIContext(options: [.cacheIntermediates: false])
      }
    }
    self.rotation = rotation
    let shown = VideoFrameSource(width: sourceWidth, height: sourceHeight, pixelFormat: kCVPixelFormatType_32BGRA).rotated(rotation)
    letterboxes = shown.width != canvas.width || shown.height != canvas.height
    let screen = VideoOutputDimensions.calculate(
      sourceWidth: shown.width, sourceHeight: shown.height, scaleFactor: scaleFactor, edgeInsets: edgeInsets)
    screenWidth = screen.width
    screenHeight = screen.height
    let dimensions = VideoOutputDimensions.calculate(
      sourceWidth: canvas.width, sourceHeight: canvas.height, scaleFactor: scaleFactor, edgeInsets: edgeInsets)
    outputWidth = dimensions.width
    outputHeight = dimensions.height
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: outputWidth,
      kCVPixelBufferHeightKey as String: outputHeight,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    var pool: CVPixelBufferPool?
    unsafe CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    self.pool = pool
  }

  /// Releases the pool and the overlay. The context is kept for a later `configure`.
  func reset() {
    pool = nil
    overlayBuffer = nil
  }

  /// The frame to encode: the source composited with the overlay and insets into a pooled output
  /// buffer, or the source itself when there is nothing to composite (or the pool has nothing to give).
  func composite(_ source: CVPixelBuffer) -> CVPixelBuffer {
    guard let image = compositedImage(of: source, layout: frameLayout), let pool, let context else {
      return source
    }
    var output: CVPixelBuffer?
    guard unsafe CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else {
      return source
    }
    context.render(image, to: output)
    return output
  }

  /// A PNG of the source with the overlay composited, rendered straight to a `CGImage` rather than
  /// through the pool. A letterboxed source is shown at its own shape instead, under `screenOverlay`: the overlay
  /// laid out for that screen.
  func screenshotPNG(of source: CVPixelBuffer, screenOverlay: CVPixelBuffer?) throws -> Data {
    let layout =
      letterboxes ? Layout(width: screenWidth, height: screenHeight, letterboxes: false, overlay: screenOverlay) : frameLayout
    let image = compositedImage(of: source, layout: layout) ?? CIImage(cvPixelBuffer: source)
    let context = self.context ?? CIContext()
    guard let cgImage = context.createCGImage(image, from: image.extent) else {
      throw OverlayCompositorError.failedToCreateCGImage
    }
    let png = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
      throw OverlayCompositorError.failedToEncodePNG
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw OverlayCompositorError.failedToEncodePNG
    }
    return png as Data
  }

  /// The source turned into the interface's orientation and scaled into the inset frame, letterboxed when its shape
  /// differs from the canvas, with the overlay over it; nil when nothing calls for compositing, or before `configure`.
  private func compositedImage(of source: CVPixelBuffer, layout: Layout) -> CIImage? {
    guard hasInsets || layout.overlay != nil || rotation != .upright || layout.letterboxes, context != nil, pool != nil else {
      return nil
    }
    var sourceImage = CIImage(cvPixelBuffer: source)
    if rotation != .upright {
      sourceImage = sourceImage.oriented(forExifOrientation: rotation.exifOrientation)
      sourceImage = sourceImage.transformed(by: CGAffineTransform(translationX: -sourceImage.extent.minX, y: -sourceImage.extent.minY))
    }

    // Core Image's origin is bottom-left: scale the source to the inset-free width, then move it up
    // and right by the bottom and left insets.
    let sourceWidth = Int(sourceImage.extent.width)
    let targetWidth = layout.width - Int(edgeInsets.left) - Int(edgeInsets.right)
    if layout.letterboxes {
      sourceImage = letterboxed(sourceImage, width: targetWidth, height: layout.height - Int(edgeInsets.top) - Int(edgeInsets.bottom))
    } else if targetWidth != sourceWidth && sourceWidth > 0 {
      let scale = CGFloat(targetWidth) / CGFloat(sourceWidth)
      sourceImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
    if edgeInsets.left > 0 || edgeInsets.bottom > 0 {
      sourceImage = sourceImage.transformed(by: CGAffineTransform(translationX: CGFloat(edgeInsets.left), y: CGFloat(edgeInsets.bottom)))
    }
    guard let overlay = layout.overlay else {
      return sourceImage
    }
    return CIImage(cvPixelBuffer: overlay).composited(over: sourceImage)
  }

  /// The image scaled to fit a `width` by `height` frame and centred in it over black, with its origin at zero.
  private func letterboxed(_ image: CIImage, width: Int, height: Int) -> CIImage {
    guard image.extent.width > 0, image.extent.height > 0 else {
      return image
    }
    let scale = min(CGFloat(width) / image.extent.width, CGFloat(height) / image.extent.height)
    let fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let centred = fitted.transformed(
      by: CGAffineTransform(translationX: (CGFloat(width) - fitted.extent.width) / 2, y: (CGFloat(height) - fitted.extent.height) / 2))
    return centred.composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)))
  }
}
