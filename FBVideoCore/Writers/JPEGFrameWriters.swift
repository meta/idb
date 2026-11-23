/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import CoreVideo
import FBControlCore
import Foundation

/// Raw JPEG frames back to back; consumers split on the JPEG markers.
public struct MJPEGFrameWriter: EncodedFrameWriter {
  public init() {}

  public func write(_ sampleBuffer: CMSampleBuffer, to consumer: any DataConsumer, logger: any ControlCoreLogger) throws {
    guard let jpegDataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      throw EncodedFrameWriterError.failedToGetDataBuffer
    }
    try write(jpegDataBuffer, to: consumer, logger: logger)
  }

  public func write(_ jpegDataBuffer: CMBlockBuffer, to consumer: any DataConsumer, logger: any ControlCoreLogger) throws {
    try jpegDataBuffer.write(to: consumer)
  }
}

/// The Minicap wire format: a one-time 24-byte global header sized from the first frame, then each
/// JPEG frame prefixed with its little-endian 32-bit length. https://github.com/openstf/minicap#usage
///
/// A class because the header-once flag is per-stream state, like the transport writers' counters.
public final class MinicapFrameWriter: EncodedFrameWriter {
  private var hasWrittenHeader = false

  public init() {}

  public func write(_ sampleBuffer: CMSampleBuffer, to consumer: any DataConsumer, logger: any ControlCoreLogger) throws {
    if !hasWrittenHeader, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
      let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
      writeHeader(width: UInt32(dimensions.width), height: UInt32(dimensions.height), to: consumer, logger: logger)
      hasWrittenHeader = true
    }
    guard let jpegDataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      throw EncodedFrameWriterError.failedToGetDataBuffer
    }
    try write(jpegDataBuffer, to: consumer, logger: logger)
  }

  public func write(_ jpegDataBuffer: CMBlockBuffer, to consumer: any DataConsumer, logger: any ControlCoreLogger) throws {
    let dataLength = CMBlockBufferGetDataLength(jpegDataBuffer)
    var imageLength = UInt32(dataLength).littleEndian
    let lengthData = unsafe Data(bytes: &imageLength, count: MemoryLayout<UInt32>.size)
    consumer.consumeData(lengthData)

    try jpegDataBuffer.write(to: consumer)
  }

  /// The header is built byte by byte (all fields little-endian) rather than from a Swift struct
  /// layout, matching the `#pragma pack(push, 1)` C struct Minicap defines.
  public func writeHeader(width: UInt32, height: UInt32, to consumer: any DataConsumer, logger: any ControlCoreLogger) {
    let headerSize: UInt8 = 24
    let pid = UInt32(bitPattern: ProcessInfo.processInfo.processIdentifier).littleEndian
    let displayWidth = width.littleEndian
    let displayHeight = height.littleEndian
    let virtualDisplayWidth = width.littleEndian
    let virtualDisplayHeight = height.littleEndian

    var header = [UInt8]()
    header.reserveCapacity(Int(headerSize))
    header.append(1) // version = 1
    header.append(headerSize) // headerSize = 24
    withUnsafeBytes(of: pid) { unsafe header.append(contentsOf: $0) }
    withUnsafeBytes(of: displayWidth) { unsafe header.append(contentsOf: $0) }
    withUnsafeBytes(of: displayHeight) { unsafe header.append(contentsOf: $0) }
    withUnsafeBytes(of: virtualDisplayWidth) { unsafe header.append(contentsOf: $0) }
    withUnsafeBytes(of: virtualDisplayHeight) { unsafe header.append(contentsOf: $0) }
    header.append(0) // displayOrientation
    header.append(0) // quirks

    consumer.consumeData(Data(header))
  }
}

/// The sample's pixel bytes as they are, unframed. Sync consumers receive zero-copy `Data` backed by
/// the pixel buffer for the duration of the call; async consumers receive a copy.
public struct BGRAFrameWriter: EncodedFrameWriter {
  public init() {}

  public func write(_ sampleBuffer: CMSampleBuffer, to consumer: any DataConsumer, logger: any ControlCoreLogger) throws {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      throw EncodedFrameWriterError.failedToGetDataBuffer
    }
    try write(pixelBuffer, to: consumer)
  }

  public func write(_ pixelBuffer: CVPixelBuffer, to consumer: any DataConsumer) throws {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = unsafe CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw EncodedFrameWriterError.failedToGetDataBuffer
    }
    let size = CVPixelBufferGetDataSize(pixelBuffer)
    if case .synchronous = consumer.consumption {
      unsafe consumer.consumeData(Data(bytesNoCopy: baseAddress, count: size, deallocator: .none))
    } else {
      unsafe consumer.consumeData(Data(bytes: baseAddress, count: size))
    }
  }
}
