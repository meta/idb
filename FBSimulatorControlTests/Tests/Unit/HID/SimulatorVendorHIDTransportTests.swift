/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBSimulatorControl
import Foundation
import Testing
import XPC

/// The vendor-defined transport connects once and keeps the connection, here to a synthetic vendor
/// service that answers the liveness barrier.
@Suite
struct SimulatorVendorHIDTransportTests {

  private enum ConnectFailure: Error {
    case injected
  }

  private struct NoSleep: DTUHIDSleeper {
    func sleep(for duration: Duration) async throws {}
  }

  private actor Connections {
    let services = SyntheticXPCServices()
    let peer: SyntheticXPCPeer
    var attempts = 0
    var failNext = false

    init() {
      peer = services.register(SimulatorVendorHIDTransport.serviceName) { request in
        guard xpc_dictionary_get_bool(request.message, "isBarrier") else { return }
        request.reply(xpc_dictionary_create(nil, nil, 0))
      }
    }

    func fail(_ fail: Bool) { failNext = fail }

    func connect() async throws -> SimulatorDTUHIDConnection {
      attempts += 1
      if failNext { throw ConnectFailure.injected }
      return try await SimulatorDTUHIDConnection.connect(
        using: services.connector,
        serviceName: SimulatorVendorHIDTransport.serviceName,
        sleeper: NoSleep())
    }
  }

  private func event() throws -> IndigoVendorDefinedEvent {
    try SimulatorHingeAngle(degrees: 90).vendorEvent()
  }

  @Test
  func theConnectionIsEstablishedOnceAndReusedAcrossSends() async throws {
    let connections = Connections()
    let vendor = SimulatorVendorHIDTransport { try await connections.connect() }
    for _ in 0..<3 {
      try await vendor.send(event())
    }
    let attempts = await connections.attempts
    #expect(attempts == 1)
    let peer = connections.peer
    #expect(peer.connections == 1)
    let received = await peer.received(atLeast: 4)
    #expect(received.map { xpc_dictionary_get_bool($0, "isBarrier") } == [true, false, false, false])
    #expect(
      received.map { xpc_dictionary_get_string($0, "messageType").map { String(cString: $0) } } == ["IndigoKeyboardButtonEvent"] + Array(repeating: "IndigoVendorDefinedEvent", count: 3))
    await vendor.disconnect()
  }

  @Test
  func aFailedConnectionIsAttemptedAgainOnTheNextSend() async throws {
    let connections = Connections()
    await connections.fail(true)
    let vendor = SimulatorVendorHIDTransport { try await connections.connect() }
    do {
      try await vendor.send(event())
      Issue.record("Expected the injected failure")
    } catch ConnectFailure.injected {}
    await connections.fail(false)
    try await vendor.send(event())
    try await vendor.send(event())
    let attempts = await connections.attempts
    #expect(attempts == 2)
    await vendor.disconnect()
  }

  @Test
  func disconnectingForgetsTheConnectionAndASendReconnects() async throws {
    let connections = Connections()
    let vendor = SimulatorVendorHIDTransport { try await connections.connect() }
    try await vendor.send(event())
    await vendor.disconnect()
    await vendor.disconnect()
    try await vendor.send(event())
    let attempts = await connections.attempts
    #expect(attempts == 2)
    await vendor.disconnect()
  }

  @Test
  func disconnectingTheHIDCommandsDropsTheVendorConnection() async throws {
    let connections = Connections()
    let hid = SimulatorHIDCommands(simulator: nil, vendorDefined: SimulatorVendorHIDTransport { try await connections.connect() })
    try await hid.vendorDefined.send(event())
    await hid.disconnect()
    try await hid.vendorDefined.send(event())
    let attempts = await connections.attempts
    #expect(attempts == 2)
    await hid.disconnect()
  }

  @Test
  func concurrentFirstSendsShareOneConnection() async throws {
    let connections = Connections()
    let vendor = SimulatorVendorHIDTransport { try await connections.connect() }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<4 {
        group.addTask { try await vendor.send(try self.event()) }
      }
      try await group.waitForAll()
    }
    let attempts = await connections.attempts
    #expect(attempts == 1)
    await vendor.disconnect()
  }
}
