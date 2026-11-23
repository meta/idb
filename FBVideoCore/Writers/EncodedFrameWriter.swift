/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import FBControlCore
import Foundation

/// Frames an encoded H.264/HEVC sample for a transport and hands it to a consumer.
public protocol EncodedFrameWriter {
  func write(_ sampleBuffer: CMSampleBuffer, to consumer: any DataConsumer, logger: any ControlCoreLogger) throws
}

/// A transport that can carry timed-metadata markers in-band with the video.
public protocol VideoStreamTimedMetadataWriter {
  func writeTimedMetadata(_ text: String, to consumer: any DataConsumer)
}

/// The writers a transport provides: the frame writer, and the metadata writer where the transport
/// has a metadata channel.
public struct VideoStreamFrameWriters {
  public let frameWriter: any EncodedFrameWriter
  public let timedMetadataWriter: (any VideoStreamTimedMetadataWriter)?

  public init(frameWriter: any EncodedFrameWriter, timedMetadataWriter: (any VideoStreamTimedMetadataWriter)?) {
    self.frameWriter = frameWriter
    self.timedMetadataWriter = timedMetadataWriter
  }
}

public extension VideoStreamTransport {
  func frameWriters(for codec: VideoStreamCodec) -> VideoStreamFrameWriters {
    switch self {
    case .fmp4:
      let writer = FMP4FrameWriter(codec: codec)
      return VideoStreamFrameWriters(frameWriter: writer, timedMetadataWriter: writer)
    case .mpegts:
      let writer = MPEGTSFrameWriter(codec: codec)
      return VideoStreamFrameWriters(frameWriter: writer, timedMetadataWriter: writer)
    case .annexB:
      return VideoStreamFrameWriters(frameWriter: AnnexBFrameWriter(codec: codec), timedMetadataWriter: nil)
    }
  }
}

public extension VideoStreamFormat {
  /// Fresh writers for one stream in this format. Only the compressed-video transports carry a
  /// metadata channel.
  func frameWriters() -> VideoStreamFrameWriters {
    switch self {
    case let .compressedVideo(codec, transport):
      return transport.frameWriters(for: codec)
    case .mjpeg:
      return VideoStreamFrameWriters(frameWriter: MJPEGFrameWriter(), timedMetadataWriter: nil)
    case .minicap:
      return VideoStreamFrameWriters(frameWriter: MinicapFrameWriter(), timedMetadataWriter: nil)
    case .bgra:
      return VideoStreamFrameWriters(frameWriter: BGRAFrameWriter(), timedMetadataWriter: nil)
    }
  }
}

enum EncodedFrameWriterError: Error {
  case failedToGetDataPointer(offset: Int, status: OSStatus)
  case failedToGetDataBuffer
  case failedToAccessBlockBufferData(offset: Int, status: OSStatus)
  case failedToReplaceBlockBufferData(offset: Int, status: OSStatus)
  case sampleBufferNotReady
  case failedToGetFormatDescription
  case failedToGetParameterSetCount(codecName: String, status: OSStatus)
  case failedToGetParameterSet(codecName: String, index: Int, status: OSStatus)
  case failedToCopyBlockBufferData(status: OSStatus)
  /// An AVCC length prefix that does not fit the bytes that follow it.
  case malformedNALUnitLength(offset: Int, length: Int, remaining: Int)
}

extension EncodedFrameWriterError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case let .failedToGetDataPointer(offset, status):
      return "Failed to get Data Pointer at offset \(offset): \(status)"
    case .failedToGetDataBuffer:
      return "Failed to get data buffer"
    case let .failedToAccessBlockBufferData(offset, status):
      return "Failed to access block buffer data at offset \(offset): \(status)"
    case let .failedToReplaceBlockBufferData(offset, status):
      return "Failed to replace block buffer data at offset \(offset): \(status)"
    case .sampleBufferNotReady:
      return "Sample Buffer is not ready"
    case .failedToGetFormatDescription:
      return "Failed to get format description"
    case let .failedToGetParameterSetCount(codecName, status):
      return "Failed to get \(codecName) parameter set count \(status)"
    case let .failedToGetParameterSet(codecName, index, status):
      return "Failed to get \(codecName) parameter set at index \(index): \(status)"
    case let .failedToCopyBlockBufferData(status):
      return "Failed to copy block buffer data: \(status)"
    case let .malformedNALUnitLength(offset, length, remaining):
      return "Malformed AVCC length prefix at offset \(offset): claims \(length) bytes with \(remaining) remaining"
    }
  }
}

// MARK: - NAL unit framing

/// The two byte-stream framings of a NAL unit sequence: VideoToolbox emits AVCC (a big-endian length
/// prefix per NAL unit); Annex-B and MPEG-TS want a start code in its place. Both are four bytes,
/// so the rewrite is in place.
enum AnnexB {
  static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
  static let lengthPrefixSize = 4

  /// Replaces every AVCC length prefix in the sample's data buffer with an Annex-B start code.
  /// Throws if a prefix is zero, claims more bytes than follow it, or leaves a partial prefix at the
  /// end, so a malformed sample is refused rather than emitted with its payload rewritten.
  static func replaceLengthPrefixes(in sampleBuffer: CMSampleBuffer) throws {
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      throw EncodedFrameWriterError.failedToGetDataBuffer
    }
    let dataLength = CMBlockBufferGetDataLength(dataBuffer)

    var offset = 0
    while offset + lengthPrefixSize <= dataLength {
      var lengthBytes = [UInt8](repeating: 0, count: lengthPrefixSize)
      var lengthPointer: UnsafeMutablePointer<CChar>?
      var status = lengthBytes.withUnsafeMutableBytes { temp -> OSStatus in
        guard let tempBase = temp.baseAddress else { return kCMBlockBufferBlockAllocationFailedErr }
        return unsafe CMBlockBufferAccessDataBytes(dataBuffer, atOffset: offset, length: lengthPrefixSize, temporaryBlock: tempBase, returnedPointerOut: &lengthPointer)
      }
      if status != noErr {
        throw EncodedFrameWriterError.failedToAccessBlockBufferData(offset: offset, status: status)
      }
      var nalLength: UInt32 = 0
      if let lengthPointer = unsafe lengthPointer {
        unsafe lengthPointer.withMemoryRebound(to: UInt8.self, capacity: lengthPrefixSize) { bytes in
          nalLength = unsafe (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        }
      }
      let remaining = dataLength - offset - lengthPrefixSize
      guard nalLength > 0, Int(nalLength) <= remaining else {
        throw EncodedFrameWriterError.malformedNALUnitLength(offset: offset, length: Int(nalLength), remaining: remaining)
      }
      status = startCode.withUnsafeBytes { start -> OSStatus in
        guard let startBase = start.baseAddress else { return kCMBlockBufferBlockAllocationFailedErr }
        return unsafe CMBlockBufferReplaceDataBytes(with: startBase, blockBuffer: dataBuffer, offsetIntoDestination: offset, dataLength: lengthPrefixSize)
      }
      if status != noErr {
        throw EncodedFrameWriterError.failedToReplaceBlockBufferData(offset: offset, status: status)
      }
      offset += lengthPrefixSize + Int(nalLength)
    }
    if offset != dataLength {
      throw EncodedFrameWriterError.malformedNALUnitLength(offset: offset, length: 0, remaining: dataLength - offset)
    }
  }
}

// MARK: - CoreMedia helpers

/// H264 and HEVC parameter set getters have identical signatures.
private typealias ParameterSetGetter = (
  _ formatDescription: CMFormatDescription,
  _ parameterSetIndex: Int,
  _ parameterSetPointerOut: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
  _ parameterSetSizeOut: UnsafeMutablePointer<Int>?,
  _ parameterSetCountOut: UnsafeMutablePointer<Int>?,
  _ nalUnitHeaderLengthOut: UnsafeMutablePointer<Int32>?
) -> OSStatus

extension VideoStreamCodec {
  fileprivate var parameterSetGetter: ParameterSetGetter {
    switch self {
    case .h264:
      return unsafe CMVideoFormatDescriptionGetH264ParameterSetAtIndex
    case .hevc:
      return unsafe CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
    }
  }

  var displayName: String {
    switch self {
    case .h264:
      return "H264"
    case .hevc:
      return "HEVC"
    }
  }
}

extension CMFormatDescription {
  /// The codec's parameter sets (SPS/PPS, or VPS/SPS/PPS) in the order the description lists them,
  /// without framing.
  func parameterSets(for codec: VideoStreamCodec) throws -> [[UInt8]] {
    var count = 0
    var status = unsafe codec.parameterSetGetter(self, 0, nil, nil, &count, nil)
    if status != noErr {
      throw EncodedFrameWriterError.failedToGetParameterSetCount(codecName: codec.displayName, status: status)
    }
    var sets: [[UInt8]] = []
    sets.reserveCapacity(count)
    for index in 0..<count {
      var size = 0
      var pointer: UnsafePointer<UInt8>?
      status = unsafe codec.parameterSetGetter(self, index, &pointer, &size, nil, nil)
      if status != noErr {
        throw EncodedFrameWriterError.failedToGetParameterSet(codecName: codec.displayName, index: index, status: status)
      }
      guard let pointer = unsafe pointer else {
        sets.append([])
        continue
      }
      unsafe sets.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
    }
    return sets
  }
}

extension CMSampleBuffer {
  /// A sample is a keyframe unless its `NotSync` attachment is true. VideoToolbox's hardware encoders and its software
  /// H.264 encoder leave the attachment off a keyframe, but its software HEVC encoder sets it to false there, so
  /// the attachment being present does not make a sample a delta frame.
  var isKeyFrame: Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: true) as? [[CFString: Any]],
      let attachment = attachments.first
    else {
      return false
    }
    return (attachment[kCMSampleAttachmentKey_NotSync] as? Bool) != true
  }
}

extension CMBlockBuffer {
  /// Writes the buffer's bytes to the consumer, one contiguous run at a time. Sync consumers receive
  /// zero-copy `Data` backed by the block buffer; async consumers receive a copy.
  func write(to consumer: any DataConsumer) throws {
    let dataLength = CMBlockBufferGetDataLength(self)
    let isSyncConsumer = if case .synchronous = consumer.consumption { true } else { false }
    var offset = 0
    while offset < dataLength {
      var dataPointer: UnsafeMutablePointer<CChar>?
      var lengthAtOffset = 0
      let status = unsafe CMBlockBufferGetDataPointer(self, atOffset: offset, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
      if status != noErr {
        throw EncodedFrameWriterError.failedToGetDataPointer(offset: offset, status: status)
      }
      guard let dataPointer = unsafe dataPointer else {
        throw EncodedFrameWriterError.failedToGetDataPointer(offset: offset, status: status)
      }
      if isSyncConsumer {
        unsafe consumer.consumeData(Data(bytesNoCopy: dataPointer, count: lengthAtOffset, deallocator: .none))
      } else {
        unsafe consumer.consumeData(Data(bytes: dataPointer, count: lengthAtOffset))
      }
      offset += lengthAtOffset
    }
  }

  /// Appends the buffer's bytes to `data`, handling non-contiguous block buffers.
  func appendBytes(to data: inout Data) throws {
    let length = CMBlockBufferGetDataLength(self)
    let offset = data.count
    data.append(contentsOf: [UInt8](repeating: 0, count: length))
    let status = unsafe data.withUnsafeMutableBytes { bytes -> OSStatus in
      guard let base = bytes.baseAddress else { return kCMBlockBufferBlockAllocationFailedErr }
      return unsafe CMBlockBufferCopyDataBytes(self, atOffset: 0, dataLength: length, destination: base + offset)
    }
    if status != noErr {
      throw EncodedFrameWriterError.failedToCopyBlockBufferData(status: status)
    }
  }
}
