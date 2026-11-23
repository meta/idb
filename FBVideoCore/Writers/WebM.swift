/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import FBControlCore
import Foundation

// MARK: - EBML

/// EBML (RFC 8794) element construction, the encoding Matroska and WebM are written in. An element is
/// its ID, the size of its data as a variable-length integer, then the data.
enum EBML {
  /// The size that marks an element whose end is not yet known, written in eight bytes so that it can
  /// be replaced by the real size in place.
  static let unknownSize: [UInt8] = [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

  /// The bytes of an element ID. IDs carry their own length marker, so the value's significant bytes
  /// are the encoding.
  static func id(_ id: UInt32) -> [UInt8] {
    let byteCount = id > 0xFF_FFFF ? 4 : id > 0xFFFF ? 3 : id > 0xFF ? 2 : 1
    return (0..<byteCount).reversed().map { UInt8(truncatingIfNeeded: id >> (8 * $0)) }
  }

  /// A data size as the shortest variable-length integer that holds it. A length of `n` bytes holds
  /// values up to 2^(7n) - 2; all ones is reserved for an unknown size.
  static func size(_ value: UInt64) -> [UInt8] {
    var length = 1
    while length < 8 && value >= (UInt64(1) << (7 * length)) - 1 {
      length += 1
    }
    return size(value, length: length)
  }

  /// A data size as a variable-length integer of exactly `length` bytes, for a size patched in later.
  static func size(_ value: UInt64, length: Int) -> [UInt8] {
    let marked = value | (UInt64(1) << (7 * length))
    return (0..<length).reversed().map { UInt8(truncatingIfNeeded: marked >> (8 * $0)) }
  }

  /// Appends elements to a byte array.
  struct Writer {
    private(set) var data: [UInt8] = []

    var count: Int {
      data.count
    }

    /// Writes a master element whose children `contents` writes, sized once they are written.
    mutating func master(_ id: UInt32, contents: (inout Writer) -> Void) {
      var children = Writer()
      contents(&children)
      binary(id, children.data)
    }

    mutating func uint(_ id: UInt32, _ value: UInt64) {
      var bytes: [UInt8] = []
      var remaining = value
      repeat {
        bytes.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
        remaining >>= 8
      } while remaining > 0
      binary(id, bytes)
    }

    mutating func float(_ id: UInt32, _ value: Double) {
      binary(id, withUnsafeBytes(of: value.bitPattern.bigEndian) { Array($0) })
    }

    mutating func string(_ id: UInt32, _ value: String) {
      binary(id, Array(value.utf8))
    }

    mutating func binary(_ id: UInt32, _ bytes: [UInt8]) {
      data.append(contentsOf: EBML.id(id))
      data.append(contentsOf: EBML.size(UInt64(bytes.count)))
      data.append(contentsOf: bytes)
    }

    /// A Void element occupying exactly `totalSize` bytes, at least two: space reserved for an
    /// element written later, which readers skip.
    mutating func void(totalSize: Int) {
      precondition(totalSize >= 2, "A Void element needs at least two bytes")
      let sizeLength = totalSize - 2 <= 126 ? 1 : 2
      let dataSize = totalSize - 1 - sizeLength
      data.append(contentsOf: EBML.id(WebM.ID.void))
      data.append(contentsOf: EBML.size(UInt64(dataSize), length: sizeLength))
      data.append(contentsOf: [UInt8](repeating: 0, count: dataSize))
    }

    mutating func append(_ bytes: [UInt8]) {
      data.append(contentsOf: bytes)
    }
  }
}

// MARK: - WebM

/// WebM (Matroska with DocType `webm`) for a single H.264 or HEVC video track. H.264 and HEVC are
/// outside the WebM specification's codec list, but Chrome plays them in WebM and follows a change of
/// frame size mid-file, which MP4 players do not; the file is labelled `webm` because that is what
/// servers recognise as video.
enum WebM {
  enum ID {
    static let ebml: UInt32 = 0x1A45_DFA3
    static let ebmlVersion: UInt32 = 0x4286
    static let ebmlReadVersion: UInt32 = 0x42F7
    static let ebmlMaxIDLength: UInt32 = 0x42F2
    static let ebmlMaxSizeLength: UInt32 = 0x42F3
    static let docType: UInt32 = 0x4282
    static let docTypeVersion: UInt32 = 0x4287
    static let docTypeReadVersion: UInt32 = 0x4285
    static let void: UInt32 = 0xEC
    static let segment: UInt32 = 0x1853_8067
    static let seekHead: UInt32 = 0x114D_9B74
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549_A966
    static let timestampScale: UInt32 = 0x2A_D7B1
    static let duration: UInt32 = 0x4489
    static let muxingApp: UInt32 = 0x4D80
    static let writingApp: UInt32 = 0x5741
    static let tracks: UInt32 = 0x1654_AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackUID: UInt32 = 0x73C5
    static let trackType: UInt32 = 0x83
    static let flagLacing: UInt32 = 0x9C
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let cluster: UInt32 = 0x1F43_B675
    static let timestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let cues: UInt32 = 0x1C53_BB6B
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueTrack: UInt32 = 0xF7
    static let cueClusterPosition: UInt32 = 0xF1
    static let chapters: UInt32 = 0x1043_A770
    static let editionEntry: UInt32 = 0x45B9
    static let chapterAtom: UInt32 = 0xB6
    static let chapterUID: UInt32 = 0x73C4
    static let chapterTimeStart: UInt32 = 0x91
    static let chapterTimeEnd: UInt32 = 0x92
    static let chapterDisplay: UInt32 = 0x80
    static let chapString: UInt32 = 0x85
    static let chapLanguage: UInt32 = 0x437C
  }

  /// Block and cue times are in milliseconds.
  static let timestampScaleNanoseconds: UInt64 = 1_000_000
  static let trackNumber: UInt64 = 1
  /// A block's time is a signed 16-bit offset from its cluster's, so a cluster spans at most this.
  static let maximumClusterSpanMilliseconds: Int64 = 30_000
  /// Room at the start of the segment for the SeekHead, written once the positions it lists are known.
  static let seekHeadReservation = 128
  /// The size of the Duration element, reserved as a Void until the recording finishes.
  static let durationElementSize = 11

  static func header() -> [UInt8] {
    var writer = EBML.Writer()
    writer.master(ID.ebml) { header in
      header.uint(ID.ebmlVersion, 1)
      header.uint(ID.ebmlReadVersion, 1)
      header.uint(ID.ebmlMaxIDLength, 4)
      header.uint(ID.ebmlMaxSizeLength, 8)
      header.string(ID.docType, "webm")
      header.uint(ID.docTypeVersion, 4)
      header.uint(ID.docTypeReadVersion, 2)
    }
    return writer.data
  }

  static func codecID(_ codec: VideoStreamCodec) -> String {
    switch codec {
    case .h264:
      return "V_MPEG4/ISO/AVC"
    case .hevc:
      return "V_MPEGH/ISO/HEVC"
    }
  }

  static func tracks(codec: VideoStreamCodec, codecPrivate: [UInt8], width: Int32, height: Int32) -> [UInt8] {
    var writer = EBML.Writer()
    writer.master(ID.tracks) { tracks in
      tracks.master(ID.trackEntry) { entry in
        entry.uint(ID.trackNumber, trackNumber)
        entry.uint(ID.trackUID, 1)
        entry.uint(ID.trackType, 1)
        entry.uint(ID.flagLacing, 0)
        entry.string(ID.codecID, codecID(codec))
        entry.binary(ID.codecPrivate, codecPrivate)
        entry.master(ID.video) { video in
          video.uint(ID.pixelWidth, UInt64(max(width, 0)))
          video.uint(ID.pixelHeight, UInt64(max(height, 0)))
        }
      }
    }
    return writer.data
  }

  /// A SimpleBlock on track 1, `relativeTime` milliseconds after its cluster's timestamp.
  static func simpleBlock(relativeTime: Int16, isKeyFrame: Bool, frame: [UInt8]) -> [UInt8] {
    var payload: [UInt8] = EBML.size(trackNumber)
    payload.append(contentsOf: withUnsafeBytes(of: relativeTime.bigEndian) { Array($0) })
    payload.append(isKeyFrame ? 0x80 : 0x00)
    payload.append(contentsOf: frame)
    var writer = EBML.Writer()
    writer.binary(ID.simpleBlock, payload)
    return writer.data
  }

  static func cluster(timestamp: UInt64, blocks: [UInt8]) -> [UInt8] {
    var timestampElement = EBML.Writer()
    timestampElement.uint(ID.timestamp, timestamp)
    var writer = EBML.Writer()
    writer.binary(ID.cluster, timestampElement.data + blocks)
    return writer.data
  }

  /// A cue for each keyframe cluster: its time and its position from the start of the segment's data.
  static func cues(_ points: [(time: UInt64, clusterPosition: UInt64)]) -> [UInt8] {
    var writer = EBML.Writer()
    writer.master(ID.cues) { cues in
      for point in points {
        cues.master(ID.cuePoint) { cuePoint in
          cuePoint.uint(ID.cueTime, point.time)
          cuePoint.master(ID.cueTrackPositions) { positions in
            positions.uint(ID.cueTrack, trackNumber)
            positions.uint(ID.cueClusterPosition, point.clusterPosition)
          }
        }
      }
    }
    return writer.data
  }

  /// One edition of chapters, each running until the next begins and the last until `end`. Times are
  /// in milliseconds from the start of the file.
  static func chapters(_ chapters: [WebMChapter], end: UInt64) -> [UInt8] {
    var writer = EBML.Writer()
    writer.master(ID.chapters) { element in
      element.master(ID.editionEntry) { edition in
        for (index, chapter) in chapters.enumerated() {
          let nextStart = index + 1 < chapters.count ? chapters[index + 1].milliseconds : end
          edition.master(ID.chapterAtom) { atom in
            atom.uint(ID.chapterUID, UInt64(index + 1))
            atom.uint(ID.chapterTimeStart, chapter.milliseconds * timestampScaleNanoseconds)
            atom.uint(ID.chapterTimeEnd, max(nextStart, chapter.milliseconds) * timestampScaleNanoseconds)
            atom.master(ID.chapterDisplay) { display in
              display.string(ID.chapString, chapter.title)
              display.string(ID.chapLanguage, "eng")
            }
          }
        }
      }
    }
    return writer.data
  }

  /// The SeekHead listing each top-level element's position from the start of the segment's data,
  /// padded with a Void to exactly `seekHeadReservation` bytes.
  static func seekHead(_ entries: [(id: UInt32, position: UInt64)]) -> [UInt8] {
    var writer = EBML.Writer()
    writer.master(ID.seekHead) { seekHead in
      for entry in entries {
        seekHead.master(ID.seek) { seek in
          seek.binary(ID.seekID, EBML.id(entry.id))
          seek.uint(ID.seekPosition, entry.position)
        }
      }
    }
    precondition(writer.count + 2 <= seekHeadReservation, "The SeekHead outgrew its reservation")
    writer.void(totalSize: seekHeadReservation - writer.count)
    return writer.data
  }

  static func duration(milliseconds: Double) -> [UInt8] {
    var writer = EBML.Writer()
    writer.float(ID.duration, milliseconds)
    return writer.data
  }
}

// MARK: - WebMChapter

/// A chapter of a WebM recording: its title, and when it starts in milliseconds from the file's start.
public struct WebMChapter: Equatable, Sendable {
  public let title: String
  public let milliseconds: UInt64

  public init(title: String, milliseconds: UInt64) {
    self.title = title
    self.milliseconds = milliseconds
  }
}

// MARK: - WebMFileWriter

public enum WebMFileWriterError: Error, LocalizedError {
  case unsupportedCodec(FourCharCode)
  case missingCodecConfiguration
  case missingFormatDescription
  case writeAfterFinish
  case failedToWrite(any Error)

  public var errorDescription: String? {
    switch self {
    case let .unsupportedCodec(subtype):
      return "WebM recording supports H.264 and HEVC, not codec \(subtype)"
    case .missingCodecConfiguration:
      return "The first keyframe's format description has no codec configuration record"
    case .missingFormatDescription:
      return "A keyframe has no format description"
    case .writeAfterFinish:
      return "The WebM file is already finished"
    case let .failedToWrite(error):
      return "Failed to write the WebM file: \(error)"
    }
  }
}

/// Writes encoded H.264 or HEVC samples to a WebM file as they arrive, without re-encoding.
///
/// Every keyframe carries its parameter sets in its block, so a change of frame size mid-recording (a
/// rotation, or a switch to another display) reaches the decoder on the keyframe it begins with, and so
/// does a seek to any keyframe. The track's codec private data is the first keyframe's configuration.
///
/// The segment is written with an unknown size and each cluster as soon as the next one begins, so a
/// recording that never reaches `finish` still plays up to its last complete cluster. `finish` writes
/// the cues and chapters, then fills in the segment size, the duration and the SeekHead, which make the
/// file seekable.
///
/// Not thread-safe: `write` and `finish` must be called serially.
public final class WebMFileWriter {
  private let fileURL: URL

  /// The file is opened by the first keyframe, and once finished takes no more samples.
  private enum State {
    case waitingForKeyFrame
    case writing(FileHandle)
    case finished
  }
  private var state = State.waitingForKeyFrame
  private var offset: UInt64 = 0
  private var codec: VideoStreamCodec = .h264

  /// Where things to be filled in at `finish` are, as file offsets.
  private var segmentSizeOffset: UInt64 = 0
  private var segmentDataOffset: UInt64 = 0
  private var durationOffset: UInt64 = 0
  private var infoPosition: UInt64 = 0
  private var tracksPosition: UInt64 = 0

  private struct PendingCluster {
    let timestamp: Int64
    let startsWithKeyFrame: Bool
    var blocks: [UInt8]
  }
  private var cluster: PendingCluster?
  private var cuePoints: [(time: UInt64, clusterPosition: UInt64)] = []
  private var lastTimestamp: Int64 = 0
  private var lastFrameDuration: Int64 = 0

  /// The first written sample's presentation time: the file's time zero.
  public private(set) var startPresentationTime: CMTime?

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  /// Writes one encoded sample. Samples before the first keyframe are dropped, since nothing can
  /// decode them; returns whether the sample was written. Throws once the file is finished.
  @discardableResult
  public func write(_ sampleBuffer: CMSampleBuffer) throws -> Bool {
    let isKeyFrame = sampleBuffer.isKeyFrame
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let file: FileHandle
    switch state {
    case .finished:
      throw WebMFileWriterError.writeAfterFinish
    case .waitingForKeyFrame:
      guard isKeyFrame else {
        return false
      }
      file = try open(firstKeyFrame: sampleBuffer)
      state = .writing(file)
      startPresentationTime = presentationTime
    case let .writing(openFile):
      file = openFile
    }
    guard let startPresentationTime else {
      return false
    }
    let timestamp = max(0, Int64((CMTimeGetSeconds(CMTimeSubtract(presentationTime, startPresentationTime)) * 1000).rounded()))
    let duration = CMSampleBufferGetDuration(sampleBuffer)
    if duration.isValid, CMTimeGetSeconds(duration) > 0 {
      lastFrameDuration = Int64((CMTimeGetSeconds(duration) * 1000).rounded())
    } else if timestamp > lastTimestamp {
      lastFrameDuration = timestamp - lastTimestamp
    }
    lastTimestamp = max(lastTimestamp, timestamp)

    var frame: [UInt8] = []
    if isKeyFrame {
      guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
        throw WebMFileWriterError.missingFormatDescription
      }
      for parameterSet in try formatDescription.parameterSets(for: codec) {
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(parameterSet.count).bigEndian) { Array($0) })
        frame.append(contentsOf: parameterSet)
      }
    }
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      throw EncodedFrameWriterError.failedToGetDataBuffer
    }
    var sampleData = Data()
    try dataBuffer.appendBytes(to: &sampleData)
    frame.append(contentsOf: sampleData)

    if isKeyFrame || cluster.map({ timestamp - $0.timestamp > WebM.maximumClusterSpanMilliseconds }) ?? true {
      try flushCluster(to: file)
      cluster = PendingCluster(timestamp: timestamp, startsWithKeyFrame: isKeyFrame, blocks: [])
    }
    guard let clusterTimestamp = cluster?.timestamp else {
      return false
    }
    let relativeTime = Int16(clamping: timestamp - clusterTimestamp)
    cluster?.blocks.append(contentsOf: WebM.simpleBlock(relativeTime: relativeTime, isKeyFrame: isKeyFrame, frame: frame))
    return true
  }

  /// Writes the last cluster, the cues and the chapters, then fills in the segment size, duration and
  /// SeekHead. Chapter times are presentation times on the samples' clock. Nothing is written if no
  /// sample was, and the file takes no more samples afterwards.
  public func finish(chapters: [(title: String, time: CMTime)] = []) throws {
    let finishing = state
    state = .finished
    guard case let .writing(file) = finishing, let startPresentationTime else {
      return
    }
    defer {
      try? file.close()
    }
    try flushCluster(to: file)
    var seekEntries: [(id: UInt32, position: UInt64)] = [(WebM.ID.info, infoPosition), (WebM.ID.tracks, tracksPosition)]
    if !cuePoints.isEmpty {
      seekEntries.append((WebM.ID.cues, offset - segmentDataOffset))
      try append(WebM.cues(cuePoints), to: file)
    }
    let end = UInt64(lastTimestamp + lastFrameDuration)
    let chapterList = chapters.map { chapter in
      let seconds = chapter.time.isValid ? CMTimeGetSeconds(CMTimeSubtract(chapter.time, startPresentationTime)) : 0
      return WebMChapter(title: chapter.title, milliseconds: min(UInt64(max(0, (seconds * 1000).rounded())), end))
    }
    if !chapterList.isEmpty {
      seekEntries.append((WebM.ID.chapters, offset - segmentDataOffset))
      try append(WebM.chapters(chapterList, end: end), to: file)
    }
    try overwrite(at: segmentSizeOffset, with: EBML.size(offset - segmentDataOffset, length: 8), in: file)
    try overwrite(at: durationOffset, with: WebM.duration(milliseconds: Double(end)), in: file)
    try overwrite(at: segmentDataOffset, with: WebM.seekHead(seekEntries), in: file)
  }

  // MARK: - Private

  /// Creates the file and writes everything ahead of the first cluster, returning the file to write the rest to.
  private func open(firstKeyFrame sampleBuffer: CMSampleBuffer) throws -> FileHandle {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      throw WebMFileWriterError.missingFormatDescription
    }
    let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
    switch subtype {
    case kCMVideoCodecType_H264:
      codec = .h264
    case kCMVideoCodecType_HEVC:
      codec = .hevc
    default:
      throw WebMFileWriterError.unsupportedCodec(subtype)
    }
    guard let codecPrivate = FMP4.codecConfigurationRecord(formatDescription, codec: codec) else {
      throw WebMFileWriterError.missingCodecConfiguration
    }
    let file: FileHandle
    do {
      try? FileManager.default.removeItem(at: fileURL)
      guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
      }
      file = try FileHandle(forWritingTo: fileURL)
    } catch {
      throw WebMFileWriterError.failedToWrite(error)
    }

    try append(WebM.header(), to: file)
    try append(EBML.id(WebM.ID.segment), to: file)
    segmentSizeOffset = offset
    try append(EBML.unknownSize, to: file)
    segmentDataOffset = offset

    var reservation = EBML.Writer()
    reservation.void(totalSize: WebM.seekHeadReservation)
    try append(reservation.data, to: file)

    // The Duration is unknown until `finish`, and a placeholder would tell a player of an unfinished
    // recording that it is empty, so its space is a Void until then.
    var info = EBML.Writer()
    info.uint(WebM.ID.timestampScale, WebM.timestampScaleNanoseconds)
    info.string(WebM.ID.muxingApp, "idb")
    info.string(WebM.ID.writingApp, "idb")
    let durationIndex = info.count
    info.void(totalSize: WebM.durationElementSize)
    var infoElement = EBML.Writer()
    infoElement.binary(WebM.ID.info, info.data)
    infoPosition = offset - segmentDataOffset
    durationOffset = offset + UInt64(infoElement.count - info.count + durationIndex)
    try append(infoElement.data, to: file)

    let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
    tracksPosition = offset - segmentDataOffset
    try append(WebM.tracks(codec: codec, codecPrivate: codecPrivate, width: dimensions.width, height: dimensions.height), to: file)
    return file
  }

  private func flushCluster(to file: FileHandle) throws {
    guard let cluster else {
      return
    }
    self.cluster = nil
    if cluster.startsWithKeyFrame {
      cuePoints.append((time: UInt64(cluster.timestamp), clusterPosition: offset - segmentDataOffset))
    }
    try append(WebM.cluster(timestamp: UInt64(cluster.timestamp), blocks: cluster.blocks), to: file)
  }

  private func append(_ bytes: [UInt8], to file: FileHandle) throws {
    do {
      try file.write(contentsOf: bytes)
    } catch {
      throw WebMFileWriterError.failedToWrite(error)
    }
    offset += UInt64(bytes.count)
  }

  private func overwrite(at position: UInt64, with bytes: [UInt8], in file: FileHandle) throws {
    do {
      try file.seek(toOffset: position)
      try file.write(contentsOf: bytes)
      try file.seek(toOffset: offset)
    } catch {
      throw WebMFileWriterError.failedToWrite(error)
    }
  }
}

// MARK: - WebMFileReader

public enum WebMFileReaderError: Error, LocalizedError {
  case malformed(String)
  case noKeyFrame
  case unsupportedCodec(String)
  case failedToCreateSample(OSStatus)

  public var errorDescription: String? {
    switch self {
    case let .malformed(reason):
      return "Not a readable WebM file: \(reason)"
    case .noKeyFrame:
      return "The WebM file has no keyframe"
    case let .unsupportedCodec(codecID):
      return "The WebM file's codec \(codecID) is not H.264 or HEVC"
    case let .failedToCreateSample(status):
      return "Failed to describe the WebM file's first keyframe: \(status)"
    }
  }
}

/// Reads back what a WebM recording needs to be checked for playability: its duration, and its first keyframe as a
/// sample buffer that a decoder can take, described by the parameter sets that keyframe carries.
public enum WebMFileReader {
  public struct Summary {
    /// The duration in seconds: the file's own, or the time of its last block when it was never finished.
    public let duration: Double
    public let firstKeyFrame: CMSampleBuffer
  }

  private struct Element {
    let id: UInt32
    let data: Range<Int>
  }

  public static func read(_ fileURL: URL) throws -> Summary {
    let bytes = try Data(contentsOf: fileURL)
    let top = try elements(bytes, in: 0..<bytes.count)
    guard top.first?.id == WebM.ID.ebml, let segment = top.first(where: { $0.id == WebM.ID.segment }) else {
      throw WebMFileReaderError.malformed("no EBML header and segment")
    }
    let children = try elements(bytes, in: segment.data)
    var timestampScale: UInt64 = WebM.timestampScaleNanoseconds
    var duration: Double?
    if let info = children.first(where: { $0.id == WebM.ID.info }) {
      for element in try elements(bytes, in: info.data) {
        switch element.id {
        case WebM.ID.timestampScale:
          timestampScale = unsigned(bytes, element)
        case WebM.ID.duration where element.data.count == 8:
          duration = Double(bitPattern: unsigned(bytes, element))
        case WebM.ID.duration where element.data.count == 4:
          duration = Double(Float(bitPattern: UInt32(unsigned(bytes, element))))
        default:
          break
        }
      }
    }
    guard let tracks = children.first(where: { $0.id == WebM.ID.tracks }),
      let entry = try elements(bytes, in: tracks.data).first(where: { $0.id == WebM.ID.trackEntry }),
      let codecIDElement = try elements(bytes, in: entry.data).first(where: { $0.id == WebM.ID.codecID })
    else {
      throw WebMFileReaderError.malformed("no video track")
    }
    let trackNumber = try elements(bytes, in: entry.data).first { $0.id == WebM.ID.trackNumber }.map { unsigned(bytes, $0) } ?? WebM.trackNumber
    let codecID = String(decoding: bytes[codecIDElement.data], as: UTF8.self)
    let codec: VideoStreamCodec
    switch codecID {
    case WebM.codecID(.h264):
      codec = .h264
    case WebM.codecID(.hevc):
      codec = .hevc
    default:
      throw WebMFileReaderError.unsupportedCodec(codecID)
    }

    var firstKeyFrame: [UInt8]?
    var lastTime: Int64 = 0
    for cluster in children where cluster.id == WebM.ID.cluster {
      let clusterChildren = try elements(bytes, in: cluster.data)
      let clusterTime = clusterChildren.first { $0.id == WebM.ID.timestamp }.map { Int64(unsigned(bytes, $0)) } ?? 0
      for element in clusterChildren where element.id == WebM.ID.simpleBlock {
        guard let block = try simpleBlock(bytes, element), block.trackNumber == trackNumber else {
          continue
        }
        lastTime = max(lastTime, clusterTime + Int64(block.relativeTime))
        if firstKeyFrame == nil, block.isKeyFrame {
          firstKeyFrame = Array(bytes[block.frame])
        }
      }
    }
    guard let firstKeyFrame else {
      throw WebMFileReaderError.noKeyFrame
    }
    let seconds = (duration ?? Double(lastTime)) * Double(timestampScale) / 1_000_000_000
    return Summary(duration: seconds, firstKeyFrame: try sampleBuffer(firstKeyFrame, codec: codec))
  }

  private struct SimpleBlock {
    let trackNumber: UInt64
    let relativeTime: Int16
    let isKeyFrame: Bool
    let frame: Range<Int>
  }

  /// A SimpleBlock's header and frame: a variable-length track number, a signed 16-bit time from its cluster's, then
  /// flags. Nil for a block too short to hold its header. A laced block holds several frames behind lacing framing,
  /// which this writer never produces, so it is refused rather than misread as one frame.
  private static func simpleBlock(_ bytes: Data, _ element: Element) throws -> SimpleBlock? {
    let start = element.data.lowerBound
    guard !element.data.isEmpty else {
      return nil
    }
    let trackLength = bytes[start].leadingZeroBitCount + 1
    guard trackLength <= 8, element.data.count >= trackLength + 3 else {
      return nil
    }
    var trackNumber = UInt64(bytes[start] & (0xFF >> trackLength))
    for byte in bytes[(start + 1)..<(start + trackLength)] {
      trackNumber = trackNumber << 8 | UInt64(byte)
    }
    let timeOffset = start + trackLength
    let flags = bytes[timeOffset + 2]
    guard flags & 0x06 == 0 else {
      throw WebMFileReaderError.malformed("a laced block, which an idb recording never writes")
    }
    return SimpleBlock(
      trackNumber: trackNumber, relativeTime: Int16(bitPattern: UInt16(bytes[timeOffset]) << 8 | UInt16(bytes[timeOffset + 1])),
      isKeyFrame: flags & 0x80 != 0, frame: (timeOffset + 3)..<element.data.upperBound)
  }

  /// The keyframe as a one-sample buffer: its leading parameter sets become the format description, and the rest of
  /// its NAL units the sample data. Any other leading NAL units, such as SEI, stay in the sample, as decoders expect.
  private static func sampleBuffer(_ frame: [UInt8], codec: VideoStreamCodec) throws -> CMSampleBuffer {
    var parameterSets: [[UInt8]] = []
    var sliceData: [UInt8] = []
    var position = 0
    while position + 4 <= frame.count {
      let length = Int(frame[position..<position + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
      guard length > 0, length <= frame.count - position - 4 else {
        throw WebMFileReaderError.malformed("a NAL unit overruns its block")
      }
      let unit = Array(frame[(position + 4)..<(position + 4 + length)])
      let isParameterSet: Bool
      switch codec {
      case .h264:
        isParameterSet = [7, 8].contains(unit[0] & 0x1F)
      case .hevc:
        isParameterSet = [32, 33, 34].contains((unit[0] >> 1) & 0x3F)
      }
      if isParameterSet {
        parameterSets.append(unit)
      } else {
        sliceData.append(contentsOf: frame[position..<(position + 4 + length)])
      }
      position += 4 + length
    }
    guard !parameterSets.isEmpty, !sliceData.isEmpty else {
      throw WebMFileReaderError.malformed("the first keyframe carries no parameter sets or no picture")
    }

    var formatDescription: CMFormatDescription?
    let pointers = parameterSets.map { set -> UnsafeMutablePointer<UInt8> in
      let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
      pointer.initialize(from: set, count: set.count)
      return pointer
    }
    defer { pointers.forEach { $0.deallocate() } }
    let constPointers = pointers.map { UnsafePointer($0) }
    let sizes = parameterSets.map(\.count)
    var status: OSStatus
    switch codec {
    case .h264:
      status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        allocator: nil, parameterSetCount: parameterSets.count, parameterSetPointers: constPointers, parameterSetSizes: sizes,
        nalUnitHeaderLength: 4, formatDescriptionOut: &formatDescription)
    case .hevc:
      status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        allocator: nil, parameterSetCount: parameterSets.count, parameterSetPointers: constPointers, parameterSetSizes: sizes,
        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &formatDescription)
    }
    guard status == noErr, let formatDescription else {
      throw WebMFileReaderError.failedToCreateSample(status)
    }

    var blockBuffer: CMBlockBuffer?
    status = CMBlockBufferCreateWithMemoryBlock(
      allocator: nil, memoryBlock: nil, blockLength: sliceData.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
      dataLength: sliceData.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer)
    guard status == noErr, let blockBuffer else {
      throw WebMFileReaderError.failedToCreateSample(status)
    }
    status = sliceData.withUnsafeBytes { bytes -> OSStatus in
      guard let base = bytes.baseAddress else {
        return kCMBlockBufferBadPointerParameterErr
      }
      return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: sliceData.count)
    }
    guard status == noErr else {
      throw WebMFileReaderError.failedToCreateSample(status)
    }
    var sample: CMSampleBuffer?
    var size = sliceData.count
    status = CMSampleBufferCreateReady(
      allocator: nil, dataBuffer: blockBuffer, formatDescription: formatDescription, sampleCount: 1, sampleTimingEntryCount: 0,
      sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    guard status == noErr, let sample else {
      throw WebMFileReaderError.failedToCreateSample(status)
    }
    return sample
  }

  private static func unsigned(_ bytes: Data, _ element: Element) -> UInt64 {
    bytes[element.data].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
  }

  /// The elements in `range`, in order. An element of unknown size runs to the end of the range, which is how an
  /// unfinished recording's segment reads, and a recording cut off part way through an element reads up to it.
  private static func elements(_ bytes: Data, in range: Range<Int>) throws -> [Element] {
    var elements: [Element] = []
    var position = range.lowerBound
    while position < range.upperBound {
      let idLength = bytes[position].leadingZeroBitCount + 1
      guard idLength <= 4 else {
        throw WebMFileReaderError.malformed("an element ID at \(position)")
      }
      guard position + idLength < range.upperBound else {
        break
      }
      let id = bytes[position..<(position + idLength)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
      position += idLength
      let sizeLength = bytes[position].leadingZeroBitCount + 1
      guard sizeLength <= 8 else {
        throw WebMFileReaderError.malformed("an element size at \(position)")
      }
      guard position + sizeLength <= range.upperBound else {
        break
      }
      var size = UInt64(bytes[position] & (0xFF >> sizeLength))
      var allOnes = size == UInt64(0xFF >> sizeLength)
      for byte in bytes[(position + 1)..<(position + sizeLength)] {
        size = size << 8 | UInt64(byte)
        allOnes = allOnes && byte == 0xFF
      }
      position += sizeLength
      let end = allOnes ? range.upperBound : position + Int(size)
      // A recording cut off mid-cluster ends with a truncated element; what precedes it is still readable.
      guard end <= range.upperBound else {
        break
      }
      elements.append(Element(id: id, data: position..<end))
      position = end
    }
    return elements
  }
}
