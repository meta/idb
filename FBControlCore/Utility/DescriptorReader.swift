/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// Mapping is zero-copy when the data is already a single contiguous region, and a mapped
/// dispatch_data bridges to `NSData` without copying.
private func contiguousData(from data: DispatchData) -> Data {
  let mapped: AnyObject = __dispatch_data_create_map(data as __DispatchData, nil, nil)
  return (mapped as? Data) ?? Data(data)
}

/// Reads a descriptor from construction until end-of-file, an error, or `stop()`, passing each
/// chunk to a consumer and then end-of-file exactly once, however reading ended.
///
/// The reader keeps itself alive until its channel has relinquished the descriptor, so it may be
/// dropped while reading. Only once `finished()` returns may an unowned descriptor be closed:
/// closing one that a dispatch source still monitors crashes libdispatch with `EV_VANISHED`.
///
/// @unchecked Sendable: the channel and the read error are confined to `queue`, and the outcome
/// and its waiters to `lock`.
public final class DescriptorReader: @unchecked Sendable {

  public enum Outcome: Sendable {
    case endOfFile
    case stopped
    case failed(errno: Int32)

    fileprivate init(errno: Int32) {
      switch errno {
      case 0:
        self = .endOfFile
      case ECANCELED:
        self = .stopped
      default:
        self = .failed(errno: errno)
      }
    }
  }

  private let queue = DispatchQueue(label: "com.facebook.fbcontrolcore.descriptorreader")
  private let consumer: any DataConsumer
  private var io: DispatchIO?
  private var readError: Int32 = 0
  private var deliveredEndOfFile = false

  private let lock = NSLock()
  private var outcome: Outcome?
  private var waiters: [CheckedContinuation<Outcome, Never>] = []

  /// With `closeOnEndOfFile`, the descriptor is closed once the channel relinquishes it; otherwise
  /// it stays open and owned by the caller.
  public init(fileDescriptor: Int32, closeOnEndOfFile: Bool, consumer: any DataConsumer) {
    self.consumer = consumer
    // Set O_NONBLOCK before DispatchIO snapshots the descriptor flags: libdispatch restores that
    // snapshot asynchronously on teardown through the shared open file description (or a recycled
    // descriptor number), and a snapshot without O_NONBLOCK would wedge an unrelated live channel in
    // a blocking read(2).
    _ = fcntl(fileDescriptor, F_SETFL, fcntl(fileDescriptor, F_GETFL) | O_NONBLOCK)
    queue.sync {
      // A bad descriptor is reported here, without the read handler ever running. The capture of
      // self is what keeps the reader alive until the channel lets go of the descriptor.
      let io = DispatchIO(type: .stream, fileDescriptor: fileDescriptor, queue: queue) { createError in
        // Closed before the waiters resume, so a reader that has finished has let go of an owned descriptor.
        if closeOnEndOfFile {
          close(fileDescriptor)
        }
        self.relinquished(errno: createError != 0 ? createError : self.readError)
      }
      self.io = io
      io.setLimit(lowWater: 1)
      io.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
        if let data, !data.isEmpty {
          self.consumer.consumeData(contiguousData(from: data))
        }
        guard done else { return }
        self.readError = error
        self.deliverEndOfFile()
        // A finished read does not relinquish the descriptor; only closing the channel does.
        self.io?.close()
      }
    }
  }

  /// Stops reading. Data already read is still delivered, followed by end-of-file.
  public func stop() {
    queue.async {
      self.io?.close(flags: .stop)
    }
  }

  /// Returns once the descriptor has been relinquished. Cancelling the wait stops reading, so it
  /// still returns promptly with the outcome rather than leaving the descriptor monitored.
  public func finished() async -> Outcome {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        lock.lock()
        guard let outcome else {
          waiters.append(continuation)
          lock.unlock()
          return
        }
        lock.unlock()
        continuation.resume(returning: outcome)
      }
    } onCancel: {
      stop()
    }
  }

  /// As `finished()`, stopping reading if it has not ended within `timeout` seconds.
  public func finished(within timeout: TimeInterval) async -> Outcome {
    let deadline = Task {
      try await Task.sleep(nanoseconds: UInt64(timeout * Double(NSEC_PER_SEC)))
      stop()
    }
    defer { deadline.cancel() }
    return await finished()
  }

  private func deliverEndOfFile() {
    guard !deliveredEndOfFile else { return }
    deliveredEndOfFile = true
    consumer.consumeEndOfFile()
  }

  private func relinquished(errno: Int32) {
    deliverEndOfFile()
    io = nil
    let outcome = Outcome(errno: errno)
    let waiters = lock.withLock {
      self.outcome = outcome
      defer { self.waiters = [] }
      return self.waiters
    }
    for waiter in waiters {
      waiter.resume(returning: outcome)
    }
  }
}
