/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
@preconcurrency import Foundation

public enum SimulatorLaunchCtlError: Error {
  case searchPatternConstructionFailed(processIdentifier: pid_t)
  case noMatchingProcesses(pattern: String)
  case multipleMatchingProcesses(pattern: String, matches: [String: pid_t])
  case insufficientOutput(output: String)
  case stopFailed(serviceName: String, underlying: Error)
  case startFailed(serviceName: String, underlying: Error)
  case malformedListLine(words: [String])
  case invalidProcessIdentifier(word: String, words: [String])
  case commandFailed(arguments: [String], exitCode: Int32, stderr: String)
}

extension SimulatorLaunchCtlError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .searchPatternConstructionFailed(processIdentifier):
      return "Couldn't build search pattern for '\(processIdentifier)'"
    case let .noMatchingProcesses(pattern):
      return "No Matching processes for '\(pattern)'"
    case let .multipleMatchingProcesses(pattern, matches):
      return "Multiple Matching processes for '\(pattern)' \(CollectionInformation.oneLineDescription(from: matches))"
    case let .insufficientOutput(output):
      return "Insufficient number of lines from output '\(output)'"
    case let .stopFailed(serviceName, _):
      return "Failed to stop service '\(serviceName)'"
    case let .startFailed(serviceName, _):
      return "Failed to start service '\(serviceName)'"
    case let .malformedListLine(words):
      return "Output does not have exactly three words: \(CollectionInformation.oneLineDescription(from: words))"
    case let .invalidProcessIdentifier(word, words):
      return "Expected a process identifier as first word, but got \(word) from \(CollectionInformation.oneLineDescription(from: words))"
    case let .commandFailed(arguments, exitCode, stderr):
      return "launchctl \(arguments.joined(separator: " ")) failed with exit code \(exitCode): \(stderr)"
    }
  }
}

public final class SimulatorLaunchCtlCommands: LaunchCtlCommands {

  private let simulator: Simulator

  // MARK: - Initializers

  /// The runtime's own `launchctl`, for anything in this package that needs to run it in the guest.
  package static func launchCtlLaunchPath(for simulator: Simulator) throws -> String {
    let path = (simulator.device.runtime.root as NSString)
      .appendingPathComponent("bin")
      .appending("/launchctl")
    let binary = try BinaryDescriptor(path: path)
    return binary.path
  }

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Services

  public func serviceName(forProcessIdentifier pid: pid_t) async throws -> String {
    let pattern = "^\(NSRegularExpression.escapedPattern(for: "\(pid)"))\t"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      throw SimulatorLaunchCtlError.searchPatternConstructionFailed(processIdentifier: pid)
    }
    let (serviceName, _) = try await firstServiceNameAndProcessIdentifier(matching: regex)
    return serviceName
  }

  public func serviceNamesAndProcessIdentifiers(matching regex: NSRegularExpression) async throws -> [String: pid_t] {
    let text = try await run(.list)
    let lines = text.components(separatedBy: .newlines)
    var mapping: [String: pid_t] = [:]
    for line in lines {
      if regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.count)) == nil {
        continue
      }
      var processIdentifier: pid_t = 0
      guard let serviceName = try? SimulatorLaunchCtlCommands.extractServiceName(fromListLine: line, processIdentifierOut: &processIdentifier) else {
        continue
      }
      mapping[serviceName] = processIdentifier
    }
    return mapping
  }

  public func firstServiceNameAndProcessIdentifier(matching regex: NSRegularExpression) async throws -> (serviceName: String, processIdentifier: pid_t) {
    let serviceNameToProcessIdentifier = try await serviceNamesAndProcessIdentifiers(matching: regex)
    guard let (serviceName, processIdentifier) = serviceNameToProcessIdentifier.first else {
      throw SimulatorLaunchCtlError.noMatchingProcesses(pattern: regex.pattern)
    }
    if serviceNameToProcessIdentifier.count > 1 {
      throw SimulatorLaunchCtlError.multipleMatchingProcesses(pattern: regex.pattern, matches: serviceNameToProcessIdentifier)
    }
    return (serviceName, processIdentifier)
  }

  /// Running services whose label names `bundleID` as a whole identifier,
  /// regardless of the `UIKitApplication:` prefix. System sheets such as
  /// SafariViewService do not appear as `UIKitApplication:<bid>` in
  /// `launchctl list`, so a `UIKitApplication:`-only lookup reports no match
  /// while the service is live. The caller decides ambiguity: an empty map
  /// means absent, several entries mean the label is not unique.
  public func runningServices(matchingBundleID bundleID: String) async throws -> [String: pid_t] {
    Self.runningServices(matchingBundleID: bundleID, in: try await listServices())
  }

  static func runningServices(matchingBundleID bundleID: String, in services: [String: pid_t?]) -> [String: pid_t] {
    var matches: [String: pid_t] = [:]
    for (serviceName, processIdentifier) in services {
      guard let processIdentifier, processIdentifier > 0 else {
        continue
      }
      guard Self.serviceName(serviceName, matchesBundleID: bundleID) else {
        continue
      }
      matches[serviceName] = processIdentifier
    }
    return matches
  }

  /// A launchctl label names `bundleID` only when the identifier stands whole:
  /// the entire label, or trailed by the UIKit instance suffix (`bid[0x..]`).
  /// A longer identifier that merely begins with it (`bid.helper`,
  /// `bid.xctrunner`) belongs to a different service: resolving it would hand
  /// launch handling or an AX read the wrong process.
  static func serviceName(_ serviceName: String, matchesBundleID bundleID: String) -> Bool {
    if serviceName == bundleID || serviceName.hasPrefix(bundleID + "[") {
      return true
    }
    return extractApplicationBundleIdentifier(fromServiceName: serviceName) == bundleID
  }

  public func serviceName(forProcess process: RunningProcessInfo) async throws -> String {
    try await serviceName(forProcessIdentifier: process.processIdentifier)
  }

  public func processIsRunning(onSimulator process: RunningProcessInfo) async throws -> Bool {
    _ = try await serviceName(forProcessIdentifier: process.processIdentifier)
    return true
  }

  public func listServices() async throws -> [String: pid_t?] {
    let text = try await run(.list)
    let lines = text.components(separatedBy: .newlines)
    if lines.count < 2 {
      throw SimulatorLaunchCtlError.insufficientOutput(output: text)
    }
    return Self.services(fromListOutput: text)
  }

  /// Every listed service with its pid, keeping a stopped service as a present `nil`.
  static func services(fromListOutput text: String) -> [String: pid_t?] {
    var services: [String: pid_t?] = [:]
    for (serviceName, processIdentifier) in serviceMap(fromListOutput: text) {
      // `updateValue` stores a nil pid; assigning `nil` through the subscript would remove the key.
      services.updateValue(processIdentifier > 0 ? processIdentifier : nil, forKey: serviceName)
    }
    return services
  }

  public func stopService(withName serviceName: String) async throws -> String {
    do {
      return try await run(.stop(serviceName: serviceName))
    } catch {
      throw SimulatorLaunchCtlError.stopFailed(serviceName: serviceName, underlying: error)
    }
  }

  public func startService(withName serviceName: String) async throws -> String {
    do {
      return try await run(.start(serviceName: serviceName))
    } catch {
      throw SimulatorLaunchCtlError.startFailed(serviceName: serviceName, underlying: error)
    }
  }

  public static func extractApplicationBundleIdentifier(fromServiceName serviceName: String) -> String? {
    guard let marker = serviceName.range(of: "UIKitApplication:") else {
      return nil
    }
    return String(serviceName[marker.upperBound...].prefix { $0 != "[" })
  }

  // MARK: - Private

  private static func extractServiceName(fromListLine line: String, processIdentifierOut: inout pid_t) throws -> String {
    let words = line.components(separatedBy: .whitespaces)
    guard words.count == 3, let processIdentifierString = words.first, let serviceName = words.last else {
      throw SimulatorLaunchCtlError.malformedListLine(words: words)
    }
    if processIdentifierString == "-" {
      processIdentifierOut = -1
      return serviceName
    }

    let processIdentifierInteger = Int(processIdentifierString) ?? 0
    guard processIdentifierInteger >= 1 else {
      throw SimulatorLaunchCtlError.invalidProcessIdentifier(word: processIdentifierString, words: words)
    }
    processIdentifierOut = pid_t(processIdentifierInteger)
    return serviceName
  }

  // A pid of -1 marks a loaded-but-not-running service (the "-" placeholder). The header row and
  // malformed lines are skipped.
  static func serviceMap(fromListOutput text: String) -> [String: pid_t] {
    var services: [String: pid_t] = [:]
    for line in text.components(separatedBy: .newlines) {
      if line.isEmpty {
        continue
      }
      var processIdentifier: pid_t = -1
      guard let serviceName = try? extractServiceName(fromListLine: line, processIdentifierOut: &processIdentifier) else {
        continue
      }
      services[serviceName] = processIdentifier
    }
    return services
  }

  enum Command {
    case list
    case stop(serviceName: String)
    case start(serviceName: String)

    var arguments: [String] {
      switch self {
      case .list:
        return ["list"]
      case let .stop(serviceName):
        return ["stop", serviceName]
      case let .start(serviceName):
        return ["start", serviceName]
      }
    }

    var exitCodePolicy: ExitCodePolicy {
      switch self {
      case .list:
        return .require([0])
      case .stop:
        // launchctl returns ESRCH (3) when the service is not running; for stop that is an idempotent
        // no-op. Any other non-zero is a genuine failure to stop a running service.
        return .require([0, 3])
      case .start:
        // For start, ESRCH (3) means there is no such service to start — a genuine failure, not a
        // no-op — so only a 0 exit is success.
        return .require([0])
      }
    }
  }

  private func run(_ command: Command) async throws -> String {
    let output = try await simulator.runtimeTools.run(hostExecutable: Self.launchCtlLaunchPath(for: simulator), arguments: command.arguments)
    return try SimulatorLaunchCtlCommands.stdout(orThrowFrom: output, command: command, logger: simulator.logger)
  }

  static func stdout(orThrowFrom output: InSimulatorToolOutput, command: Command, logger: (any ControlCoreLogger)?) throws -> String {
    if output.exitCode != 0 {
      let stderr = String(data: output.stderr, encoding: .utf8) ?? ""
      guard command.exitCodePolicy.accepts(output.exitCode) else {
        throw SimulatorLaunchCtlError.commandFailed(arguments: command.arguments, exitCode: output.exitCode, stderr: stderr)
      }
      logger?.log("launchctl \(command.arguments.joined(separator: " ")) exited with code \(output.exitCode): \(stderr)")
    }
    return String(data: output.stdout, encoding: .utf8) ?? ""
  }
}
