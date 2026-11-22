/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import FBSimulatorBridgeProtocol
import FBSimulatorControl
@preconcurrency import Foundation

/// Manages an application's HealthKit authorization for individual sample types.
public struct SimulatorHealthCommands {

  private let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Authorization

  public func set(_ approved: Bool, forBundleID bundleID: String, typeIdentifiers: [String]) async throws {
    try await simulator.runSimulatorFrameworkBridge(
      .health(
        approved
          ? .approve(bundleID: bundleID, typeIDs: typeIdentifiers)
          : .revoke(bundleID: bundleID, typeIDs: typeIdentifiers)))
  }

  public func clear(forBundleID bundleID: String) async throws {
    try await simulator.runSimulatorFrameworkBridge(.health(.clear(bundleID: bundleID)))
  }

  public func list(forBundleID bundleID: String) async throws -> String {
    try await simulator.runSimulatorFrameworkBridge(.health(.list(bundleID: bundleID)))
  }
}
