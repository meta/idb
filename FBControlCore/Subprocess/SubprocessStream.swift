/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

extension Subprocess {

  /// Launches through `launcher`, passes standard output to `chunk` as it is
  /// read, and returns once the process has terminated. The next read waits
  /// for `chunk` to return, so a slow consumer stalls the child instead of
  /// its output accumulating in memory.
  ///
  /// The call owns the process: it is terminated when `chunk` throws and
  /// when the calling task is cancelled. Throws
  /// `SubprocessError.unacceptableTermination` exactly as `run` does.
  public func stream<Err: Sendable>(
    on launcher: any SubprocessLauncher = HostSubprocessLauncher(),
    error: Output<Err>,
    input: Input = .closed,
    exitPolicy: ExitPolicy = .mustExitZero,
    chunkSize: Int = 16384,
    gracePeriod: TimeInterval = 4,
    logger: (any ControlCoreLogger)? = nil,
    _ chunk: (Data) async throws -> Void
  ) async throws -> Completed<Void, Err> {
    let (running, captureOut, captureErr) = try await start(on: launcher, output: .pipe, error: error, input: input, logger: logger)
    let reader = PipeReader(descriptor: captureOut())
    do {
      try await withTaskCancellationHandler {
        while let data = try await reader.read(upToCount: chunkSize) {
          try await chunk(data)
        }
        try Task.checkCancellation()
      } onCancel: {
        // A read blocked on the child only returns once the child exits, so
        // cancellation has to end the child rather than wait for the loop.
        Task { await running.terminate(gracePeriod: gracePeriod) }
      }
    } catch let failure {
      await running.terminate(gracePeriod: gracePeriod)
      throw failure
    }
    let status = try await running.terminationStatus
    try check(status, against: exitPolicy, processIdentifier: running.processIdentifier, error: error, captureErr: captureErr)
    return Completed(
      executable: executable,
      processIdentifier: running.processIdentifier,
      terminationStatus: status,
      standardOutput: (),
      standardError: captureErr())
  }
}

/// Owns the read end of a pipe and reads it on a queue of its own, so that a
/// read blocked on a slow child holds a dispatch thread rather than one of
/// the cooperative pool's.
private final class PipeReader: Sendable {
  private let descriptor: Int32
  private let queue = DispatchQueue(label: "com.facebook.fbcontrolcore.subprocess.stream")

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    close(descriptor)
  }

  /// Up to `count` bytes, or nil at end-of-file.
  func read(upToCount count: Int) async throws -> Data? {
    try await queue.perform { [descriptor] in
      var buffer = Data(count: count)
      var readCount: Int
      repeat {
        readCount = unsafe buffer.withUnsafeMutableBytes { unsafe Darwin.read(descriptor, $0.baseAddress, count) }
      } while readCount < 0 && errno == EINTR
      guard readCount >= 0 else {
        throw unsafe SubprocessError.outputUnavailable(path: "pipe", message: String(cString: strerror(errno)))
      }
      guard readCount > 0 else {
        return nil
      }
      buffer.count = readCount
      return buffer
    }
  }
}
