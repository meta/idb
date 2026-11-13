/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
import Foundation

/// Errors thrown while modifying simulator defaults/preferences. String-representable so the message
/// reaches the caller and the error log without the NSError wrapper.
enum SimulatorDefaultsError: Error, CustomStringConvertible {
  case couldNotCreateDirectory(plist: String, underlying: Error)
  case couldNotWritePlist(String)
  case invalidState(TargetState, action: String)
  case commandFailed(command: String, exitCode: Int32, stderr: String)
  case noDataDirectory
  case defaultsUnavailable(String)

  var description: String {
    switch self {
    case let .couldNotCreateDirectory(plist, underlying):
      return "Could not create intermediate directories for temporary plist \(plist): \(underlying)"
    case let .couldNotWritePlist(plist):
      return "Failed to write out defaults to temporary file \(plist)"
    case let .invalidState(state, action):
      return "Cannot \(action) a plist when the Simulator state is \(state.stateString), should be \(TargetStateString.shutdown) or \(TargetStateString.booted)"
    case let .commandFailed(command, exitCode, stderr):
      return "defaults \(command) failed with exit code \(exitCode): \(stderr)"
    case .noDataDirectory:
      return "The Simulator has no data directory, so its plists cannot be located"
    case let .defaultsUnavailable(reason):
      return reason
    }
  }
}

extension SimulatorDefaultsError: LocalizedError {
  var errorDescription: String? { description }
}

/// Reads and writes a simulator's defaults with the runtime's own `defaults` tool.
package struct SimulatorDefaults {

  let simulator: Simulator

  package init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Preferences

  private static let appleGlobalDomain = "Apple Global Domain"

  package func setPreference(_ name: String, value: String, type: String?, domain: String?) async throws {
    let effectiveDomain = domain ?? SimulatorDefaults.appleGlobalDomain
    try await setDefault(inDomain: effectiveDomain, key: name, value: value, type: type)
  }

  package func currentPreference(_ name: String, domain: String?) async throws -> String {
    let effectiveDomain = domain ?? SimulatorDefaults.appleGlobalDomain
    return try await defaultValue(inDomain: effectiveDomain, key: name)
  }

  /// Every preference of `domain`, as a property list. Throws where the other preference calls
  /// trap: on a runtime that has no `defaults`.
  package func exportedPreferences(domain: String?) async throws -> Data {
    let command = Command.export(domain: domain ?? SimulatorDefaults.appleGlobalDomain)
    let output = try await simulator.runtimeTools.run(hostExecutable: try locateDefaultsBinary(), arguments: command.arguments)
    guard command.exitCodePolicy.accepts(output.exitCode) else {
      throw SimulatorDefaultsError.commandFailed(
        command: command.arguments.joined(separator: " "), exitCode: output.exitCode, stderr: String(decoding: output.stderr, as: UTF8.self))
    }
    return output.stdout
  }

  // MARK: - Location Services

  package func approveLocationServices(forBundleIDs bundleIDs: [String]) async throws {
    var defaults: [String: Any] = [:]
    for bundleID in bundleIDs {
      defaults[bundleID] =
        [
          "Whitelisted": false,
          "BundleId": bundleID,
          "SupportedAuthorizationMask": 3,
          "Authorization": 2,
          "Authorized": true,
          "Executable": "",
          "Registered": "",
        ] as [String: Any]
    }

    try await amendRelativeTo(
      path: "Library/Caches/locationd/clients.plist",
      defaults: defaults,
      managingService: "locationd"
    )
  }

  package func revokeLocationServices(forBundleIDs bundleIDs: [String]) async throws {
    let state = simulator.state
    guard state == .booted || state == .shutdown else {
      throw SimulatorDefaultsError.invalidState(state, action: "modify")
    }
    guard let dataDirectory = simulator.dataDirectory else {
      throw SimulatorDefaultsError.noDataDirectory
    }

    let serviceName = "locationd"
    if state == .booted {
      _ = try await simulator.launchCtl.stopService(withName: serviceName)
    }

    let path = (dataDirectory as NSString)
      .appendingPathComponent("Library/Caches/locationd/clients.plist")
    // Delete sequentially: every delete is a read-modify-write of the same clients.plist, so running
    // them concurrently races and can drop entries when revoking several bundle IDs at once.
    for bundleID in bundleIDs {
      _ = try await run(.delete(path: path, key: bundleID))
    }

    if state == .booted {
      _ = try await simulator.launchCtl.startService(withName: serviceName)
    }
  }

  // MARK: - Defaults

  private func modifyDefaults(inDomainOrPath domainOrPath: String?, defaults: [String: Any]) async throws {
    let file = (simulator.auxillaryDirectory as NSString).appendingPathComponent("temporary.plist")
    let dirPath = (file as NSString).deletingLastPathComponent

    do {
      try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: nil)
    } catch {
      throw SimulatorDefaultsError.couldNotCreateDirectory(plist: file, underlying: error)
    }

    if !(defaults as NSDictionary).write(toFile: file, atomically: true) {
      throw SimulatorDefaultsError.couldNotWritePlist(file)
    }

    _ = try await run(.importPlist(domainOrPath: domainOrPath, file: file))
  }

  private func setDefault(inDomain domain: String, key: String, value: String, type: String?) async throws {
    _ = try await run(.write(domain: domain, key: key, type: type ?? "string", value: value))
  }

  private func defaultValue(inDomain domain: String, key: String) async throws -> String {
    return try await run(.read(domain: domain, key: key))
  }

  // The closed set of `defaults` operations this type issues.
  enum Command {
    case read(domain: String, key: String)
    case write(domain: String, key: String, type: String, value: String)
    case importPlist(domainOrPath: String?, file: String)
    case delete(path: String, key: String)
    case export(domain: String)

    var arguments: [String] {
      switch self {
      case let .read(domain, key):
        return ["read", domain, key]
      case let .write(domain, key, type, value):
        return ["write", domain, key, "-\(type)", value]
      case let .importPlist(domainOrPath, file):
        var args = ["import"]
        if let domainOrPath {
          args.append(domainOrPath)
        }
        args.append(file)
        return args
      case let .delete(path, key):
        return ["delete", path, key]
      case let .export(domain):
        return ["export", domain, "-"]
      }
    }

    var exitCodePolicy: ExitCodePolicy {
      switch self {
      case .read, .delete:
        // `defaults` returns 1 for a missing key/domain (a benign optional read or idempotent delete)
        // and for a genuine failure alike, with no distinguishing code, so tolerate any non-zero.
        return .tolerateAny
      case .write, .importPlist, .export:
        return .require([0])
      }
    }
  }

  private func run(_ command: Command) async throws -> String {
    let launchPath = defaultsBinary
    let output = try await simulator.runtimeTools.run(hostExecutable: launchPath, arguments: command.arguments)
    return try SimulatorDefaults.stdout(orThrowFrom: output, command: command, logger: simulator.logger)
  }

  static func stdout(orThrowFrom output: InSimulatorToolOutput, command: Command, logger: (any ControlCoreLogger)?) throws -> String {
    if output.exitCode != 0 {
      let stderr = String(data: output.stderr, encoding: .utf8) ?? ""
      guard command.exitCodePolicy.accepts(output.exitCode) else {
        throw SimulatorDefaultsError.commandFailed(command: command.arguments.joined(separator: " "), exitCode: output.exitCode, stderr: stderr)
      }
      logger?.log("defaults \(command.arguments.joined(separator: " ")) exited with code \(output.exitCode): \(stderr)")
    }
    let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
    return stdout.trimmingCharacters(in: .newlines)
  }

  private func amendRelativeTo(path relativePath: String, defaults: [String: Any], managingService serviceName: String) async throws {
    let state = simulator.state
    guard state == .booted || state == .shutdown else {
      throw SimulatorDefaultsError.invalidState(state, action: "amend")
    }
    guard let dataDirectory = simulator.dataDirectory else {
      throw SimulatorDefaultsError.noDataDirectory
    }

    // Stop the service while the plist is rewritten, restarting it afterwards if it was running.
    if state == .booted {
      _ = try await simulator.launchCtl.stopService(withName: serviceName)
    }
    let fullPath = (dataDirectory as NSString).appendingPathComponent(relativePath)
    try await modifyDefaults(inDomainOrPath: fullPath, defaults: defaults)
    if state == .booted {
      _ = try await simulator.launchCtl.startService(withName: serviceName)
    }
  }

  // MARK: - Private

  private var defaultsBinary: String {
    do {
      return try locateDefaultsBinary()
    } catch {
      fatalError("\(error)")
    }
  }

  private func locateDefaultsBinary() throws -> String {
    // `SimRuntime.root` comes from an unannotated CoreSimulator header, so it imports implicitly
    // unwrapped; it is only absent for a runtime that could not be resolved at all.
    guard let runtimeRoot = simulator.device.runtime.root else {
      throw SimulatorDefaultsError.defaultsUnavailable("Could not locate defaults as the Simulator runtime has no root")
    }
    let path =
      ((runtimeRoot as NSString)
      .appendingPathComponent("usr") as NSString)
      .appendingPathComponent("bin") as NSString
    let fullPath = path.appendingPathComponent("defaults")
    do {
      let binary = try BinaryDescriptor(path: fullPath)
      return binary.path
    } catch {
      throw SimulatorDefaultsError.defaultsUnavailable("Could not locate defaults at expected location '\(fullPath)', error \(error)")
    }
  }
}
