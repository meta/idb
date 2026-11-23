/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import zlib

/// The data of a zip entry, which every extractor decodes alike once it has found where it starts.
enum ZipEntryData {

  /// Calls `output` with the contents of the entry whose data starts at the front of `input`, and returns their CRC and size
  /// for the caller to check against what its zip records. A stored entry ends after `compressedSize` bytes, and a deflated
  /// one where its stream does, as a zip read forwards may only record its sizes after the data.
  static func decode(
    _ path: String,
    method: UInt16,
    compressedSize: UInt64,
    from input: PeekableSource,
    into output: (UnsafeRawBufferPointer) throws -> Void
  ) throws -> (crc32: UInt32, size: UInt64) {
    var crc = zlib.crc32(0, nil, 0)
    var size: UInt64 = 0
    func emit(_ chunk: UnsafeRawBufferPointer) throws {
      crc = unsafe zlib.crc32(crc, chunk.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count))
      size += UInt64(chunk.count)
      unsafe try output(chunk)
    }
    switch method {
    case 0:
      var remaining = compressedSize
      while remaining > 0 {
        guard try input.buffer(atLeast: 1) else {
          throw ArchiveError.corrupt("\(path) is truncated")
        }
        let count = Int(min(UInt64(input.available), remaining))
        unsafe try input.withAvailable { unsafe try emit(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        input.consume(count)
        remaining -= UInt64(count)
      }
    case 8:
      unsafe try inflate(path, from: input, into: emit)
    default:
      throw ArchiveError.unsupported("compression method \(method)")
    }
    return (UInt32(crc), size)
  }

  private static func inflate(_ path: String, from input: PeekableSource, into output: (UnsafeRawBufferPointer) throws -> Void) throws {
    guard let inflater = Inflater(.deflate) else {
      throw ArchiveError.corrupt("cannot inflate \(path)")
    }
    var decompressed = [UInt8](repeating: 0, count: 1 << 18)
    while true {
      // Input bounded to the entry can end with output still to come.
      let more = try input.buffer(atLeast: 1)
      let step = unsafe input.withAvailable { compressed in
        decompressed.withUnsafeMutableBytes { unsafe inflater.inflate(compressed, into: $0) }
      }
      guard let step else {
        throw ArchiveError.corrupt("\(path) does not inflate")
      }
      input.consume(step.consumed)
      try decompressed.withUnsafeBytes { unsafe try output(UnsafeRawBufferPointer(rebasing: $0[0..<step.produced])) }
      if step.ended {
        return
      }
      guard more || step.produced > 0 else {
        throw ArchiveError.corrupt("\(path) is truncated")
      }
    }
  }
}
