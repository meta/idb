/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation

/// One bounded contact, submitted in full before any input is sent. Coordinates are display points.
public enum DeviceHIDTouchEvent: Sendable {
  case down(x: Double, y: Double)
  case move(x: Double, y: Double)
  case up(x: Double, y: Double)
  case delay(TimeInterval)
}

struct DeviceHIDPosition: Sendable {
  let point: CGPoint
  var delay: TimeInterval
}

/// The lift matches the last position, including when that position's delivery is uncertain.
public struct DeviceHIDTouchSequence: Sendable {
  public static let maximumEvents = 256
  let positions: [DeviceHIDPosition]
  let duration: TimeInterval

  public init(_ events: [DeviceHIDTouchEvent]) throws {
    guard (2...Self.maximumEvents).contains(events.count),
      case let .down(x, y) = events[0]
    else { throw DeviceHIDError.preparationFailed("A touch sequence requires one down and one up, with at most 256 events") }
    var positions = [DeviceHIDPosition(point: CGPoint(x: x, y: y), delay: 0)]
    var duration: TimeInterval = 0
    for (index, event) in events.enumerated().dropFirst() {
      switch event {
      case .down:
        throw DeviceHIDError.preparationFailed("A touch sequence owns exactly one contact")
      case let .move(x, y):
        guard index < events.count - 1 else { throw DeviceHIDError.preparationFailed("A touch sequence must end with up") }
        positions.append(DeviceHIDPosition(point: CGPoint(x: x, y: y), delay: 0))
      case let .delay(delay):
        guard index < events.count - 1, delay.isFinite, delay >= 0 else {
          throw DeviceHIDError.preparationFailed("Touch delays must be finite, nonnegative, and precede up")
        }
        duration += delay
        positions[positions.count - 1].delay += delay
      case let .up(x, y):
        guard index == events.count - 1, positions.last?.point == CGPoint(x: x, y: y) else {
          throw DeviceHIDError.preparationFailed("The final up must match the last contact position")
        }
      }
    }
    guard case .up = events[events.count - 1], duration.isFinite, duration < 5,
      positions.allSatisfy({ $0.point.x.isFinite && $0.point.y.isFinite && $0.point.x >= 0 && $0.point.y >= 0 })
    else { throw DeviceHIDError.preparationFailed("Touch coordinates must be finite and nonnegative, and total hold must be less than five seconds") }
    self.positions = positions
    self.duration = duration
  }
}

struct DeviceHIDPreparedTouch: Sendable {
  let start: DeviceHIDPreparedTap
  let positions: [DeviceHIDPosition]
}
