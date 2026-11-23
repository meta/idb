/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// The native host engine behind `Subprocess.run`: `posix_spawn` with every
/// descriptor not explicitly mapped closed in the child and all signals reset
/// to their defaults, exit observed through a process dispatch source that
/// reaps with `waitpid`.
enum HostSubprocess {

  /// How long to keep draining an output pipe after the process has exited
  /// before giving up on end-of-file.
  static let drainTimeout: TimeInterval = 4

  static func spawn(
    executable: String,
    arguments: [String],
    environment: [String: String],
    standardInput: Int32?,
    standardOutput: Int32?,
    standardError: Int32?
  ) throws -> pid_t {
    var fileActions: posix_spawn_file_actions_t?
    unsafe try checked(posix_spawn_file_actions_init(&fileActions), executable)
    defer { unsafe posix_spawn_file_actions_destroy(&fileActions) }
    if let standardInput {
      unsafe try checked(posix_spawn_file_actions_adddup2(&fileActions, standardInput, STDIN_FILENO), executable)
    }
    if let standardOutput {
      unsafe try checked(posix_spawn_file_actions_adddup2(&fileActions, standardOutput, STDOUT_FILENO), executable)
    }
    if let standardError {
      unsafe try checked(posix_spawn_file_actions_adddup2(&fileActions, standardError, STDERR_FILENO), executable)
    }

    var attributes: posix_spawnattr_t?
    unsafe try checked(posix_spawnattr_init(&attributes), executable)
    defer { unsafe posix_spawnattr_destroy(&attributes) }
    var signals = sigset_t()
    unsafe sigemptyset(&signals)
    unsafe try checked(posix_spawnattr_setsigmask(&attributes, &signals), executable)
    unsafe sigfillset(&signals)
    unsafe try checked(posix_spawnattr_setsigdefault(&attributes, &signals), executable)
    unsafe try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)), executable)

    var processIdentifier: pid_t = 0
    let status = unsafe withCStringArray([executable] + arguments) { argv in
      unsafe withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { envp in
        unsafe posix_spawn(&processIdentifier, executable, &fileActions, &attributes, argv, envp)
      }
    }
    guard status == 0 else {
      throw unsafe SubprocessError.launchFailed(executable: executable, message: String(cString: strerror(status)))
    }
    return processIdentifier
  }

  /// The spawn helpers return an error number rather than setting `errno`. An
  /// unchecked failure would leave the child with a partially applied set of
  /// file actions or attributes — the wrong descriptors on its streams, or an
  /// inherited signal disposition — instead of a launch that failed.
  private static func checked(_ result: Int32, _ executable: String) throws {
    guard result == 0 else {
      throw unsafe SubprocessError.launchFailed(executable: executable, message: String(cString: strerror(result)))
    }
  }

  /// Waits for `processIdentifier` to exit and returns the raw `wait(2)`
  /// status word. Not a cancellation point: the exit monitor that calls this
  /// must always reap, whatever happens to the tasks observing it.
  ///
  /// The event handler deliberately holds the only strong reference to its
  /// dispatch source and cancels it after the event fires. Weakening that
  /// capture deallocates the source before the exit arrives, `waitpid` never
  /// runs, and the wait never resolves — do not "fix" the cycle.
  static func exitStatLoc(of processIdentifier: pid_t, logger: (any ControlCoreLogger)?) async -> Int32 {
    await withCheckedContinuation { continuation in
      let queue = DispatchQueue(label: "com.facebook.fbcontrolcore.subprocess.wait")
      let source = DispatchSource.makeProcessSource(identifier: processIdentifier, eventMask: .exit, queue: queue)
      source.setEventHandler {
        var statLoc: Int32 = 0
        // The event means the child is already a zombie, so the reap returns
        // it. Anything else leaves the status word at zero, which decodes as
        // a clean exit — a failed reap must not be mistaken for one, so it
        // falls back to a blocking wait before giving up.
        var reaped = unsafe waitpid(processIdentifier, &statLoc, WNOHANG)
        if reaped == 0 {
          reaped = unsafe waitpid(processIdentifier, &statLoc, 0)
        }
        if reaped != processIdentifier {
          logger?.log(unsafe "Failed to get the exit status with waitpid: \(String(cString: strerror(errno)))")
        }
        continuation.resume(returning: statLoc)
        source.cancel()
      }
      source.resume()
    }
  }
}

private func withCStringArray<Result>(
  _ strings: [String],
  _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
  var pointers: [UnsafeMutablePointer<CChar>?] = unsafe strings.map { unsafe strdup($0) }
  unsafe pointers.append(nil)
  defer {
    // swift-format would join `for unsafe` into one word.
    // swift-format-ignore
    for unsafe pointer in unsafe pointers {
      unsafe free(pointer)
    }
  }
  return unsafe body(&pointers)
}

/// One resolved output stream of a host launch: the descriptor the child
/// receives, and the reader draining the parent's end where one exists.
struct HostSink {
  /// Duplicated onto the child's stream by the spawn; nil leaves the child's
  /// descriptor closed. The parent's copy must be closed once the child owns
  /// it, so that end-of-file on the drain is driven solely by the child
  /// exiting.
  private(set) var childDescriptor: Int32?
  let reader: DescriptorReader?
  /// The parent's end of an undrained pipe, owned by the caller once the
  /// launch succeeds and closed here only if it fails.
  var parentDescriptor: Int32?

  mutating func closeChildDescriptor() {
    if let childDescriptor {
      close(childDescriptor)
    }
    childDescriptor = nil
  }

  mutating func dispose() {
    closeChildDescriptor()
    if let parentDescriptor {
      close(parentDescriptor)
    }
    parentDescriptor = nil
    reader?.stop()
  }
}

extension Subprocess.Output {

  /// Resolves the capture into the descriptor and drain for a host launch,
  /// paired with a reader for the captured value once the drain completes.
  func resolveHost() throws -> (sink: HostSink, capture: () -> Captured) {
    switch kind {
    case .closed:
      return (HostSink(childDescriptor: nil, reader: nil), { Self.captured(()) })
    case .nullDevice:
      return (HostSink(childDescriptor: try Self.openSink(at: "/dev/null"), reader: nil), { Self.captured(()) })
    case .file(let url):
      return (HostSink(childDescriptor: try Self.openSink(at: url.path), reader: nil), { Self.captured(url) })
    case .consumer(let consumer):
      return (try Self.drainedSink(into: consumer, logger: nil), { Self.captured(()) })
    case .logger(let logger):
      return (try Self.drainedSink(into: LoggingDataConsumer(logger: logger), logger: nil), { Self.captured(()) })
    case .loggerCapturingErrorMessage(let logger):
      let buffer = AccumulatingBuffer(capacity: Subprocess.errorMessageLength)
      // Lossy, because the tail can begin mid-character, and one invalid byte would otherwise empty the whole message.
      return (try Self.drainedSink(into: buffer, logger: logger), { Self.captured(Self.string(from: buffer.data(), lossy: true)) })
    case .pipe:
      var descriptors: [Int32] = [0, 0]
      guard unsafe Darwin.pipe(&descriptors) == 0 else {
        throw unsafe SubprocessError.outputUnavailable(path: "pipe", message: String(cString: strerror(errno)))
      }
      return (HostSink(childDescriptor: descriptors[1], reader: nil, parentDescriptor: descriptors[0]), { Self.captured(descriptors[0]) })
    case .lines(let sink):
      // The descriptor reader is the output-drained barrier. A separate delivery
      // queue would let termination overtake callbacks that are still pending.
      let consumer = LineConsumer(delivery: .synchronous, consumer: sink)
      return (try Self.drainedSink(into: consumer, logger: nil), { Self.captured(()) })
    case .data:
      let buffer = AccumulatingBuffer()
      let sink = try Self.drainedSink(into: buffer, logger: nil)
      return (sink, { Self.captured(buffer.data()) })
    case .string:
      let buffer = AccumulatingBuffer()
      let sink = try Self.drainedSink(into: buffer, logger: nil)
      return (sink, { Self.captured(Self.string(from: buffer.data())) })
    }
  }

  /// The engine's string capture has always stripped exactly one trailing
  /// newline byte, and decoded invalid UTF-8 to the empty string unless
  /// `lossy`.
  private static func string(from data: Data, lossy: Bool = false) -> String {
    var data = data
    if data.last == UInt8(ascii: "\n") {
      data.removeLast()
    }
    return lossy ? String(decoding: data, as: UTF8.self) : String(data: data, encoding: .utf8) ?? ""
  }

  /// Opens without `O_TRUNC`, as the engine always has; the explicit mode is
  /// new — the engine omits one, leaving created files with undefined
  /// permissions.
  private static func openSink(at path: String) throws -> Int32 {
    let descriptor = unsafe open(path, O_WRONLY | O_CREAT, 0o644)
    guard descriptor >= 0 else {
      throw unsafe SubprocessError.outputUnavailable(path: path, message: String(cString: strerror(errno)))
    }
    return descriptor
  }

  private static func drainedSink(into consumer: any DataConsumer, logger: (any ControlCoreLogger)?) throws -> HostSink {
    var descriptors: [Int32] = [0, 0]
    guard unsafe Darwin.pipe(&descriptors) == 0 else {
      throw unsafe SubprocessError.outputUnavailable(path: "pipe", message: String(cString: strerror(errno)))
    }
    let composed: any DataConsumer
    if let logger {
      composed = CompositeDataConsumer(consumers: [consumer, LoggingDataConsumer(logger: logger)])
    } else {
      composed = consumer
    }
    let reader = DescriptorReader(fileDescriptor: descriptors[0], closeOnEndOfFile: true, consumer: composed)
    return HostSink(childDescriptor: descriptors[1], reader: reader)
  }
}
