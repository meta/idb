/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBDeviceHID
import Foundation
import Testing

@Suite("Physical button contact lifetime")
struct DeviceHIDButtonTests {
  static func prepared(_ button: DeviceHIDButton = .home, duration: TimeInterval? = nil) -> DeviceHIDPreparedInput {
    .button(DeviceHIDPreparedButton(deviceIdentifier: UUID(), button: button, duration: duration))
  }

  @Test(arguments: [DeviceHIDButton.home, .volumeUp, .volumeDown])
  func sendsOneMatchingButtonContact(_ button: DeviceHIDButton) async throws {
    let fixture = DeviceHIDFixture()
    let operation = DeviceHIDOperation(transport: fixture.transport, input: Self.prepared(button, duration: 0.02), quarantine: {})
    let outcome = await operation.run()
    #expect(outcome.error == nil)
    #expect(!outcome.uncertain)
    #expect(fixture.state.sync { $0.buttons } == [button, button])
    #expect(fixture.state.sync { $0.points.isEmpty })
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("position") == 0)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
    let start = try #require(fixture.events.time("startReturned"))
    let end = try #require(fixture.events.time("end"))
    #expect(start.duration(to: end) >= .seconds(0.02))
  }

  @Test(arguments: ["start", "end", "barrier"])
  func uncertainButtonDeliveryIsNotRetried(_ failure: String) async {
    let fixture = DeviceHIDFixture(fail: failure)
    let operation = DeviceHIDOperation(transport: fixture.transport, input: Self.prepared(.volumeUp), quarantine: { fixture.state.sync { $0.quarantined = true } })
    let outcome = await operation.run()
    #expect(outcome.error != nil)
    #expect(outcome.uncertain)
    #expect(fixture.state.sync { $0.quarantined })
    #expect(fixture.state.sync { $0.buttons } == [.volumeUp, .volumeUp])
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
  }

  @Test func cancellationAndInvalidationShareTheButtonUp() async throws {
    let fixture = DeviceHIDFixture()
    let operation = DeviceHIDOperation(transport: fixture.transport, input: Self.prepared(.volumeDown, duration: 1), quarantine: {})
    let task = Task { await operation.run() }
    try await fixture.events.waitFor("startReturned")
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 { group.addTask { operation.cancel() } }
      group.addTask { fixture.state.sync { $0.invalidated }?() }
    }
    let outcome = await task.value
    #expect(outcome.error != nil)
    #expect(fixture.state.sync { $0.buttons } == [.volumeDown, .volumeDown])
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
  }

  @Test(arguments: ["start", "end"])
  func blockedButtonCannotOverlapOrReplay(_ phase: String) async throws {
    let fixture = DeviceHIDFixture(block: phase)
    let outcome = try await completeBlocked(fixture, phase: phase)
    try await fixture.events.waitFor("transportRetired")
    #expect(outcome.error is CancellationError)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
    #expect(fixture.events.count("releaseReturned") == 1)
  }

  private func completeBlocked(_ fixture: DeviceHIDFixture, phase: String) async throws -> DeviceHIDOutcome {
    defer { fixture.gate.open() }
    let operation = DeviceHIDOperation(transport: fixture.transport, input: Self.prepared(), operationSeconds: 2, cleanupReserve: 0.1, quarantine: {})
    let task = Task { await operation.run() }
    try await fixture.events.waitFor(phase)
    operation.cancel()
    #expect(fixture.events.count("end") == (phase == "start" ? 0 : 1))
    #expect(fixture.events.count("release") == 0)
    fixture.gate.open()
    return await task.value
  }

  @Test(arguments: [-1.0, Double.nan, Double.infinity, 6])
  func invalidOrOverBudgetHoldNeverStarts(_ duration: Double) async {
    let fixture = DeviceHIDFixture()
    let operation = DeviceHIDOperation(transport: fixture.transport, input: Self.prepared(duration: duration), quarantine: {})
    let outcome = await operation.run()
    #expect(outcome.error != nil)
    #expect(!outcome.uncertain)
    #expect(fixture.events.count("start") == 0)
    #expect(fixture.events.count("end") == 0)
  }
}
