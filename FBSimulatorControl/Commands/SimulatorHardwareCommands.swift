/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import Foundation

/// Physical actions on the simulated device that are not input to its screen or buttons.
public struct SimulatorHardwareCommands {
  private static let shakeNotification = "com.apple.UIKit.SimulatorShake"

  private let simulator: Simulator

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  public func lock() async throws {
    try await simulator.purpleHID.sendLockDevice()
  }

  public func shake() async throws {
    try simulator.device.postDarwinNotification(Self.shakeNotification)
  }
}
