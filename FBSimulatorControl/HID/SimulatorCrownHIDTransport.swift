/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Maps a stream of crown samples onto the `dtuhidd` `began` / `changed` / `ended` phases, as
/// `DigitizerContactTracker` does for contacts: the first `.down` begins a turn, later ones change it,
/// and `.up` ends it. A `.down` that would continue a turn begun under an earlier `interruptions`
/// count throws, since the daemon no longer has that turn; the next `.down` begins afresh.
struct CrownPhaseTracker {
  /// The connection's interruption count when the turn began, while one is in progress.
  private var beganAt: Int?

  mutating func phase(for direction: SimulatorHIDDirection, interruptions: Int) throws -> ScrollPhase {
    switch direction {
    case .down:
      guard let beganAt else {
        beganAt = interruptions
        return .began
      }
      guard beganAt == interruptions else {
        self.beganAt = nil
        throw SimulatorHIDError.dtuhidGestureInterrupted
      }
      return .changed
    case .up:
      beganAt = nil
      return .ended
    }
  }
}

/**
 The transport for Apple Watch Digital Crown rotation. `dtuhidd` serves the crown on a scroll service
 of its own, beside the digitizer, so this is a second DTUHID connection rather than a second use of
 the first.

 Established on first use and then kept: the guest's crown service belongs to the connection, and
 tearing the connection down before the guest has consumed a turn cancels the turn.

 One per `SimulatorHID`, closed with it.
 */
actor SimulatorCrownHIDTransport {
  typealias Connect = @Sendable () async throws -> SimulatorDTUHIDConnection

  static let serviceName = "com.apple.coredevice.feature.remote.hid.scroll"

  private let connection: SimulatorSharedConnection<SimulatorDTUHIDConnection>
  private let productFamily: ProductFamily
  private var rotation = CrownPhaseTracker()
  /// The connection once one has been made, so that draining never makes one.
  private var established: SimulatorDTUHIDConnection?

  init(simulator: Simulator?) {
    self.init(productFamily: simulator?.productFamily ?? .unknown) { [weak simulator] in
      guard let simulator else { throw WeakTargetError.simulator }
      return try await SimulatorDTUHIDConnection.connect(using: simulator.xpc, serviceName: Self.serviceName)
    }
  }

  init(productFamily: ProductFamily, connect: @escaping Connect) {
    self.productFamily = productFamily
    self.connection = SimulatorSharedConnection(connect)
  }

  /// Sends one sample of a rotation. `.down` carries `delta`; `.up` ends the turn and carries none.
  ///
  /// Nothing suspends between the tracker assigning a phase and the write, so concurrent sends
  /// cannot deliver an `ended` ahead of the `began` it followed.
  func sendCrown(direction: SimulatorHIDDirection, delta: Double) async throws {
    guard productFamily == .appleWatch else {
      throw SimulatorHIDError.crownUnsupportedOnProductFamily(productFamily)
    }
    guard delta.isFinite else {
      throw SimulatorCrownRotationError.notFinite(delta)
    }
    let connection = try await self.connection.connection()
    established = connection
    let phase = try rotation.phase(for: direction, interruptions: connection.interruptions)
    let event = IndigoScrollEvent(
      point: .crown(phase == .ended ? 0 : delta),
      phase: phase,
      target: .digitalCrown)
    do {
      try connection.write(messageType: "IndigoScrollEvent", payload: event)
    } catch {
      await disconnect()
      throw error
    }
    await connection.awaitSendBarrier()
  }

  /// Lets the guest consume what was sent before anything tears the connection down.
  func flush() async throws {
    try await established?.flush()
  }

  /// Tears down the connection, if one was ever established, and forgets any turn in progress.
  func disconnect() async {
    rotation = CrownPhaseTracker()
    established = nil
    (try? await connection.reset()?.value)?.disconnect()
  }
}
