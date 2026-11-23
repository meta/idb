/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import Foundation

/// Injects code into processes on a Simulator.
///
/// Each host is started with the shim injected. `additionalLibraries` are loaded into the host
/// alongside it, before any code is injected, so injected code resolves their symbols at load.
public struct SimulatorCodeInjectionCommands {

  private let simulator: Simulator

  init(simulator: Simulator) {
    self.simulator = simulator
  }

  /// Starts `target` with the shim injected and connects to it, waiting up to `connectTimeout` for
  /// the host to serve its control socket.
  public func inject(
    into target: CodeInjectionTarget,
    shim: CodeInjectionShim = .bundled,
    additionalLibraries: [String] = [],
    connectTimeout: TimeInterval = 120
  ) async throws -> CodeInjectionSession {
    let launcher = CodeInjectionHostLauncher(simulator: simulator)
    let host: CodeInjectionHost
    switch target {
    case let .application(bundleID, reattach):
      host = try await launcher.startApp(bundleID: bundleID, reuseSession: reattach, shim: shim, additionalLibraries: additionalLibraries)
    case .simulator:
      host = try await launcher.startSimulator(shim: shim, additionalLibraries: additionalLibraries)
    case let .logicTestBundle(path):
      host = try await launcher.startTest(bundlePath: path, shim: shim, additionalLibraries: additionalLibraries)
    }
    return try await CodeInjectionSession.connect(to: host, timeout: connectTimeout)
  }

  /// The environment that has an ordinary launch of the app `bundleID` start with the shim
  /// injected, so a later `inject(into: .application(bundleID:reattach: true))` joins it.
  public func launchEnvironment(
    forApplication bundleID: String,
    shim: CodeInjectionShim = .bundled,
    additionalLibraries: [String] = []
  ) throws -> [String: String] {
    try CodeInjectionHostLauncher(simulator: simulator).appLaunchEnvironment(bundleID: bundleID, shim: shim, additionalLibraries: additionalLibraries)
  }
}

extension Simulator {

  /// Injects code into the Simulator's processes: its apps, its guest bridge, and logic tests.
  public var codeInjection: SimulatorCodeInjectionCommands {
    SimulatorCodeInjectionCommands(simulator: self)
  }
}
