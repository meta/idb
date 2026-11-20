/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import Foundation

public enum DevicectlError: Error {
  case commandFailed(exitCode: String, arguments: [String], stdOut: String, stdErr: String)
}

extension DevicectlError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .commandFailed(exitCode, arguments, stdOut, stdErr):
      return "devicectl failed with exit code \(exitCode)\narguments: \(CollectionInformation.oneLineDescription(from: arguments))\n\(stdOut)\n\(stdErr)"
    }
  }
}

/// Runs `xcrun devicectl` against one device, through the device's subprocess launcher.
final class AppleDevicectlCommandExecutor {

  let logger: ControlCoreLogger?
  let device: Device

  init(device: Device) {
    logger = device.logger.withName("devicectl")
    self.device = device
  }

  /// Runs `devicectl` with `arguments` and fails with its output unless it exits cleanly.
  func run(_ arguments: [String]) async throws {
    let result = try await Subprocess(executable: "/usr/bin/xcrun", arguments: ["devicectl"] + arguments)
      .run(on: device.devicectlLauncher, exitPolicy: .any, logger: logger)
    try result.checkExitedCleanly { code in
      DevicectlError.commandFailed(
        exitCode: String(code),
        arguments: arguments,
        stdOut: result.standardOutput,
        stdErr: result.standardError)
    }
  }
}

extension AppleDevicectlCommandExecutor {
  func launchApplication(configuration: ApplicationLaunchConfiguration) async throws -> pid_t {
    let tmpPath = try FileManager.default.temporaryFile(extension: "json")
    let tmpPathStr = tmpPath.path()
    var arguments = [
      "device",
      "process",
      "launch",
      "--device",
      device.udid,
      "--terminate-existing",
      "--json-output",
      tmpPathStr,
    ]
    if !configuration.environment.isEmpty {
      if let envstr = String(
        data: try JSONSerialization.data(withJSONObject: configuration.environment),
        encoding: .utf8)
      {
        arguments += ["--environment-variables", envstr]
      }
    }
    if configuration.waitForDebugger {
      arguments.append("--start-stopped")
    }
    arguments.append(configuration.bundleID)
    arguments += configuration.arguments

    try await run(arguments)
    let data = try Data(contentsOf: tmpPath)
    let info = try JSONDecoder().decode(DevicectlProcInfo.self, from: data)
    return info.result.process.processIdentifier
  }

  /// Sends SIGKILL to `processIdentifier`, which the process cannot catch or ignore. Fails if the
  /// process cannot be signalled.
  func terminateProcess(processIdentifier: pid_t) async throws {
    try await run([
      "device",
      "process",
      "terminate",
      "--device",
      device.udid,
      "--pid",
      String(processIdentifier),
      "--kill",
    ])
  }

  /// The executable path of each running process, by process identifier.
  func processExecutablePaths() async throws -> [pid_t: String] {
    let output = try FileManager.default.temporaryFile(extension: "json")
    defer {
      try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
    }
    try await run([
      "device",
      "info",
      "processes",
      "--device",
      device.udid,
      "--json-output",
      output.path(),
    ])
    let listing = try JSONDecoder().decode(DevicectlProcessList.self, from: Data(contentsOf: output))
    var paths: [pid_t: String] = [:]
    for process in listing.result.runningProcesses {
      guard let executable = process.executable else {
        continue
      }
      paths[process.processIdentifier] = URL(string: executable)?.path(percentEncoded: false) ?? executable
    }
    return paths
  }

  /// Captures the device's main display as PNG data.
  func screenshot() async throws -> Data {
    let destination = try FileManager.default.temporaryFile(extension: "png")
    defer {
      try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
    }
    try await run([
      "device",
      "capture",
      "screenshot",
      "--device",
      device.udid,
      "--destination",
      destination.path(),
    ])
    return try Data(contentsOf: destination)
  }

  private struct DevicectlProcessList: Decodable {
    struct Result: Decodable {
      struct Process: Decodable {
        var processIdentifier: pid_t
        var executable: String?
      }
      var runningProcesses: [Process]
    }
    var result: Result
  }

  private struct DevicectlProcInfo: Decodable {
    struct Result: Decodable {
      struct Process: Decodable {
        var processIdentifier: pid_t
      }
      var process: Process
    }
    var result: Result
  }
}

extension FileManager {
  func temporaryFile(extension fileExtension: String) throws -> URL {
    let tmpPath = try url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: "/tmp"), create: true)
    return tmpPath.appending(component: "\(ProcessInfo().globallyUniqueString).\(fileExtension)")
  }
}
