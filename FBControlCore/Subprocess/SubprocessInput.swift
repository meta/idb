/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// A writable standard input whose lifetime is decoupled from the launch that
/// consumes it: the producer constructs one, hands it to a launch call as
/// `.source(_:)`, writes as its own data arrives, and closes it when there is
/// no more.
///
/// Writes are synchronous and ordered for a single producer, so one driven by
/// a callback — a `URLSession` delegate, a gRPC stream handler — writes from
/// inside the callback without hopping to another context and reordering
/// itself. Bytes written before the process launches are held and flushed at
/// launch, ahead of anything written while the launch is in progress. Two
/// producers writing concurrently get no ordering between them.
///
// SAFETY: `state` is only ever read or written inside `lock`, and the consumer
// it yields is written to after the lock is released, so no caller code runs
// under it.
// patternlint-disable-next-line unchecked-sendable
public final class InputSource: @unchecked Sendable {

  private enum State {
    /// Not yet attached to a launch: writes accumulate, an early `finish()` is
    /// remembered and delivered once there is somewhere to deliver it.
    case pending(buffered: [Data], finished: Bool)
    /// Attaching: the held bytes are being flushed, so writes queue behind them
    /// and a `finish()` waits until the flush is done. Nothing overtakes the
    /// buffered prefix.
    case flushing(FileWriter.Draining, queued: [Data], finished: Bool)
    /// Attached: writes go straight through to the pipe.
    case writing(FileWriter.Draining)
    /// End of file delivered; further writes are ignored.
    case closed
  }

  private let lock = NSLock()
  private var state: State = .pending(buffered: [], finished: false)

  public init() {}

  /// Writes `data` to the child's standard input, or holds it until the child
  /// launches. Writes after `finish()` are ignored.
  public func write(_ data: Data) {
    let writer: FileWriter.Draining? = lock.withLock {
      switch state {
      case .pending(let buffered, let finished):
        guard !finished else {
          return nil
        }
        state = .pending(buffered: buffered + [data], finished: false)
        return nil
      case .flushing(let writer, let queued, let finished):
        guard !finished else {
          return nil
        }
        state = .flushing(writer, queued: queued + [data], finished: false)
        return nil
      case .writing(let writer):
        return writer
      case .closed:
        return nil
      }
    }
    writer?.consumer.consumeData(data)
  }

  /// Writes `data` and suspends until the child's pipe has taken all of it, so a producer that
  /// awaits each write is held to the pace the child reads at rather than queueing without bound.
  /// Before launch this holds the bytes and returns at once, as `write(_:)` does. Throws if the
  /// pipe refuses the bytes, typically because the child exited without reading them.
  public func writeAndWait(_ data: Data) async throws {
    let writer: FileWriter.Draining? = lock.withLock {
      switch state {
      case .pending(let buffered, let finished):
        if !finished {
          state = .pending(buffered: buffered + [data], finished: false)
        }
        return nil
      case .flushing(let writer, let queued, let finished):
        if !finished {
          state = .flushing(writer, queued: queued + [data], finished: false)
        }
        return nil
      case .writing(let writer):
        return writer
      case .closed:
        return nil
      }
    }
    guard let writer else {
      return
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      writer.write(data) { error in
        guard error == 0 else {
          unsafe continuation.resume(throwing: SubprocessError.inputUnavailable(message: String(cString: strerror(error))))
          return
        }
        continuation.resume()
      }
    }
  }

  /// Closes the child's standard input, so that a child reading it to
  /// end-of-file completes. Idempotent.
  public func finish() {
    let writer: FileWriter.Draining? = lock.withLock {
      switch state {
      case .pending(let buffered, false):
        state = .pending(buffered: buffered, finished: true)
        return nil
      case .flushing(let writer, let queued, false):
        state = .flushing(writer, queued: queued, finished: true)
        return nil
      case .pending, .flushing, .closed:
        return nil
      case .writing(let writer):
        state = .closed
        return writer
      }
    }
    writer?.consumer.consumeEndOfFile()
  }

  /// Builds the pipe, flushes everything written so far, and returns the read
  /// end for the child. The write end is closed by the writer on end-of-file.
  func attach() throws -> Int32 {
    var descriptors: [Int32] = [0, 0]
    guard unsafe pipe(&descriptors) == 0 else {
      throw unsafe SubprocessError.inputUnavailable(message: String(cString: strerror(errno)))
    }
    let readEnd = descriptors[0]
    let writeEnd = descriptors[1]

    let writer: FileWriter.Draining
    do {
      writer = try FileWriter.drainingWriter(withFileDescriptor: writeEnd, closeOnEndOfFile: true)
    } catch {
      close(readEnd)
      close(writeEnd)
      throw SubprocessError.inputUnavailable(message: error.localizedDescription)
    }

    do {
      try lock.withLock {
        switch state {
        case .pending(let buffered, let finished):
          state = .flushing(writer, queued: buffered, finished: finished)
        case .flushing, .writing, .closed:
          throw SubprocessError.inputUnavailable(message: "this input source is already attached to a launch")
        }
      }
    } catch {
      close(readEnd)
      writer.consumer.consumeEndOfFile()
      throw error
    }

    // Drain whatever queued while the previous batch was being written, and
    // only publish the attached state once the queue is seen empty under the
    // lock, so a write racing the launch cannot overtake the held bytes.
    while true {
      let (batch, finished, drained): ([Data], Bool, Bool) = lock.withLock {
        guard case .flushing(_, let queued, let finished) = state else {
          preconditionFailure("attach() owns the flushing state until it publishes")
        }
        if queued.isEmpty {
          state = finished ? .closed : .writing(writer)
          return ([], finished, true)
        }
        state = .flushing(writer, queued: [], finished: finished)
        return (queued, finished, false)
      }
      for data in batch {
        writer.consumer.consumeData(data)
      }
      if drained {
        if finished {
          writer.consumer.consumeEndOfFile()
        }
        return readEnd
      }
    }
  }
}

extension Subprocess {

  /// Where the child's standard input comes from.
  ///
  /// As with `Output`, an `Input` is an argument to a launch call rather than
  /// stored configuration. The two empty spellings are deliberately distinct:
  /// `.closed` hands the child no descriptor at all, so a read fails with
  /// `EBADF`, while `.nullDevice` hands it an open `/dev/null`, so a read sees
  /// end-of-file.
  public struct Input: Sendable {

    enum Kind: Sendable {
      case closed
      case nullDevice
      case data(Data)
      case source(InputSource)
    }

    let kind: Kind

    private init(_ kind: Kind) {
      self.kind = kind
    }

    /// No descriptor is handed to the child: reads fail with `EBADF`. The
    /// default, and what every launch did before input was configurable.
    public static var closed: Self {
      .init(.closed)
    }

    /// The child reads an open `/dev/null`, seeing immediate end-of-file.
    public static var nullDevice: Self {
      .init(.nullDevice)
    }

    /// The child reads exactly `data`, then end-of-file.
    public static func data(_ data: Data) -> Self {
      .init(.data(data))
    }

    /// The child reads whatever `source` is written with, until it is
    /// finished.
    public static func source(_ source: InputSource) -> Self {
      .init(.source(source))
    }

    var isClosed: Bool {
      if case .closed = kind {
        return true
      }
      return false
    }

    /// The descriptor the child receives on its standard input, or nil to
    /// leave it closed. The parent's copy is closed once the child owns it.
    func resolveHost() throws -> Int32? {
      switch kind {
      case .closed:
        return nil
      case .nullDevice:
        let descriptor = unsafe open("/dev/null", O_RDONLY)
        guard descriptor >= 0 else {
          throw unsafe SubprocessError.inputUnavailable(message: String(cString: strerror(errno)))
        }
        return descriptor
      case .data(let data):
        let source = InputSource()
        source.write(data)
        source.finish()
        return try source.attach()
      case .source(let source):
        return try source.attach()
      }
    }
  }
}
