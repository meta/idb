/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import Testing

@Suite
struct HidRequestTranslationTests {
  @Test
  func hingeAnglesSurviveTheWire() throws {
    for degrees in [0.0, 90.0, 135.5, 180.0] {
      let request = Idb_HIDEvent.with { $0.hinge.angle = degrees }
      guard case let .hinge(angle) = try HidMethodHandler.request(from: request) else {
        Issue.record("Expected a hinge request")
        return
      }
      #expect(angle.degrees == degrees)
    }
  }

  @Test
  func invalidAnglesAreInvalidArguments() {
    for degrees in [-1, 180.001, Double.nan, .infinity, -.infinity] {
      let request = Idb_HIDEvent.with { $0.hinge.angle = degrees }
      let error = #expect(throws: (any Error).self) { try HidMethodHandler.request(from: request) }
      #expect((error as? RPCError)?.code == .invalidArgument)
    }
  }

  @Test
  func orientationsKeepTheirNamesOnTheWire() throws {
    let expected: [(Idb_HIDEvent.HIDOrientationType, SimulatorHIDDeviceOrientation)] = [
      (.portrait, .portrait),
      (.portraitUpsideDown, .portraitUpsideDown),
      (.landscapeLeft, .landscapeLeft),
      (.landscapeRight, .landscapeRight),
    ]
    for (wire, orientation) in expected {
      let request = Idb_HIDEvent.with { $0.orientation.orientation = wire }
      #expect(try HidMethodHandler.request(from: request) == .orientation(orientation))
    }
  }

  @Test
  func anUnrecognizedOrientationIsAnInvalidArgument() {
    let request = Idb_HIDEvent.with { $0.orientation.orientation = .UNRECOGNIZED(99) }
    let error = #expect(throws: (any Error).self) { try HidMethodHandler.request(from: request) }
    #expect((error as? RPCError)?.code == .invalidArgument)
  }

  @Test
  func buttonsKeepTheirNamesOnTheWire() throws {
    let expected: [(Idb_HIDEvent.HIDButtonType, SimulatorHIDButton)] = [
      (.applePay, .applePay),
      (.home, .homeButton),
      (.lock, .lock),
      (.sideButton, .sideButton),
      (.siri, .siri),
      (.playPause, .playPause),
      (.volumeUp, .volumeUp),
      (.volumeDown, .volumeDown),
      (.eject, .eject),
    ]
    for (wire, button) in expected {
      for (wireDirection, direction) in [(Idb_HIDEvent.HIDDirection.down, SimulatorHIDDirection.down), (.up, .up)] {
        let request = Idb_HIDEvent.with {
          $0.press.action.button.button = wire
          $0.press.direction = wireDirection
        }
        #expect(try HidMethodHandler.request(from: request) == .input(.button(direction: direction, button: button)))
      }
    }
  }

  @Test
  func anUnrecognizedButtonIsAnInvalidArgument() {
    let request = Idb_HIDEvent.with { $0.press.action.button.button = .UNRECOGNIZED(99) }
    let error = #expect(throws: (any Error).self) { try HidMethodHandler.request(from: request) }
    #expect((error as? RPCError)?.code == .invalidArgument)
  }

  @Test
  func shakeTranslatesToShake() throws {
    let request = Idb_HIDEvent.with { $0.shake = Idb_HIDEvent.HIDShake() }
    #expect(try HidMethodHandler.request(from: request) == .shake)
  }

  @Test
  func textWithNoLayoutIsTypedOnTheSimulatorsOwn() throws {
    let request = Idb_HIDEvent.with { $0.text.text = "héllo" }
    #expect(try HidMethodHandler.request(from: request) == .text("héllo", layout: nil))
  }

  @Test
  func textCarriesTheLayoutItNames() throws {
    let request = Idb_HIDEvent.with {
      $0.text.text = "azerty"
      $0.text.layout = "French"
    }
    #expect(try HidMethodHandler.request(from: request) == .text("azerty", layout: SimulatorKeyboardLayout(name: "French")))
  }

  @Test
  func textThatCannotBeTypedAsAskedIsAnInvalidArgument() {
    let failures: [SimulatorHIDError] = [
      .characterNotOnKeyboardLayout(offset: 3, layout: "French"),
      .unknownKeyboardLayout(name: "Bogus"),
    ]
    for failure in failures {
      let error = HidMethodHandler.typingFailure(failure) as? RPCError
      #expect(error?.code == .invalidArgument)
      #expect(error?.message == failure.localizedDescription)
    }
    #expect(HidMethodHandler.typingFailure(SimulatorHIDError.clientDisposed) is SimulatorHIDError)
  }

  // MARK: - The events of a stream

  private struct Refused: Error {}

  /// Messages handed out one at a time, counting how many have been asked for.
  private final class Messages: AsyncIteratorProtocol {
    private var remaining: [Result<Idb_HIDEvent, any Error>]
    private(set) var read = 0

    init(_ messages: [Result<Idb_HIDEvent, any Error>]) {
      remaining = messages
    }

    func next() async throws -> Idb_HIDEvent? {
      guard !remaining.isEmpty else { return nil }
      read += 1
      return try remaining.removeFirst().get()
    }
  }

  private func delay(_ duration: Double) -> Result<Idb_HIDEvent, any Error> {
    .success(.with { $0.delay.duration = duration })
  }

  /// A delay resolves to itself, a shake to no event, and anything else is refused.
  private func resolve(_ message: Idb_HIDEvent) throws -> SimulatorHIDEvent? {
    switch message.event {
    case let .delay(delay): return .delay(delay.duration)
    case .shake: return nil
    default: throw Refused()
    }
  }

  private func collect<S: AsyncSequence>(_ events: S) async throws -> [SimulatorHIDEvent] where S.Element == SimulatorHIDEvent {
    var collected: [SimulatorHIDEvent] = []
    for try await event in events { collected.append(event) }
    return collected
  }

  @Test
  func theFirstEventIsResolvedBeforeTheEventsAreAskedFor() async throws {
    let messages = Messages([delay(1), delay(2)])
    var resolved: [Idb_HIDEvent] = []

    let events = try await HidMethodHandler.Events.resolvingFirst(of: messages) {
      resolved.append($0)
      return try self.resolve($0)
    }

    #expect(messages.read == 1)
    #expect(resolved.count == 1)
    #expect(try await collect(events) == [.delay(1), .delay(2)])
    #expect(resolved.count == 2)
  }

  @Test
  func eventsKeepTheirOrderAndMessagesThatAreNoInputAreLeftOut() async throws {
    let shake: Result<Idb_HIDEvent, any Error> = .success(.with { $0.shake = Idb_HIDEvent.HIDShake() })

    let leading = try await HidMethodHandler.Events.resolvingFirst(of: Messages([shake, delay(1), shake, delay(2)]), event: resolve)
    #expect(try await collect(leading) == [.delay(1), .delay(2)])

    let trailing = try await HidMethodHandler.Events.resolvingFirst(of: Messages([delay(1), delay(2), delay(3), shake]), event: resolve)
    #expect(try await collect(trailing) == [.delay(1), .delay(2), .delay(3)])
  }

  @Test
  func anEmptyStreamHasNoEvents() async throws {
    let events = try await HidMethodHandler.Events.resolvingFirst(of: Messages([]), event: resolve)
    #expect(try await collect(events).isEmpty)
  }

  @Test
  func aFirstMessageThatFailsFailsBeforeThereAreEvents() async {
    let unresolvable: Result<Idb_HIDEvent, any Error> = .success(.with { $0.hinge.angle = 90 })
    await #expect(throws: Refused.self) {
      _ = try await HidMethodHandler.Events.resolvingFirst(of: Messages([unresolvable, self.delay(1)]), event: self.resolve)
    }
    await #expect(throws: Refused.self) {
      _ = try await HidMethodHandler.Events.resolvingFirst(of: Messages([.failure(Refused())]), event: self.resolve)
    }
  }

  @Test
  func anErrorAfterTheFirstEventEndsTheEventsOnceItIsDelivered() async throws {
    let events = try await HidMethodHandler.Events.resolvingFirst(of: Messages([delay(1), .failure(Refused()), delay(2)]), event: resolve)
    var iterator = events.makeAsyncIterator()

    #expect(try await iterator.next() == .delay(1))
    await #expect(throws: Refused.self) { _ = try await iterator.next() }
  }
}
