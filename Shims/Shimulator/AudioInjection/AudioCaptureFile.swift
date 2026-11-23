/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation

// Samples are copied to and from the file in the host's byte order.
#if !_endian(little)
#error("The capture file format assumes a little-endian host, as every Apple platform is")
#endif

/// One IO cycle of the samples a process wrote to an output device.
public struct AudioCaptureChunk: Equatable, Sendable {
  /// The IO proc that wrote the samples, unique for the life of the process.
  public let stream: UInt64
  public let device: UInt32
  /// The device's nominal rate, or 0 when it could not be read.
  public let sampleRate: Double
  /// When the first frame reaches the device, in `mach_absolute_time` ticks, or 0 when the HAL gave none.
  public let hostTime: UInt64
  /// The first frame's position on the device's sample clock.
  public let sampleTime: Double
  public let channels: Int
  /// Frames were dropped between the previous chunk of this stream and this one.
  public let discontinuity: Bool
  /// `frames * channels` interleaved samples.
  public let samples: [Float]

  public init(
    stream: UInt64, device: UInt32, sampleRate: Double, hostTime: UInt64, sampleTime: Double, channels: Int,
    discontinuity: Bool, samples: [Float]
  ) {
    self.stream = stream
    self.device = device
    self.sampleRate = sampleRate
    self.hostTime = hostTime
    self.sampleTime = sampleTime
    self.channels = channels
    self.discontinuity = discontinuity
    self.samples = samples
  }

  public var frames: Int {
    channels > 0 ? samples.count / channels : 0
  }
}

/// The file a process writes while it is captured: a header, a record per chunk, and a summary once
/// the capture stops. Every number is little-endian.
///
/// A file without a summary was cut short: the process exited, or was killed, while it was captured.
public enum AudioCaptureFile {
  public static let pathExtension = "idbcap"
  /// Appended to the final name while the file is written, so a reader never mistakes a file that
  /// is still growing for a finished one.
  public static let partialPathExtension = "partial"
  public static let maximumChannels = 16
  public static let maximumFrames = 1 << 16

  static let magic = Data("IDBACAP1".utf8)
  static let version: UInt32 = 1
  static let headerSize = 32
  static let chunkHeaderSize = 48

  enum RecordKind: UInt8 {
    case chunk = 1
    case summary = 2
  }

  /// What one chunk's record says about its samples, and where they are in the file.
  public struct ChunkRecord: Equatable, Sendable {
    public let stream: UInt64
    public let device: UInt32
    public let sampleRate: Double
    public let hostTime: UInt64
    public let sampleTime: Double
    public let channels: Int
    public let frames: Int
    public let discontinuity: Bool
    /// The byte offset of the chunk's samples in the file.
    public let samplesOffset: Int
  }

  public struct Index: Equatable, Sendable {
    public let processIdentifier: Int32
    /// The `mach_timebase_info` of the host clock the chunks' host times count.
    public let timebaseNumerator: UInt32
    public let timebaseDenominator: UInt32
    public let chunks: [ChunkRecord]
    /// Frames the process kept but could not hand over, or nil when the file has no summary.
    public let droppedFrames: UInt64?
  }

  public static func header(processIdentifier: Int32, timebase: mach_timebase_info_data_t) -> Data {
    var data = magic
    data.appendLittleEndian(version)
    data.appendLittleEndian(UInt32(bitPattern: processIdentifier))
    data.appendLittleEndian(timebase.numer)
    data.appendLittleEndian(timebase.denom)
    data.appendLittleEndian(UInt64(0))
    return data
  }

  public static func record(_ chunk: AudioCaptureChunk) -> Data {
    var body = Data()
    body.reserveCapacity(chunkHeaderSize + chunk.samples.count * MemoryLayout<Float>.size)
    body.append(RecordKind.chunk.rawValue)
    body.append(chunk.discontinuity ? 1 : 0)
    body.appendLittleEndian(UInt16(clamping: chunk.channels))
    body.appendLittleEndian(UInt32(clamping: chunk.frames))
    body.appendLittleEndian(chunk.stream)
    body.appendLittleEndian(chunk.device)
    body.appendLittleEndian(UInt32(0))
    body.appendLittleEndian(chunk.sampleRate.bitPattern)
    body.appendLittleEndian(chunk.hostTime)
    body.appendLittleEndian(chunk.sampleTime.bitPattern)
    body.appendLittleEndian(chunk.samples.prefix(chunk.frames * chunk.channels))
    return framed(body)
  }

  public static func summary(droppedFrames: UInt64) -> Data {
    var body = Data()
    body.append(RecordKind.summary.rawValue)
    body.append(contentsOf: [0, 0, 0])
    body.appendLittleEndian(droppedFrames)
    return framed(body)
  }

  /// The record whose header `body` starts, at `offset` in a file. `body` holds the record from its
  /// kind byte to at least the end of its header; `length` is the whole record's.
  static func record(_ body: Data, length: Int, at offset: Int) throws -> (ChunkRecord?, droppedFrames: UInt64?) {
    var reader = LittleEndianReader(data: body)
    switch reader.read(UInt8.self).flatMap(RecordKind.init(rawValue:)) {
    case .chunk:
      guard let flags = reader.read(UInt8.self),
        let channels = reader.read(UInt16.self).map(Int.init),
        let frames = reader.read(UInt32.self).map(Int.init),
        let stream = reader.read(UInt64.self),
        let device = reader.read(UInt32.self),
        reader.read(UInt32.self) != nil,
        let sampleRate = reader.read(UInt64.self).map(Double.init(bitPattern:)),
        let hostTime = reader.read(UInt64.self),
        let sampleTime = reader.read(UInt64.self).map(Double.init(bitPattern:)),
        (1...maximumChannels).contains(channels), frames <= maximumFrames,
        length == chunkHeaderSize + frames * channels * MemoryLayout<Float>.size
      else {
        throw AudioCaptureFileError.malformedRecord
      }
      let chunk = ChunkRecord(
        stream: stream, device: device, sampleRate: sampleRate, hostTime: hostTime, sampleTime: sampleTime,
        channels: channels, frames: frames, discontinuity: flags & 1 != 0,
        samplesOffset: offset + MemoryLayout<UInt32>.size + chunkHeaderSize)
      return (chunk, nil)
    case .summary:
      guard reader.read(count: 3) != nil, let dropped = reader.read(UInt64.self) else {
        throw AudioCaptureFileError.malformedRecord
      }
      return (nil, dropped)
    case nil:
      throw AudioCaptureFileError.malformedRecord
    }
  }

  static func index(header: Data) throws -> (processIdentifier: Int32, numerator: UInt32, denominator: UInt32) {
    var reader = LittleEndianReader(data: header)
    guard reader.remaining >= headerSize, reader.read(count: magic.count) == magic else {
      throw AudioCaptureFileError.notACaptureFile
    }
    guard let version = reader.read(UInt32.self), version == Self.version,
      let processIdentifier = reader.read(UInt32.self),
      let numerator = reader.read(UInt32.self), let denominator = reader.read(UInt32.self)
    else {
      throw AudioCaptureFileError.unsupportedVersion
    }
    return (Int32(bitPattern: processIdentifier), numerator, denominator)
  }

  private static func framed(_ body: Data) -> Data {
    var data = Data()
    data.reserveCapacity(MemoryLayout<UInt32>.size + body.count)
    data.appendLittleEndian(UInt32(clamping: body.count))
    data.append(body)
    return data
  }
}

public enum AudioCaptureFileError: Error, Equatable, LocalizedError {
  case notACaptureFile
  case unsupportedVersion
  case malformedRecord
  case directoryNotPrivate(path: String)
  case unwritable(path: String, reason: String)
  case unreadable(path: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .notACaptureFile:
      return "The file is not an audio capture"
    case .unsupportedVersion:
      return "The audio capture was written in a version this reader does not know"
    case .malformedRecord:
      return "The audio capture holds a record that does not parse"
    case let .directoryNotPrivate(path):
      return "Will not write an audio capture into \(path): it must be a directory only this user can reach"
    case let .unwritable(path, reason):
      return "Could not write the audio capture at \(path): \(reason)"
    case let .unreadable(path, reason):
      return "Could not read the audio capture at \(path): \(reason)"
    }
  }
}

/// Writes one process's capture file. Not thread-safe: the capture client's thread owns it.
public final class AudioCaptureFileWriter {
  /// Where the finished file is, once `finish` has renamed it into place.
  public let path: String
  public private(set) var framesWritten: UInt64 = 0
  /// Why writing stopped, once it has.
  public private(set) var failure: String?
  private let partialPath: String
  private var descriptor: Int32

  public init(directory: String, processIdentifier: Int32) throws {
    var metadata = stat()
    guard unsafe lstat(directory, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(),
      metadata.st_mode & 0o077 == 0
    else {
      throw AudioCaptureFileError.directoryNotPrivate(path: directory)
    }
    path = (directory as NSString).appendingPathComponent(
      "\(processIdentifier)-\(UUID().uuidString).\(AudioCaptureFile.pathExtension)")
    partialPath = (path as NSString).appendingPathExtension(AudioCaptureFile.partialPathExtension) ?? path
    descriptor = unsafe open(partialPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw unsafe AudioCaptureFileError.unwritable(path: partialPath, reason: String(cString: strerror(errno)))
    }
    var timebase = mach_timebase_info_data_t()
    unsafe mach_timebase_info(&timebase)
    write(AudioCaptureFile.header(processIdentifier: processIdentifier, timebase: timebase))
    if let failure {
      close(descriptor)
      unsafe unlink(partialPath)
      throw AudioCaptureFileError.unwritable(path: partialPath, reason: failure)
    }
  }

  deinit {
    if descriptor >= 0 {
      close(descriptor)
    }
  }

  public func append(_ chunk: AudioCaptureChunk) {
    guard chunk.frames > 0 else {
      return
    }
    write(AudioCaptureFile.record(chunk))
    if failure == nil {
      framesWritten += UInt64(chunk.frames)
    }
  }

  /// Writes the summary and renames the file into place, so a reader sees it whole or not at all.
  /// A file whose writing failed part-way is renamed too, without a summary: what it holds is still
  /// what the process played.
  public func finish(droppedFrames: UInt64) {
    guard descriptor >= 0 else {
      return
    }
    write(AudioCaptureFile.summary(droppedFrames: droppedFrames))
    close(descriptor)
    descriptor = -1
    if unsafe rename(partialPath, path) != 0, failure == nil {
      failure = unsafe "Could not rename \(partialPath) into place: \(String(cString: strerror(errno)))"
    }
  }

  private func write(_ data: Data) {
    guard failure == nil, descriptor >= 0 else {
      return
    }
    let complete = unsafe data.withUnsafeBytes { buffer -> Bool in
      var offset = 0
      while offset < buffer.count {
        guard let base = buffer.baseAddress else {
          return false
        }
        let written = unsafe Darwin.write(descriptor, base + offset, buffer.count - offset)
        if written < 0 {
          if errno == EINTR {
            continue
          }
          return false
        }
        offset += written
      }
      return true
    }
    if !complete {
      failure = unsafe "Could not write \(partialPath): \(String(cString: strerror(errno)))"
    }
  }
}

/// Reads a capture file a record at a time, so a long capture never has to fit in memory. A record
/// cut short by the end of the file ends the index, as a process that exited while it was captured
/// leaves; anything else that does not parse is an error.
public final class AudioCaptureFileReader {
  public let index: AudioCaptureFile.Index
  private let descriptor: Int32

  public init(path: String) throws {
    descriptor = unsafe open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw unsafe AudioCaptureFileError.unreadable(path: path, reason: String(cString: strerror(errno)))
    }
    do {
      index = try Self.index(descriptor, path: path)
    } catch {
      close(descriptor)
      throw error
    }
  }

  deinit {
    close(descriptor)
  }

  /// The chunk's `frames * channels` interleaved samples.
  public func samples(of chunk: AudioCaptureFile.ChunkRecord) throws -> [Float] {
    var samples = [Float](repeating: 0, count: chunk.frames * chunk.channels)
    let complete = samples.withUnsafeMutableBytes { buffer in
      unsafe Self.read(descriptor, into: buffer, at: chunk.samplesOffset)
    }
    guard complete else {
      throw AudioCaptureFileError.malformedRecord
    }
    return samples
  }

  private static func index(_ descriptor: Int32, path: String) throws -> AudioCaptureFile.Index {
    var metadata = stat()
    guard unsafe fstat(descriptor, &metadata) == 0 else {
      throw unsafe AudioCaptureFileError.unreadable(path: path, reason: String(cString: strerror(errno)))
    }
    let size = Int(metadata.st_size)
    let header = try AudioCaptureFile.index(header: read(descriptor, count: AudioCaptureFile.headerSize, at: 0) ?? Data())
    var chunks: [AudioCaptureFile.ChunkRecord] = []
    var droppedFrames: UInt64?
    var offset = AudioCaptureFile.headerSize
    let lengthSize = MemoryLayout<UInt32>.size
    while offset + lengthSize <= size, let lengthBytes = read(descriptor, count: lengthSize, at: offset) {
      let length = lengthBytes.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
      guard length > 0, offset + lengthSize + length <= size,
        let body = read(descriptor, count: min(length, AudioCaptureFile.chunkHeaderSize), at: offset + lengthSize)
      else {
        break
      }
      let (chunk, dropped) = try AudioCaptureFile.record(body, length: length, at: offset)
      if let chunk {
        chunks.append(chunk)
      }
      if let dropped {
        droppedFrames = dropped
      }
      offset += lengthSize + length
    }
    return AudioCaptureFile.Index(
      processIdentifier: header.processIdentifier, timebaseNumerator: header.numerator,
      timebaseDenominator: header.denominator, chunks: chunks, droppedFrames: droppedFrames)
  }

  private static func read(_ descriptor: Int32, count: Int, at offset: Int) -> Data? {
    var data = Data(count: count)
    let complete = unsafe data.withUnsafeMutableBytes { unsafe read(descriptor, into: $0, at: offset) }
    return complete ? data : nil
  }

  private static func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int) -> Bool {
    guard let base = buffer.baseAddress else {
      return unsafe buffer.isEmpty
    }
    var done = 0
    while done < buffer.count {
      let count = unsafe pread(descriptor, base + done, buffer.count - done, off_t(offset + done))
      if count < 0, errno == EINTR {
        continue
      }
      guard count > 0 else {
        return false
      }
      done += count
    }
    return true
  }
}

private struct LittleEndianReader {
  let data: Data
  private var offset: Int

  init(data: Data) {
    self.data = data
    offset = data.startIndex
  }

  var remaining: Int {
    data.endIndex - offset
  }

  mutating func read(count: Int) -> Data? {
    guard count >= 0, count <= remaining else {
      return nil
    }
    defer { offset += count }
    return data.subdata(in: offset..<(offset + count))
  }

  mutating func read<Value: FixedWidthInteger>(_ type: Value.Type) -> Value? {
    let size = MemoryLayout<Value>.size
    guard size <= remaining else {
      return nil
    }
    var value: Value = 0
    for index in 0..<size {
      value |= Value(data[offset + index]) << (8 * index)
    }
    offset += size
    return value
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
    Swift.withUnsafeBytes(of: value.littleEndian) { unsafe append(contentsOf: $0) }
  }

  fileprivate mutating func appendLittleEndian(_ samples: ArraySlice<Float>) {
    samples.withUnsafeBytes { unsafe append(contentsOf: $0) }
  }
}
