/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Creates files decoded on one thread, an archive read forwards, on
/// `ArchiveExtraction.writerCount` others.
///
/// Small files are handed to the writers; a large one is written by the caller
/// as it decodes, so that no more than about the queue's limit is held in memory.
final class ParallelFileWriter {

  private let queue = WriteQueue()
  private let writers = DispatchGroup()
  private let overrideModificationTime: Bool

  init(overrideModificationTime: Bool) {
    self.overrideModificationTime = overrideModificationTime
    for _ in 0..<ArchiveExtraction.writerCount {
      writers.enter()
      Thread { [queue, writers] in
        defer { writers.leave() }
        while let file = queue.take() {
          do {
            try Self.write(file, overrideModificationTime: overrideModificationTime)
          } catch {
            queue.fail(error)
          }
        }
      }.start()
    }
  }

  /// Creates `path`, which must not exist, with the contents `produce` passes to
  /// its argument in order. `mode` is the file's permissions, or nil for the
  /// default. Extended attributes are set as far as the system allows.
  func write(
    _ path: String,
    mode: mode_t? = nil,
    modified: timespec?,
    extendedAttributes: [String: Data] = [:],
    contents produce: ((UnsafeRawBufferPointer) throws -> Void) throws -> Void
  ) throws {
    var contents = Data()
    var inline: Int32?
    defer { inline.map { _ = close($0) } }
    try produce { buffer in
      if let fd = inline {
        try ArchiveExtraction.writeAll(buffer, to: fd)
        return
      }
      contents.append(contentsOf: buffer)
      if contents.count > Self.inlineThreshold {
        let fd = try ArchiveExtraction.createFile(path)
        inline = fd
        try contents.withUnsafeBytes { try ArchiveExtraction.writeAll($0, to: fd) }
        contents = Data()
      }
    }
    let file = File(path: path, contents: contents, mode: mode, modified: modified, extendedAttributes: extendedAttributes)
    if let fd = inline {
      try Self.finish(file, fd: fd, overrideModificationTime: overrideModificationTime)
    } else {
      try queue.put(file)
    }
  }

  /// How long the caller has been held back by the writers falling behind.
  var waited: TimeInterval {
    queue.waited
  }

  /// Stops the writers taking more, so that `finish` throws `error`.
  func fail(_ error: any Error) {
    queue.fail(error)
  }

  /// Waits for everything handed over to be written, throwing the first failure.
  func finish() throws {
    queue.close()
    writers.wait()
    if let error = queue.failure {
      throw error
    }
  }

  // MARK: - Private

  private static let inlineThreshold = 4 << 20

  struct File {
    var path: String
    var contents: Data
    var mode: mode_t?
    var modified: timespec?
    var extendedAttributes: [String: Data]
  }

  private static func write(_ file: File, overrideModificationTime: Bool) throws {
    let fd = try ArchiveExtraction.createFile(file.path)
    defer { close(fd) }
    try file.contents.withUnsafeBytes { try ArchiveExtraction.writeAll($0, to: fd) }
    try finish(file, fd: fd, overrideModificationTime: overrideModificationTime)
  }

  private static func finish(_ file: File, fd: Int32, overrideModificationTime: Bool) throws {
    try ArchiveExtraction.finishFile(fd, mode: file.mode, modified: overrideModificationTime ? nil : file.modified, extendedAttributes: file.extendedAttributes)
  }

  /// Hands files from the decoding thread to the writers, holding back the decoder
  /// when the writers fall behind.
  final class WriteQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var files: [File] = []
    private var head = 0
    private var bytes = 0
    private var closed = false
    private var error: (any Error)?
    private var waitedNanoseconds: UInt64 = 0

    var waited: TimeInterval {
      condition.lock()
      defer { condition.unlock() }
      return Double(waitedNanoseconds) / 1e9
    }

    var failure: (any Error)? {
      condition.lock()
      defer { condition.unlock() }
      return error
    }

    /// What the queue holds on to, in bytes, taken or not: the memory it costs.
    var heldBytes: Int {
      condition.lock()
      defer { condition.unlock() }
      return files.reduce(0) { $0 + $1.contents.count }
    }

    func put(_ file: File) throws {
      condition.lock()
      defer { condition.unlock() }
      let start = DispatchTime.now().uptimeNanoseconds
      while error == nil, files.count - head >= 1024 || bytes >= 64 << 20 {
        condition.wait()
      }
      waitedNanoseconds += DispatchTime.now().uptimeNanoseconds - start
      if let error {
        throw error
      }
      files.append(file)
      bytes += file.contents.count
      condition.broadcast()
    }

    func take() -> File? {
      condition.lock()
      defer { condition.unlock() }
      while error == nil, !closed, head == files.count {
        condition.wait()
      }
      guard error == nil, head < files.count else {
        return nil
      }
      let file = files[head]
      // A file is let go as soon as it is taken: a decoder that keeps ahead of the writers never lets the queue empty,
      // so waiting for it to would hold every file decoded.
      files[head].contents = Data()
      head += 1
      if head == files.count {
        files.removeAll(keepingCapacity: true)
        head = 0
      } else if head >= 64 && head * 2 >= files.count {
        files.removeFirst(head)
        head = 0
      }
      bytes -= file.contents.count
      condition.broadcast()
      return file
    }

    func fail(_ failure: any Error) {
      condition.lock()
      defer { condition.unlock() }
      error = error ?? failure
      condition.broadcast()
    }

    func close() {
      condition.lock()
      defer { condition.unlock() }
      closed = true
      condition.broadcast()
    }
  }
}
