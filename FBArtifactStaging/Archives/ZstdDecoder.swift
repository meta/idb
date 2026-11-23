/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
internal import ZstdDecompress

/// A zstd decompression stream. Frames are read one after another, and skippable frames are skipped.
// @safe: The stream is created here, freed in `deinit` and never handed out; callers lend their buffers for one call.
@safe final class ZstdDecoder {

  struct Step {
    let consumed: Int
    let produced: Int
    /// The frame that was being read has ended and all of its output has been produced.
    let frameEnded: Bool
  }

  private let stream: OpaquePointer

  init?() {
    guard let stream = unsafe ZSTD_createDStream() else {
      return nil
    }
    unsafe self.stream = unsafe stream
  }

  deinit {
    unsafe ZSTD_freeDStream(stream)
  }

  /// Nil if `input` is not zstd.
  func decompress(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> Step? {
    var inBuffer = unsafe ZSTD_inBuffer(src: input.baseAddress, size: input.count, pos: 0)
    var outBuffer = unsafe ZSTD_outBuffer(dst: output.baseAddress, size: output.count, pos: 0)
    let hint = unsafe ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
    guard ZSTD_isError(hint) == 0 else {
      return nil
    }
    return unsafe Step(consumed: inBuffer.pos, produced: outBuffer.pos, frameEnded: hint == 0)
  }
}
