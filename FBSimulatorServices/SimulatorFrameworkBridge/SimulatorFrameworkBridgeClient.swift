/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
import FBSimulatorControl
import Foundation

/// Where a typed command runs.
enum SimulatorFrameworkBridgeRoute: Equatable {
  case persistent
  /// A oneshot guest staged to appear as `bundleIdentity`.
  case staged(bundleIdentity: String)
}

extension BridgeCommand {
  /// The persistent guest is launched from `Resources` and shared by every command, so it cannot appear as any one
  /// app: a command that needs an identity is staged.
  var route: SimulatorFrameworkBridgeRoute {
    if case let .notifications(command) = self {
      switch command {
      case let .delivered(bundleID), let .clearDelivered(bundleID), let .sendWithServiceExtension(bundleID, _):
        if let bundleIdentity = SimulatorFrameworkBridgeStaging.bundleIdentity(bundleID) {
          return .staged(bundleIdentity: bundleIdentity)
        }
      case .list, .approve, .revoke:
        break
      }
    }
    return .persistent
  }
}

extension BridgeCommand {
  /// `<service> <action>`, as the positional CLI spells it.
  var serviceAndAction: String {
    switch self {
    case .clearContacts: "contacts clear"
    case .clearPhotos: "photos clear"
    case let .dns(command):
      switch command {
      case .list: "dns list"
      case .set: "dns set"
      case .clear: "dns clear"
      }
    case let .dynamicStore(command):
      switch command {
      case .snapshot: "dynamic-store snapshot"
      case .restore: "dynamic-store restore"
      }
    case let .proxy(command):
      switch command {
      case .list: "proxy list"
      case .set: "proxy set"
      case .clear: "proxy clear"
      }
    case let .notifications(command):
      switch command {
      case .list: "notifications list"
      case .approve: "notifications approve"
      case .revoke: "notifications revoke"
      case .delivered: "notifications delivered"
      case .clearDelivered: "notifications clear-delivered"
      case .sendWithServiceExtension: "notifications send-service-extension"
      }
    case let .health(command):
      switch command {
      case .list: "health list"
      case .clear: "health clear"
      case .approve: "health approve"
      case .revoke: "health revoke"
      }
    case let .lockScreen(command):
      switch command {
      case .state: "lock-screen state"
      case .lock: "lock-screen lock"
      case .unlock: "lock-screen unlock"
      }
    case let .accessibility(request): "accessibility \(request.verb.rawValue)"
    case .ping: "ping"
    case .shutdown: "shutdown"
    }
  }
}

/// Launches a copy of the guest that daemons see as a particular app.
///
/// The guest is spawned by host path — `SimDevice` resolves `launchPath` against the host
/// filesystem rather than the runtime root — so the directory the executable sits in is
/// something the simulator can see, not only a detail of how the companion is packaged.
enum SimulatorFrameworkBridgeStaging {

  /// The app identity a guest may be staged as, or nil for an argument that could not name an app.
  ///
  /// `usernotificationsd` answers a client only for the bundle `BSBundleIDForPID` reports for
  /// it, and that is read from the `Info.plist` beside the client's executable. The delivered
  /// notifications of an app can therefore only be read or withdrawn by a guest that appears
  /// to be it. Rejecting anything else also keeps the identity from being used as an arbitrary
  /// path component when staging.
  static func bundleIdentity(_ bundleID: String) -> String? {
    guard bundleID.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil, bundleID != ".", bundleID != ".." else {
      return nil
    }
    return bundleID
  }

  /// `bundledGuestPath` is the guest shipped in the companion's `Resources`, shared by every
  /// command, so it cannot carry any one app's identity. This stages a copy of it in
  /// `stagingDirectory` beside an `Info.plist` naming that app. The copy is a hardlink where the
  /// filesystem allows it, and never a symlink: `proc_pidpath` resolves a symlink back to
  /// `Resources`, where there is no `Info.plist` to read.
  static func stagedExecutablePath(bundledGuestPath: String, bundleIdentity: String, stagingDirectory: URL) throws -> String {
    let guest = URL(fileURLWithPath: bundledGuestPath)
    let bundle = stagingDirectory.appendingPathComponent(bundleIdentity, isDirectory: true)
    let staged = bundle.appendingPathComponent(guest.lastPathComponent)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    do {
      try FileManager.default.linkItem(at: guest, to: staged)
    } catch {
      // Resources and the temporary directory need not share a filesystem.
      try FileManager.default.copyItem(at: guest, to: staged)
    }
    let infoPlist: [String: String] = [
      "CFBundleExecutable": guest.lastPathComponent,
      "CFBundleIdentifier": bundleIdentity,
      "CFBundlePackageType": "APPL",
      "CFBundleVersion": "1",
    ]
    try PropertyListSerialization
      .data(fromPropertyList: infoPlist, format: .xml, options: 0)
      .write(to: bundle.appendingPathComponent("Info.plist"))
    return staged.path
  }
}

/// Runs the guest once to completion, for a oneshot transport.
protocol BridgeGuestLauncher: Sendable {
  func launch(_ arguments: [String]) async throws -> InSimulatorToolOutput
}

package struct SimulatorFrameworkBridgeOneshotTransport: Sendable {
  private let launcher: any BridgeGuestLauncher

  init(simulator: Simulator, bundleIdentity: String? = nil) {
    launcher = SimulatorBridgeGuestLauncher(simulator: simulator, bundleIdentity: bundleIdentity)
  }

  init(launcher: any BridgeGuestLauncher) {
    self.launcher = launcher
  }

  func send(_ request: BridgeRequest) async throws -> BridgeResult {
    try await exchange(request).result
  }

  /// The result, and the size of the output it was printed as.
  func exchange(_ request: BridgeRequest) async throws -> (result: BridgeResult, frameBytes: Int) {
    let output = try await launcher.launch(request.arguments)
    guard !output.stdout.isEmpty else {
      throw AXBridgeError.guestFailure("exit \(output.exitCode); \(SimulatorFrameworkBridgeError.failureDetails(stderr: output.stderr, stdout: output.stdout))")
    }
    let response = try BridgeResponse.decode(output.stdout, for: request)
    guard output.exitCode == response.result.exitCode else {
      throw AXBridgeError.guestFailure("process exited with \(output.exitCode) after reporting \(response.result.exitCode)")
    }
    return (response.result, output.stdout.count)
  }
}

private struct SimulatorBridgeGuestLauncher: BridgeGuestLauncher {
  let simulator: Simulator
  let bundleIdentity: String?

  func launch(_ arguments: [String]) async throws -> InSimulatorToolOutput {
    guard let path = simulator.frameworkBridgePath else { throw SimulatorFrameworkBridgeError.binaryMissing }
    guard let bundleIdentity else {
      return try await simulator.runtimeTools.run(hostExecutable: path, arguments: arguments)
    }
    return try await simulator.temporaryDirectory.withTemporaryDirectory { stagingDirectory in
      try await simulator.runtimeTools.run(
        hostExecutable: SimulatorFrameworkBridgeStaging.stagedExecutablePath(
          bundledGuestPath: path,
          bundleIdentity: bundleIdentity,
          stagingDirectory: stagingDirectory),
        arguments: arguments)
    }
  }
}

extension BridgeResult {
  /// The guest's answer to an accessibility command.
  func accessibilityAnswer() throws -> BridgeAXAnswer {
    guard let accessibility else {
      throw AXBridgeError.guestFailure(error ?? "accessibility returned no answer")
    }
    return accessibility
  }

}

extension Simulator {
  /// Reuses guest startup across services while keeping shared and exclusive connections separate.
  package func frameworkBridgeTransport(scope: BridgeServiceScope) -> SimulatorFrameworkBridgePersistentTransport {
    commandCache.resolve { BridgeTransportsByScope() }
      .transport(for: scope) { SimulatorFrameworkBridgePersistentTransport(simulator: self, scope: scope) }
  }

  /// Executes a typed guest command; the result retains partial output when the guest fails.
  func frameworkBridge(_ command: BridgeCommand) async throws -> BridgeResult {
    let request = BridgeRequest(command: command)
    do {
      switch command.route {
      case let .staged(bundleIdentity): return try await SimulatorFrameworkBridgeOneshotTransport(simulator: self, bundleIdentity: bundleIdentity).send(request)
      case .persistent: return try await frameworkBridgeTransport(scope: .shared).send(request)
      }
    } catch AXBridgeError.bridgeUnavailable {
      throw SimulatorFrameworkBridgeError.binaryMissing
    } catch let AXBridgeError.guestFailure(reason) {
      // The transports report in accessibility's terms because accessibility classifies these failures; other
      // services only need the reason.
      throw SimulatorFrameworkBridgeError.transportFailed(command: command.serviceAndAction, reason: reason)
    } catch let error as AXBridgeError {
      throw SimulatorFrameworkBridgeError.transportFailed(command: command.serviceAndAction, reason: error.localizedDescription)
    }
  }

  @discardableResult
  func runSimulatorFrameworkBridge(_ command: BridgeCommand) async throws -> String {
    let result = try await frameworkBridge(command)
    let output = try result.reportedOutput
    guard result.exitCode == 0 else {
      throw SimulatorFrameworkBridgeError.commandFailed(command: command.serviceAndAction, exitCode: result.exitCode, output: output)
    }
    return output
  }
}

/// One socket-backed transport per service scope, for one target.
///
/// `TargetCommandCache` keys its slots by type, and the two scopes need separate transports that
/// are the same type, so this holds them apart.
///
// SAFETY: `transports` is only read or written with `lock` held, so no mutable state is reachable from
// two threads at once.
// patternlint-disable-next-line unchecked-sendable
final class BridgeTransportsByScope: @unchecked Sendable {
  private let lock = NSLock()
  private var transports: [BridgeServiceScope: SimulatorFrameworkBridgePersistentTransport] = [:]

  func transport(
    for scope: BridgeServiceScope,
    build: () -> SimulatorFrameworkBridgePersistentTransport
  ) -> SimulatorFrameworkBridgePersistentTransport {
    lock.lock()
    defer { lock.unlock() }
    if let existing = transports[scope] {
      return existing
    }
    let created = build()
    transports[scope] = created
    return created
  }
}
