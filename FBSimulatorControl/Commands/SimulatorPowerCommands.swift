/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation

private let shutdownWhenShuttingDownErrorCode = 164

public struct SimulatorPowerCommands: PowerCommands {
  private let simulator: Simulator

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Async

  public func shutdown() async throws {
    let logger = simulator.logger
    logger.debug().log("Starting Safe Shutdown of \(simulator.udid)")

    if simulator.state == .unknown {
      throw SimulatorStateError.unknownState(operation: "prepare for usage")
    }
    if simulator.state == .shutdown {
      logger.debug().log("Shutdown of \(simulator.udid) succeeded as it is already shutdown")
      return
    }
    if simulator.state == .creating {
      try await transitionCreatingToShutdown()
      return
    }
    try await shutdownSimulator()
  }

  public func reboot() async throws {
    try await shutdown()
    try await simulator.lifecycle.boot(SimulatorBootConfiguration.default)
  }

  // MARK: - Private

  private func shutdownSimulator() async throws {
    let logger = simulator.logger
    logger.debug().log("Shutting down Simulator \(simulator.udid)")
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      simulator.device.shutdownAsync(withCompletionQueue: simulator.asyncQueue) { error in
        if let error = error as NSError?, error.code == shutdownWhenShuttingDownErrorCode {
          logger.log("Got Error Code \(error.code) from shutdown, simulator is already shutdown")
          continuation.resume(returning: ())
        } else if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
    try await TargetResolveState(simulator, .shutdown)
  }

  private func transitionCreatingToShutdown() async throws {
    do {
      try await TargetResolveState(
        simulator,
        .shutdown,
        deadline: PollDeadline(
          timeout: ControlCoreGlobalConfiguration.regularTimeout,
          waitingFor: "Simulator to resolve state \(TargetStateString.shutdown)"))
      return
    } catch {
      try await eraseCreatingSimulator()
    }
  }

  private func eraseCreatingSimulator() async throws {
    simulator.logger.debug().log("Erasing Simulator \(simulator.udid)")
    try await awaitCoreSimulatorCompletion {
      simulator.device.eraseContentsAndSettingsAsync(withCompletionQueue: simulator.asyncQueue, completionHandler: $0)
    }
    try await TargetResolveState(
      simulator,
      .shutdown,
      deadline: PollDeadline(
        timeout: ControlCoreGlobalConfiguration.regularTimeout,
        waitingFor: "Simulator to transition from Creating -> Shutdown"))
  }
}
