/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// A consumer that passes each chunk of data to a block on the thread that consumed it.
///
/// Deliveries are serialized, and data consumed after end-of-file is ignored.
// SAFETY: `consumer` is only touched under `lock`.
public final class SynchronousDataConsumer: DataConsumer, DataConsumerLifecycle, @unchecked Sendable {
  // Recursive because the block runs under the lock, and a block may feed this consumer again.
  private let lock = NSRecursiveLock()
  private var consumer: ((Data) -> Void)?
  public let finishedConsuming = AsyncEvent<Void>()

  public init(consumer: @escaping (Data) -> Void) {
    self.consumer = consumer
  }

  public func consumeData(_ data: Data) {
    lock.withLock {
      consumer?(data)
    }
  }

  public func consumeEndOfFile() {
    lock.withLock {
      consumer = nil
      finishedConsuming.happen()
    }
  }

  public var consumption: DataConsumption { .synchronous }
}

/// A consumer that passes each chunk of data to a block, in order, on a queue.
///
/// End-of-file blocks its caller until every chunk already queued has been delivered, so
/// `finishedConsuming` opens only after the last delivery. Data consumed after end-of-file is ignored,
/// including data a queued delivery feeds back while end-of-file waits.
// SAFETY: `consumer` is only touched under `lock` and `pending` only under `pendingLock`.
public final class AsynchronousDataConsumer: DataConsumer, DataConsumerLifecycle, @unchecked Sendable {
  private let queue: DispatchQueue
  private let group = DispatchGroup()
  private let lock = NSRecursiveLock()
  private var consumer: (@Sendable (Data) -> Void)?
  private let pendingLock = NSLock()
  private var pending = 0
  public let finishedConsuming = AsyncEvent<Void>()

  public init(queue: DispatchQueue = AsynchronousDataConsumer.privateQueue(), consumer: @escaping @Sendable (Data) -> Void) {
    self.queue = queue
    self.consumer = consumer
  }

  public static func privateQueue() -> DispatchQueue {
    DispatchQueue(label: "com.facebook.FBControlCore.BlockDataConsumer.data")
  }

  public func consumeData(_ data: Data) {
    lock.withLock {
      guard let consumer else {
        return
      }
      pendingLock.withLock { pending += 1 }
      queue.async(group: group) {
        consumer(data)
        self.pendingLock.withLock { self.pending -= 1 }
      }
    }
  }

  public func consumeEndOfFile() {
    lock.withLock {
      consumer = nil
    }
    // Outside the lock: a queued delivery that feeds this consumer again takes it.
    group.wait()
    finishedConsuming.happen()
  }

  public var consumption: DataConsumption { .queued(unprocessed: unprocessedDataCount()) }

  public func unprocessedDataCount() -> Int {
    pendingLock.withLock { pending }
  }
}
