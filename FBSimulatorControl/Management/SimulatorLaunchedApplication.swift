/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Arbitrates the hand-off between the process exit source, an explicit `terminate()` and whoever
/// is waiting on the exit.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
private final class TerminationState: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var exited = false
  private var explicitlyTerminated = false

  var hasExited: Bool {
    lock.withLock { exited }
  }

  var wasExplicitlyTerminated: Bool {
    lock.withLock { explicitlyTerminated }
  }

  /// Returns false when the process had already exited, in which case there is nothing left to
  /// terminate and waiters still see a normal exit, or when another caller is already
  /// terminating it, so the kill is issued once.
  func markExplicitlyTerminated() -> Bool {
    lock.withLock {
      if exited || explicitlyTerminated {
        return false
      }
      explicitlyTerminated = true
      return true
    }
  }

  /// Undoes `markExplicitlyTerminated()` for a kill that did not happen, so an exit that
  /// follows is reported as the normal exit it is.
  func clearExplicitTermination() {
    lock.withLock { explicitlyTerminated = false }
  }

  /// Idempotent: the exit source's handler can be invoked again before the cancellation it
  /// requests takes effect.
  func markExited() {
    lock.lock()
    if exited {
      lock.unlock()
      return
    }
    exited = true
    let continuations = self.continuations
    self.continuations = []
    lock.unlock()

    for continuation in continuations {
      continuation.resume()
    }
  }

  func waitForExit() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if exited {
        lock.unlock()
        continuation.resume()
        return
      }
      continuations.append(continuation)
      lock.unlock()
    }
  }
}

public final class SimulatorLaunchedApplication: LaunchedApplication, CustomStringConvertible, Sendable {

  public let configuration: ApplicationLaunchConfiguration
  public let processIdentifier: pid_t

  // MARK: - Private Properties

  private let terminator: ProcessTerminator
  private let state: TerminationState
  private let terminationTask: Task<Void, Never>
  private let terminationFinished: AsyncEvent<Void>

  // MARK: - LaunchedApplication Protocol

  public var bundleID: String {
    configuration.bundleID
  }

  /// Waits for the process to exit and its output to drain. Cancelling a wait throws
  /// `CancellationError`, even after the exit, and leaves the exit observer and output drain
  /// running for other waiters.
  public func waitForTermination() async throws {
    try Task.checkCancellation()
    try await terminationFinished.wait()
    try Task.checkCancellation()
    // An explicit `terminate()` is reported as a cancellation rather than as an observed exit.
    if state.wasExplicitlyTerminated {
      throw CancellationError()
    }
  }

  public func terminate() async throws {
    guard state.markExplicitlyTerminated() else {
      await terminationTask.value
      return
    }
    do {
      try await terminator.terminate(processIdentifier)
    } catch {
      state.clearExplicitTermination()
      throw error
    }
    await terminationTask.value
  }

  // MARK: - Initializers

  public init(
    simulator: Simulator,
    configuration: ApplicationLaunchConfiguration,
    outputs: [FileBackedOutput],
    processIdentifier: pid_t
  ) {
    let state = TerminationState()
    let terminationFinished = AsyncEvent<Void>()
    self.configuration = configuration
    self.processIdentifier = processIdentifier
    self.state = state
    self.terminationFinished = terminationFinished
    self.terminator = ProcessTerminator(
      processFetcher: ProcessFetcher(),
      workQueue: simulator.workQueue,
      logger: simulator.logger)
    // Armed before the task so that a `terminate()` racing construction cannot signal the process
    // before anything is watching for its exit.
    Self.armExitSource(forProcessIdentifier: processIdentifier, state: state)
    self.terminationTask = Task {
      await state.waitForExit()
      for output in outputs {
        await output.finish()
      }
      terminationFinished.happen()
    }
  }

  private static func armExitSource(forProcessIdentifier processIdentifier: pid_t, state: TerminationState) {
    let queue = DispatchQueue(label: "com.facebook.fbsimulatorcontrol.application_termination_notifier")
    let source = DispatchSource.makeProcessSource(
      identifier: processIdentifier,
      eventMask: .exit,
      queue: queue
    )
    source.setEventHandler {
      source.cancel()
      state.markExited()
    }
    source.resume()
  }

  public var description: String {
    "Application Operation \(configuration.description) | pid \(processIdentifier) | Exited \(state.hasExited)"
  }
}
