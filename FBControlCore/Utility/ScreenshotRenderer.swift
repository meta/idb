/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotRenderError: Error {
  case colorSpaceCreationFailed
  case croppingFailed(cropRect: CGRect, sourceSize: CGSize)
  case contextCreationFailed(size: CGSize)
  case scalingFailed(size: CGSize)
  case destinationCreationFailed(format: ScreenshotImageFormat)
  case encodingFailed(format: ScreenshotImageFormat)
  case unreadableImageData
  case unknownImageDimensions
  case decodingFailed
  case compressionQualityOutOfRange(Double)
}

extension ScreenshotRenderError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .colorSpaceCreationFailed:
      return "Failed to create the sRGB screenshot color space"
    case let .croppingFailed(cropRect, sourceSize):
      return "Failed to crop an image of \(Int(sourceSize.width))x\(Int(sourceSize.height)) pixels to \(cropRect)"
    case let .contextCreationFailed(size):
      return "Failed to create a drawing context of \(Int(size.width))x\(Int(size.height)) pixels"
    case let .scalingFailed(size):
      return "Failed to scale an image to \(Int(size.width))x\(Int(size.height)) pixels"
    case let .destinationCreationFailed(format):
      return "Failed to create an image destination for \(format.rawValue)"
    case let .encodingFailed(format):
      return "Failed to encode an image as \(format.rawValue)"
    case .unreadableImageData:
      return "Captured bytes are not a readable image"
    case .unknownImageDimensions:
      return "Captured image does not report its dimensions"
    case .decodingFailed:
      return "Failed to decode the captured image"
    case let .compressionQualityOutOfRange(quality):
      return "JPEG compression quality \(quality) is not in the range (0, 1]"
    }
  }
}

/// Applies a resolved `ScreenshotPlan` to a captured `CGImage` and encodes the result. A target
/// that folds the transform into capture instead must produce the same pixels.
public enum ScreenshotRenderer {

  /// Transforms and encodes `image` as `plan` and `encoding` describe.
  ///
  /// - Parameter screenScale: reported back on the result so a caller can convert between points and
  ///   pixels itself; it does not affect the render, which `plan` has already resolved to pixels.
  public static func render(
    _ image: CGImage,
    plan: ScreenshotPlan,
    encoding: ScreenshotEncoding,
    screenScale: Double?
  ) throws -> ScreenshotResult {
    try render(
      transformed: try transform(image, plan: plan),
      sourceSize: CGSize(width: image.width, height: image.height),
      encoding: encoding,
      screenScale: screenScale
    )
  }

  /// Encodes an image whose plan was already applied during capture; `sourceSize` is the size it was cut from.
  public static func render(
    transformed image: CGImage,
    sourceSize: CGSize,
    encoding: ScreenshotEncoding,
    screenScale: Double?,
    displayID: String? = nil
  ) throws -> ScreenshotResult {
    ScreenshotResult(
      imageData: try encode(image, encoding: encoding),
      format: encoding.format,
      size: CGSize(width: image.width, height: image.height),
      sourceSize: sourceSize,
      screenScale: screenScale,
      displayID: displayID
    )
  }

  /// Applies `configuration` to an already-encoded image, as a device delivers. An identity PNG
  /// request returns the bytes untouched: re-encoding would alter them, and drawing through a context
  /// would flatten the source color space.
  public static func render(
    encoded data: Data,
    configuration: ScreenshotConfiguration,
    screenScale: Double?
  ) throws -> ScreenshotResult {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
      throw ScreenshotRenderError.unreadableImageData
    }
    // Read the dimensions from the header. This does not decode the pixels, so the passthrough below
    // stays as cheap as returning the bytes.
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else {
      throw ScreenshotRenderError.unknownImageDimensions
    }
    let sourceSize = CGSize(width: width, height: height)
    let plan = try ScreenshotGeometry.plan(for: configuration, sourceSize: sourceSize, screenScale: screenScale)

    // Only PNG passes through. It is lossless and takes no encoder options, so bytes already in that
    // container are exactly what a re-encode would have been asked to produce. JPEG carries a
    // quality this image cannot be known to have been encoded at, and the TIFF case promises no
    // compression, which the source is not known to honor.
    if plan.isIdentity, configuration.encoding == .png, CGImageSourceGetType(source) == UTType.png.identifier as CFString {
      return ScreenshotResult(
        imageData: data,
        format: .png,
        size: sourceSize,
        sourceSize: sourceSize,
        screenScale: screenScale
      )
    }

    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw ScreenshotRenderError.decodingFailed
    }
    return try render(image, plan: plan, encoding: configuration.encoding, screenScale: screenScale)
  }

  /// Crops and scales `image` as `plan` describes, in that order.
  public static func transform(_ image: CGImage, plan: ScreenshotPlan) throws -> CGImage {
    var result = image
    if let cropRect = plan.cropRect {
      guard let cropped = result.cropping(to: cropRect) else {
        throw ScreenshotRenderError.croppingFailed(
          cropRect: cropRect,
          sourceSize: CGSize(width: result.width, height: result.height)
        )
      }
      result = cropped
    }
    // Compare the dimensions rather than the factor: a factor that rounds back to the size already
    // in hand is a resample that would cost time to change nothing.
    if Int(plan.outputSize.width) != result.width || Int(plan.outputSize.height) != result.height {
      result = try scale(result, to: plan.outputSize)
    }
    return result
  }

  /// Resamples `image` to `size` on the CPU.
  static func scale(_ image: CGImage, to size: CGSize) throws -> CGImage {
    let width = Int(size.width)
    let height = Int(size.height)
    // Draw into a known-good 8-bit BGRA context rather than one derived from the source. A CGImage
    // can carry a bit layout CGContext refuses to construct -- indexed or non-RGB color spaces, 16
    // bits per component, alpha arrangements with no matching context -- and screenshots arrive in
    // enough shapes across simulator, device and Mac that deriving the layout means occasionally
    // failing to scale an image that is otherwise fine.
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
      )
    else {
      throw ScreenshotRenderError.contextCreationFailed(size: size)
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage() else {
      throw ScreenshotRenderError.scalingFailed(size: size)
    }
    return scaled
  }

  /// Encodes `image` in `encoding`. The JPEG quality range is validated here because ImageIO
  /// silently clamps out-of-range values.
  public static func encode(_ image: CGImage, encoding: ScreenshotEncoding) throws -> Data {
    if let quality = encoding.compressionQuality, !(quality > 0 && quality <= 1) {
      throw ScreenshotRenderError.compressionQualityOutOfRange(quality)
    }
    let format = encoding.format
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, format.contentType.identifier as CFString, 1, nil) else {
      throw ScreenshotRenderError.destinationCreationFailed(format: format)
    }
    var properties: [CFString: Any] = [:]
    switch encoding {
    case .png:
      break
    case .tiff:
      // Uncompressed TIFF: preserve the pixels and color space with no codec cost.
      properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 1]
    case let .jpeg(quality):
      properties[kCGImageDestinationLossyCompressionQuality] = quality
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw ScreenshotRenderError.encodingFailed(format: format)
    }
    return data as Data
  }
}

extension ScreenshotImageFormat {
  /// The type ImageIO knows this format by.
  public var contentType: UTType {
    switch self {
    case .png:
      return .png
    case .jpeg:
      return .jpeg
    case .tiff:
      return .tiff
    }
  }
}
