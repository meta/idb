/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBDeviceHID
import Foundation
import GRPCCore
import IDBGRPCSwift

/// Buffers one bounded recipe through successful EOF; no event is emitted while reading.
enum DeviceHIDRequest {
  case tap(DeviceTapRequest)
  case touch(DeviceHIDTouchSequence)
  case button(DeviceButtonRequest)

  static func read<S: AsyncSequence>(from requests: S) async throws -> Self where S.Element == Idb_HIDEvent {
    var messages: [Idb_HIDEvent] = []
    try Task.checkCancellation()
    for try await message in requests {
      try Task.checkCancellation()
      guard messages.count < DeviceHIDTouchSequence.maximumEvents else {
        throw RPCError(code: .invalidArgument, message: "Physical HID accepts at most 256 events per contact")
      }
      messages.append(message)
    }
    try Task.checkCancellation()
    if case let .press(press)? = messages.first?.event, case .button? = press.action.action {
      return .button(try DeviceButtonRequest.parse(messages))
    }
    if messages.count == 2 || (messages.count == 3 && messages[1].event?.isDelay == true),
      case .press(let press)? = messages.first?.event, case .touch? = press.action.action
    {
      let buffered = AsyncStream<Idb_HIDEvent> { continuation in
        for message in messages { continuation.yield(message) }
        continuation.finish()
      }
      return .tap(try await DeviceTapRequest.read(from: buffered))
    }
    do {
      if messages.count == 1, case .swipe(let swipe)? = messages.first?.event {
        return .touch(try DeviceHIDTouchSequence(swipeEvents(swipe)))
      }
      let events = try messages.enumerated().map { index, message -> DeviceHIDTouchEvent in
        switch message.event {
        case let .press(press):
          guard case let .touch(touch)? = press.action.action, touch.hasPoint else {
            throw RPCError(code: .unimplemented, message: "Physical HID does not support this press action")
          }
          switch press.direction {
          case .down:
            return index == 0 ? .down(x: touch.point.x, y: touch.point.y) : .move(x: touch.point.x, y: touch.point.y)
          case .up: return .up(x: touch.point.x, y: touch.point.y)
          case .UNRECOGNIZED: throw RPCError(code: .invalidArgument, message: "Unrecognized physical touch direction")
          }
        case let .delay(delay): return .delay(delay.duration)
        case .swipe, .pinch, .orientation, .shake, .hinge:
          throw RPCError(code: .unimplemented, message: "Physical HID requires one touch recipe or one swipe; other events are unsupported")
        case .none:
          throw RPCError(code: .invalidArgument, message: "Missing physical HID event")
        }
      }
      return .touch(try DeviceHIDTouchSequence(events))
    } catch let error as DeviceHIDError {
      throw RPCError(code: .invalidArgument, message: error.localizedDescription)
    }
  }

  private static func swipeEvents(_ swipe: Idb_HIDEvent.HIDSwipe) throws -> [DeviceHIDTouchEvent] {
    guard swipe.hasStart, swipe.hasEnd,
      swipe.start.x.isFinite, swipe.start.y.isFinite, swipe.end.x.isFinite, swipe.end.y.isFinite,
      swipe.start.x >= 0, swipe.start.y >= 0, swipe.end.x >= 0, swipe.end.y >= 0,
      swipe.delta.isFinite, swipe.duration.isFinite, swipe.duration >= 0, swipe.duration < 5
    else { throw RPCError(code: .invalidArgument, message: "Swipe points and duration must be finite and nonnegative; duration must be less than five seconds") }
    let distance = hypot(swipe.end.x - swipe.start.x, swipe.end.y - swipe.start.y)
    let delta = swipe.delta > 0 ? swipe.delta : 10
    let count = floor(distance / delta)
    // A start, a delay after each down, one duplicate endpoint, and one up.
    guard count.isFinite, count <= Double((DeviceHIDTouchSequence.maximumEvents - 5) / 2) else {
      throw RPCError(code: .invalidArgument, message: "Swipe exceeds the bounded physical sample count; use a larger delta")
    }
    let steps = max(1, Int(count))
    let delay = swipe.duration / Double(steps + 2)
    var events: [DeviceHIDTouchEvent] = [.down(x: swipe.start.x, y: swipe.start.y), .delay(delay)]
    for index in 1...steps {
      let fraction = Double(index) / Double(steps)
      events.append(.move(x: swipe.start.x + (swipe.end.x - swipe.start.x) * fraction, y: swipe.start.y + (swipe.end.y - swipe.start.y) * fraction))
      events.append(.delay(delay))
    }
    events.append(.move(x: swipe.end.x, y: swipe.end.y))
    events.append(.delay(delay))
    events.append(.up(x: swipe.end.x, y: swipe.end.y))
    return events
  }
}

private extension Idb_HIDEvent.OneOf_Event {
  var isDelay: Bool {
    if case .delay = self { return true }
    return false
  }
}
