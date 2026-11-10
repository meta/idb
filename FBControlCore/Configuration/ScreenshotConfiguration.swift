/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation

/// The container a screenshot is encoded into.
public enum ScreenshotImageFormat: String, Hashable, Sendable, CaseIterable {
  case png
  case jpeg
  case tiff
}

/// A JPEG quality on PNG or TIFF is rejected where the request is decoded, not silently ignored.
public enum ScreenshotEncoding: Equatable, Sendable {
  case png
  /// Uncompressed: preserves the pixels and color space with no codec cost.
  case tiff
  /// `quality` is in (0, 1].
  case jpeg(quality: Double)

  /// Matches the video stream encoder's default.
  public static let defaultJPEGQuality: Double = 0.8

  public var format: ScreenshotImageFormat {
    switch self {
    case .png:
      return .png
    case .tiff:
      return .tiff
    case .jpeg:
      return .jpeg
    }
  }

  /// The quality to hand the encoder, or `nil` for formats that have none.
  public var compressionQuality: Double? {
    switch self {
    case .png, .tiff:
      return nil
    case let .jpeg(quality):
      return quality
    }
  }
}

// MARK: - ScreenshotEncoding: CustomStringConvertible

extension ScreenshotEncoding: CustomStringConvertible {
  public var description: String {
    switch self {
    case .png:
      return "PNG"
    case .tiff:
      return "TIFF"
    case let .jpeg(quality):
      return String(format: "JPEG (quality %.2f)", quality)
    }
  }
}

/// Points are converted with the target's screen scale, which not every target reports; a `points` request
/// on such a target fails rather than assuming 1x. `pixels` is the default and always available.
public enum ScreenshotUnit: String, Hashable, Sendable {
  case pixels
  case points
}

/// Shrinks only; a factor or fit bound never enlarges.
public enum ScreenshotScale: Sendable {
  /// Capture at the target's native resolution.
  case native
  /// Multiply both dimensions by a factor in (0, 1].
  case factor(Double)
  /// `nil` leaves that axis unbounded; at least one bound is required; the more restrictive wins.
  /// Aspect ratio is preserved up to per-axis rounding to whole pixels.
  case fit(maxWidth: Int?, maxHeight: Int?)
}

// MARK: - ScreenshotScale: CustomStringConvertible

extension ScreenshotScale: CustomStringConvertible {
  public var description: String {
    switch self {
    case .native:
      return "Native"
    case let .factor(factor):
      return String(format: "Factor %.4f", factor)
    case let .fit(maxWidth, maxHeight):
      let width = maxWidth.map(String.init) ?? "unbounded"
      let height = maxHeight.map(String.init) ?? "unbounded"
      return "Fit \(width)x\(height)"
    }
  }
}

/// Describes a screenshot: what to capture, how much of it, at what size, in what encoding.
public struct ScreenshotConfiguration: Sendable {

  public let encoding: ScreenshotEncoding
  /// The region to capture, in `unit`, with a top-left origin. `nil` captures the whole screen.
  public let cropRect: CGRect?
  public let scale: ScreenshotScale
  /// The unit `cropRect` and `scale`'s fit bounds are expressed in.
  public let unit: ScreenshotUnit
  /// The display to capture, on a simulator with several. Every other target has one screen.
  public let display: DisplaySelection

  public init(
    encoding: ScreenshotEncoding = .png,
    cropRect: CGRect? = nil,
    scale: ScreenshotScale = .native,
    unit: ScreenshotUnit = .pixels,
    display: DisplaySelection = .active
  ) {
    self.encoding = encoding
    self.cropRect = cropRect
    self.scale = scale
    self.unit = unit
    self.display = display
  }

  /// Only a crop rect or a fit bound carries a unit; `native` and `factor` have nothing to convert.
  var requiresScreenScale: Bool {
    guard unit == .points else {
      return false
    }
    if cropRect != nil {
      return true
    }
    if case .fit = scale {
      return true
    }
    return false
  }
}

// MARK: - ScreenshotConfiguration: CustomStringConvertible

extension ScreenshotConfiguration: CustomStringConvertible {
  public var description: String {
    let crop = cropRect.map { "\($0)" } ?? "full screen"
    return "Encoding \(encoding) | Crop \(crop) | Scale \(scale) | Unit \(unit.rawValue) | Display \(display)"
  }
}

/// A captured screenshot. `size` can differ from what was requested: an overhanging crop is clamped and a fit bound rounds.
public struct ScreenshotResult: Sendable {

  public let imageData: Data
  public let format: ScreenshotImageFormat
  /// The dimensions of `imageData`, in pixels, after cropping and scaling.
  public let size: CGSize
  /// The dimensions of the native capture, in pixels, before cropping and scaling.
  public let sourceSize: CGSize
  /// Pixels per point, or `nil` on a target that does not report its screen scale.
  public let screenScale: Double?
  /// The display identified by the capture, or nil when no nonempty identity was reported.
  public let displayID: String?

  public init(imageData: Data, format: ScreenshotImageFormat, size: CGSize, sourceSize: CGSize, screenScale: Double?, displayID: String? = nil) {
    self.imageData = imageData
    self.format = format
    self.size = size
    self.sourceSize = sourceSize
    self.screenScale = screenScale
    self.displayID = displayID.flatMap { $0.isEmpty ? nil : $0 }
  }
}

/// Each case maps to an invalid-argument failure at the API boundary.
public enum ScreenshotGeometryError: Error {
  case scaleFactorOutOfRange(Double)
  case fitBoundsEmpty
  case fitBoundNotPositive(Int)
  case cropExtentNotPositive(CGRect)
  case cropOutsideBounds(cropRect: CGRect, sourceSize: CGSize)
  case sourceSizeNotPositive(CGSize)
  case screenScaleUnknown
}

// MARK: - ScreenshotGeometryError: LocalizedError

extension ScreenshotGeometryError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .scaleFactorOutOfRange(factor):
      return "Scale factor \(factor) is not in the range (0, 1]; a screenshot can be shrunk but not enlarged"
    case .fitBoundsEmpty:
      return "A fit needs at least one of a maximum width or a maximum height"
    case let .fitBoundNotPositive(bound):
      return "Fit bound \(bound) is not positive"
    case let .cropExtentNotPositive(cropRect):
      return "Crop rect \(cropRect) has a non-positive width or height"
    case let .cropOutsideBounds(cropRect, sourceSize):
      return "Crop rect \(cropRect) lies entirely outside a screen of \(Int(sourceSize.width))x\(Int(sourceSize.height)) pixels"
    case let .sourceSizeNotPositive(sourceSize):
      return "Captured image of \(sourceSize) has a non-positive width or height"
    case .screenScaleUnknown:
      return "This target does not report a screen scale, so a screenshot region cannot be given in points; use pixels"
    }
  }
}

/// A resolved transform: everything in pixels, every bound checked. Shared by the simulator and device paths.
public struct ScreenshotPlan: Sendable {

  /// The region to capture, in pixels, clamped to the source and rounded out to whole pixels.
  /// `nil` captures the whole source image.
  public let cropRect: CGRect?
  /// In (0, 1]. Exactly 1 means no resampling is needed.
  public let scaleFactor: Double
  /// The final dimensions in pixels. Always at least 1x1.
  public let outputSize: CGSize

  public init(cropRect: CGRect?, scaleFactor: Double, outputSize: CGSize) {
    self.cropRect = cropRect
    self.scaleFactor = scaleFactor
    self.outputSize = outputSize
  }

  /// True when the image can be encoded exactly as captured.
  var isIdentity: Bool {
    cropRect == nil && scaleFactor == 1
  }
}

/// The screenshot geometry, as pure functions over sizes.
public enum ScreenshotGeometry {

  /// Crop is applied before scale, so a fit bound applies to the cropped region.
  /// `screenScale` is required only when `configuration` measures something in points.
  public static func plan(
    for configuration: ScreenshotConfiguration,
    sourceSize: CGSize,
    screenScale: Double?
  ) throws -> ScreenshotPlan {
    guard sourceSize.width >= 1, sourceSize.height >= 1 else {
      throw ScreenshotGeometryError.sourceSizeNotPositive(sourceSize)
    }
    let scale =
      try configuration.requiresScreenScale
      ? pointsToPixels(for: configuration.unit, screenScale: screenScale)
      : 1

    let cropRect = try configuration.cropRect.map {
      try clampedCropRect($0, pointsToPixels: scale, sourceSize: sourceSize)
    }
    let baseSize = cropRect?.size ?? sourceSize
    let factor = try scaleFactor(for: configuration.scale, baseSize: baseSize, pointsToPixels: scale)

    return ScreenshotPlan(
      cropRect: cropRect,
      scaleFactor: factor,
      outputSize: outputSize(baseSize: baseSize, factor: factor)
    )
  }

  /// The multiplier that takes a measurement in `unit` to pixels.
  static func pointsToPixels(for unit: ScreenshotUnit, screenScale: Double?) throws -> Double {
    switch unit {
    case .pixels:
      return 1
    case .points:
      guard let screenScale, screenScale > 0 else {
        throw ScreenshotGeometryError.screenScaleUnknown
      }
      return screenScale
    }
  }

  /// Converts to whole pixels and clamps to the source; a rect entirely outside the source is an error.
  static func clampedCropRect(_ cropRect: CGRect, pointsToPixels: Double, sourceSize: CGSize) throws -> CGRect {
    // `width`/`height` are standardized (a negative height reads positive); `size` is not.
    guard cropRect.size.width > 0, cropRect.size.height > 0 else {
      throw ScreenshotGeometryError.cropExtentNotPositive(cropRect)
    }
    let pixelRect = CGRect(
      x: cropRect.origin.x * pointsToPixels,
      y: cropRect.origin.y * pointsToPixels,
      width: cropRect.size.width * pointsToPixels,
      height: cropRect.size.height * pointsToPixels
    ).integral
    let bounds = CGRect(origin: .zero, size: sourceSize)
    let clamped = pixelRect.intersection(bounds)
    guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else {
      throw ScreenshotGeometryError.cropOutsideBounds(cropRect: cropRect, sourceSize: sourceSize)
    }
    return clamped
  }

  /// The factor that shrinks `baseSize` as `scale` asks, in (0, 1].
  static func scaleFactor(for scale: ScreenshotScale, baseSize: CGSize, pointsToPixels: Double) throws -> Double {
    switch scale {
    case .native:
      return 1
    case let .factor(factor):
      guard factor > 0, factor <= 1 else {
        throw ScreenshotGeometryError.scaleFactorOutOfRange(factor)
      }
      return factor
    case let .fit(maxWidth, maxHeight):
      if maxWidth == nil, maxHeight == nil {
        throw ScreenshotGeometryError.fitBoundsEmpty
      }
      var factor = 1.0
      for (bound, extent) in [(maxWidth, baseSize.width), (maxHeight, baseSize.height)] {
        guard let bound else {
          continue
        }
        guard bound > 0 else {
          throw ScreenshotGeometryError.fitBoundNotPositive(bound)
        }
        factor = min(factor, Double(bound) * pointsToPixels / Double(extent))
      }
      return factor
    }
  }

  /// Rounds half up (not to even) to match common image libraries, and floors at 1px per side.
  static func outputSize(baseSize: CGSize, factor: Double) -> CGSize {
    CGSize(
      width: roundToPixels(Double(baseSize.width) * factor),
      height: roundToPixels(Double(baseSize.height) * factor)
    )
  }

  static func roundToPixels(_ value: Double) -> Double {
    max(1, (value + 0.5).rounded(.down))
  }
}
