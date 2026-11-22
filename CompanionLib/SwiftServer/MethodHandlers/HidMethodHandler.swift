/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBDeviceControl
import FBDeviceHID
import FBSimulatorControl
import FBSimulatorServices
import Foundation
import GRPCCore
import IDBGRPCSwift

struct HidMethodHandler {

  /// What a streamed `Idb_HIDEvent` asks of the simulator: input for the HID, or a device action.
  enum Request: Equatable {
    case input(SimulatorHIDEvent)
    case orientation(SimulatorHIDDeviceOrientation)
    case shake
    case hinge(SimulatorHingeAngle)
    /// Text to type on a hardware keyboard layout, or on the simulator's own if none is named.
    case text(String, layout: SimulatorKeyboardLayout?)
  }

  let target: CompanionTarget
  let commandExecutor: IDBCommandExecutor

  func handle(requestStream: RequestStreamReader<Idb_HIDEvent>, context: ServerContext) async throws -> Idb_HIDResponse {
    // Resolved up front so the stream's closure can hold it, and thrown only when a device action needs it.
    let simulator = Result { try target.simulator() }
    let commandExecutor = commandExecutor
    let deviceHID = (target as? Device)?.hid
    try await withRPCCancellation(context.cancellation) {
      if let deviceHID {
        switch try await DeviceHIDRequest.read(from: requestStream) {
        case let .touch(sequence):
          try await deviceHID.touch(sequence)
        case let .button(request):
          try await deviceHID.button(request.button, duration: request.duration)
        }
        return
      }
      // A leading text event is resolved before the HID is taken, so that reading the simulator's keyboard
      // layout keeps no other stream to the simulator waiting. Device actions only ever run under the HID.
      let events = try await Events.resolvingFirst(of: requestStream.makeAsyncIterator(), if: Self.isText) {
        try await Self.event(for: $0, simulator: simulator)
      }
      try await commandExecutor.hid(events: events)
    }
    return .init()
  }

  /// The HID events that a stream of messages resolves to, the first of them possibly resolved already.
  struct Events<Messages: AsyncIteratorProtocol>: AsyncSequence, AsyncIteratorProtocol where Messages.Element == Idb_HIDEvent {
    /// The first message, resolved or still to be resolved when it is asked for.
    private enum First {
      case resolved(SimulatorHIDEvent?)
      case unresolved(Idb_HIDEvent)
    }

    private var first: First?
    private var messages: Messages
    private let event: (Idb_HIDEvent) async throws -> SimulatorHIDEvent?

    private init(first: First?, messages: Messages, event: @escaping (Idb_HIDEvent) async throws -> SimulatorHIDEvent?) {
      self.first = first
      self.messages = messages
      self.event = event
    }

    /// Reads the first message of `messages` and, if `resolvesEarly` holds for it, resolves it with `event` now.
    /// `event` resolves every other message as it is asked for. A message resolves to `nil` where it is no
    /// input for the HID.
    static func resolvingFirst(
      of messages: Messages,
      if resolvesEarly: (Idb_HIDEvent) -> Bool,
      event: @escaping (Idb_HIDEvent) async throws -> SimulatorHIDEvent?
    ) async throws -> Self {
      var messages = messages
      guard let message = try await messages.next() else {
        return Self(first: nil, messages: messages, event: event)
      }
      guard resolvesEarly(message) else {
        return Self(first: .unresolved(message), messages: messages, event: event)
      }
      return Self(first: .resolved(try await event(message)), messages: messages, event: event)
    }

    func makeAsyncIterator() -> Self {
      self
    }

    mutating func next() async throws -> SimulatorHIDEvent? {
      if let first {
        self.first = nil
        switch first {
        case let .resolved(resolved?):
          return resolved
        case .resolved(nil):
          break
        case let .unresolved(message):
          if let resolved = try await event(message) {
            return resolved
          }
        }
      }
      while let message = try await messages.next() {
        if let event = try await event(message) {
          return event
        }
      }
      return nil
    }
  }

  /// Whether `message` is text, whose key presses are worked out before the HID is taken.
  static func isText(_ message: Idb_HIDEvent) -> Bool {
    if case .text = message.event {
      return true
    }
    return false
  }

  /// The input a message asks for, or `nil` once the device action it asks for is done.
  private static func event(for message: Idb_HIDEvent, simulator: Result<Simulator, any Error>) async throws -> SimulatorHIDEvent? {
    switch try request(from: message) {
    case let .input(event):
      return event
    case let .orientation(orientation):
      // Interface numbering is what `idb`'s HID stream has always carried.
      try await simulator.get().orientation.set(orientation, convention: .interface)
    case .shake:
      try await simulator.get().hardware.shake()
    case let .hinge(angle):
      try await simulator.get().hinge.set(angle)
    case let .text(text, layout):
      do {
        return try await simulator.get().keyboard.typingEvent(for: text, layout: layout)
      } catch {
        throw typingFailure(error)
      }
    }
    return nil
  }

  /// Text that cannot be typed as asked is the request's fault.
  static func typingFailure(_ error: any Error) -> any Error {
    switch error {
    case SimulatorHIDError.characterNotOnKeyboardLayout, SimulatorHIDError.unknownKeyboardLayout:
      return RPCError(code: .invalidArgument, message: error.localizedDescription)
    default:
      return error
    }
  }

  static func request(from request: Idb_HIDEvent) throws -> Request {
    switch request.event {
    case let .press(press):
      return .input(try pressEvent(from: press))

    case let .swipe(swipe):
      return .input(
        .swipe(
          swipe.start.x,
          yStart: swipe.start.y,
          xEnd: swipe.end.x,
          yEnd: swipe.end.y,
          delta: swipe.delta,
          duration: swipe.duration))

    case let .delay(delay):
      return .input(.delay(delay.duration))

    case let .pinch(pinch):
      return .input(
        .pinchAt(
          x: pinch.center.x, y: pinch.center.y, scale: pinch.scale,
          duration: pinch.effectiveDuration, radius: pinch.effectiveRadius))

    case let .orientation(orientation):
      return .orientation(try OrientationMethodHandler.orientation(orientation.orientation))

    case .shake:
      return .shake

    case let .hinge(hinge):
      do {
        return .hinge(try SimulatorHingeAngle(degrees: hinge.angle))
      } catch {
        throw RPCError(code: .invalidArgument, message: error.localizedDescription)
      }

    case let .text(text):
      return .text(text.text, layout: text.layout.isEmpty ? nil : SimulatorKeyboardLayout(name: text.layout))

    case .none:
      throw RPCError(code: .invalidArgument, message: "Unrecognized request.event")
    }
  }

  private static func pressEvent(from press: Idb_HIDEvent.HIDPress) throws -> SimulatorHIDEvent {
    switch press.action.action {
    case let .key(key):
      switch press.direction {
      case .up:
        return .keyboard(direction: .up, keyCode: UInt32(key.keycode))
      case .down:
        return .keyboard(direction: .down, keyCode: UInt32(key.keycode))
      case .UNRECOGNIZED:
        throw RPCError(code: .invalidArgument, message: "Unrecognized press.direction")
      }

    case let .button(button):
      guard let hidButton = fbSimulatorHIDButton(from: button.button) else {
        throw RPCError(code: .invalidArgument, message: "Unrecognized hid button type")
      }
      switch press.direction {
      case .up:
        return .button(direction: .up, button: hidButton)
      case .down:
        return .button(direction: .down, button: hidButton)
      case .UNRECOGNIZED:
        throw RPCError(code: .invalidArgument, message: "Unrecognized press.direction")
      }

    case let .touch(touch):
      switch press.direction {
      case .up:
        return .touch(direction: .up, x: touch.point.x, y: touch.point.y)
      case .down:
        return .touch(direction: .down, x: touch.point.x, y: touch.point.y)
      case .UNRECOGNIZED:
        throw RPCError(code: .invalidArgument, message: "Unrecognized press.direction")
      }

    case .none:
      throw RPCError(code: .invalidArgument, message: "Unrecognized press.action")
    }
  }

  private static func fbSimulatorHIDButton(from request: Idb_HIDEvent.HIDButtonType) -> SimulatorHIDButton? {
    switch request {
    case .applePay:
      return .applePay
    case .home:
      return .homeButton
    case .lock:
      return .lock
    case .sideButton:
      return .sideButton
    case .siri:
      return .siri
    case .playPause:
      return .playPause
    case .volumeUp:
      return .volumeUp
    case .volumeDown:
      return .volumeDown
    case .eject:
      return .eject
    case .UNRECOGNIZED:
      return nil
    }
  }
}

extension Idb_HIDEvent.HIDPinch {
  var effectiveDuration: Double { duration > 0 ? duration : 0.5 }
  var effectiveRadius: Double { radius > 0 ? radius : 100 }
}
