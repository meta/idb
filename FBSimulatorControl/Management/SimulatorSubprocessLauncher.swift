/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation

/// Spawns inside a simulator with `SimDevice`.
///
/// `SimDevice` addresses stdout and stderr by descriptor but has no way of
/// connecting a stdin, so only a `.closed` input is accepted.
public struct SimulatorSubprocessLauncher: SubprocessLauncher {

  let simulator: Simulator

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  public var supportsStandardInput: Bool {
    false
  }

  public func spawn(
    _ subprocess: Subprocess,
    standardInput: Int32?,
    standardOutput: Int32?,
    standardError: Int32?,
    logger: (any ControlCoreLogger)?
  ) async throws -> LaunchedProcess {
    let options = Self.simDeviceLaunchOptions(
      withSimulator: simulator,
      launchPath: subprocess.executable,
      arguments: subprocess.arguments,
      // Nothing of this process's environment belongs inside the simulator, so
      // the inheriting cases resolve to nothing and only explicit variables pass.
      environment: subprocess.environment.resolved(against: [:]),
      waitForDebugger: false,
      standardOutput: standardOutput,
      standardError: standardError,
      mode: subprocess.mode)
    let exit = SimulatorExit()
    let processIdentifier = try await simulator.device.spawnAsync(
      withPath: subprocess.executable,
      options: options,
      terminationQueue: simulator.asyncQueue,
      terminationHandler: { statLoc in exit.resolve(statLoc) },
      completionQueue: simulator.asyncQueue
    )
    return LaunchedProcess(processIdentifier: processIdentifier) {
      await exit.statLoc()
    }
  }

  // MARK: - Launch Options

  static func launchOptions(withArguments arguments: [String], environment: [String: String], waitForDebugger: Bool) -> [String: Any] {
    var options: [String: Any] = [:]
    options["arguments"] = arguments
    options["environment"] = environment
    if waitForDebugger {
      options["wait_for_debugger"] = NSNumber(value: 1)
    }
    return options
  }

  static func simDeviceLaunchOptions(withSimulator simulator: Simulator, launchPath: String, arguments: [String], environment: [String: String], waitForDebugger: Bool, standardOutput: Int32?, standardError: Int32?, mode: Subprocess.LaunchMode) -> [String: Any] {
    // argv[0] should be launch path of the process. SimDevice does not do this automatically, so we need to add it.
    let fullArguments = [launchPath] + arguments
    var options = launchOptions(withArguments: fullArguments, environment: environment, waitForDebugger: waitForDebugger)
    if let standardOutput {
      options["stdout"] = NSNumber(value: standardOutput)
    }
    if let standardError {
      options["stderr"] = NSNumber(value: standardError)
    }
    options["standalone"] = NSNumber(value: shouldLaunchStandalone(onSimulator: simulator, mode: mode))
    return options
  }

  static func shouldLaunchStandalone(onSimulator simulator: Simulator, mode: Subprocess.LaunchMode) -> Bool {
    switch mode {
    case .launchd:
      return false
    case .posixSpawn:
      return true
    case .default:
      return simulator.state != .booted
    }
  }
}

/// Holds the status from `SimDevice`'s termination handler until the exit
/// monitor asks for it, whichever comes first.
///
// SAFETY: `resolved` and `waiter` are only read or written inside `lock`, and
// the continuation is resumed after the lock is released.
// patternlint-disable-next-line unchecked-sendable
private final class SimulatorExit: @unchecked Sendable {
  private let lock = NSLock()
  private var resolved: Int32?
  private var waiter: CheckedContinuation<Int32, Never>?

  func resolve(_ statLoc: Int32) {
    let waiting: CheckedContinuation<Int32, Never>? = lock.withLock {
      resolved = statLoc
      defer { waiter = nil }
      return waiter
    }
    waiting?.resume(returning: statLoc)
  }

  func statLoc() async -> Int32 {
    await withCheckedContinuation { continuation in
      let immediate: Int32? = lock.withLock {
        if let resolved {
          return resolved
        }
        waiter = continuation
        return nil
      }
      if let immediate {
        continuation.resume(returning: immediate)
      }
    }
  }
}
