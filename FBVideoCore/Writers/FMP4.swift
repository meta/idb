/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import FBControlCore
import Foundation

/// Fragmented MP4 (ISO 14496-12) box construction for a single video track: an init segment
/// (`ftyp` + `moov`) and one `moof` + `mdat` fragment per sample, plus `emsg` for timed metadata.
/// Everything here is a pure function of its arguments; the per-stream state (sequence numbers,
/// the timeline anchor) lives in `FMP4FrameWriter`.
enum FMP4 {
  /// The track and movie timescale: 90 kHz, as MPEG-TS uses, so a PTS converts once.
  static let timescale: UInt32 = 90000

  /// Appends big-endian fields and nested boxes to a byte array.
  struct BoxWriter {
    private(set) var data: [UInt8]

    init(capacity: Int = 0) {
      data = []
      data.reserveCapacity(capacity)
    }

    var count: Int {
      data.count
    }

    mutating func write8(_ value: UInt8) {
      data.append(value)
    }

    mutating func write16(_ value: UInt16) {
      withUnsafeBytes(of: value.bigEndian) { unsafe data.append(contentsOf: $0) }
    }

    mutating func write32(_ value: UInt32) {
      withUnsafeBytes(of: value.bigEndian) { unsafe data.append(contentsOf: $0) }
    }

    mutating func write64(_ value: UInt64) {
      withUnsafeBytes(of: value.bigEndian) { unsafe data.append(contentsOf: $0) }
    }

    /// Writes a box: the size and type header, then `contents`, then the size patched in. Nesting
    /// closures nests boxes, so a box cannot be left unclosed.
    mutating func writeBox(_ type: String, contents: (inout Self) -> Void) {
      let sizeOffset = data.count
      write32(0)
      writeBytes(type)
      contents(&self)
      write32(UInt32(data.count - sizeOffset), at: sizeOffset)
    }

    mutating func writeFullBoxHeader(version: UInt8, flags: UInt32) {
      write32((UInt32(version) << 24) | (flags & 0x00FF_FFFF))
    }

    mutating func writeZeros(_ count: Int) {
      assert(count <= 64, "Zero count greater than 64")
      data.append(contentsOf: [UInt8](repeating: 0, count: count))
    }

    mutating func writeBytes(_ string: String) {
      data.append(contentsOf: string.utf8)
    }

    mutating func append(_ bytes: [UInt8]) {
      data.append(contentsOf: bytes)
    }

    mutating func write32(_ value: UInt32, at offset: Int) {
      withUnsafeBytes(of: value.bigEndian) { bytes in
        for k in 0..<4 {
          data[offset + k] = unsafe bytes[k]
        }
      }
    }
  }

  // MARK: - Init segment

  /// The `avcC`/`hvcC` decoder configuration record: the one VideoToolbox attached to the format
  /// description when present, else built from the parameter sets.
  static func codecConfigurationRecord(_ formatDescription: CMFormatDescription, codec: VideoStreamCodec) -> [UInt8]? {
    if let atoms = CMFormatDescriptionGetExtension(formatDescription, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
      let record = atoms[codec.fmp4CodecConfigType] as? Data
    {
      return [UInt8](record)
    }
    var writer = BoxWriter()
    switch codec {
    case .h264:
      var sps: UnsafePointer<UInt8>?
      var spsSize = 0
      var parameterSetCount = 0
      let status = unsafe CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: &sps, parameterSetSizeOut: &spsSize, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
      guard status == noErr, spsSize >= 4, let sps = unsafe sps else {
        return nil
      }
      var pps: UnsafePointer<UInt8>?
      var ppsSize = 0
      if parameterSetCount > 1 {
        unsafe CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 1, parameterSetPointerOut: &pps, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
      }
      writer.write8(1) // configurationVersion
      unsafe writer.write8(sps[1]) // AVCProfileIndication
      unsafe writer.write8(sps[2]) // profile_compatibility
      unsafe writer.write8(sps[3]) // AVCLevelIndication
      writer.write8(0xFF) // lengthSizeMinusOne = 3
      writer.write8(0xE1) // numOfSequenceParameterSets = 1
      writer.write16(UInt16(spsSize))
      unsafe writer.append(Array(UnsafeBufferPointer(start: sps, count: spsSize)))
      unsafe writer.write8(pps != nil ? 1 : 0)
      if let pps = unsafe pps {
        writer.write16(UInt16(ppsSize))
        unsafe writer.append(Array(UnsafeBufferPointer(start: pps, count: ppsSize)))
      }
    case .hevc:
      var parameterSetCount = 0
      let status = unsafe CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
      if status != noErr {
        return nil
      }
      // Group the parameter sets by NAL type, in first-seen order.
      var groupedOrder = [UInt8]()
      var grouped = [UInt8: [[UInt8]]]()
      for index in 0..<parameterSetCount {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        unsafe CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard let pointer = unsafe pointer, size > 0 else { continue }
        let nalType = unsafe (pointer[0] >> 1) & 0x3F
        if grouped[nalType] == nil {
          grouped[nalType] = []
          groupedOrder.append(nalType)
        }
        unsafe grouped[nalType]?.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
      }
      writer.write8(1) // configurationVersion
      writer.write8(0) // general_profile_space, tier, profile_idc
      writer.write32(0) // general_profile_compatibility_flags
      writer.write16(0) // general_constraint_indicator_flags (48 bits)
      writer.write32(0)
      writer.write8(0) // general_level_idc
      writer.write16(0xF000) // min_spatial_segmentation_idc
      writer.write8(0xFC) // parallelismType
      writer.write8(0xFC) // chromaFormat
      writer.write8(0xF8) // bitDepthLumaMinus8
      writer.write8(0xF8) // bitDepthChromaMinus8
      writer.write16(0) // avgFrameRate
      writer.write8(0x0F) // constantFrameRate, numTemporalLayers, temporalIdNested, lengthSizeMinusOne = 3
      writer.write8(UInt8(groupedOrder.count))
      for nalType in groupedOrder {
        let sets = grouped[nalType] ?? []
        writer.write8(nalType & 0x3F)
        writer.write16(UInt16(sets.count))
        for set in sets {
          writer.write16(UInt16(set.count))
          writer.append(set)
        }
      }
    }
    return writer.data
  }

  static func ftypBox(codec: VideoStreamCodec) -> [UInt8] {
    var writer = BoxWriter(capacity: 24)
    writer.writeBox("ftyp") { writer in
      writer.writeBytes("isom")
      writer.write32(0x200)
      writer.writeBytes("isom")
      writer.writeBytes("iso6")
      writer.writeBytes(codec.fmp4CompatibleBrand)
    }
    return writer.data
  }

  /// A `moov` describing one video track with an empty sample table; every sample arrives in a
  /// fragment.
  static func moovBox(_ formatDescription: CMFormatDescription, codec: VideoStreamCodec, width: UInt32, height: UInt32) -> [UInt8] {
    let identityMatrix: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]
    let codecConfiguration = codecConfigurationRecord(formatDescription, codec: codec)
    var writer = BoxWriter(capacity: 512)
    writer.writeBox("moov") { writer in
      writer.writeBox("mvhd") { writer in
        writer.writeFullBoxHeader(version: 0, flags: 0)
        writer.write32(0) // creation_time
        writer.write32(0) // modification_time
        writer.write32(timescale)
        writer.write32(0) // duration: unknown
        writer.write32(0x0001_0000) // rate 1.0
        writer.write16(0x0100) // volume 1.0
        writer.writeZeros(10)
        for value in identityMatrix {
          writer.write32(value)
        }
        writer.writeZeros(24) // pre_defined
        writer.write32(2) // next_track_ID
      }
      writer.writeBox("trak") { writer in
        writer.writeBox("tkhd") { writer in
          writer.writeFullBoxHeader(version: 0, flags: 0x03) // enabled, in movie
          writer.write32(0) // creation_time
          writer.write32(0) // modification_time
          writer.write32(1) // track_ID
          writer.write32(0) // reserved
          writer.write32(0) // duration
          writer.writeZeros(8)
          writer.write16(0) // layer
          writer.write16(0) // alternate_group
          writer.write16(0) // volume
          writer.write16(0) // reserved
          for value in identityMatrix {
            writer.write32(value)
          }
          writer.write32(width << 16)
          writer.write32(height << 16)
        }
        writer.writeBox("mdia") { writer in
          writer.writeBox("mdhd") { writer in
            writer.writeFullBoxHeader(version: 0, flags: 0)
            writer.write32(0) // creation_time
            writer.write32(0) // modification_time
            writer.write32(timescale)
            writer.write32(0) // duration
            writer.write16(0x55C4) // language: und
            writer.write16(0)
          }
          writer.writeBox("hdlr") { writer in
            writer.writeFullBoxHeader(version: 0, flags: 0)
            writer.write32(0)
            writer.writeBytes("vide")
            writer.writeZeros(12)
            writer.writeBytes("VideoHandler")
            writer.write8(0)
          }
          writer.writeBox("minf") { writer in
            writer.writeBox("vmhd") { writer in
              writer.writeFullBoxHeader(version: 0, flags: 1)
              writer.write16(0) // graphicsmode
              writer.writeZeros(6) // opcolor
            }
            writer.writeBox("dinf") { writer in
              writer.writeBox("dref") { writer in
                writer.writeFullBoxHeader(version: 0, flags: 0)
                writer.write32(1)
                writer.writeBox("url ") { writer in
                  writer.writeFullBoxHeader(version: 0, flags: 1) // self-contained
                }
              }
            }
            writer.writeBox("stbl") { writer in
              writer.writeBox("stsd") { writer in
                writer.writeFullBoxHeader(version: 0, flags: 0)
                writer.write32(1)
                writer.writeBox(codec.fmp4SampleEntryType) { writer in
                  writer.writeZeros(6)
                  writer.write16(1) // data_reference_index
                  writer.writeZeros(16)
                  writer.write16(UInt16(width))
                  writer.write16(UInt16(height))
                  writer.write32(0x0048_0000) // horizresolution 72 dpi
                  writer.write32(0x0048_0000) // vertresolution 72 dpi
                  writer.write32(0)
                  writer.write16(1) // frame_count
                  writer.writeZeros(32) // compressorname
                  writer.write16(0x0018) // depth
                  writer.write16(0xFFFF) // pre_defined
                  if let codecConfiguration {
                    writer.writeBox(codec.fmp4CodecConfigType) { writer in
                      writer.append(codecConfiguration)
                    }
                  }
                }
              }
              for type in ["stts", "stsc"] {
                writer.writeBox(type) { writer in
                  writer.writeFullBoxHeader(version: 0, flags: 0)
                  writer.write32(0)
                }
              }
              writer.writeBox("stsz") { writer in
                writer.writeFullBoxHeader(version: 0, flags: 0)
                writer.write32(0)
                writer.write32(0)
              }
              writer.writeBox("stco") { writer in
                writer.writeFullBoxHeader(version: 0, flags: 0)
                writer.write32(0)
              }
            }
          }
        }
      }
      writer.writeBox("mvex") { writer in
        writer.writeBox("trex") { writer in
          writer.writeFullBoxHeader(version: 0, flags: 0)
          writer.write32(1) // track_ID
          writer.write32(1) // default_sample_description_index
          writer.write32(0) // default_sample_duration
          writer.write32(0) // default_sample_size
          writer.write32(0) // default_sample_flags
        }
      }
    }
    return writer.data
  }

  // MARK: - Fragments

  /// `moof` + the `mdat` header for a single-sample fragment. The sample data is not included: the
  /// caller appends exactly `sampleSize` bytes after these.
  static func fragmentHeader(sequenceNumber: UInt32, baseDecodeTime: UInt64, duration: UInt32, sampleSize: UInt32, isKeyFrame: Bool) -> [UInt8] {
    // trun: header(12) + data_offset(4) + one sample entry (duration(4) + size(4) + flags(4))
    let trunSize = 12 + 4 + 12
    let moofSize = 8 + 16 + 8 + 16 + 20 + trunSize
    let mdatHeaderSize = 8
    var writer = BoxWriter(capacity: moofSize + mdatHeaderSize)

    // Recorded while the trun is written so the data_offset can be patched once the moof is closed
    // and its size is known.
    var dataOffsetPosition = 0
    writer.writeBox("moof") { writer in
      writer.writeBox("mfhd") { writer in
        writer.writeFullBoxHeader(version: 0, flags: 0)
        writer.write32(sequenceNumber)
      }
      writer.writeBox("traf") { writer in
        writer.writeBox("tfhd") { writer in
          writer.writeFullBoxHeader(version: 0, flags: 0x020000) // default-base-is-moof
          writer.write32(1) // track_ID
        }
        writer.writeBox("tfdt") { writer in
          writer.writeFullBoxHeader(version: 1, flags: 0)
          writer.write64(baseDecodeTime)
        }
        writer.writeBox("trun") { writer in
          writer.writeFullBoxHeader(version: 0, flags: 0x000701) // data-offset, sample-duration, -size, -flags present
          writer.write32(1) // sample_count
          dataOffsetPosition = writer.count
          writer.write32(0) // data_offset, patched below
          writer.write32(duration)
          writer.write32(sampleSize)
          writer.write32(isKeyFrame ? 0x0200_0000 : 0x0101_0000) // sample_flags: sync / non-sync depends-on
        }
      }
    }
    // data_offset: from the start of moof (offset 0 in this writer) to the first sample byte, which
    // follows the mdat header.
    writer.write32(UInt32(writer.count) + UInt32(mdatHeaderSize), at: dataOffsetPosition)

    writer.write32(UInt32(mdatHeaderSize) + sampleSize)
    writer.writeBytes("mdat")
    return writer.data
  }

  /// A DASH event message (`emsg` v1) carrying `text` at `presentationTime90k`, in the `urn:sime2e:chapter` scheme.
  static func emsgBox(presentationTime90k: UInt64, text: String) -> Data {
    let textBytes = [UInt8](text.utf8)
    var writer = BoxWriter(capacity: 64 + textBytes.count)
    writer.writeBox("emsg") { writer in
      writer.writeFullBoxHeader(version: 1, flags: 0)
      writer.write32(timescale)
      writer.write64(presentationTime90k)
      writer.write32(0) // event_duration
      writer.write32(0) // id
      writer.writeBytes("urn:sime2e:chapter")
      writer.write8(0) // scheme_id_uri terminator
      writer.write8(0) // empty value
      writer.append(textBytes)
    }
    return Data(writer.data)
  }
}

extension VideoStreamCodec {
  var fmp4CompatibleBrand: String {
    switch self {
    case .h264:
      return "mp41"
    case .hevc:
      return "hvc1"
    }
  }

  var fmp4SampleEntryType: String {
    switch self {
    case .h264:
      return "avc1"
    case .hevc:
      return "hvc1"
    }
  }

  var fmp4CodecConfigType: String {
    switch self {
    case .h264:
      return "avcC"
    case .hevc:
      return "hvcC"
    }
  }
}

// MARK: - FMP4FrameWriter

/// Frames each encoded sample as a one-sample fMP4 fragment, with an init segment ahead of the first
/// keyframe — and again ahead of any keyframe whose format description differs from the one the last
/// init segment described (a rotation changes the SPS), so that the `avcC`/`hvcC` record decoders
/// configure themselves from matches the samples that follow. The timeline continues across a
/// re-initialisation.
final class FMP4FrameWriter: EncodedFrameWriter, VideoStreamTimedMetadataWriter {
  private let codec: VideoStreamCodec
  private(set) var initWritten = false
  private(set) var sequenceNumber: UInt32 = 0
  private var baseDecodeTime: UInt64 = 0
  private var firstPts90k: UInt64 = 0
  var lastPts90k: UInt64 = 0
  private var initFormatDescription: CMFormatDescription?

  public init(codec: VideoStreamCodec) {
    self.codec = codec
  }

  public func write(_ sampleBuffer: CMSampleBuffer, to consumer: any DataConsumer, logger: any ControlCoreLogger) throws {
    if !CMSampleBufferDataIsReady(sampleBuffer) {
      throw EncodedFrameWriterError.sampleBufferNotReady
    }

    let isKeyFrame = sampleBuffer.isKeyFrame

    let pts90k = UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 90000.0)
    let previousPts90k = lastPts90k
    lastPts90k = pts90k

    if !initWritten, !isKeyFrame {
      return // Drop frames before the first keyframe.
    }

    // One write per frame: an async consumer counts writes against its drop threshold, so the init
    // segment, the fragment header and the sample data are assembled into a single item.
    var output = Data()

    if isKeyFrame {
      guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
        throw EncodedFrameWriterError.failedToGetFormatDescription
      }
      let formatChanged = initFormatDescription.map { !CMFormatDescriptionEqual($0, otherFormatDescription: formatDescription) } ?? true
      if formatChanged {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        output.append(contentsOf: FMP4.ftypBox(codec: codec))
        output.append(contentsOf: FMP4.moovBox(formatDescription, codec: codec, width: UInt32(dimensions.width), height: UInt32(dimensions.height)))
        if !initWritten {
          initWritten = true
          firstPts90k = pts90k
          baseDecodeTime = 0
        }
        initFormatDescription = formatDescription
        logger.log("fMP4 init segment written (\(dimensions.width)x\(dimensions.height), \(codec.displayName))")
      }
    }

    let duration90k: UInt32
    let sampleDuration = CMSampleBufferGetDuration(sampleBuffer)
    if CMTIME_IS_VALID(sampleDuration) && CMTimeGetSeconds(sampleDuration) > 0 {
      duration90k = UInt32(CMTimeGetSeconds(sampleDuration) * 90000.0)
    } else if previousPts90k > 0 && pts90k > previousPts90k {
      duration90k = UInt32(pts90k - previousPts90k)
    } else {
      duration90k = 3000 // ~33ms at 30fps fallback
    }

    // The fragment's decode time is the sample's own presentation time, relative to the first
    // sample — never the running sum of declared durations, which drifts from real time whenever
    // a source misses its nominal cadence.
    if pts90k >= firstPts90k {
      baseDecodeTime = pts90k - firstPts90k
    }

    // AVCC NAL data as-is: MP4 samples carry length prefixes, not start codes.
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      throw EncodedFrameWriterError.failedToGetDataBuffer
    }
    sequenceNumber += 1
    output.append(
      contentsOf: FMP4.fragmentHeader(
        sequenceNumber: sequenceNumber, baseDecodeTime: baseDecodeTime, duration: duration90k,
        sampleSize: UInt32(CMBlockBufferGetDataLength(dataBuffer)), isKeyFrame: isKeyFrame))
    try dataBuffer.appendBytes(to: &output)
    consumer.consumeData(output)
  }

  public func writeTimedMetadata(_ text: String, to consumer: any DataConsumer) {
    consumer.consumeData(FMP4.emsgBox(presentationTime90k: lastPts90k, text: text))
  }
}
