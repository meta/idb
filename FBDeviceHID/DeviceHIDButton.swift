/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation

/// Typed physical button identities, not lock-state or accessibility actions.
public enum DeviceHIDButton: Sendable {
  case home
  case volumeUp
  case volumeDown
}

enum DeviceHIDContact: Sendable {
  case touch(CGPoint)
  case button(DeviceHIDButton)
}

struct DeviceHIDPreparedButton: Sendable {
  let deviceIdentifier: UUID
  let button: DeviceHIDButton
  let duration: TimeInterval?
}

enum DeviceHIDPreparedInput: Sendable {
  case touch(DeviceHIDPreparedTouch)
  case button(DeviceHIDPreparedButton)

  var deviceIdentifier: UUID {
    switch self {
    case let .touch(value): value.start.deviceIdentifier
    case let .button(value): value.deviceIdentifier
    }
  }

  var contact: DeviceHIDContact {
    switch self {
    case let .touch(value): .touch(value.start.point)
    case let .button(value): .button(value.button)
    }
  }

  var duration: TimeInterval? {
    switch self {
    case let .touch(value): value.start.duration
    case let .button(value): value.duration
    }
  }

  var positions: [DeviceHIDPosition] {
    switch self {
    case let .touch(value): value.positions
    case .button: []
    }
  }
}
