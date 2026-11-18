/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBDeviceHID
import GRPCCore
import IDBGRPCSwift

/// One matching down/up pair, fully read before acquiring any native capability.
struct DeviceButtonRequest {
  let button: DeviceHIDButton
  let duration: Double?

  static func parse(_ messages: [Idb_HIDEvent]) throws -> Self {
    guard messages.count == 2 || messages.count == 3 else {
      throw RPCError(code: .invalidArgument, message: "Physical buttons require down, an optional delay, matching up, and EOF")
    }
    func button(_ message: Idb_HIDEvent, direction: Idb_HIDEvent.HIDDirection) throws -> Idb_HIDEvent.HIDButtonType {
      guard case let .press(press)? = message.event, press.direction == direction,
        case let .button(button)? = press.action.action
      else { throw RPCError(code: .invalidArgument, message: "Expected a matching physical button press") }
      return button.button
    }
    let down = try button(messages[0], direction: .down)
    let up = try button(messages[messages.count - 1], direction: .up)
    guard down == up else { throw RPCError(code: .invalidArgument, message: "Physical button up must match down") }
    var duration: Double?
    if messages.count == 3 {
      guard case let .delay(delay)? = messages[1].event, delay.duration.isFinite, delay.duration >= 0, delay.duration < 5 else {
        throw RPCError(code: .invalidArgument, message: "Physical button hold must be finite, nonnegative, and less than five seconds")
      }
      duration = delay.duration
    }
    let selected: DeviceHIDButton
    switch down {
    case .home: selected = .home
    case .volumeUp: selected = .volumeUp
    case .volumeDown: selected = .volumeDown
    case .applePay, .lock, .sideButton, .siri, .playPause, .eject:
      throw RPCError(code: .unimplemented, message: "This button is not enabled for physical HID")
    case .UNRECOGNIZED:
      throw RPCError(code: .invalidArgument, message: "Unrecognized physical button")
    }
    return DeviceButtonRequest(button: selected, duration: duration)
  }
}
