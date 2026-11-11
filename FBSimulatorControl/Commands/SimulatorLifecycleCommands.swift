/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
@preconcurrency import Foundation

private let openURLRetries = 2

public enum SimulatorLifecycleError: Error {
  case focusUnsupportedForCustomDeviceSet(deviceSetPath: String)
  case focusAmbiguous(runningApplications: String)
  case focusFailed(applicationDescription: String)
  case openURLFailed(url: URL, simulatorDescription: String, underlying: Error?)
}

extension SimulatorLifecycleError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .focusUnsupportedForCustomDeviceSet(deviceSetPath):
      return "Focusing on the Simulator App for a simulator in a custom device set (\(deviceSetPath)) is not supported"
    case let .focusAmbiguous(runningApplications):
      return "More than one SimulatorApp \(runningApplications) running, focus is ambiguous"
    case let .focusFailed(applicationDescription):
      return "Failed to focus \(applicationDescription)"
    case let .openURLFailed(url, simulatorDescription, underlying):
      guard let underlying else {
        return "Failed to open URL \(url) on simulator \(simulatorDescription)"
      }
      return "Failed to open URL \(url) on simulator \(simulatorDescription): \(underlying)"
    }
  }
}

public struct SimulatorLifecycleCommands: LifecycleCommands, Sendable {

  private let simulator: Simulator

  init(simulator: Simulator) {
    self.simulator = simulator
  }

  public func boot(_ configuration: SimulatorBootConfiguration) async throws {
    if simulator.state == .booted {
      return
    }
    if simulator.state != .shutdown {
      throw SimulatorStateError.notShutdown(operation: "boot", state: simulator.stateString.rawValue)
    }

    try await performBoot(with: configuration)
    if configuration.options.contains(.verifyUsable) {
      try await verifySimulatorIsBooted(simulator)
    } else {
      // CoreSimulator can run the boot's completion handler before the device reports `.booted`.
      try await TargetResolveState(simulator, .booted)
    }
  }

  private func performBoot(with configuration: SimulatorBootConfiguration) async throws {
    // "persist": the booted Simulator outlives the calling process; `.tieToProcessLifecycle` is its inverse.
    let persist = !configuration.options.contains(.tieToProcessLifecycle)
    let options: [String: Any] = [
      "persist": persist,
      "env": configuration.environment,
    ]

    try await awaitCoreSimulatorCompletion {
      simulator.device.bootAsync(options: options, completionQueue: simulator.workQueue, completionHandler: $0)
    }
  }

  public func resolveState(_ state: TargetState) async throws {
    try await TargetResolveState(simulator, state)
  }

  public func resolveLeavesState(_ state: TargetState) async throws {
    try await CoreSimulatorNotifier.resolveLeavesState(state, for: simulator.device)
  }

  /// Waits until the Simulator is usable: it reports itself `.booted` while still coming up, so
  /// the two are not the same moment. This is the wait `SimulatorBootOptions.verifyUsable`
  /// performs during `boot`, available on its own for a caller that took the state first.
  ///
  /// - Parameter deadline: How long to wait for. Waits indefinitely when `nil`.
  public func resolveUsable(deadline: PollDeadline? = nil) async throws {
    try await verifySimulatorIsBooted(simulator, deadline: deadline)
  }

  public func focus() async throws {
    // The Simulator host app (Simulator.app, or DeviceHub.app on Xcode 27+) only displays
    // simulators in the default device set, so 'focus' is unsupported for a custom device set.
    // This is also why Xcode parallel testing — which clones into a non-default device set — is
    // not visible in DeviceHub (Apple known issue 176809181).
    if let deviceSetPath = simulator.customDeviceSetPath {
      throw SimulatorLifecycleError.focusUnsupportedForCustomDeviceSet(deviceSetPath: deviceSetPath)
    }

    // Find the running instances of the Simulator host app. Xcode 27 renamed Simulator.app
    // (com.apple.iphonesimulator) to DeviceHub.app (com.apple.dt.Devices); match either.
    let apps = NSWorkspace.shared.runningApplications
    let simulatorAppBundleIDs: Set<String> = ["com.apple.iphonesimulator", "com.apple.dt.Devices"]
    let simulatorApps = apps.filter { app in
      guard let bundleIdentifier = app.bundleIdentifier else { return false }
      return simulatorAppBundleIDs.contains(bundleIdentifier)
    }

    guard let simulatorApp = simulatorApps.first else {
      try await SimulatorLifecycleCommands.launchSimulatorApplicationForDefaultDeviceSet()
      return
    }

    if simulatorApps.count > 1 {
      throw SimulatorLifecycleError.focusAmbiguous(runningApplications: CollectionInformation.oneLineDescription(from: simulatorApps))
    }

    if !simulatorApp.activate() {
      throw SimulatorLifecycleError.focusFailed(applicationDescription: String(describing: simulatorApp))
    }
  }

  private static func launchSimulatorApplicationForDefaultDeviceSet() async throws {
    let applicationBundle = XcodeConfiguration.simulatorApp
    let applicationURL = URL(fileURLWithPath: applicationBundle.path)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  public func open(_ url: URL) async throws {
    var lastError: NSError?
    for _ in 0...openURLRetries {
      lastError = nil
      do {
        try simulator.device.open(url)
        return
      } catch {
        lastError = error as NSError
      }
    }
    throw SimulatorLifecycleError.openURLFailed(url: url, simulatorDescription: String(describing: simulator), underlying: lastError)
  }
}

private let bootVerificationPollInterval: TimeInterval = 0.5
private let bootVerificationStallInterval: TimeInterval = 1.5

/// Waits until `simulator` has finished booting. `.booted` is not that signal — it is reported the
/// moment the boot is underway — so this waits for the state and then for the boot status to reach
/// a terminal value.
///
/// - Parameter deadline: How long to wait for, across both phases. Waits indefinitely when `nil`;
///   exceeding it throws `PollTimeoutError`.
///
/// Public: consumers outside this module wait on simulators they booted for the state only.
public func verifySimulatorIsBooted(_ simulator: Simulator, deadline: PollDeadline? = nil) async throws {
  // Started before the first wait, so the two phases share one bound rather than getting one each.
  let checkExpiry = deadline?.start()
  try await TargetResolveState(simulator, .booted, deadline: deadline)

  var lastBootInfo: SimDeviceBootInfo?
  var lastChange = Date()

  while true {
    try Task.checkCancellation()
    if let bootInfo = simulator.device.bootStatus() {
      if bootInfo.isEqual(lastBootInfo) {
        let stalledFor = Date().timeIntervalSince(lastChange)
        if stalledFor >= bootVerificationStallInterval {
          simulator.logger.log("Boot Status has not changed from '\(bootInfo.progressDescription)' for \(stalledFor) seconds")
        }
      } else {
        simulator.logger.debug().log("Boot Status Changed: \(bootInfo.progressDescription)")
        lastBootInfo = bootInfo
        lastChange = Date()
      }
      if bootInfo.isTerminalStatus {
        return
      }
    }
    try checkExpiry?()
    try await Task.sleep(nanoseconds: UInt64(bootVerificationPollInterval * Double(NSEC_PER_SEC)))
  }
}

extension SimDeviceBootInfoStatus {

  /// The status as it reads in a log line.
  var statusName: String {
    switch self {
    case .booting:
      return "Booting"
    case .waitingOnBackboard:
      return "WaitingOnBackboard"
    case .waitingOnDataMigration:
      return "WaitingOnDataMigration"
    case .waitingOnSystemApp:
      return "WaitingOnSystemApp"
    case .finished:
      return "Finished"
    case .dataMigrationFailed:
      return "DataMigrationFailed"
    @unknown default:
      return "Unknown(\(rawValue))"
    }
  }
}

extension SimDeviceBootInfo {

  /// The boot's progress as it reads in a log line: the status and how long it has taken, plus the
  /// migration detail when that is what it is waiting on.
  var progressDescription: String {
    let progress = "\(status.statusName) | Elapsed \(bootElapsedTime)"
    guard status == .waitingOnDataMigration else {
      return progress
    }
    return "\(progress) | Migration Phase '\(migrationPhaseDescription ?? "")' | Migration Elapsed \(migrationElapsedTime)"
  }
}
