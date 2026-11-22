/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBDeviceHID
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import Testing

@Suite("Complete physical button requests")
struct DeviceButtonRequestTests {
  @Test(arguments: [Idb_HIDEvent.HIDButtonType.home, .volumeUp, .volumeDown])
  func mapsOnlyEnabledButtons(_ button: Idb_HIDEvent.HIDButtonType) async throws {
    let request = try await DeviceHIDRequest.read(
      from: stream([
        press(.down, button), Idb_HIDEvent.with { $0.delay.duration = 0.15 }, press(.up, button),
      ]))
    guard case let .button(value) = request else {
      Issue.record("Expected button request")
      return
    }
    switch value.button {
    case .home: #expect(button == .home)
    case .volumeUp: #expect(button == .volumeUp)
    case .volumeDown: #expect(button == .volumeDown)
    }
    #expect(value.duration == 0.15)
  }

  @Test func rejectsOtherButtonsAndMalformedPairs() {
    for button in [Idb_HIDEvent.HIDButtonType.applePay, .lock, .sideButton, .siri, .playPause, .eject, .UNRECOGNIZED(99)] {
      #expect(throws: RPCError.self) { try DeviceButtonRequest.parse([press(.down, button), press(.up, button)]) }
    }
    let down = press(.down, .home)
    let up = press(.up, .home)
    for messages in [
      [], [down], [up, down], [down, press(.up, .volumeUp)], [down, down, up],
      [down, up, down, up], [down, Idb_HIDEvent.with { $0.delay.duration = 5 }, up],
      [down, Idb_HIDEvent.with { $0.delay.duration = .nan }, up],
    ] {
      #expect(throws: RPCError.self) { try DeviceButtonRequest.parse(messages) }
    }
  }

  @Test func failedEOFDoesNotAdmitAButton() async {
    let requests = AsyncThrowingStream<Idb_HIDEvent, any Error> { continuation in
      continuation.yield(press(.down, .home))
      continuation.yield(press(.up, .home))
      continuation.finish(throwing: Failure.eof)
    }
    await #expect(throws: Failure.self) { try await DeviceHIDRequest.read(from: requests) }
  }

  private enum Failure: Error { case eof }
  private func press(_ direction: Idb_HIDEvent.HIDDirection, _ button: Idb_HIDEvent.HIDButtonType) -> Idb_HIDEvent {
    Idb_HIDEvent.with {
      $0.press.direction = direction
      $0.press.action.button.button = button
    }
  }
  private func stream(_ events: [Idb_HIDEvent]) -> AsyncStream<Idb_HIDEvent> {
    AsyncStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }
}
