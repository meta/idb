/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// Mutable line-accumulation buffer for `stdinLines`. Confined to the read source's serial queue, so
/// the unchecked Sendable conformance is sound (it is only ever touched from that one queue).
private final class StdinLineBuffer: @unchecked Sendable {
  var data = Data()
}

/// An async sequence of newline-delimited lines read from a file descriptor (stdin by default) via a
/// GCD read source.
///
/// Unlike `FileHandle.standardInput.bytes.lines`, whose blocked `read` on an idle pipe ignores task
/// cancellation, this finishes promptly when the consuming task is cancelled: the read source is
/// cancelled in `onTermination`, so a `for await` over it can be raced against a signal in a task
/// group without wedging on the uninterruptible read.
///
/// Reads happen on a private serial queue and are decoupled from the consumer (which may be on any
/// actor). Each complete line is yielded without its trailing newline; a final unterminated line is
/// yielded at EOF.
func stdinLines(fileDescriptor: Int32 = STDIN_FILENO) -> AsyncStream<String> {
  AsyncStream { continuation in
    let queue = DispatchQueue(label: "com.facebook.sime2e.stdin-reader")
    let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
    let buffer = StdinLineBuffer()

    source.setEventHandler {
      var chunk = [UInt8](repeating: 0, count: 4096)
      let count = unsafe read(fileDescriptor, &chunk, chunk.count)
      if count > 0 {
        buffer.data.append(contentsOf: chunk[0..<count])
        // Emit every complete line currently buffered; keep any trailing partial line.
        while let newline = buffer.data.firstIndex(of: 0x0A) {
          let lineData = buffer.data.subdata(in: buffer.data.startIndex..<newline)
          buffer.data.removeSubrange(buffer.data.startIndex...newline)
          continuation.yield(String(decoding: lineData, as: UTF8.self))
        }
      } else if count == 0 {
        // EOF: flush a trailing unterminated line, then finish.
        if !buffer.data.isEmpty {
          continuation.yield(String(decoding: buffer.data, as: UTF8.self))
          buffer.data.removeAll()
        }
        continuation.finish()
      } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
        // EINTR / EAGAIN: no bytes consumed, the source re-fires when readable. Any other error ends it.
        continuation.finish()
      }
    }

    continuation.onTermination = { _ in
      source.cancel()
    }

    source.resume()
  }
}
