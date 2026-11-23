/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import zlib

/// A zlib inflate stream. A class, as zlib keeps a pointer back to the `z_stream`
/// it initialised, so the stream must not be copied.
// @safe: The stream is initialised here, ended in `deinit` and never handed out; callers lend their buffers for one call.
@safe final class Inflater {

  enum Format {
    /// Raw deflate, without a header, as a zip holds.
    case deflate
    /// A gzip member, header and trailer included.
    case gzip
  }

  struct Step {
    let consumed: Int
    let produced: Int
    let ended: Bool
  }

  private var stream = unsafe z_stream()
  private var initialised = false

  init?(_ format: Format) {
    let windowBits = format == .deflate ? -MAX_WBITS : MAX_WBITS + 16
    guard unsafe inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      return nil
    }
    initialised = true
  }

  deinit {
    if initialised {
      unsafe inflateEnd(&stream)
    }
  }

  /// Nil if `input` is not what the format says.
  func inflate(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> Step? {
    unsafe stream.next_in = unsafe UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
    unsafe stream.avail_in = uInt(input.count)
    unsafe stream.next_out = unsafe output.bindMemory(to: Bytef.self).baseAddress
    unsafe stream.avail_out = uInt(output.count)
    let status = unsafe zlib.inflate(&stream, Z_NO_FLUSH)
    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
      return nil
    }
    return unsafe Step(consumed: input.count - Int(stream.avail_in), produced: output.count - Int(stream.avail_out), ended: status == Z_STREAM_END)
  }

  /// Readies the stream for another member after one ends.
  func reset() {
    unsafe inflateReset(&stream)
  }
}
