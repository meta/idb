/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation

enum ProcessFetcherError: Error, LocalizedError {
  case processInfoUnavailable(processIdentifier: pid_t)
  case stackshotFailed(processIdentifier: pid_t, underlying: any Error)

  var errorDescription: String? {
    switch self {
    case let .processInfoUnavailable(processIdentifier):
      return "Failed fetching process info for (pid \(processIdentifier))"
    case let .stackshotFailed(processIdentifier, underlying):
      return "Failed to obtain a stack sample of process \(processIdentifier): \(underlying.localizedDescription)"
    }
  }
}

/// Queries for processes running on the host. Buffers are re-used across calls, so the
/// queries serialise on a lock and one fetcher can be shared across tasks.
///
/// Not final: tests substitute the process table by overriding the queries.
///
// @safe: The buffers are allocated in `init`, freed in `deinit` and never handed out.
// SAFETY: the buffers are only ever touched inside `lock`, and everything else is immutable.
// patternlint-disable-next-line unchecked-sendable
@safe public class ProcessFetcher: @unchecked Sendable {

  /// `KERN_ARGMAX`, the largest argument block the kernel will report.
  private static let maxArgumentBufferSize: Int = {
    var argmax = 0
    var size = MemoryLayout<Int>.stride
    var name: [Int32] = [CTL_KERN, KERN_ARGMAX]
    if unsafe sysctl(&name, 2, &argmax, &size, nil, 0) == 0, argmax > 0 {
      return argmax
    }
    return Int(ARG_MAX)
  }()

  // From 'ulimit -u', but twice as large.
  private static let maxPidCount = 5568 * 2

  private let lock = NSLock()
  private let argumentBuffer: UnsafeMutablePointer<CChar>
  private let argumentBufferSize: Int
  private let pidBuffer: UnsafeMutablePointer<pid_t>
  private let pidCount: Int

  public init() {
    argumentBufferSize = Self.maxArgumentBufferSize
    unsafe argumentBuffer = .allocate(capacity: argumentBufferSize)
    pidCount = Self.maxPidCount
    unsafe pidBuffer = .allocate(capacity: pidCount)
  }

  deinit {
    unsafe argumentBuffer.deallocate()
    unsafe pidBuffer.deallocate()
  }

  // MARK: - Queries

  /// All of the process information for `processIdentifier`, or nil if no such process could be found.
  public func processInfo(for processIdentifier: pid_t) -> RunningProcessInfo? {
    lock.withLock { readProcessInfo(for: processIdentifier) }
  }

  /// The processes named `processName`.
  public func processes(withProcessName processName: String) -> [RunningProcessInfo] {
    lock.withLock {
      let count = unsafe proc_listallpids(pidBuffer, Int32(pidCount * MemoryLayout<pid_t>.stride))
      if count < 1 {
        return []
      }
      var processes: [RunningProcessInfo] = []
      for index in 0..<Int(count) {
        let processIdentifier = unsafe pidBuffer[index]
        guard unsafe proc_name(processIdentifier, argumentBuffer, UInt32(argumentBufferSize)) > 1 else {
          continue
        }
        guard unsafe String(cString: argumentBuffer) == processName else {
          continue
        }
        guard let info = readProcessInfo(for: processIdentifier) else {
          continue
        }
        processes.append(info)
      }
      return processes
    }
  }

  /// Whether the process is in the `SRUN` state. Throws if the process cannot be looked up.
  public func isProcessRunning(_ processIdentifier: pid_t) throws -> Bool {
    unsafe try Int32(kernelInfo(for: processIdentifier).kp_proc.p_stat) == SRUN
  }

  /// Whether the process is in the `SSTOP` state. Throws if the process cannot be looked up.
  public func isProcessStopped(_ processIdentifier: pid_t) throws -> Bool {
    unsafe try Int32(kernelInfo(for: processIdentifier).kp_proc.p_stat) == SSTOP
  }

  /// Whether a tracer is attached to the process. Throws if the process cannot be looked up.
  public func isDebuggerAttached(to processIdentifier: pid_t) throws -> Bool {
    let info = unsafe try kernelInfo(for: processIdentifier)
    // When a tracer attaches, the tracee's parent becomes the tracer and the original parent moves to `p_oppid`.
    return unsafe info.kp_proc.p_oppid != 0 && info.kp_eproc.e_ppid != info.kp_proc.p_oppid
  }

  // MARK: - Reading

  /// Callers hold `lock`.
  private func readProcessInfo(for processIdentifier: pid_t) -> RunningProcessInfo? {
    // Much of the layout information here comes from libtop.c in Apple's top(1) Open Source implementation.
    var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
    var size = argumentBufferSize
    guard unsafe sysctl(&name, 3, argumentBuffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    let bytes = unsafe UnsafeRawBufferPointer(start: argumentBuffer, count: size)
    let argc = unsafe Int(bytes.loadUnaligned(as: Int32.self))
    if argc < 1 {
      return nil
    }

    var position = MemoryLayout<Int32>.size
    func readString() -> String? {
      guard position < bytes.count else {
        return nil
      }
      let start = position
      while position < bytes.count, unsafe bytes[position] != 0 {
        position += 1
      }
      let string = unsafe String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
      position += 1
      return string
    }

    // The launch path starts above argc, then padding runs up to argv.
    guard let launchPath = readString() else {
      return nil
    }
    while position < bytes.count, unsafe bytes[position] == 0 {
      position += 1
    }

    var arguments: [String] = []
    for _ in 0..<argc {
      guard let argument = readString() else {
        break
      }
      arguments.append(argument)
    }

    // The environment follows argv, ending at an empty string.
    var environment: [String: String] = [:]
    while position < bytes.count, unsafe bytes[position] != 0, let entry = readString() {
      let tokens = entry.components(separatedBy: "=")
      if tokens.count != 2 {
        break
      }
      environment[tokens[0]] = tokens[1]
    }

    return RunningProcessInfo(
      processIdentifier: processIdentifier,
      launchPath: launchPath,
      arguments: arguments,
      environment: environment
    )
  }

  // MARK: - Waits

  /// Waits for a debugger to attach to the process and for the process to be running again.
  /// Throws if the process cannot be looked up.
  public static func waitForDebuggerToAttachAndContinue(for processIdentifier: pid_t) async throws {
    let fetcher = ProcessFetcher()
    try await pollUntilTrue(on: .global()) {
      try fetcher.isDebuggerAttached(to: processIdentifier) && fetcher.isProcessRunning(processIdentifier)
    }
  }

  /// Waits for the process to enter the `SSTOP` state. Throws if the process cannot be looked up.
  public static func waitForStopSignal(process processIdentifier: pid_t) async throws {
    let fetcher = ProcessFetcher()
    try await pollUntilTrue(on: .global()) {
      try fetcher.isProcessStopped(processIdentifier)
    }
  }

  /// Samples the process with `/usr/bin/sample`, returning the report text. The process is left running.
  public static func sampleStackshot(processIdentifier: pid_t) async throws -> String {
    do {
      return try await Subprocess(executable: "/usr/bin/sample", arguments: [String(processIdentifier), String(sampleDuration)])
        .run(exitPolicy: .any)
        .standardOutput
    } catch {
      throw ProcessFetcherError.stackshotFailed(processIdentifier: processIdentifier, underlying: error)
    }
  }

  // MARK: - Private

  private static let sampleDuration = 1

  private func kernelInfo(for processIdentifier: pid_t) throws -> kinfo_proc {
    var info = unsafe kinfo_proc()
    var size = unsafe MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
    guard unsafe sysctl(&name, 4, &info, &size, nil, 0) == 0, unsafe info.kp_proc.p_pid == processIdentifier else {
      throw ProcessFetcherError.processInfoUnavailable(processIdentifier: processIdentifier)
    }
    return unsafe info
  }
}
