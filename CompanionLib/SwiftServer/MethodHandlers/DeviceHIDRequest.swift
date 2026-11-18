/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBDeviceHID
import GRPCCore
import IDBGRPCSwift

/// Buffers one bounded recipe through successful EOF; no event is emitted while reading.
enum DeviceHIDRequest {
  case touch(DeviceHIDTouchSequence)
  case button(DeviceButtonRequest)

  static func read<S: AsyncSequence>(from requests: S) async throws -> Self where S.Element == Idb_HIDEvent {
    var messages: [Idb_HIDEvent] = []
    try Task.checkCancellation()
    for try await message in requests {
      try Task.checkCancellation()
      guard messages.count < DeviceHIDTouchSequence.maximumEvents else {
        throw RPCError(code: .invalidArgument, message: "Physical HID accepts at most 256 events per recipe")
      }
      messages.append(message)
    }
    try Task.checkCancellation()
    if case let .press(press)? = messages.first?.event, case .button? = press.action.action {
      return .button(try DeviceButtonRequest.parse(messages))
    }
    do {
      if messages.count == 1, case .swipe(let swipe)? = messages.first?.event {
        guard swipe.hasStart, swipe.hasEnd else {
          throw RPCError(code: .invalidArgument, message: "Swipe requires start and end points")
        }
        return .touch(
          try .swipe(
            swipe.start.x, yStart: swipe.start.y, xEnd: swipe.end.x, yEnd: swipe.end.y,
            delta: swipe.delta, duration: swipe.duration))
      }
      if messages.count == 1, case .pinch(let pinch)? = messages.first?.event {
        guard pinch.hasCenter, pinch.duration.isFinite, pinch.duration >= 0, pinch.radius.isFinite, pinch.radius >= 0 else {
          throw RPCError(code: .invalidArgument, message: "Pinch requires a center and finite, nonnegative duration and radius")
        }
        return .touch(
          try .pinch(
            x: pinch.center.x, y: pinch.center.y, scale: pinch.scale,
            duration: pinch.effectiveDuration, radius: pinch.effectiveRadius))
      }
      var activeContact = false
      let events = try messages.map { message -> DeviceHIDTouchEvent in
        switch message.event {
        case let .press(press):
          guard let action = press.action.action else {
            throw RPCError(code: .invalidArgument, message: "Missing physical HID press action")
          }
          guard case let .touch(touch) = action else {
            throw RPCError(code: .unimplemented, message: "Physical HID does not support this press action")
          }
          guard touch.hasPoint else {
            throw RPCError(code: .invalidArgument, message: "Physical touch requires a point")
          }
          switch press.direction {
          case .down:
            let event: DeviceHIDTouchEvent = activeContact ? .move(x: touch.point.x, y: touch.point.y) : .down(x: touch.point.x, y: touch.point.y)
            activeContact = true
            return event
          case .up:
            activeContact = false
            return .up(x: touch.point.x, y: touch.point.y)
          case .UNRECOGNIZED: throw RPCError(code: .invalidArgument, message: "Unrecognized physical touch direction")
          }
        case let .delay(delay): return .delay(delay.duration)
        case .swipe, .pinch, .orientation, .shake, .hinge:
          throw RPCError(code: .unimplemented, message: "Physical HID requires one touch recipe, swipe or pinch; mixed and other events are unsupported")
        case .none:
          throw RPCError(code: .invalidArgument, message: "Missing physical HID event")
        }
      }
      return .touch(try DeviceHIDTouchSequence(events))
    } catch let error as DeviceHIDError {
      throw RPCError(code: .invalidArgument, message: error.localizedDescription)
    }
  }
}
