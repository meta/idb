/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import Foundation

/// Resolves names in the simulated device's bootstrap namespace.
public struct SimulatorBootstrapPortCommands {

  private let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Lookup

  /// Bootstrap-namespace lookup for a Mach port name in the simulator. A live XPC round-trip to
  /// the CoreSimulator daemon (`SimDevice.lookup` is not cached).
  ///
  /// - Returns: the looked-up Mach port.
  /// - Throws: the device's own error if the lookup failed, or `SimulatorPortLookupError` when
  ///   the daemon reported no port without reporting an error.
  public func lookup(named name: String) throws -> mach_port_t {
    var error: NSError?
    let port = unsafe simulator.device.lookup(name, error: &error)
    // The port is checked before the error: CoreSimulator is unannotated private API, and a
    // populated error alongside a valid port is a success.
    guard port != mach_port_t(MACH_PORT_NULL) else {
      throw error ?? SimulatorPortLookupError.portNotFound(name: name)
    }
    return port
  }
}

/// The way a bootstrap-port lookup fails without the daemon reporting an error of its own.
public enum SimulatorPortLookupError: Error, LocalizedError {
  case portNotFound(name: String)

  public var errorDescription: String? {
    switch self {
    case let .portNotFound(name):
      return "No mach port named \(name) is registered in the simulator's bootstrap namespace"
    }
  }
}
