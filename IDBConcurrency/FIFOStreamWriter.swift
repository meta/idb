/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

public protocol AsyncStreamWriter {
  associatedtype Value: Sendable

  func send(_ value: Value) async throws
}

/// Wraps any async stream writer and bridges it to synchronous world
/// preserving FIFO order of elements.
public final class FIFOStreamWriter<StreamWriter: AsyncStreamWriter & Sendable>: Sendable {

  private let stream: StreamWriter

  private let semaphore = DispatchSemaphore(value: 0)

  public init(stream: StreamWriter) {
    self.stream = stream
  }

  // Carries the error across the semaphore boundary, which the concurrency checker cannot see through.
  private class ErrorWrapper: @unchecked Sendable {
    var error: (any Error)?
  }

  /// Call from GCD only: blocking a Swift concurrency cooperative-pool thread here can deadlock the runtime.
  public func send(_ value: StreamWriter.Value) throws {
    // Blocks the calling thread until `stream.send` returns; assumes sends are short.
    let errWrapper = ErrorWrapper()
    Task {
      do {
        try await stream.send(value)
      } catch {
        errWrapper.error = error
      }
      semaphore.signal()
    }
    semaphore.wait()

    if let err = errWrapper.error {
      throw err
    }
  }
}
