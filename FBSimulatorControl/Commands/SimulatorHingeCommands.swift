/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

public struct SimulatorHingeCommands {
  private let simulator: Simulator

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  public func set(_ angle: SimulatorHingeAngle) async throws {
    try await MotionCapabilities.resolve(on: simulator).require(.hingeAngle)
    try await simulator.hid.vendorDefined.send(angle.vendorEvent())
  }

  /// Sets the hinge, then waits within `timeout` for the measured angle to come within half a degree of it and
  /// for the displays to settle. Returns the configuration the change left the displays in, which is
  /// `.transitioning` when they outlast the budget.
  public func set(_ angle: SimulatorHingeAngle, confirmingWithin timeout: Duration) async throws -> SimulatorDisplayConfiguration {
    try await set(angle, confirmingWithin: timeout, interval: .milliseconds(100))
  }

  /// Reads a fresh measured angle. During a hinge animation this can be between its endpoints.
  public func current() async throws -> SimulatorHingeAngle {
    try await MotionCapabilities.resolve(on: simulator).require(.hingeAngle)
    let channel = UUID()
    // Samples older than the request are the provider replaying its last known state.
    let notBefore = ProcessInfo.processInfo.systemUptime
    return try await simulator.coreDevice.stream(
      action: SimulatorHingeProtocol.action, service: SimulatorHingeProtocol.service,
      input: SimulatorHingeProtocol.StreamInput(channel: channel)
    ) { event in
      try SimulatorHingeProtocol.sample(event, channel: channel, notBefore: notBefore, now: ProcessInfo.processInfo.systemUptime)
    }
  }

  /// Publishes fresh measured angles until cancelled, retaining only the newest unread sample.
  public func angles() async throws -> AsyncThrowingStream<SimulatorHingeAngle, any Error> {
    try await MotionCapabilities.resolve(on: simulator).require(.hingeAngle)
    try Task.checkCancellation()
    let channel = UUID()
    let notBefore = ProcessInfo.processInfo.systemUptime
    return try simulator.coreDevice.subscribe(
      action: SimulatorHingeProtocol.action, service: SimulatorHingeProtocol.service,
      input: SimulatorHingeProtocol.StreamInput(channel: channel),
      bufferingPolicy: .bufferingNewest(1)
    ) { event in
      try SimulatorHingeProtocol.sample(event, channel: channel, notBefore: notBefore, now: ProcessInfo.processInfo.systemUptime)
    }
  }
}

extension SimulatorHingeCommands: PoseCommands {
  package var displays: any DisplayCommands { simulator.displays }

  package func reached(_ value: SimulatorHingeAngle, target: SimulatorHingeAngle) -> Bool {
    abs(value.degrees - target.degrees) <= 0.5
  }

  package func pose(_ value: SimulatorHingeAngle) -> SimulatorPose { .hinge(value) }
}
