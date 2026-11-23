/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation

public protocol MemoryCommands {

  func simulateWarning() async throws
}

public enum SimulatorMemoryError: Error, LocalizedError {
  case selectorUnavailable

  public var errorDescription: String? {
    switch self {
    case .selectorUnavailable:
      return "SimDevice doesn't have simulateMemoryWarning selector"
    }
  }
}

public struct SimulatorMemoryCommands: MemoryCommands {

  private let simulator: Simulator

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  public func simulateWarning() async throws {
    guard simulator.device.responds(to: NSSelectorFromString("simulateMemoryWarning")) else {
      throw SimulatorMemoryError.selectorUnavailable
    }
    simulator.device.simulateMemoryWarning()
  }
}
