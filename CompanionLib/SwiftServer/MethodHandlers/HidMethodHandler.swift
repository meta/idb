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
import GRPCCore
import IDBGRPCSwift

struct HidMethodHandler {

  /// What a streamed `Idb_HIDEvent` asks of the simulator: input for the HID, or a device action.
  enum Request: Equatable {
    case input(SimulatorHIDEvent)
    case orientation(SimulatorHIDDeviceOrientation)
    case shake
    case hinge(SimulatorHingeAngle)
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
        let tap = try await DeviceTapRequest.read(from: requestStream)
        try await deviceHID.tap(x: tap.x, y: tap.y, duration: tap.duration)
        return
      }
      try await commandExecutor.hid(
        events: requestStream.compactMap { message -> SimulatorHIDEvent? in
          switch try Self.request(from: message) {
          case let .input(event):
            return event
          case let .orientation(orientation):
            // Interface numbering is what `idb`'s HID stream has always carried.
            try await simulator.get().orientation.set(orientation, convention: .interface)
          case .shake:
            try await simulator.get().hardware.shake()
          case let .hinge(angle):
            try await simulator.get().hinge.set(angle)
          }
          return nil
        })
    }
    return .init()
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
      let centerX = Double(pinch.center.x)
      let centerY = Double(pinch.center.y)
      let scale = pinch.scale
      let duration = pinch.duration > 0 ? pinch.duration : 0.5
      let radius = pinch.radius > 0 ? pinch.radius : 100.0
      return .input(.pinchAt(x: centerX, y: centerY, scale: scale, duration: duration, radius: radius))

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
