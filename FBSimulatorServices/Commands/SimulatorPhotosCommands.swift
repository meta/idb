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

/// Manages the contents of the simulated device's photo library.
public struct SimulatorPhotosCommands {

  private let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Library

  public func clear() async throws {
    try await simulator.runSimulatorFrameworkBridge(.clearPhotos)
  }
}
