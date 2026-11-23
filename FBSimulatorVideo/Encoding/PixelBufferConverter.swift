/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreVideo
import FBSimulatorControl
import Foundation
import VideoToolbox

/// Converts frames to a fixed output size and pixel format on the GPU, in one `VTPixelTransferSession`
/// pass, recycling the destination buffers through a pool.
///
/// The encoder uses it for BGRA→NV12: `VTCompressionSession`'s native input is NV12, and feeding it
/// BGRA costs an implicit conversion per frame; converting explicitly also lets the session
/// pre-allocate its pipeline for the format it will actually receive. The bitmap pusher uses it to
/// scale BGRA to BGRA.
final class PixelBufferConverter {
  /// The format the encoder is fed: bi-planar 4:2:0, video range.
  static let encoderPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

  let outputWidth: Int
  let outputHeight: Int
  let pixelFormat: OSType
  private var transferSession: VTPixelTransferSession?
  private var pool: CVPixelBufferPool?

  /// Throws `VideoToolboxFramePusherError.failedToCreatePixelTransferSession` if the transfer session cannot be made.
  /// `destinationColor` names the colour space the output is converted into; nil leaves the choice
  /// to VideoToolbox, which is right for a same-space BGRA→BGRA scale and wrong for BGRA→YCbCr,
  /// where the matrix must match what the bitstream will be tagged with.
  init(outputWidth: Int, outputHeight: Int, pixelFormat: OSType, destinationColor: VideoColorDescription? = nil) throws {
    self.outputWidth = outputWidth
    self.outputHeight = outputHeight
    self.pixelFormat = pixelFormat

    var transferSession: VTPixelTransferSession?
    let status = unsafe VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession)
    if status != noErr {
      throw VideoToolboxFramePusherError.failedToCreatePixelTransferSession(status: status)
    }
    if let transferSession, let destinationColor {
      let colorStatus = VTSessionSetProperties(transferSession, propertyDictionary: destinationColor.pixelTransferDestinationProperties as CFDictionary)
      if colorStatus != noErr {
        throw VideoToolboxFramePusherError.failedToCreatePixelTransferSession(status: colorStatus)
      }
    }
    self.transferSession = transferSession

    let bufferAttributes: [String: Any] = [
      kCVPixelBufferWidthKey as String: outputWidth,
      kCVPixelBufferHeightKey as String: outputHeight,
      kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    let poolAttributes: [String: Any] = [
      kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
      kCVPixelBufferPoolAllocationThresholdKey as String: 16,
    ]
    var pool: CVPixelBufferPool?
    unsafe CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, bufferAttributes as CFDictionary, &pool)
    self.pool = pool
  }

  /// The destination colour description the transfer session has been given, keyed by the
  /// `kVTPixelTransferPropertyKey_Destination*` keys; empty when it converts by its own defaults.
  var destinationColorProperties: [String: String] {
    guard let transferSession else { return [:] }
    var properties: [String: String] = [:]
    for key in [kVTPixelTransferPropertyKey_DestinationColorPrimaries, kVTPixelTransferPropertyKey_DestinationTransferFunction, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix] {
      var value: UnsafeMutableRawPointer?
      withUnsafeMutablePointer(to: &value) { pointer in
        _ = unsafe VTSessionCopyProperty(transferSession, key: key, allocator: kCFAllocatorDefault, valueOut: pointer)
      }
      if let value = unsafe value {
        properties[key as String] = unsafe Unmanaged<CFString>.fromOpaque(value).takeRetainedValue() as String
      }
    }
    return properties
  }

  /// The attributes of the buffers `convert` produces, for a `VTCompressionSession` to expect.
  var outputBufferAttributes: [String: Any] {
    [
      kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
      kCVPixelBufferWidthKey as String: outputWidth,
      kCVPixelBufferHeightKey as String: outputHeight,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
  }

  /// The converted frame, or a failure the caller decides how to fall back from.
  enum Conversion {
    case converted(CVPixelBuffer)
    case poolExhausted(CVReturn)
    case transferFailed(OSStatus)
  }

  func convert(_ source: CVPixelBuffer) -> Conversion {
    guard let pool, let transferSession else {
      return .poolExhausted(kCVReturnInvalidArgument)
    }
    var destination: CVPixelBuffer?
    let poolStatus = unsafe CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
    guard poolStatus == kCVReturnSuccess, let destination else {
      return .poolExhausted(poolStatus)
    }
    let transferStatus = VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination)
    guard transferStatus == noErr else {
      return .transferFailed(transferStatus)
    }
    return .converted(destination)
  }

  /// Releases the transfer session and the pool. The converter cannot be used afterwards.
  func invalidate() {
    if let transferSession {
      VTPixelTransferSessionInvalidate(transferSession)
      self.transferSession = nil
    }
    pool = nil
  }
}
