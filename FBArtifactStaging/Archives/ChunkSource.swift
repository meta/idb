/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// A source fed, chunk by chunk, by an asynchronous producer: the bridge from bytes that arrive as an `AsyncSequence`,
/// such as an RPC's frames, to an extractor that reads them synchronously.
///
/// The producer `pump`s chunks in and awaits room once `capacity` bytes are waiting, until half of it is free, so it is
/// held to the reader's pace and what is waiting never exceeds `capacity` plus one chunk. The reader blocks its own thread until a chunk arrives.
/// Whatever ends the producer reaches the reader in-band: the end of the input, or the producer's own failure as an
/// `UpstreamFailure`, never mistaken for the end. A reader that stops early `abandon`s the source, and the producer then
/// fails with `ReaderClosed` rather than waiting for room that won't come.
public final class ChunkSource: ByteSource, @unchecked Sendable {

  /// What the producer threw, as the reader sees it.
  public struct UpstreamFailure: Error, CustomStringConvertible {
    public let underlying: any Error

    public var description: String { "The input failed: \(underlying)" }
  }

  /// What the producer gets once the reader has stopped reading.
  public struct ReaderClosed: Error, CustomStringConvertible {
    public var description: String { "The reader stopped before the input ended" }
  }

  public let capacity: Int

  private let condition = NSCondition()
  // Guarded by `condition`.
  private var chunks: [Data] = []
  private var first = 0
  private var offset = 0
  private var waiting = 0
  private var ended = false
  private var failure: (any Error)?
  private var closed = false
  private var roomWaiter: CheckedContinuation<Void, any Error>?

  public init(capacity: Int = 8 << 20) {
    self.capacity = capacity
  }

  /// A source holding `data` and then its end.
  public convenience init(_ data: Data) {
    self.init(capacity: max(data.count, 1))
    if !data.isEmpty {
      chunks = [data]
      waiting = data.count
    }
    ended = true
  }

  /// Writes `head`, then each chunk of `chunks`, for the reader, awaiting room, then ends the input. A failure of
  /// `chunks`, including cancellation, reaches the reader and is rethrown; a reader that has stopped makes this throw
  /// `ReaderClosed`.
  public func pump<Chunks: AsyncSequence>(
    _ chunks: Chunks, after head: Data = Data(), onChunk: (Data) -> Void = { _ in }
  ) async throws where Chunks.Element == Data {
    do {
      try await append(head)
      onChunk(head)
      for try await chunk in chunks {
        try await append(chunk)
        onChunk(chunk)
      }
      // Some sequences end quietly once their task is cancelled, which would otherwise read as a complete input.
      try Task.checkCancellation()
    } catch let error as ReaderClosed {
      throw error
    } catch {
      end(failing: error)
      throw error
    }
    end(failing: nil)
  }

  /// What is waiting for the reader, in bytes.
  var waitingBytes: Int {
    condition.withLock { waiting }
  }

  /// What the source holds on to, in bytes, read or not: the memory it costs.
  var heldBytes: Int {
    condition.withLock { chunks.reduce(0) { $0 + $1.count } }
  }

  /// Stops reading: anything waiting is discarded, and the producer fails with `ReaderClosed`.
  public func abandon() {
    let waiter: CheckedContinuation<Void, any Error>? = condition.withLock {
      closed = true
      chunks = []
      first = 0
      waiting = 0
      condition.broadcast()
      defer { roomWaiter = nil }
      return roomWaiter
    }
    waiter?.resume(throwing: ReaderClosed())
  }

  public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    condition.lock()
    while first == chunks.count && !ended && failure == nil && !closed {
      condition.wait()
    }
    guard first < chunks.count else {
      defer { condition.unlock() }
      if let failure {
        throw UpstreamFailure(underlying: failure)
      }
      return 0
    }
    let chunk = chunks[first]
    let count = min(buffer.count, chunk.count - offset)
    unsafe chunk.withUnsafeBytes { bytes in
      unsafe buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + count]))
    }
    offset += count
    waiting -= count
    if offset == chunk.count {
      // A chunk that has been read is let go at once: a producer that keeps a little ahead means the reader never
      // empties the queue, so waiting for it to would hold every chunk ever written.
      chunks[first] = Data()
      first += 1
      offset = 0
      if first == chunks.count {
        chunks = []
        first = 0
      } else if first >= 64 && first * 2 >= chunks.count {
        chunks.removeFirst(first)
        first = 0
      }
    }
    // Woken only once half the capacity is free: woken on every read, a producer of chunks larger than a read finds no
    // room for one and goes back to sleep, over and over.
    let waiter = waiting <= capacity / 2 ? roomWaiter : nil
    if waiter != nil {
      roomWaiter = nil
    }
    condition.unlock()
    waiter?.resume()
    return count
  }

  private func append(_ chunk: Data) async throws {
    guard !chunk.isEmpty else {
      return
    }
    while true {
      let appended: Bool = try condition.withLock {
        if closed {
          throw ReaderClosed()
        }
        guard waiting == 0 || waiting + chunk.count <= capacity else {
          return false
        }
        chunks.append(chunk)
        waiting += chunk.count
        condition.broadcast()
        return true
      }
      if appended {
        return
      }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
          let resumeNow: Bool = condition.withLock {
            if closed || waiting <= capacity / 2 || Task.isCancelled {
              return true
            }
            precondition(roomWaiter == nil, "a ChunkSource has one producer")
            roomWaiter = continuation
            return false
          }
          if resumeNow {
            continuation.resume()
          }
        }
      } onCancel: {
        let waiter: CheckedContinuation<Void, any Error>? = condition.withLock {
          defer { roomWaiter = nil }
          return roomWaiter
        }
        waiter?.resume(throwing: CancellationError())
      }
      try Task.checkCancellation()
    }
  }

  private func end(failing error: (any Error)?) {
    condition.withLock {
      guard !ended, failure == nil else {
        return
      }
      if let error {
        failure = error
      } else {
        ended = true
      }
      condition.broadcast()
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
