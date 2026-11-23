/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// An output stream handed to a process by path rather than by descriptor,
/// for launches that only accept a path — CoreSimulator's application launch
/// options, or a report channel named in the environment. The path exists
/// before the process starts.
///
/// A `.fifo(draining:)` output starts draining as soon as it is created, so
/// a writer opening the path never blocks waiting for a reader. It holds a
/// write end of its own until `finish()`, so the drain reaches end-of-file
/// only once `finish()` has been called and every writer the process opened
/// has closed; a process that never opens the path, or opens it more than
/// once, is drained all the same. Releasing an output without finishing it
/// removes the FIFO and ends the consumer straight away.
public final class FileBackedOutput: Sendable {

  /// The path the process writes to.
  public let path: String

  private let drain: FifoDrain?

  private init(path: String, drain: FifoDrain?) {
    self.path = path
    self.drain = drain
  }

  /// The process writes straight to the file at `path`; there is nothing to
  /// drain.
  public static func file(_ path: String) -> FileBackedOutput {
    FileBackedOutput(path: path, drain: nil)
  }

  /// The process writes to an open `/dev/null`.
  public static var nullDevice: FileBackedOutput {
    .file("/dev/null")
  }

  /// The process writes to a FIFO whose contents are forwarded to `consumer`
  /// as they arrive, followed by end-of-file once `finish()` completes.
  public static func fifo(draining consumer: any DataConsumer) throws -> FileBackedOutput {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
    guard unsafe mkfifo(path, S_IRUSR | S_IWUSR) == 0 else {
      throw unsafe SubprocessError.outputUnavailable(path: path, message: String(cString: strerror(errno)))
    }
    // Opening the read end blocks until there is a writer unless it is
    // non-blocking; once it is open, the write end can open without blocking.
    let readEnd = unsafe open(path, O_RDONLY | O_NONBLOCK)
    guard readEnd >= 0 else {
      let message = unsafe String(cString: strerror(errno))
      unsafe unlink(path)
      throw SubprocessError.outputUnavailable(path: path, message: message)
    }
    let keepAlive = unsafe open(path, O_WRONLY)
    guard keepAlive >= 0 else {
      let message = unsafe String(cString: strerror(errno))
      close(readEnd)
      unsafe unlink(path)
      throw SubprocessError.outputUnavailable(path: path, message: message)
    }
    let flags = fcntl(readEnd, F_GETFL)
    guard flags >= 0, fcntl(readEnd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
      let message = unsafe String(cString: strerror(errno))
      close(keepAlive)
      close(readEnd)
      unsafe unlink(path)
      throw SubprocessError.outputUnavailable(path: path, message: message)
    }
    return FileBackedOutput(path: path, drain: FifoDrain(readEnd: readEnd, keepAlive: keepAlive, consumer: consumer))
  }

  /// Waits for the drain to deliver everything the process wrote, then
  /// removes the FIFO. Call once the process has exited: a writer that is
  /// still running is given the same bounded grace as a host launch's output
  /// pipe, after which the consumer is ended and later output is dropped.
  public func finish() async {
    guard let drain else {
      return
    }
    await drain.finish(within: HostSubprocess.drainTimeout)
    unsafe unlink(path)
  }

  deinit {
    guard let drain else {
      return
    }
    drain.abandon()
    unsafe unlink(path)
  }
}

/// Drains a FIFO with blocking reads on a thread of its own. Neither kqueue
/// nor `poll(2)` reports end-of-file on a FIFO once a writer has opened it
/// after the reader started waiting, so `DispatchIO` and read sources never
/// see the process close it; a blocked `read(2)` is woken by the last close.
///
// SAFETY: every mutable property is only read or written on `queue`, which
// also serialises every call to `consumer`.
// patternlint-disable-next-line unchecked-sendable
private final class FifoDrain: @unchecked Sendable {

  private let queue = DispatchQueue(label: "com.facebook.fbcontrolcore.fifodrain")
  private let consumer: any DataConsumer
  private var keepAlive: Int32?
  private var ended = false
  private let drained = AsyncEvent<Void>()

  init(readEnd: Int32, keepAlive: Int32, consumer: any DataConsumer) {
    self.keepAlive = keepAlive
    self.consumer = consumer
    let thread = Thread { [self] in
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while true {
        let count = unsafe read(readEnd, &buffer, buffer.count)
        if count < 0 && errno == EINTR {
          continue
        }
        guard count > 0 else {
          break
        }
        let data = Data(buffer[0..<count])
        queue.async { [self] in
          if !ended {
            consumer.consumeData(data)
          }
        }
      }
      close(readEnd)
      queue.async { [self] in
        end()
      }
    }
    thread.name = "com.facebook.fbcontrolcore.fifodrain"
    thread.start()
  }

  func finish(within grace: TimeInterval) async {
    await withTaskCancellationHandler {
      queue.async { [self] in
        closeKeepAlive()
        guard !ended else {
          return
        }
        queue.asyncAfter(deadline: .now() + grace) { [self] in
          end()
        }
      }
      // Never fails: the drain only ever happens.
      _ = try? await drained.waitIgnoringCancellation()
    } onCancel: {
      queue.async { [self] in
        end()
      }
    }
  }

  /// Gives up on the drain without waiting, for an output released without
  /// being finished.
  func abandon() {
    queue.async { [self] in
      closeKeepAlive()
      end()
    }
  }

  private func closeKeepAlive() {
    if let keepAlive {
      close(keepAlive)
      self.keepAlive = nil
    }
  }

  /// Delivers end-of-file, once, and releases every waiter: at the FIFO's
  /// end-of-file, or when the drain is abandoned. An abandoned drain's thread
  /// stays blocked until its last writer closes, and delivers nothing more.
  private func end() {
    if !ended {
      ended = true
      consumer.consumeEndOfFile()
    }
    drained.happen()
  }
}
