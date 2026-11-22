/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf

/// Translates a `screenshot` request to `ScreenshotConfiguration` and a capture to the response.
/// Rejects request shapes the configuration type cannot represent (a quality on a lossless format, an
/// unrecognized enum value).
enum ScreenshotRequestTranslation {

  // MARK: - Request

  static func configuration(from request: Idb_ScreenshotRequest) throws -> ScreenshotConfiguration {
    ScreenshotConfiguration(
      encoding: try encoding(from: request),
      cropRect: cropRect(from: request),
      scale: scale(from: request),
      unit: try unit(from: request)
    )
  }

  private static func encoding(from request: Idb_ScreenshotRequest) throws -> ScreenshotEncoding {
    switch request.format {
    case .png:
      try rejectCompressionQuality(on: request, format: "PNG")
      return .png
    case .tiff:
      try rejectCompressionQuality(on: request, format: "TIFF")
      return .tiff
    case .jpeg:
      // Unset is 0 on the wire and cannot be told apart from a deliberate 0, which is not a legal
      // quality anyway. Both mean "whatever the server thinks is reasonable".
      guard request.compressionQuality != 0 else {
        return .jpeg(quality: ScreenshotEncoding.defaultJPEGQuality)
      }
      guard request.compressionQuality > 0, request.compressionQuality <= 1 else {
        throw RPCError(
          code: .invalidArgument,
          message: "compression_quality \(request.compressionQuality) is not in (0, 1]"
        )
      }
      return .jpeg(quality: request.compressionQuality)
    case let .UNRECOGNIZED(value):
      throw RPCError(code: .invalidArgument, message: "\(value) is not a recognized screenshot format")
    }
  }

  /// A quality on a lossless format is rejected rather than silently ignored.
  private static func rejectCompressionQuality(on request: Idb_ScreenshotRequest, format: String) throws {
    guard request.compressionQuality == 0 else {
      throw RPCError(code: .invalidArgument, message: "compression_quality is not meaningful for \(format)")
    }
  }

  private static func cropRect(from request: Idb_ScreenshotRequest) -> CGRect? {
    guard request.hasCrop else {
      return nil
    }
    return CGRect(
      x: request.crop.x,
      y: request.crop.y,
      width: request.crop.width,
      height: request.crop.height
    )
  }

  private static func scale(from request: Idb_ScreenshotRequest) -> ScreenshotScale {
    guard let scale = request.scale else {
      return .native
    }
    switch scale {
    case let .scaleFactor(factor):
      return .factor(factor)
    case let .fit(fit):
      // 0 is unset on the wire, and an unset bound means unbounded on that axis rather than a
      // bound of zero. Both being unset is rejected by the geometry, not treated as native, since
      // a caller who sent a `fit` at all meant to bound something.
      return .fit(
        maxWidth: fit.maxWidth == 0 ? nil : Int(fit.maxWidth),
        maxHeight: fit.maxHeight == 0 ? nil : Int(fit.maxHeight)
      )
    }
  }

  private static func unit(from request: Idb_ScreenshotRequest) throws -> ScreenshotUnit {
    switch request.unit {
    case .pixels:
      return .pixels
    case .points:
      return .points
    case let .UNRECOGNIZED(value):
      throw RPCError(code: .invalidArgument, message: "\(value) is not a recognized screenshot unit")
    }
  }

  // MARK: - Response

  static func response(from result: ScreenshotResult) -> Idb_ScreenshotResponse {
    .with {
      $0.imageData = result.imageData
      $0.imageFormat = result.format.rawValue
      $0.destination = size(result.size)
      $0.source = size(result.sourceSize)
      // 0 is the documented "this target does not report one" value. A real scale is never 0, so it
      // needs no separate presence bit.
      $0.screenScale = result.screenScale ?? 0
    }
  }

  private static func size(_ value: CGSize) -> Idb_ScreenshotResponse.Size {
    .with {
      $0.width = pixels(value.width)
      $0.height = pixels(value.height)
    }
  }

  /// `UInt32(_: CGFloat)` traps on a negative, non-finite or too-large value. Report those as 0 ("not
  /// reported") rather than crash the companion over a metadata field.
  private static func pixels(_ value: CGFloat) -> UInt32 {
    guard value.isFinite, value > 0 else {
      return 0
    }
    return UInt32(min(value.rounded(), CGFloat(UInt32.max)))
  }

  // MARK: - Errors

  /// Maps a geometry rejection onto a status code.
  static func status(for error: ScreenshotGeometryError) -> RPCError {
    switch error {
    case .scaleFactorOutOfRange, .fitBoundsEmpty, .fitBoundNotPositive,
      .cropExtentNotPositive, .cropOutsideBounds:
      return RPCError(code: .invalidArgument, message: error.localizedDescription)
    case .screenScaleUnknown:
      // The request is well formed, and the same request succeeds against a target that reports a
      // screen scale. That is target state rather than a bad argument.
      return RPCError(code: .failedPrecondition, message: error.localizedDescription)
    case .sourceSizeNotPositive:
      // The target handed back an empty screen. Nothing the caller sent could cause this.
      return RPCError(code: .internalError, message: error.localizedDescription)
    }
  }

  /// Maps a render failure onto a status code so it reaches the caller with a message rather than as a
  /// bare `UNKNOWN`.
  static func status(for error: ScreenshotRenderError) -> RPCError {
    switch error {
    case .colorSpaceCreationFailed, .croppingFailed, .contextCreationFailed, .scalingFailed, .destinationCreationFailed,
      .encodingFailed, .unreadableImageData, .unknownImageDimensions, .decodingFailed:
      return RPCError(code: .internalError, message: error.localizedDescription)
    case .compressionQualityOutOfRange:
      // Rejected on the way in, so reaching here means the request was not the one translated. Kept
      // as an invalid argument anyway, because that is what it describes.
      return RPCError(code: .invalidArgument, message: error.localizedDescription)
    }
  }
}
