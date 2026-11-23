/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

enum FileWriterError: Error, LocalizedError {
  case openFailed(path: String, message: String)
  case ioChannelCreationFailed(fileDescriptor: Int32)

  public var errorDescription: String? {
    switch self {
    case let .openFailed(path, message):
      return "A file handle for path \(path) could not be opened: \(message)"
    case let .ioChannelCreationFailed(fileDescriptor):
      return "A IO Channel could not be created for fd \(fileDescriptor)"
    }
  }
}

/// @unchecked Sendable: the descriptor, the flag and the latch are immutable. The async subclass keeps
/// its `DispatchIO` channel confined to its write queue.
public class FileWriter: @unchecked Sendable {

  // MARK: - Properties

  fileprivate let fileDescriptor: Int32
  fileprivate let closeOnEndOfFile: Bool
  let finishedConsuming = AsyncEvent<Void>()

  // MARK: - Initializers

  private static func createWorkQueue() -> DispatchQueue {
    return DispatchQueue(label: "com.facebook.fbcontrolcore.fbfilewriter")
  }

  private static func fileDescriptor(forPath filePath: String) throws -> Int32 {
    let fd = open(filePath, O_WRONLY | O_CREAT, 0o644)
    if fd == -1 {
      throw FileWriterError.openFailed(path: filePath, message: String(cString: strerror(errno)))
    }
    return fd
  }

  public static func syncWriter(withFileDescriptor fileDescriptor: Int32, closeOnEndOfFile: Bool) -> any DataConsumer & DataConsumerLifecycle {
    return Sync(fileDescriptor: fileDescriptor, closeOnEndOfFile: closeOnEndOfFile)
  }

  public static func asyncWriter(withFileDescriptor fileDescriptor: Int32, closeOnEndOfFile: Bool, queue: DispatchQueue) throws -> any DataConsumer & DataConsumerLifecycle {
    let writer = Async(fileDescriptor: fileDescriptor, closeOnEndOfFile: closeOnEndOfFile, writeQueue: queue)
    try writer.startWriting()
    return writer
  }

  public static func asyncWriter(withFileDescriptor fileDescriptor: Int32, closeOnEndOfFile: Bool) throws -> any DataConsumer & DataConsumerLifecycle {
    try asyncWriter(withFileDescriptor: fileDescriptor, closeOnEndOfFile: closeOnEndOfFile, queue: createWorkQueue())
  }

  /// An async writer whose writes can also report when the descriptor has taken them, so that a
  /// producer can hold off sending more until it has.
  static func drainingWriter(withFileDescriptor fileDescriptor: Int32, closeOnEndOfFile: Bool) throws -> Draining {
    let writer = Async(fileDescriptor: fileDescriptor, closeOnEndOfFile: closeOnEndOfFile, writeQueue: createWorkQueue())
    try writer.startWriting()
    return Draining(writer: writer)
  }

  public static func syncWriter(forFilePath filePath: String) throws -> any DataConsumer & DataConsumerLifecycle {
    FileWriter.syncWriter(withFileDescriptor: try fileDescriptor(forPath: filePath), closeOnEndOfFile: true)
  }

  public static func asyncWriter(forFilePath filePath: String) async throws -> any DataConsumer & DataConsumerLifecycle {
    let queue = createWorkQueue()
    // Opening a FIFO for writing blocks until something opens it for reading, so the open must not
    // hold a Swift concurrency thread.
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        continuation.resume(
          with: Result<any DataConsumer & DataConsumerLifecycle, any Error> {
            let writer = Async(fileDescriptor: try fileDescriptor(forPath: filePath), closeOnEndOfFile: true, writeQueue: queue)
            try writer.startWriting()
            return writer
          })
      }
    }
  }

  fileprivate init(fileDescriptor: Int32, closeOnEndOfFile: Bool) {
    self.fileDescriptor = fileDescriptor
    self.closeOnEndOfFile = closeOnEndOfFile
  }

  // MARK: - Draining

  final class Draining: Sendable {

    private let writer: Async
    /// Writes and end-of-file without waiting, as `asyncWriter` does.
    let consumer: any DataConsumer & DataConsumerLifecycle

    fileprivate init(writer: Async) {
      self.writer = writer
      self.consumer = writer
    }

    /// Calls `completion` with 0 once all of `data` is written, or with the `errno` that stopped it.
    func write(_ data: Data, completion: @escaping @Sendable (Int32) -> Void) {
      writer.write(data, completion: completion)
    }
  }

  // MARK: - Sync

  private final class Sync: FileWriter, DataConsumer, DataConsumerLifecycle, @unchecked Sendable {

    var consumption: DataConsumption { .synchronous }

    func consumeData(_ data: Data) {
      data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        write(self.fileDescriptor, baseAddress, buffer.count)
      }
    }

    func consumeEndOfFile() {
      finishedConsuming.happen()
      if closeOnEndOfFile {
        close(fileDescriptor)
      }
    }
  }

  // MARK: - Async

  fileprivate final class Async: FileWriter, DataConsumer, DataConsumerLifecycle, @unchecked Sendable {

    let writeQueue: DispatchQueue
    var io: DispatchIO?

    init(fileDescriptor: Int32, closeOnEndOfFile: Bool, writeQueue: DispatchQueue) {
      self.writeQueue = writeQueue
      super.init(fileDescriptor: fileDescriptor, closeOnEndOfFile: closeOnEndOfFile)
    }

    func consumeData(_ data: Data) {
      guard let io else { return }
      io.write(offset: 0, data: data.withUnsafeBytes { DispatchData(bytes: $0) }, queue: writeQueue) { _, _, _ in }
    }

    func write(_ data: Data, completion: @escaping @Sendable (Int32) -> Void) {
      guard let io else {
        completion(ECANCELED)
        return
      }
      io.write(offset: 0, data: data.withUnsafeBytes { DispatchData(bytes: $0) }, queue: writeQueue) { done, _, error in
        guard done else { return }
        completion(error)
      }
    }

    func consumeEndOfFile() {
      guard let io else { return }
      // The descriptor is closed in the DispatchIO cleanup handler; the barrier ensures no writes are
      // pending before the channel is stopped.
      io.barrier {
        io.close(flags: .stop)
      }
    }

    func startWriting() throws {
      assert(io == nil)

      // O_NONBLOCK must be set before DispatchIO snapshots the descriptor flags; see
      // DescriptorReader.init for why.
      _ = fcntl(self.fileDescriptor, F_SETFL, fcntl(self.fileDescriptor, F_GETFL) | O_NONBLOCK)

      let finishedConsuming = self.finishedConsuming
      // The descriptor belongs to the channel rather than to this writer, so its
      // close must not be reached through the weak capture below: teardown is
      // asynchronous and routinely outlives a writer that its owner released as
      // soon as it ended it.
      let fileDescriptor = self.fileDescriptor
      let closeOnEndOfFile = self.closeOnEndOfFile

      io = DispatchIO(type: .stream, fileDescriptor: fileDescriptor, queue: writeQueue) { [weak self] _ in
        self?.io = nil
        if closeOnEndOfFile {
          close(fileDescriptor)
        }
        // Since writing is asynchronous, wait until the io channel is fully closed.
        finishedConsuming.happen()
      }
      guard io != nil else {
        throw FileWriterError.ioChannelCreationFailed(fileDescriptor: fileDescriptor)
      }

      io?.setLimit(lowWater: 1)
    }
  }
}
