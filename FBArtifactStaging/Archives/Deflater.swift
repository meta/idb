/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import zlib

/// A zlib deflate stream writing a single gzip member. A class, as zlib keeps a pointer back to the
/// `z_stream` it initialised, and to the header it was given, so neither may move.
// @safe: The stream and header are allocated here, freed in `deinit` and never handed out; callers lend their buffers for one call.
@safe final class Deflater {

  struct Step {
    let consumed: Int
    let produced: Int
    let ended: Bool
  }

  private var stream = unsafe z_stream()
  private let header: UnsafeMutablePointer<gz_header>
  private var initialised = false

  init?() {
    unsafe header = .allocate(capacity: 1)
    unsafe header.initialize(to: gz_header())
    // zlib names macOS by its own OS code; gzip and bsdtar write 3 for any Unix host, which is what clients see today.
    unsafe header.pointee.os = 3
    guard unsafe deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      unsafe header.deallocate()
      return nil
    }
    guard unsafe deflateSetHeader(&stream, header) == Z_OK else {
      unsafe deflateEnd(&stream)
      unsafe header.deallocate()
      return nil
    }
    initialised = true
  }

  deinit {
    if initialised {
      unsafe deflateEnd(&stream)
      unsafe header.deallocate()
    }
  }

  /// Deflates `input`, writing the trailer once `finish` is set and all of the input is consumed.
  func deflate(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer, finish: Bool) -> Step? {
    unsafe stream.next_in = unsafe UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
    unsafe stream.avail_in = uInt(input.count)
    unsafe stream.next_out = unsafe output.bindMemory(to: Bytef.self).baseAddress
    unsafe stream.avail_out = uInt(output.count)
    let status = unsafe zlib.deflate(&stream, finish ? Z_FINISH : Z_NO_FLUSH)
    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
      return nil
    }
    return unsafe Step(consumed: input.count - Int(stream.avail_in), produced: output.count - Int(stream.avail_out), ended: status == Z_STREAM_END)
  }
}
