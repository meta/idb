/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Bytes read forwards, a buffer at a time, by one thread at a time.
///
/// A decoder is a source that reads another, so a stream is decoded by stacking them:
/// `GzipSource(PeekableSource(FileDescriptorSource(fd)))`.
public protocol ByteSource: AnyObject {

  /// Reads up to the buffer's size into it, returning 0 at the end of the input.
  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int

  /// Reads to the end of the underlying input, discarding it, so a writer is never
  /// left blocked on a pipe that nothing reads. A decoder drains what it reads
  /// without decoding it.
  func drain() throws
}

// MARK: - Draining

extension ByteSource {

  public func drain() throws {
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    while try chunk.withUnsafeMutableBytes({ unsafe try read(into: $0) }) > 0 {}
  }
}

/// Reads a file descriptor, which the caller owns.
public final class FileDescriptorSource: ByteSource {

  private let fileDescriptor: Int32

  public init(_ fileDescriptor: Int32) {
    self.fileDescriptor = fileDescriptor
  }

  public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    while true {
      let count = unsafe Darwin.read(fileDescriptor, buffer.baseAddress, buffer.count)
      if count >= 0 {
        return count
      }
      guard errno == EINTR else {
        throw POSIXError.current
      }
    }
  }
}

/// Reads `length` bytes of a file descriptor from `offset`, which the caller owns, leaving its file offset alone so that
/// several can read one file at once. Ends early if the file does.
final class FileRangeSource: ByteSource {

  private let fileDescriptor: Int32
  private var offset: UInt64
  private var remaining: UInt64

  init(_ fileDescriptor: Int32, offset: UInt64, length: UInt64) {
    self.fileDescriptor = fileDescriptor
    self.offset = offset
    remaining = length
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    guard remaining > 0, unsafe !buffer.isEmpty else {
      return 0
    }
    while true {
      let count = unsafe pread(fileDescriptor, buffer.baseAddress, Int(min(UInt64(buffer.count), remaining)), off_t(offset))
      if count >= 0 {
        offset += UInt64(count)
        remaining = count == 0 ? 0 : remaining - UInt64(count)
        return count
      }
      guard errno == EINTR else {
        throw POSIXError.current
      }
    }
  }
}

/// Reads another source, writing everything read to a file as well. Draining reads
/// to the end through the file, so what a reader stops short of still reaches it.
final class TeeSource: ByteSource {

  private let source: any ByteSource
  private let file: FileHandle

  init(_ source: any ByteSource, to file: FileHandle) {
    self.source = source
    self.file = file
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    let count = unsafe try source.read(into: buffer)
    if count > 0 {
      unsafe try file.write(contentsOf: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
    }
    return count
  }
}

/// Reads ahead of a parser that reads forwards, which can look at what is buffered
/// before consuming it. Whatever is not consumed is still read afterwards.
public final class PeekableSource: ByteSource {

  private let source: any ByteSource
  private var bytes: [UInt8]
  private var start = 0
  private var end = 0
  private var ended = false

  public init(_ source: any ByteSource, capacity: Int = 1 << 18) {
    self.source = source
    bytes = [UInt8](repeating: 0, count: capacity)
  }

  var available: Int { end - start }

  var buffered: Data { Data(bytes[start..<end]) }

  subscript(offset: Int) -> UInt8 { bytes[start + offset] }

  /// Up to `count` bytes from the front without consuming them; fewer only if the input ends first.
  public func peek(_ count: Int) throws -> Data {
    _ = try buffer(atLeast: min(count, bytes.count))
    return Data(bytes[start..<start + min(count, available)])
  }

  /// Reads more after what is buffered, returning false at the end of the input.
  func fill() throws -> Bool {
    guard !ended else {
      return false
    }
    if start > 0 {
      let (from, count) = (start, available)
      bytes.withUnsafeMutableBytes { bytes in
        guard let base = bytes.baseAddress else {
          return
        }
        unsafe memmove(base, base + from, count)
      }
      (start, end) = (0, count)
    }
    let offset = end
    let count = try bytes.withUnsafeMutableBytes { unsafe try source.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[offset...])) }
    ended = count == 0
    end += count
    return count > 0
  }

  /// Returns whether at least `count` bytes are buffered, reading more if needed.
  func buffer(atLeast count: Int) throws -> Bool {
    while available < count {
      guard try fill() else {
        return false
      }
    }
    return true
  }

  func withAvailable<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
    try bytes.withUnsafeBytes { unsafe try body(UnsafeRawBufferPointer(rebasing: $0[start..<end])) }
  }

  func consume(_ count: Int) {
    start += count
  }

  /// Copies out what is buffered or, once that is used up, reads straight into `buffer`.
  public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    guard available > 0 else {
      guard !ended else {
        return 0
      }
      let count = unsafe try source.read(into: buffer)
      ended = count == 0
      return count
    }
    let count = min(available, buffer.count)
    unsafe withAvailable { unsafe buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
    start += count
    return count
  }

  public func drain() throws {
    (start, end) = (0, 0)
    guard !ended else {
      return
    }
    ended = true
    try source.drain()
  }
}

/// Inflates gzip members, one after another; anything else after a member ends the stream.
public final class GzipSource: ByteSource {

  private enum State {
    case inflating(Inflater)
    case finished
  }

  private var state: State
  private let input: PeekableSource

  public init(_ source: any ByteSource) throws {
    guard let inflater = Inflater(.gzip) else {
      throw ArchiveError.corrupt("cannot inflate the gzip")
    }
    input = source as? PeekableSource ?? PeekableSource(source)
    state = .inflating(inflater)
  }

  public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    guard case .inflating(let inflater) = state else {
      return 0
    }
    while true {
      guard try input.buffer(atLeast: 1) else {
        throw ArchiveError.corrupt("the gzip ends early")
      }
      guard let step = unsafe input.withAvailable({ unsafe inflater.inflate($0, into: buffer) }) else {
        throw ArchiveError.corrupt("the gzip does not inflate")
      }
      input.consume(step.consumed)
      var finished = false
      if step.ended {
        if try input.buffer(atLeast: 2), input[0] == 0x1F, input[1] == 0x8B {
          inflater.reset()
        } else {
          state = .finished
          finished = true
        }
      }
      if step.produced > 0 || finished {
        return step.produced
      }
    }
  }

  public func drain() throws {
    state = .finished
    try input.drain()
  }
}

/// Gzips another source as a single member.
public final class GzippingSource: ByteSource {

  private let source: any ByteSource
  private let deflater: Deflater
  private var input = [UInt8](repeating: 0, count: 1 << 16)
  private var start = 0
  private var end = 0
  private var inputEnded = false
  private var finished = false

  public init(_ source: any ByteSource) throws {
    guard let deflater = Deflater() else {
      throw ArchiveCreationError.compressionFailed
    }
    self.source = source
    self.deflater = deflater
  }

  public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    guard !finished else {
      return 0
    }
    while true {
      if start == end && !inputEnded {
        let count = try input.withUnsafeMutableBytes { unsafe try source.read(into: $0) }
        (start, end, inputEnded) = (0, count, count == 0)
      }
      let (from, to, finish) = (start, end, inputEnded)
      guard let step = input.withUnsafeBytes({ unsafe deflater.deflate(UnsafeRawBufferPointer(rebasing: $0[from..<to]), into: buffer, finish: finish) }) else {
        throw ArchiveCreationError.compressionFailed
      }
      start += step.consumed
      finished = step.ended
      if step.produced > 0 || finished {
        return step.produced
      }
    }
  }

  public func drain() throws {
    finished = true
    try source.drain()
  }
}

/// Decompresses zstd frames, one after another, skipping skippable frames; anything else is corrupt.
public final class ZstdSource: ByteSource {

  private enum State {
    case decoding(ZstdDecoder)
    case finished
  }

  private var state: State
  private let input: PeekableSource
  private var frameEnded = false

  public init(_ source: any ByteSource) throws {
    guard let decoder = ZstdDecoder() else {
      throw ArchiveError.corrupt("cannot decompress the zstd")
    }
    input = source as? PeekableSource ?? PeekableSource(source)
    state = .decoding(decoder)
  }

  /// `source`, decompressed if it starts as a zstd frame or skippable frame does.
  public static func ifZstd(_ source: any ByteSource) throws -> any ByteSource {
    let peekable = PeekableSource(source)
    switch ArchiveFormat.detect(try peekable.peek(ArchiveFormat.zstdZipMarker.count)) {
    case .zstd, .zstdZip:
      return try ZstdSource(peekable)
    case .zip, .gzip, .other, .undetermined:
      return peekable
    }
  }

  public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    guard case .decoding(let decoder) = state else {
      return 0
    }
    while true {
      // The decoder can still hold output once the input has run out, so it is asked for more until a frame ends.
      let hasInput = try input.buffer(atLeast: 1)
      if !hasInput && frameEnded {
        state = .finished
        return 0
      }
      guard let step = unsafe input.withAvailable({ unsafe decoder.decompress($0, into: buffer) }) else {
        throw ArchiveError.corrupt("the zstd does not decompress")
      }
      input.consume(step.consumed)
      frameEnded = step.frameEnded
      if step.produced > 0 {
        return step.produced
      }
      guard hasInput else {
        throw ArchiveError.corrupt("the zstd ends early")
      }
    }
  }

  public func drain() throws {
    state = .finished
    try input.drain()
  }
}

// MARK: - Decompressing

/// `source`, decompressed if it starts as a gzip member or a zstd frame does.
func decompressed(_ source: any ByteSource) throws -> any ByteSource {
  let peekable = PeekableSource(source)
  switch ArchiveFormat.detect(try peekable.peek(ArchiveFormat.zstdZipMarker.count)) {
  case .gzip:
    return try GzipSource(peekable)
  case .zstd, .zstdZip:
    return try ZstdSource(peekable)
  case .zip, .other, .undetermined:
    return peekable
  }
}
