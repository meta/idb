/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

public enum SimulatorDapServerError: Error {
  case logDirectoryCreationFailed(path: String, underlying: any Error)
  case logFileCreationFailed(path: String)
  case noDataDirectory
}

extension SimulatorDapServerError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .logDirectoryCreationFailed(path, underlying):
      return "Dap Command: Failed to create log director on path \(path). Error: \(underlying.localizedDescription)"
    case let .logFileCreationFailed(path):
      return "Failed to create log file on path \(path)"
    case .noDataDirectory:
      return "Simulator has no data directory"
    }
  }
}

public final class SimulatorDapServerCommand {

  private let simulator: Simulator

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  /// Runs the adapter at `dapPath` inside the simulator's data directory for the duration of `body`,
  /// speaking the protocol over `input` and `output`, and terminates it when `body` exits.
  public func withServer<Result: Sendable>(
    _ dapPath: String,
    input: InputSource,
    output: any DataConsumer,
    _ body: (RunningSubprocess) async throws -> Result
  ) async throws -> Result {
    let dapLogDir = (simulator.coreSimulatorLogsDirectory as NSString).appendingPathComponent("dap")

    do {
      try FileManager.default.createDirectory(atPath: dapLogDir, withIntermediateDirectories: true, attributes: nil)
    } catch {
      throw SimulatorDapServerError.logDirectoryCreationFailed(path: dapLogDir, underlying: error)
    }

    let logString = (dapLogDir as NSString).appendingPathComponent(UUID().uuidString + ".log")
    let createdLogFile = FileManager.default.createFile(atPath: logString, contents: nil, attributes: nil)
    if !createdLogFile {
      throw SimulatorDapServerError.logFileCreationFailed(path: logString)
    }

    simulator.logger.debug().log("Dap Command: Launching dap server logging at path \(logString)")
    let envs: [String: String] = [
      "LLDBVSCODE_LOG": logString
    ]
    guard let dataDirectory = simulator.dataDirectory else {
      throw SimulatorDapServerError.noDataDirectory
    }
    let fullPath = (dataDirectory as NSString).appendingPathComponent(dapPath)
    return try await Subprocess(executable: fullPath, environment: .exact(envs)).withRunning(
      output: .consumer(output),
      error: .logger(simulator.logger.debug()),
      input: .source(input),
      gracePeriod: 1,
      body)
  }
}
