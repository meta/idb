/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorControl
import Foundation
import Testing
import XPC

/// The crown transport, against a synthetic scroll service that answers the liveness barrier.
@Suite
struct SimulatorCrownHIDTransportTests {

  private struct NoSleep: DTUHIDSleeper {
    func sleep(for duration: Duration) async throws {}
  }

  private actor Connections {
    let services = SyntheticXPCServices()
    let peer: SyntheticXPCPeer
    var attempts = 0
    private(set) var latest: SimulatorDTUHIDConnection?

    init() {
      peer = services.register(SimulatorCrownHIDTransport.serviceName) { request in
        guard xpc_dictionary_get_bool(request.message, "isBarrier") else { return }
        request.reply(xpc_dictionary_create(nil, nil, 0))
      }
    }

    func connect() async throws -> SimulatorDTUHIDConnection {
      attempts += 1
      let connection = try await SimulatorDTUHIDConnection.connect(
        using: services.connector,
        serviceName: SimulatorCrownHIDTransport.serviceName,
        sleeper: NoSleep())
      latest = connection
      return connection
    }
  }

  private func transport(_ connections: Connections, family: ProductFamily = .appleWatch) -> SimulatorCrownHIDTransport {
    SimulatorCrownHIDTransport(productFamily: family) { try await connections.connect() }
  }

  // MARK: - The rotation a caller can express

  @Test(arguments: [Double.nan, .infinity, -.infinity])
  func aNonFiniteDeltaIsRejected(_ delta: Double) throws {
    #expect {
      try SimulatorCrownRotation(delta: delta)
    } throws: { error in
      guard case .notFinite = error as? SimulatorCrownRotationError else { return false }
      return true
    }
  }

  @Test
  func aZeroDeltaIsRejected() throws {
    #expect {
      try SimulatorCrownRotation(delta: 0)
    } throws: { error in
      guard case .zero = error as? SimulatorCrownRotationError else { return false }
      return true
    }
  }

  @Test(arguments: [1800.000_001, -1800.000_001, 1e9])
  func aDeltaBeyondTheBoundIsRejected(_ delta: Double) throws {
    #expect {
      try SimulatorCrownRotation(delta: delta)
    } throws: { error in
      guard case let .outOfRange(rejected, maximum) = error as? SimulatorCrownRotationError else { return false }
      return rejected == delta && maximum == 1800
    }
  }

  @Test(arguments: [0.5, -0.5, 1800.0, -1800.0])
  func theBoundsThemselvesAreAccepted(_ delta: Double) {
    #expect(throws: Never.self) {
      try SimulatorCrownRotation(delta: delta)
    }
  }

  /// A large rotation stays bounded on the wire, and the steps keep the caller's sign and total.
  @Test
  func theStepsAreBoundedAndKeepTheSignAndTotal() throws {
    let rotation = try SimulatorCrownRotation(delta: -1800)
    let steps = rotation.steps
    #expect(steps.count == 256)
    #expect(steps.allSatisfy { $0 < 0 })
    #expect(abs(steps.reduce(0, +) - rotation.delta) < 1e-9)
  }

  @Test
  func aSmallRotationIsStillSentAsAtLeastOneStep() throws {
    #expect(try SimulatorCrownRotation(delta: 0.5).steps == [0.5])
  }

  // MARK: - The gesture a rotation becomes

  @Test
  func aRotationIsAWholeGestureEndingInARelease() throws {
    let event = try SimulatorHIDEvent.crownRotation(try SimulatorCrownRotation(delta: 25), duration: 0)
    let children = try #require(event.subEvents)
    let crowns = children.compactMap { child -> SimulatorHIDEvent? in
      guard case .crown = child else { return nil }
      return child
    }
    #expect(
      crowns == Array(repeating: .crown(direction: .down, delta: 5), count: 5) + [.crown(direction: .up, delta: 0)])
  }

  @Test(arguments: [-0.1, Double.nan, .infinity, 1e20])
  func aDurationThatCannotBeSleptForIsRejectedBeforeAnyEventIsBuilt(_ duration: Double) throws {
    #expect {
      try SimulatorHIDEvent.crownRotation(try SimulatorCrownRotation(delta: 25), duration: duration)
    } throws: { error in
      guard case .invalidDelay = error as? SimulatorHIDError else { return false }
      return true
    }
  }

  // MARK: - What reaches dtuhidd

  private func payloads(_ received: [xpc_object_t]) -> [xpc_object_t] {
    received
      .filter { !xpc_dictionary_get_bool($0, "isBarrier") }
      .compactMap { xpc_dictionary_get_value($0, "payload") }
  }

  private func phases(_ received: [xpc_object_t]) -> [UInt64] {
    payloads(received).map { xpc_dictionary_get_uint64($0, "phase") }
  }

  @Test
  func aRotationIsSerializedAsAScrollEventOnTheCrownTarget() async throws {
    let connections = Connections()
    let crown = transport(connections)
    try await crown.sendCrown(direction: .down, delta: 7.5)
    try await crown.sendCrown(direction: .up, delta: 0)
    let peer = connections.peer
    let received = await peer.received(atLeast: 3)

    #expect(
      received.dropFirst().map { xpc_dictionary_get_string($0, "messageType").map { String(cString: $0) } }
        == ["IndigoScrollEvent", "IndigoScrollEvent"])
    #expect(
      received.dropFirst().map { xpc_dictionary_get_string($0, "featureIdentifier").map { String(cString: $0) } }
        == ["com.apple.coredevice.feature.remote.hid.scroll", "com.apple.coredevice.feature.remote.hid.scroll"])

    let payloads = payloads(received)
    #expect(payloads.count == 2)
    let first = try #require(payloads.first)
    let point = try #require(xpc_dictionary_get_value(first, "point"))
    #expect(xpc_dictionary_get_double(point, "x") == 0)
    #expect(xpc_dictionary_get_double(point, "y") == 7.5)
    #expect(xpc_dictionary_get_double(point, "z") == 0)
    #expect(xpc_get_type(try #require(xpc_dictionary_get_value(first, "phase"))) == XPC_TYPE_UINT64)
    #expect(xpc_dictionary_get_uint64(first, "phase") == 1)
    #expect(xpc_dictionary_get_uint64(first, "momentum") == 0)
    #expect(xpc_dictionary_get_uint64(first, "target") == 0)
    await crown.disconnect()
  }

  /// began, then changed for every later sample, then ended, and the release carries no delta
  /// whatever the caller passed with it.
  @Test
  func thePhasesFollowTheGesture() async throws {
    let connections = Connections()
    let crown = transport(connections)
    for _ in 0..<3 {
      try await crown.sendCrown(direction: .down, delta: 5)
    }
    try await crown.sendCrown(direction: .up, delta: 99)
    let peer = connections.peer
    let received = await peer.received(atLeast: 5)
    #expect(phases(received) == [1, 2, 2, 4])
    let release = try #require(payloads(received).last)
    let point = try #require(xpc_dictionary_get_value(release, "point"))
    #expect(xpc_dictionary_get_double(point, "y") == 0)
    await crown.disconnect()
  }

  @Test
  func aGestureAfterAReleaseBeginsAgain() async throws {
    let connections = Connections()
    let crown = transport(connections)
    try await crown.sendCrown(direction: .down, delta: 5)
    try await crown.sendCrown(direction: .up, delta: 0)
    try await crown.sendCrown(direction: .down, delta: 5)
    let peer = connections.peer
    let received = await peer.received(atLeast: 4)
    #expect(phases(received) == [1, 4, 1])
    await crown.disconnect()
  }

  @Test
  func theConnectionIsEstablishedOnceAndReusedAcrossAGesture() async throws {
    let connections = Connections()
    let crown = transport(connections)
    for _ in 0..<4 {
      try await crown.sendCrown(direction: .down, delta: 5)
    }
    #expect(await connections.attempts == 1)
    #expect(connections.peer.connections == 1)
    await crown.disconnect()
  }

  // MARK: - Fail closed

  @Test(arguments: [ProductFamily.iPhone, .iPad, .appleTV, .mac, .unknown])
  func aTargetWithoutACrownIsRejectedBeforeAnythingIsSent(_ family: ProductFamily) async throws {
    let connections = Connections()
    let crown = transport(connections, family: family)
    await #expect {
      try await crown.sendCrown(direction: .down, delta: 25)
    } throws: { error in
      guard case let .crownUnsupportedOnProductFamily(reported) = error as? SimulatorHIDError else { return false }
      return reported == family
    }
    #expect(await connections.attempts == 0)
  }

  @Test
  func aNonFiniteDeltaNeverReachesTheWire() async throws {
    let connections = Connections()
    let crown = transport(connections)
    await #expect {
      try await crown.sendCrown(direction: .down, delta: .nan)
    } throws: { error in
      guard case .notFinite = error as? SimulatorCrownRotationError else { return false }
      return true
    }
    #expect(await connections.attempts == 0)
  }

  @Test
  func aFailedWriteDoesNotPoisonTheNextRotationPhase() async throws {
    let connections = Connections()
    let crown = SimulatorCrownHIDTransport(productFamily: .appleWatch) {
      let connection = try await connections.connect()
      if await connections.attempts == 1 { connection.disconnect() }
      return connection
    }
    await #expect(throws: SimulatorHIDError.self) {
      try await crown.sendCrown(direction: .down, delta: 25)
    }
    try await crown.sendCrown(direction: .down, delta: 25)
    let peer = connections.peer
    let received = await peer.received(atLeast: 3)
    #expect(phases(received) == [1])
    #expect(await connections.attempts == 2)
    await crown.disconnect()
  }

  /// `dtuhidd` loses a turn with its connection, so the turn fails rather than sending `changed` to a
  /// daemon that never saw `began`, and the next sample begins a fresh one.
  @Test
  func aTurnLostToAnInterruptionFailsAndTheNextBeginsAfresh() async throws {
    let connections = Connections()
    let crown = transport(connections)
    try await crown.sendCrown(direction: .down, delta: 5)
    let connection = try #require(await connections.latest)
    connection.observe(.interrupted)

    await #expect {
      try await crown.sendCrown(direction: .down, delta: 5)
    } throws: { error in
      guard case .dtuhidGestureInterrupted = error as? SimulatorHIDError else { return false }
      return true
    }
    try await crown.sendCrown(direction: .down, delta: 5)
    let peer = connections.peer
    let received = await peer.received(atLeast: 3)
    #expect(phases(received) == [1, 1])
    #expect(await connections.attempts == 1)
    await crown.disconnect()
  }

  /// Nothing connects until a rotation is actually sent, so a session that never uses the crown
  /// never creates the guest's crown service.
  @Test
  func flushingWithoutARotationConnectsNothing() async throws {
    let connections = Connections()
    let crown = transport(connections)
    try await crown.flush()
    #expect(await connections.attempts == 0)
  }
}
