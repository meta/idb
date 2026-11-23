/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

enum XCTraceError: Error {
  case outputDirectoryCreationFailed(underlying: any Error)
  case shimMissing
  case recordFailed(exitCode: Int32)
  case xctraceMissing(path: String)
}

extension XCTraceError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .outputDirectoryCreationFailed(underlying):
      return "Failed to create xctrace trace output directory: \(underlying)"
    case .shimMissing:
      return "Failed to locate the shim file for xctrace method swizzling"
    case let .recordFailed(exitCode):
      return "Xctrace record exited with failure - status: \(exitCode)"
    case let .xctraceMissing(path):
      return "xctrace does not exist at expected path \(path)"
    }
  }
}

public final class XCTraceRecordOperation: @unchecked Sendable {

  public let running: RunningSubprocess
  public let traceDir: URL
  public let configuration: XCTraceRecordConfiguration
  public let logger: any ControlCoreLogger

  public init(running: RunningSubprocess, traceDir: URL, configuration: XCTraceRecordConfiguration, logger: any ControlCoreLogger) {
    self.running = running
    self.traceDir = traceDir
    self.configuration = configuration
    self.logger = logger
  }

  /// Starts `xctrace record` against `target` in a new trace directory under its auxillary directory.
  public convenience init(target: any Target, configuration: XCTraceRecordConfiguration, logger: any ControlCoreLogger) async throws {
    let traceDir = (target.auxillaryDirectory as NSString).appendingPathComponent("xctrace-" + UUID().uuidString)
    do {
      try FileManager.default.createDirectory(atPath: traceDir, withIntermediateDirectories: false, attributes: nil)
    } catch {
      throw XCTraceError.outputDirectoryCreationFailed(underlying: error)
    }
    let traceFile = (traceDir as NSString).appendingPathComponent("trace.trace")

    var arguments: [String] = ["record", "--template", configuration.templateName, "--device", target.udid, "--output", traceFile, "--time-limit", "\(Int(configuration.timeLimit))s"]
    if let package = configuration.package, !package.isEmpty {
      arguments.append(contentsOf: ["--package", package])
    }
    if let targetStdin = configuration.targetStdin, !targetStdin.isEmpty {
      arguments.append(contentsOf: ["--target-stdin", targetStdin])
    }
    if let targetStdout = configuration.targetStdout, !targetStdout.isEmpty {
      arguments.append(contentsOf: ["--target-stdout", targetStdout])
    }
    if configuration.allProcesses {
      arguments.append("--all-processes")
    }
    if let processToAttach = configuration.processToAttach, !processToAttach.isEmpty {
      arguments.append(contentsOf: ["--attach", processToAttach])
    }
    if let processToLaunch = configuration.processToLaunch, !processToLaunch.isEmpty {
      if let processEnv = configuration.processEnv {
        for (key, value) in processEnv {
          arguments.append(contentsOf: ["--env", "\(key)=\(value)"])
        }
      }
      arguments.append(contentsOf: ["--launch", "--", processToLaunch])
      if let launchArgs = configuration.launchArgs {
        arguments.append(contentsOf: launchArgs)
      }
    }
    logger.log("Starting xctrace with arguments: \(CollectionInformation.oneLineDescription(from: arguments))")

    let xctracePath = try Self.xctracePath()

    var environment: [String: String] = [:]
    if let customDeviceSetPath = target.customDeviceSetPath {
      guard let shim = configuration.shim else {
        throw XCTraceError.shimMissing
      }
      environment["SIM_DEVICE_SET_PATH"] = customDeviceSetPath
      environment["DYLD_INSERT_LIBRARIES"] = shim.macOSTestShimPath
    }

    let running = try await Subprocess(executable: xctracePath, arguments: arguments, environment: .additions(environment))
      .launch(output: .logger(logger), error: .logger(logger), logger: logger)
    logger.log("Started xctrace with pid \(running.processIdentifier)")
    self.init(running: running, traceDir: URL(fileURLWithPath: traceFile), configuration: configuration, logger: logger)
  }

  /// Stops the xctrace recording and returns the trace directory URL on success.
  public func stop(withTimeout timeout: TimeInterval) async throws -> URL {
    logger.log("Terminating xctrace record with pid \(running.processIdentifier). Backoff Timeout \(timeout)")
    let status = await running.terminate(with: SIGINT, gracePeriod: timeout)
    switch status {
    case .exited(0):
      return traceDir
    case .exited(let code):
      throw XCTraceError.recordFailed(exitCode: code)
    case .signalled(let signo):
      throw ProcessTerminationError.exitedWithSignal(
        processIdentifier: running.processIdentifier,
        processName: "xctrace",
        signal: signo)
    }
  }

  public static func xctracePath() throws -> String {
    let path = (XcodeConfiguration.developerDirectory as NSString).appendingPathComponent("/usr/bin/xctrace")
    if !FileManager.default.fileExists(atPath: path) {
      throw XCTraceError.xctraceMissing(path: path)
    }
    return path
  }
}
