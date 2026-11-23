/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBControlCore
import Foundation
import Testing

/// Reports every process as absent, so the existence check fails before any signal is sent.
// SAFETY: Adds no state to `ProcessFetcher`, whose `@unchecked Sendable` conformance a subclass must restate.
// patternlint-disable-next-line unchecked-sendable
private final class AbsentProcessFetcher: ProcessFetcher, @unchecked Sendable {
  override func processInfo(for processIdentifier: pid_t) -> RunningProcessInfo? {
    nil
  }
}

@Suite(.serialized)
final class ProcessTerminatorTests {

  /// Beyond the default `kern.maxproc`, so no process can ever hold it and `kill` fails with ESRCH.
  private let unallocatablePID: pid_t = 999_999

  private let logger = ControlCoreLoggerDouble()
  private var spawned: [Process] = []

  deinit {
    for process in spawned where process.isRunning {
      process.terminate()
    }
  }

  // MARK: - Helpers

  /// A process that blocks on a pipe it will never be written to, so it only leaves the process
  /// table when signalled.
  private func spawnBlockedProcess() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/cat")
    process.standardInput = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    spawned.append(process)
    return process
  }

  private func terminator(
    signo: Int32 = SIGKILL,
    options: ProcessTerminator.Options,
    processFetcher: ProcessFetcher = ProcessFetcher()
  ) -> ProcessTerminator {
    ProcessTerminator(
      configuration: ProcessTerminator.Configuration(signo: signo, options: options),
      processFetcher: processFetcher,
      workQueue: DispatchQueue(label: "com.facebook.fbcontrolcore.termination_strategy_tests"),
      logger: logger)
  }

  private func terminationError(_ error: Error) -> ProcessTerminatorError? {
    error as? ProcessTerminatorError
  }

  // MARK: - Tests

  @Test
  func failsWithoutSignallingWhenTheProcessIsNotFound() async throws {
    let process = try spawnBlockedProcess()
    let terminator = terminator(options: [.checkProcessExistsBeforeSignal], processFetcher: AbsentProcessFetcher())

    do {
      try await terminator.terminate(process.processIdentifier)
      Issue.record("Expected the kill to fail for a process the fetcher does not report")
    } catch {
      guard case .processDoesNotExist(let processIdentifier)? = terminationError(error) else {
        Issue.record("Unexpected error \(error)")
        return
      }
      #expect(processIdentifier == process.processIdentifier)
    }

    #expect(process.isRunning)
  }

  @Test
  func failsWhenTheSignalCannotBeDelivered() async throws {
    let terminator = terminator(options: [])

    do {
      try await terminator.terminate(unallocatablePID)
      Issue.record("Expected the kill of an unallocatable process identifier to fail")
    } catch {
      guard case .killFailed(let processIdentifier, _)? = terminationError(error) else {
        Issue.record("Unexpected error \(error)")
        return
      }
      #expect(processIdentifier == unallocatablePID)
    }
  }

  @Test
  func signalsWithoutWaitingWhenDeathIsNotChecked() async throws {
    let process = try spawnBlockedProcess()
    let terminator = terminator(options: [])

    try await terminator.terminate(process.processIdentifier)

    process.waitUntilExit()
    #expect(process.terminationReason == .uncaughtSignal)
  }

  @Test
  func resolvesOnceTheProcessLeavesTheProcessTable() async throws {
    let process = try spawnBlockedProcess()
    let terminator = terminator(options: [.checkProcessExistsBeforeSignal, .checkDeathAfterSignal])
    // The signalled child is a zombie — and so still in the process table — until it is reaped.
    DispatchQueue.global().async {
      process.waitUntilExit()
    }

    try await terminator.terminate(process.processIdentifier)

    #expect(ProcessFetcher().processInfo(for: process.processIdentifier) == nil)
  }
}
