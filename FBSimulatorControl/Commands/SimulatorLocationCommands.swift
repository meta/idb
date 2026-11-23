/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation

public struct SimulatorLocationCommands: LocationCommands {

  private let simulator: Simulator

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  public func set(longitude: Double, latitude: Double) async throws {
    try simulator.device.setLocationWithLatitude(latitude, andLongitude: longitude)
  }
}
