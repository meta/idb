/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import GRPCCore
import IDBGRPCSwift

/// A complete tap is required before a physical contact can be admitted.
struct DeviceTapRequest {
  let x: Double
  let y: Double
  let duration: Double?

  static func read<S: AsyncSequence>(from requests: S) async throws -> DeviceTapRequest where S.Element == Idb_HIDEvent {
    try Task.checkCancellation()
    var iterator = requests.makeAsyncIterator()
    let down = try touch(from: try await iterator.next(), direction: .down)
    guard down.x.isFinite, down.y.isFinite, down.x >= 0, down.y >= 0 else {
      throw RPCError(code: .invalidArgument, message: "Tap coordinates must be finite and nonnegative display points")
    }

    var next = try await iterator.next()
    var duration: Double?
    if case let .delay(delay)? = next?.event {
      guard delay.duration.isFinite, delay.duration >= 0 else {
        throw RPCError(code: .invalidArgument, message: "Tap duration must be finite and nonnegative")
      }
      duration = delay.duration
      next = try await iterator.next()
    }

    let up = try touch(from: next, direction: .up)
    guard up.x == down.x, up.y == down.y else {
      throw RPCError(code: .invalidArgument, message: "A physical tap must release the same point it pressed")
    }
    guard try await iterator.next() == nil else {
      throw RPCError(code: .invalidArgument, message: "Physical HID accepts one tap per request")
    }
    try Task.checkCancellation()
    return DeviceTapRequest(x: down.x, y: down.y, duration: duration)
  }

  private static func touch(from request: Idb_HIDEvent?, direction: Idb_HIDEvent.HIDDirection) throws -> Idb_Point {
    guard case let .press(press)? = request?.event,
      press.direction == direction,
      case let .touch(touch)? = press.action.action,
      touch.hasPoint
    else {
      throw RPCError(code: .invalidArgument, message: "Physical HID requires touch-down, an optional delay, matching touch-up, and end of stream")
    }
    return touch.point
  }
}
