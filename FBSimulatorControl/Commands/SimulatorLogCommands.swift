/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation

public enum SimulatorLogError: Error, LocalizedError {
  case runtimeRootUnavailable

  public var errorDescription: String? {
    switch self {
    case .runtimeRootUnavailable:
      return "Could not obtain runtime root for simulator"
    }
  }
}

public struct SimulatorLogCommands: LogCommands {

  private let simulator: Simulator

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  public func tail(arguments: [String], consumer: any DataConsumer) async throws -> any LogOperation {
    let launchPath = try logExecutablePath()
    let streamArguments = ProcessLogOperation.osLogArgumentsInsertStreamIfNeeded(arguments)
    let process = try await Subprocess(executable: launchPath, arguments: streamArguments, environment: .exact([:]))
      .launch(on: SimulatorSubprocessLauncher(simulator: simulator), output: .consumer(consumer), error: .closed)
    return ProcessLogOperation(process: process, executable: launchPath, consumer: consumer)
  }

  private func logExecutablePath() throws -> String {
    guard let root = simulator.device.runtime.root else {
      throw SimulatorLogError.runtimeRootUnavailable
    }
    let path =
      (((root as NSString)
      .appendingPathComponent("usr") as NSString)
      .appendingPathComponent("bin") as NSString)
      .appendingPathComponent("log")
    let binary = try BinaryDescriptor(path: path)
    return binary.path
  }
}

public final class ProcessLogOperation: LogOperation {

  public let process: RunningSubprocess
  public let consumer: any DataConsumer
  private let executable: String

  public init(process: RunningSubprocess, executable: String, consumer: any DataConsumer) {
    self.process = process
    self.executable = executable
    self.consumer = consumer
  }

  // MARK: - LogOperation

  public func waitUntilCompleted() async throws {
    let status: TerminationStatus
    do {
      status = try await process.terminationStatus
    } catch {
      await process.terminate(gracePeriod: 5)
      throw error
    }
    guard ExitPolicy.mustExitZero.accepts(status) else {
      throw SubprocessError.unacceptableTermination(status: status, policy: .mustExitZero, executable: executable, processIdentifier: process.processIdentifier)
    }
  }

  public static func osLogArgumentsInsertStreamIfNeeded(_ arguments: [String]) -> [String] {
    guard let firstArgument = arguments.first else {
      return ["stream"]
    }
    if ProcessLogOperation.osLogSubcommands.contains(firstArgument) {
      return arguments
    }
    return ["stream"] + arguments
  }

  private static let osLogSubcommands: Set<String> = {
    Set(["collect", "config", "erase", "show", "stream", "stats"])
  }()
}
