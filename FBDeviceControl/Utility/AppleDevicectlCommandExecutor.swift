/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import os

public enum DevicectlError: Error {
  case commandFailed(exitCode: String, arguments: [String], stdOut: String, stdErr: String)
  case timedOut(seconds: TimeInterval, arguments: [String], deviceState: String)
  case unreadableJSON(path: String, arguments: [String], stdErr: String, underlying: any Error)
}

extension DevicectlError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .commandFailed(exitCode, arguments, stdOut, stdErr):
      return "devicectl failed with exit code \(exitCode)\narguments: \(CollectionInformation.oneLineDescription(from: arguments))\n\(stdOut)\n\(stdErr)"
    case let .timedOut(seconds, arguments, deviceState):
      return "devicectl did not finish within \(Int(seconds))s, so it was stopped. \(deviceState)\narguments: \(CollectionInformation.oneLineDescription(from: arguments))"
    case let .unreadableJSON(path, arguments, stdErr, underlying):
      return "Could not read devicectl JSON at \(path): \(underlying.localizedDescription)\narguments: \(CollectionInformation.oneLineDescription(from: arguments))\n\(stdErr)"
    }
  }
}

/// How one `devicectl` process ended.
private struct DevicectlOutcome {
  /// `nil` when the process outlived the host's deadline and was stopped.
  let status: TerminationStatus?
  let standardOutput: String
  let standardError: String
}

/// Runs `xcrun devicectl` against one device, through the device's subprocess launcher.
///
/// Every run is bounded: `devicectl` is given `timeout` through its own `--timeout`, and the host
/// stops it if it outlives that by `hostGrace`. A run also stops `devicectl` when the calling task
/// is cancelled, so an abandoned request does not leave it running.
struct AppleDevicectlCommandExecutor: Sendable {

  /// Healthy operations finish in a few seconds (a launch in 1-2 s, a screenshot in about 3 s), but
  /// `devicectl` may first have to mount the developer disk image, so the bound leaves room for
  /// that rather than tracking the healthy case closely.
  static let defaultTimeout: TimeInterval = 60
  private static let hostGrace: TimeInterval = 10
  private static let stateQueryTimeout: TimeInterval = 10
  private static let terminationGracePeriod: TimeInterval = 2

  let logger: (any ControlCoreLogger)?
  let udid: String
  let launcher: any SubprocessLauncher
  let timeout: TimeInterval

  init(device: Device, timeout: TimeInterval = AppleDevicectlCommandExecutor.defaultTimeout) {
    logger = device.logger.withName("devicectl")
    udid = device.udid
    launcher = device.devicectlLauncher
    self.timeout = timeout
  }

  /// Runs `devicectl <command> <options>` and fails with its output unless it exits cleanly. A run
  /// that times out fails with the device's state as CoreDevice reports it.
  func run(_ command: [String], _ options: [String]) async throws {
    let arguments = command + ["--timeout", String(Int(timeout.rounded(.up)))] + options
    let outcome = try await execute(arguments, hostDeadline: timeout + Self.hostGrace)
    switch outcome.status {
    case .exited(0):
      return
    case let .exited(code) where !(code == 2 && outcome.standardError.contains("Command timeout of")):
      throw DevicectlError.commandFailed(exitCode: String(code), arguments: arguments, stdOut: outcome.standardOutput, stdErr: outcome.standardError)
    case let .signalled(signo):
      throw DevicectlError.commandFailed(exitCode: "signal \(signo)", arguments: arguments, stdOut: outcome.standardOutput, stdErr: outcome.standardError)
    case .exited, nil:
      throw DevicectlError.timedOut(seconds: timeout, arguments: arguments, deviceState: await deviceStateDescription())
    }
  }

  private func execute(_ arguments: [String], hostDeadline: TimeInterval) async throws -> DevicectlOutcome {
    try await Self.execute(arguments, hostDeadline: hostDeadline, launcher: launcher, logger: logger)
  }

  /// Runs `devicectl` until it exits, the host deadline passes or the calling task is cancelled; in
  /// the last two cases it is stopped before this returns or throws.
  private static func execute(
    _ arguments: [String], hostDeadline: TimeInterval, launcher: any SubprocessLauncher, logger: (any ControlCoreLogger)?
  ) async throws -> DevicectlOutcome {
    let standardOutput = OSAllocatedUnfairLock(initialState: [String]())
    let standardError = OSAllocatedUnfairLock(initialState: [String]())
    let status = try await Subprocess(executable: "/usr/bin/xcrun", arguments: ["devicectl"] + arguments)
      .withRunning(
        on: launcher,
        output: .lines { line in standardOutput.withLock { $0.append(line) } },
        error: .lines { line in standardError.withLock { $0.append(line) } },
        gracePeriod: Self.terminationGracePeriod,
        logger: logger
      ) { running in
        try await running.terminationStatus(within: hostDeadline)
      }
    return DevicectlOutcome(
      status: status,
      standardOutput: standardOutput.withLock { $0.joined(separator: "\n") },
      standardError: standardError.withLock { $0.joined(separator: "\n") })
  }

  /// The device's connection state as `devicectl list devices` reports it, for an error that
  /// explains why an operation on it did not finish.
  private func deviceStateDescription() async -> String {
    do {
      let output = try FileManager.default.temporaryFile(extension: "json")
      defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
      let arguments = ["list", "devices", "--timeout", String(Int(Self.stateQueryTimeout)), "--json-output", output.path()]
      let outcome = try await execute(arguments, hostDeadline: Self.stateQueryTimeout + Self.hostGrace)
      guard outcome.status == .exited(0) else {
        return "Its CoreDevice state could not be read either: `devicectl list devices` did not succeed."
      }
      let listing = try JSONDecoder().decode(DevicectlConnectionList.self, from: Data(contentsOf: output))
      guard let entry = listing.result.devices.first(where: { $0.hardwareProperties?.udid == udid }) else {
        return "CoreDevice does not list the device."
      }
      let connection = entry.connectionProperties
      return "CoreDevice reports the device's tunnel state as '\(connection?.tunnelState ?? "unknown")' (pairing state '\(connection?.pairingState ?? "unknown")', transport '\(connection?.transportType ?? "unknown")')."
    } catch {
      return "Its CoreDevice state could not be read: \(error.localizedDescription)"
    }
  }

  private struct DevicectlConnectionList: Decodable {
    struct Result: Decodable {
      struct Device: Decodable {
        struct HardwareProperties: Decodable {
          var udid: String?
        }
        struct ConnectionProperties: Decodable {
          var pairingState: String?
          var transportType: String?
          var tunnelState: String?
        }
        var hardwareProperties: HardwareProperties?
        var connectionProperties: ConnectionProperties?
      }
      var devices: [Device]
    }
    var result: Result
  }
}

extension AppleDevicectlCommandExecutor {
  func launchApplication(configuration: ApplicationLaunchConfiguration) async throws -> pid_t {
    let arguments = [
      "device",
      "process",
      "launch",
      "--timeout",
      String(Int(timeout.rounded(.up))),
      "--device",
      udid,
      "--terminate-existing",
    ]
    var launchArguments: [String] = []
    if !configuration.environment.isEmpty {
      if let envstr = String(
        data: try JSONSerialization.data(withJSONObject: configuration.environment),
        encoding: .utf8)
      {
        launchArguments += ["--environment-variables", envstr]
      }
    }
    if configuration.waitForDebugger {
      launchArguments.append("--start-stopped")
    }
    do {
      let info: DevicectlProcInfo = try await Self.runJSON(
        arguments, trailingArguments: launchArguments + [configuration.bundleID] + configuration.arguments,
        logger: logger, deadline: timeout + Self.hostGrace, launcher: launcher)
      return info.result.process.processIdentifier
    } catch let error as DevicectlError {
      switch error {
      case let .timedOut(_, arguments, _):
        throw DevicectlError.timedOut(seconds: timeout, arguments: arguments, deviceState: await deviceStateDescription())
      case let .commandFailed(code, arguments, _, stderr) where code == "2" && stderr.contains("Command timeout of"):
        throw DevicectlError.timedOut(seconds: timeout, arguments: arguments, deviceState: await deviceStateDescription())
      default:
        throw error
      }
    }
  }

  /// Sends SIGKILL to `processIdentifier`, which the process cannot catch or ignore. Fails if the
  /// process cannot be signalled.
  func terminateProcess(processIdentifier: pid_t) async throws {
    // Stopping an app is teardown: once asked for, the kill runs to completion, within the
    // timeout, even if the caller is cancelled, and the caller waits for it.
    let kill = Task {
      try await run(
        ["device", "process", "terminate"],
        [
          "--device",
          udid,
          "--pid",
          String(processIdentifier),
          "--kill",
        ])
    }
    try await kill.value
  }

  /// The executable path of each running process, by process identifier.
  func processExecutablePaths() async throws -> [pid_t: String] {
    let output = try FileManager.default.temporaryFile(extension: "json")
    defer {
      try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
    }
    try await run(
      ["device", "info", "processes"],
      [
        "--device",
        udid,
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
    try await run(
      ["device", "capture", "screenshot"],
      [
        "--device",
        udid,
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

  /// The host's CoreDevice list. The host deadline bounds the run even if `devicectl` stops responding.
  static func listDevices(
    logger: any ControlCoreLogger,
    hostTimeoutMilliseconds: UInt32 = UInt32(ControlCoreGlobalConfiguration.fastTimeout * 1_000),
    launcher: any SubprocessLauncher = HostSubprocessLauncher()
  ) async throws -> [CoreDeviceEntry] {
    let arguments = ["list", "devices", "--timeout", String(Int(ControlCoreGlobalConfiguration.fastTimeout))]
    let listing: DevicectlDeviceList = try await runJSON(
      arguments, logger: logger.withName("devicectl"), deadline: TimeInterval(hostTimeoutMilliseconds) / 1_000, launcher: launcher)
    return listing.result.devices
  }

  private static func runJSON<Response: Decodable>(
    _ options: [String],
    trailingArguments: [String] = [],
    logger: (any ControlCoreLogger)?,
    deadline: TimeInterval,
    launcher: any SubprocessLauncher
  ) async throws -> Response {
    let output = try FileManager.default.temporaryFile(extension: "json")
    defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
    let arguments = options + ["--json-output", output.path()] + trailingArguments
    let outcome = try await execute(arguments, hostDeadline: deadline, launcher: launcher, logger: logger)
    switch outcome.status {
    case .exited(0):
      do {
        return try JSONDecoder().decode(Response.self, from: Data(contentsOf: output))
      } catch {
        throw DevicectlError.unreadableJSON(path: output.path(), arguments: arguments, stdErr: outcome.standardError, underlying: error)
      }
    case .exited(let code):
      throw DevicectlError.commandFailed(exitCode: String(code), arguments: arguments, stdOut: outcome.standardOutput, stdErr: outcome.standardError)
    case .signalled(let signal):
      throw DevicectlError.commandFailed(exitCode: "signal \(signal)", arguments: arguments, stdOut: outcome.standardOutput, stdErr: outcome.standardError)
    case nil:
      throw DevicectlError.timedOut(seconds: deadline, arguments: arguments, deviceState: outcome.standardError)
    }
  }

  private struct DevicectlDeviceList: Decodable {
    struct Result: Decodable {
      let devices: [CoreDeviceEntry]
    }
    let result: Result
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

/// A device as `devicectl list devices` reports it.
struct CoreDeviceEntry: Decodable {
  struct DeviceProperties: Decodable { let name: String? }
  struct HardwareProperties: Decodable { let udid: String? }
  struct ConnectionProperties: Decodable { let transportType: String? }

  let identifier: String
  let deviceProperties: DeviceProperties?
  let hardwareProperties: HardwareProperties?
  let connectionProperties: ConnectionProperties?

  var udid: String? { hardwareProperties?.udid }
  var name: String? { deviceProperties?.name }
  var isWired: Bool { connectionProperties?.transportType == "wired" }
}

extension FileManager {
  func temporaryFile(extension fileExtension: String) throws -> URL {
    let tmpPath = try url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: "/tmp"), create: true)
    return tmpPath.appending(component: "\(ProcessInfo().globallyUniqueString).\(fileExtension)")
  }
}
