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

public enum SimulatorNetworkError: Error, LocalizedError {
  case noDnsServers

  public var errorDescription: String? {
    switch self {
    case .noDnsServers:
      return "At least one DNS server address is required"
    }
  }
}

/// Configures the HTTP proxy and DNS resolvers the simulated device uses.
public struct SimulatorNetworkCommands {

  private let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Sub-nouns

  public var proxy: Proxy {
    Proxy(simulator: simulator)
  }

  public var dns: DNS {
    DNS(simulator: simulator)
  }

  /// The HTTP proxy the simulated device routes through.
  public struct Proxy {

    private let simulator: Simulator

    internal init(simulator: Simulator) {
      self.simulator = simulator
    }

    public func set(host: String, port: UInt, type: String) async throws {
      try await simulator.runSimulatorFrameworkBridge(
        .proxy(.set(host: host, port: Int32(clamping: port), kind: type == "socks" ? .socks : .http)))
    }

    public func clear() async throws {
      try await simulator.runSimulatorFrameworkBridge(.proxy(.clear))
    }

    public func list() async throws -> String {
      try await simulator.runSimulatorFrameworkBridge(.proxy(.list))
    }
  }

  /// The resolvers the simulated device queries.
  public struct DNS {

    private let simulator: Simulator

    internal init(simulator: Simulator) {
      self.simulator = simulator
    }

    public func set(_ servers: [String]) async throws {
      if servers.isEmpty {
        throw SimulatorNetworkError.noDnsServers
      }
      try await simulator.runSimulatorFrameworkBridge(.dns(.set(servers: servers)))
    }

    public func clear() async throws {
      try await simulator.runSimulatorFrameworkBridge(.dns(.clear))
    }

    public func list() async throws -> String {
      try await simulator.runSimulatorFrameworkBridge(.dns(.list))
    }
  }
}
