/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// A download's bytes, written to a file as they arrive and read back by one reader as they are written.
///
/// A link faster than its reader puts what it is ahead by on disk rather than in memory. Nothing can hold a
/// `URLSession` back: suspending its task does not stop what it has already read arriving, and blocking its delegate
/// queue until the reader catches up starves the dispatch threads the reader's progress is reported on. So the writer
/// never waits for the reader; only the reader waits, on its own thread, for the writer.
///
/// The file is unlinked as soon as it is open, so it goes when the download and its reader are done with it, however
/// they end.
final class DownloadSpool: @unchecked Sendable {

  private let condition = NSCondition()
  // Guarded by `condition`.
  private var written = 0
  private var finished = false
  private var failure: (any Error)?
  private var readerGone = false

  // Used only from the session's delegate queue, which is serial.
  private let writer: FileHandle?
  private let readDescriptor: Int32

  /// Why the spool's file couldn't be created, if it couldn't. Such a spool keeps nothing, and its reader fails at once.
  let creationFailure: (any Error)?

  init(directory: URL = FileManager.default.temporaryDirectory) {
    let path = directory.appendingPathComponent("idb-download-\(UUID().uuidString)").path
    let writeDescriptor = unsafe open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    readDescriptor = unsafe writeDescriptor >= 0 ? open(path, O_RDONLY | O_CLOEXEC) : -1
    unsafe unlink(path)
    guard writeDescriptor >= 0, readDescriptor >= 0 else {
      if writeDescriptor >= 0 {
        close(writeDescriptor)
      }
      writer = nil
      creationFailure = POSIXError.current
      failure = creationFailure
      finished = true
      return
    }
    writer = FileHandle(fileDescriptor: writeDescriptor, closeOnDealloc: true)
    creationFailure = nil
  }

  deinit {
    if readDescriptor >= 0 {
      close(readDescriptor)
    }
  }

  /// Appends `data` for the reader, unless it has gone or the spool has ended. Throws if `data` can't be written, leaving
  /// the caller to end the spool with that error once it has recorded it as the download's own.
  func append(_ data: Data) throws {
    guard let writer, condition.withLock({ !readerGone && !finished }) else {
      return
    }
    try writer.write(contentsOf: data)
    condition.withLock {
      written += data.count
      condition.broadcast()
    }
  }

  /// The end of the download: the reader reads to what was written, then sees the end, or `error` if there is one.
  func end(failing error: (any Error)? = nil) {
    condition.withLock {
      guard !finished else {
        return
      }
      finished = true
      failure = error
      condition.broadcast()
    }
    try? writer?.close()
  }

  /// Calls `body` with a source reading the spool from its start, blocking its thread until more is written, and lets
  /// the writer stop spooling once `body` returns. A spool is read once.
  func reading<T>(_ body: (any ByteSource) async throws -> T) async throws -> T {
    defer { condition.withLock { readerGone = true } }
    return try await body(Reader(spool: self))
  }

  /// Blocks until more than `offset` bytes are written or the spool ends, returning how much is written and whether it
  /// has ended.
  fileprivate func waitForBytes(beyond offset: Int) throws -> (written: Int, ended: Bool) {
    condition.lock()
    defer { condition.unlock() }
    while written <= offset && !finished {
      condition.wait()
    }
    if written <= offset, let failure {
      throw failure
    }
    return (written, finished)
  }

  private final class Reader: ByteSource {

    private let spool: DownloadSpool
    private var offset = 0

    init(spool: DownloadSpool) {
      self.spool = spool
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
      let (written, _) = try spool.waitForBytes(beyond: offset)
      guard written > offset else {
        return 0
      }
      while true {
        let count = unsafe pread(spool.readDescriptor, buffer.baseAddress, min(buffer.count, written - offset), off_t(offset))
        if count >= 0 {
          offset += count
          return count
        }
        guard errno == EINTR else {
          throw POSIXError.current
        }
      }
    }
  }
}

extension NSCondition {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
