/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
import FBSimulatorControl
import Foundation

/// SpringBoard's lock state after a lock screen command.
public struct SimulatorLockState: Decodable, Sendable {
  public let locked: Bool
  /// Nil when the guest does not report it.
  let passcodeEnabled: Bool?
}

public enum SimulatorLockScreenError: Error {
  case undecodableState(output: String, reason: String)
}

extension SimulatorLockScreenError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .undecodableState(output, reason):
      return "Failed to decode the lock state '\(output)': \(reason)"
    }
  }
}

/// Locks and unlocks the simulated device through SpringBoard, without the hardware lock button's toggle.
///
/// `lock` and `unlock` are idempotent and return only once SpringBoard reports the requested state;
/// `unlock` fails on a device with a passcode. iOS only.
///
/// An unlock presses the Home button, which SpringBoard honours on every runtime, and only on a device the guest
/// reports locked without a passcode; from iOS 27 SpringBoard ignores the guest's own unlock request. The guest's
/// unlock then waits for SpringBoard to act on the press, falls back to its own request, and succeeds only once
/// SpringBoard reports the device unlocked. A guest that does not report the passcode gets no press.
public struct SimulatorLockScreenCommands {

  private let simulator: Simulator

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  public func state() async throws -> SimulatorLockState {
    try await run(.state)
  }

  public func lock() async throws -> SimulatorLockState {
    try await run(.lock)
  }

  public func unlock() async throws -> SimulatorLockState {
    try await Self.unlock(
      state: { try await run(.state) },
      pressHome: { try await simulator.hid.connect().send(event: .shortButtonPress(.homeButton), logger: simulator.logger) },
      unlock: { try await run(.unlock) })
  }

  static func unlock(
    state: () async throws -> SimulatorLockState,
    pressHome: () async throws -> Void,
    unlock: () async throws -> SimulatorLockState
  ) async throws -> SimulatorLockState {
    let current = try await state()
    guard current.locked else {
      return current
    }
    // A device with a passcode would show its keypad for the press; the guest refuses it without touching it.
    if current.passcodeEnabled == false {
      try await pressHome()
    }
    return try await unlock()
  }

  private func run(_ command: BridgeCommand.LockScreen) async throws -> SimulatorLockState {
    let output = try await simulator.runSimulatorFrameworkBridge(.lockScreen(command))
    return try SimulatorLockState.decode(bridgeOutput: output)
  }
}

extension SimulatorLockState {
  /// The state is the guest's one JSON value.
  static func decode(bridgeOutput output: String) throws -> SimulatorLockState {
    let line = output.split(separator: "\n").first.map(String.init) ?? ""
    do {
      return try JSONDecoder().decode(SimulatorLockState.self, from: Data(line.utf8))
    } catch {
      throw SimulatorLockScreenError.undecodableState(output: output, reason: error.localizedDescription)
    }
  }
}
