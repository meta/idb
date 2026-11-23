/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Dispatch
import Foundation

/// Launches `idb_companion` processes.
public struct CompanionSpawner {
  private let paths: CompanionPaths
  private let companionPath: String
  private let deviceSetPath: String?
  /// Seconds to wait for the companion to print its startup line.
  private let readinessTimeout: TimeInterval

  /// `paths.version` selects how the companion is launched and where it logs; `companionPath` is
  /// `idb_companion` for v1, `idb2` for v2.
  public init(paths: CompanionPaths = CompanionPaths(), companionPath: String, deviceSetPath: String? = nil, readinessTimeout: TimeInterval = 30) {
    self.paths = paths
    self.companionPath = companionPath
    self.deviceSetPath = deviceSetPath
    self.readinessTimeout = readinessTimeout
  }

  /// Spawns a companion for `udid` bound to `path`, returning a record for it
  /// only after the companion reports the bound socket path on stdout — so a
  /// caller can connect without racing the bind. When `idleShutdownTime` is set,
  /// a v1 companion is launched with `--idle-shutdown-time` so it exits after that
  /// many seconds of gRPC inactivity (not yet supported for v2).
  ///
  /// - Note: For v2, `idb2 companion` detaches itself (it calls `setsid()`), so it
  ///   outlives this process and is not killed by terminal signals delivered to
  ///   this process's group. The v1 `idb_companion` is not detached by the spawner;
  ///   it survives a normal exit of this process but would receive such signals.
  func spawnDomainSocketServer(udid: String, only: String? = nil, path: String, idleShutdownTime: Int? = nil) async throws -> CompanionInfo {
    try paths.ensureLogsDirectory()
    let logPath = paths.logFilePath(forUDID: udid)
    let logHandle = try appendHandle(forPath: logPath)
    defer { try? logHandle.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: companionPath)
    process.arguments = launchArguments(udid: udid, only: only, path: path, idleShutdownTime: idleShutdownTime)
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = logHandle

    do {
      try process.run()
    } catch {
      throw CompanionDiscoveryError.spawnFailed(reason: "\(error). \(logTail(logPath))")
    }

    let line: String
    do {
      line = try await readFirstLine(from: stdoutPipe.fileHandleForReading, timeout: readinessTimeout)
    } catch {
      process.terminate()
      throw CompanionDiscoveryError.companionNotReady(reason: "couldn't read startup report. \(logTail(logPath))")
    }

    guard let reportedPath = parseReportedSocketPath(from: line) else {
      process.terminate()
      throw CompanionDiscoveryError.companionNotReady(reason: "no socket path in startup report '\(line)'. \(logTail(logPath))")
    }
    guard reportedPath == path else {
      process.terminate()
      throw CompanionDiscoveryError.socketPathMismatch(expected: path, actual: reportedPath)
    }

    return CompanionInfo(udid: udid, isLocal: true, pid: process.processIdentifier, address: .domainSocket(path: path))
  }

  // MARK: - Helpers

  /// Builds the argv to launch the companion for `paths.version`.
  private func launchArguments(udid: String, only: String?, path: String, idleShutdownTime: Int?) -> [String] {
    switch paths.version {
    case .v1:
      // idb_companion binds the socket path we hand it and reports it back.
      var arguments = ["--udid", udid, "--grpc-domain-sock", path]
      arguments += onlyArguments(only)
      if let deviceSetPath {
        arguments += ["--device-set-path", deviceSetPath]
      }
      if let idleShutdownTime {
        arguments += ["--idle-shutdown-time", "\(idleShutdownTime)"]
      }
      return arguments
    case .v2:
      // idb2 derives its own socket path from the udid and the v2 layout and
      // prints it back, so it takes no --grpc-domain-sock. --idle-shutdown-time
      // goes after the `companion` subcommand; --only / --device-set-path are not
      // supported yet.
      var arguments = ["--udid", udid, "companion"]
      if let idleShutdownTime {
        arguments += ["--idle-shutdown-time", "\(idleShutdownTime)"]
      }
      return arguments
    }
  }

  /// Extracts the bound socket path from the companion's first stdout line: v1
  /// emits a JSON `{"grpc_path": "..."}` report; v2 emits the bare path. Returns
  /// nil if the line carries no usable path.
  private func parseReportedSocketPath(from line: String) -> String? {
    switch paths.version {
    case .v1:
      guard let report = parseJSONObject(line), let grpcPath = report["grpc_path"] as? String, !grpcPath.isEmpty else {
        return nil
      }
      return grpcPath
    case .v2:
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  /// A `mac` target takes no filter; others map to `--only <value>`. nil means
  /// "search all target sets".
  private func onlyArguments(_ only: String?) -> [String] {
    guard let only, !only.isEmpty, only != "mac" else {
      return []
    }
    return ["--only", only]
  }

  private func appendHandle(forPath path: String) throws -> FileHandle {
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try handle.seekToEnd()
    return handle
  }
}

/// Reads a single newline-terminated line from `handle`, returning its content
/// without the trailing newline. Throws if no line arrives within `timeout`, or
/// if EOF is reached before any bytes are read.
private func readFirstLine(from handle: FileHandle, timeout: TimeInterval) async throws -> String {
  let state = LineReadState()
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      state.begin(handle: handle, timeout: timeout, continuation: continuation)
    }
  } onCancel: {
    state.cancel()
  }
}

/// Drives reading a single line from a `FileHandle` and bridges it to a
/// continuation. Bytes are delivered by the handle's readability handler (so no
/// thread is parked on the read) and a timer enforces the timeout. A lock
/// serialises the handler, the timer, and cancellation so the continuation is
/// resumed exactly once and the read is always torn down afterwards.
private final class LineReadState: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = [UInt8]()
  private var continuation: CheckedContinuation<String, any Error>?
  private var handle: FileHandle?
  private var timer: (any DispatchSourceTimer)?
  private var cancelled = false

  /// Starts the read and the timeout timer. If cancellation already happened,
  /// resumes immediately instead.
  func begin(handle: FileHandle, timeout: TimeInterval, continuation: CheckedContinuation<String, any Error>) {
    lock.lock()
    defer { lock.unlock() }
    if cancelled {
      continuation.resume(throwing: CancellationError())
      return
    }
    self.handle = handle
    self.continuation = continuation

    let timer = DispatchSource.makeTimerSource()
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { [weak self] in
      self?.finish(.failure(CompanionDiscoveryError.companionNotReady(reason: "timed out after \(Int(timeout))s")))
    }
    self.timer = timer

    handle.readabilityHandler = { [weak self] fileHandle in
      self?.consume(fileHandle.availableData)
    }
    timer.resume()
  }

  /// Stops the read and resumes with a cancellation error if still pending.
  func cancel() {
    finish(.failure(CancellationError()))
  }

  private func consume(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard continuation != nil else { return }
    if chunk.isEmpty {
      // EOF: the process closed stdout before a full line.
      finishLocked(
        bytes.isEmpty
          ? .failure(CompanionDiscoveryError.companionNotReady(reason: "no output"))
          : .success(String(decoding: bytes, as: UTF8.self)))
      return
    }
    for byte in chunk {
      if byte == UInt8(ascii: "\n") {
        finishLocked(.success(String(decoding: bytes, as: UTF8.self)))
        return
      }
      bytes.append(byte)
    }
  }

  /// Finishes the read (also closing the cancel-before-`begin` race) and resumes
  /// with `result` if still pending.
  private func finish(_ result: Result<String, any Error>) {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
    finishLocked(result)
  }

  /// Resumes the continuation at most once and tears down the timer and reader so
  /// nothing is left running. The caller must hold `lock`.
  private func finishLocked(_ result: Result<String, any Error>) {
    timer?.cancel()
    timer = nil
    handle?.readabilityHandler = nil
    handle = nil
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(with: result)
  }
}

/// A single JSON object line as a dictionary, or nil if it is not one.
private func parseJSONObject(_ line: String) -> [String: Any]? {
  guard let data = line.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else {
    return nil
  }
  return object
}

/// Up to the last `count` lines of the file at `path`, for error context.
private func logTail(_ path: String, count: Int = 30) -> String {
  guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
    return ""
  }
  let tail = contents.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
  return tail.isEmpty ? "" : "stderr:\n\(tail)"
}
