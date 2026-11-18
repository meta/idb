/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation

/// A bounded recipe, submitted in full before any input is sent. Coordinates are display points.
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

struct DeviceHIDTouchContact: Sendable {
  let positions: [DeviceHIDPosition]
  var pause: TimeInterval = 0
}

/// Each lift matches its last position. Contacts never overlap or remain held across calls.
public struct DeviceHIDTouchSequence: Sendable {
  public static let maximumEvents = 256
  let contacts: [DeviceHIDTouchContact]
  let duration: TimeInterval

  public init(_ events: [DeviceHIDTouchEvent]) throws {
    guard (2...Self.maximumEvents).contains(events.count),
      case .down = events[0], case .up = events[events.count - 1]
    else { throw DeviceHIDError.preparationFailed("A touch sequence must start with down and end with up, with at most 256 events") }
    var contacts: [DeviceHIDTouchContact] = []
    var positions: [DeviceHIDPosition] = []
    var duration: TimeInterval = 0
    for event in events {
      switch event {
      case let .down(x, y):
        guard positions.isEmpty else { throw DeviceHIDError.preparationFailed("Touch contacts must not overlap") }
        positions.append(DeviceHIDPosition(point: CGPoint(x: x, y: y), delay: 0))
      case let .move(x, y):
        guard !positions.isEmpty else { throw DeviceHIDError.preparationFailed("A position update requires an active contact") }
        positions.append(DeviceHIDPosition(point: CGPoint(x: x, y: y), delay: 0))
      case let .delay(delay):
        guard delay.isFinite, delay >= 0 else {
          throw DeviceHIDError.preparationFailed("Touch delays must be finite and nonnegative")
        }
        duration += delay
        if !positions.isEmpty {
          positions[positions.count - 1].delay += delay
        } else if !contacts.isEmpty {
          contacts[contacts.count - 1].pause += delay
        }
      case let .up(x, y):
        guard !positions.isEmpty, positions.last?.point == CGPoint(x: x, y: y) else {
          throw DeviceHIDError.preparationFailed("Each up must match the last active contact position")
        }
        contacts.append(DeviceHIDTouchContact(positions: positions))
        positions.removeAll(keepingCapacity: true)
      }
    }
    guard positions.isEmpty, duration.isFinite, duration < 5,
      contacts.allSatisfy({ $0.positions.allSatisfy { $0.point.x.isFinite && $0.point.y.isFinite && $0.point.x >= 0 && $0.point.y >= 0 } })
    else { throw DeviceHIDError.preparationFailed("Touch coordinates must be finite and nonnegative, and combined holds and pauses must be less than five seconds") }
    self.contacts = contacts
    self.duration = duration
  }
}

struct DeviceHIDContactPlan: Sendable {
  let contact: DeviceHIDContact
  let duration: TimeInterval
  let positions: [DeviceHIDPosition]
  var pause: TimeInterval = 0

  var totalDuration: TimeInterval { positions.reduce(duration + pause) { $0 + $1.delay } }
}

struct DeviceHIDPreparedTouch: Sendable {
  let start: DeviceHIDPreparedTap
  let positions: [DeviceHIDPosition]
  var pause: TimeInterval = 0
  var subsequent: [DeviceHIDContactPlan] = []
}
