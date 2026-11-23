/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation

/// An owned, nonblocking socket. One read and one write may run concurrently.
/// Cancelling either operation closes the connection, unblocking both directions.
public final class SocketStream: @unchecked Sendable {
  public static let chunkSize = 64 * 1024

  private let lock = NSLock()
  private var descriptor: Int32
  private var reading = false
  private var writing = false

  /// Takes ownership even when socket configuration fails.
  public init(adopting descriptor: Int32) throws {
    self.descriptor = descriptor
    let flags = fcntl(descriptor, F_GETFL)
    var enabled: Int32 = 1
    guard flags >= 0,
      fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
      fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
      unsafe setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      Darwin.close(descriptor)
      self.descriptor = -1
      throw error
    }
  }

  deinit { close() }

  public static func withSocket<Result: Sendable>(
    adopting descriptor: Int32,
    operation: @Sendable (SocketStream) async throws -> Result
  ) async throws -> Result {
    let socket = try SocketStream(adopting: descriptor)
    defer { socket.close() }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await operation(socket)
    } onCancel: {
      socket.close()
    }
  }

  /// Returns nil only on socket EOF. Reads are bounded even if a larger count is requested.
  public func read(maxBytes: Int = SocketStream.chunkSize) async throws -> Data? {
    guard maxBytes > 0 else { throw POSIXError(.EINVAL) }
    try begin(read: true)
    defer { end(read: true) }
    return try await withTaskCancellationHandler {
      while true {
        try Task.checkCancellation()
        do {
          var data = Data(count: min(maxBytes, Self.chunkSize))
          let count = try withDescriptor { descriptor in
            unsafe try data.withUnsafeMutableBytes { buffer in
              let count = unsafe recv(descriptor, buffer.baseAddress, buffer.count, 0)
              if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
              return count
            }
          }
          if count == 0 { return nil }
          data.count = count
          return data
        } catch let error as POSIXError where error.code == .EAGAIN || error.code == .EWOULDBLOCK {
          try await waitForReadiness(read: true)
        } catch let error as POSIXError where error.code == .EINTR {
          continue
        } catch {
          try Task.checkCancellation()
          throw error
        }
      }
    } onCancel: {
      self.close()
    }
  }

  /// Writes the entire chunk before returning; callers supply bounded chunks.
  public func write(_ data: Data) async throws {
    guard data.count <= Self.chunkSize else { throw POSIXError(.EMSGSIZE) }
    try begin(read: false)
    defer { end(read: false) }
    try await withTaskCancellationHandler {
      var offset = 0
      while offset < data.count {
        try Task.checkCancellation()
        do {
          let count = try withDescriptor { descriptor in
            unsafe try data.withUnsafeBytes { buffer in
              guard let baseAddress = buffer.baseAddress else { return 0 }
              let count = unsafe send(descriptor, baseAddress.advanced(by: offset), buffer.count - offset, 0)
              if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
              return count
            }
          }
          guard count > 0 else { throw POSIXError(.EPIPE) }
          offset += count
        } catch let error as POSIXError where error.code == .EAGAIN || error.code == .EWOULDBLOCK {
          try await waitForReadiness(read: false)
        } catch let error as POSIXError where error.code == .EINTR {
          continue
        } catch {
          try Task.checkCancellation()
          throw error
        }
      }
    } onCancel: {
      self.close()
    }
  }

  public func close() {
    lock.withLock {
      guard descriptor >= 0 else { return }
      // Readiness sources monitor their own duplicates, never this descriptor.
      _ = shutdown(descriptor, SHUT_RDWR)
      Darwin.close(descriptor)
      descriptor = -1
    }
  }

  private func withDescriptor<Result>(_ body: (Int32) throws -> Result) throws -> Result {
    try lock.withLock {
      guard descriptor >= 0 else { throw POSIXError(.EBADF) }
      return try body(descriptor)
    }
  }

  private func begin(read: Bool) throws {
    try lock.withLock {
      guard descriptor >= 0 else { throw POSIXError(.EBADF) }
      guard !(read ? reading : writing) else { throw POSIXError(.EBUSY) }
      if read { reading = true } else { writing = true }
    }
  }

  private func end(read: Bool) {
    lock.withLock {
      if read { reading = false } else { writing = false }
    }
  }

  /// Cancelling an operation closes the connection, possibly between its `EAGAIN` and this wait. A descriptor already
  /// gone in a cancelled task is that cancellation, and is reported as one rather than as `EBADF`.
  private func waitForReadiness(read: Bool) async throws {
    let duplicate: Int32
    do {
      duplicate = try withDescriptor { descriptor in
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(duplicate, F_SETFD, FD_CLOEXEC) == 0 else {
          let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          Darwin.close(duplicate)
          throw error
        }
        return duplicate
      }
    } catch {
      try Task.checkCancellation()
      throw error
    }
    try await SocketReadiness(descriptor: duplicate, read: read).wait()
  }
}

/// A readiness notification is returned only after its dispatch source has
/// relinquished and closed the duplicated descriptor, including on cancellation.
private final class SocketReadiness: @unchecked Sendable {
  private let lock = NSLock()
  private let source: any DispatchSourceProtocol
  private var cancellation: Bool = false
  private var outcome: Result<Void, any Error>?
  private var continuation: CheckedContinuation<Void, any Error>?

  init(descriptor: Int32, read: Bool) {
    let queue = DispatchQueue(label: "idb.socket.readiness")
    if read {
      source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    } else {
      source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
    }
    source.setEventHandler { [weak self] in self?.source.cancel() }
    source.setCancelHandler { [weak self] in
      Darwin.close(descriptor)
      self?.finished()
    }
    source.activate()
  }

  func wait() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let immediate: Result<Void, any Error>? = lock.withLock {
          if let outcome { return outcome }
          self.continuation = continuation
          return nil
        }
        if let immediate { continuation.resume(with: immediate) }
      }
    } onCancel: {
      self.lock.withLock { self.cancellation = true }
      self.source.cancel()
    }
    try Task.checkCancellation()
  }

  private func finished() {
    let result: Result<Void, any Error>
    let waiter: CheckedContinuation<Void, any Error>?
    lock.lock()
    result = cancellation ? .failure(CancellationError()) : .success(())
    outcome = result
    waiter = continuation
    continuation = nil
    lock.unlock()
    waiter?.resume(with: result)
  }
}
