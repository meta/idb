/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation

/// The captured result of running a tool inside the simulator runtime.
public struct InSimulatorToolOutput: Sendable {
  public let stdout: Data
  public let stderr: Data
  public let exitCode: Int32

  public init(stdout: Data, stderr: Data, exitCode: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}

public enum InSimulatorToolError: Error, Equatable, LocalizedError {
  /// The tool was killed by a signal rather than exiting. What it wrote to stderr first is usually why.
  case signalled(launchPath: String, signal: Int32, stderr: String)

  public var errorDescription: String? {
    switch self {
    case let .signalled(launchPath, signal, stderr):
      return "\(launchPath) was killed by signal \(signal): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
  }
}

/// Spawns executables inside the simulator, capturing what they write.
public struct SimulatorRuntimeToolCommands: Sendable {

  private let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Spawning

  /// Runs a tool vendored by the simulator runtime (`relativePath` is relative to the RuntimeRoot, e.g.
  /// `usr/bin/heap`) against the booted simulator, capturing its stdout, stderr and exit code.
  ///
  /// The executable is resolved against the simulator's RuntimeRoot — the
  /// runtime's own build of the tool — not the host's `/usr/bin` copy. This is
  /// load-bearing for the memory tools (`heap`, `vmmap`, `leaks`,
  /// `malloc_history`): the host (macOS) builds link the macOS
  /// `Symbolication.framework`, which cannot walk a simulator process' `dyld_sim`
  /// image list and fails with `Failed to get DYLD info for task ... (os/kern)
  /// failure (5)`. The runtime-vendored builds link the runtime's own
  /// `Symbolication` and can read the target.
  ///
  /// The spawn runs in the CoreSimulator domain via `launchProcess`. Exit codes
  /// are not interpreted here — callers decide which codes are acceptable.
  public func run(
    _ relativePath: String,
    arguments: [String] = [],
    environment: [String: String] = [:]
  ) async throws -> InSimulatorToolOutput {
    let launchPath = try runtimeExecutablePath(relativePath)
    return try await run(hostExecutable: launchPath, arguments: arguments, environment: environment)
  }

  /// Spawns an executable inside the simulator (the CoreSimulator domain, via
  /// `launchProcess`) and captures its stdout, stderr and exit code.
  ///
  /// `launchPath` is used verbatim: `SimDevice` resolves it against the host
  /// filesystem, not the RuntimeRoot. Use `run(_:arguments:environment:)` for runtime-vendored
  /// tools; use this only for host executables (e.g. `/bin/sh`, which
  /// the runtime does not ship). Exit codes are not interpreted — callers decide
  /// which are acceptable. A tool killed by a signal throws
  /// `InSimulatorToolError.signalled`, with its stderr.
  package func run(
    hostExecutable launchPath: String,
    arguments: [String] = [],
    environment: [String: String] = [:]
  ) async throws -> InSimulatorToolOutput {
    let completed = try await Subprocess(executable: launchPath, arguments: arguments, environment: .exact(environment))
      .run(on: SimulatorSubprocessLauncher(simulator: simulator), output: .data, error: .data, exitPolicy: .any)
    switch completed.terminationStatus {
    case let .signalled(signal):
      throw InSimulatorToolError.signalled(launchPath: launchPath, signal: signal, stderr: String(decoding: completed.standardError, as: UTF8.self))
    case let .exited(exitCode):
      return InSimulatorToolOutput(stdout: completed.standardOutput, stderr: completed.standardError, exitCode: exitCode)
    }
  }

  /// Resolves an executable vendored by the simulator runtime to its on-disk
  /// path, validating that the binary exists.
  private func runtimeExecutablePath(_ relativePath: String) throws -> String {
    guard let root = simulator.device.runtime.root else {
      throw SimulatorLogError.runtimeRootUnavailable
    }
    let path = (root as NSString).appendingPathComponent(relativePath)
    let binary = try BinaryDescriptor(path: path)
    return binary.path
  }
}
