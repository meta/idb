/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation

/// One single-finger contact. Coordinates are device display points, not normalized points.
public enum DeviceHIDLiveEvent: Sendable {
  case down(x: Double, y: Double)
  case move(x: Double, y: Double)
  case up(x: Double, y: Double)
}

struct DeviceHIDLivePreparation: Sendable {
  let deviceIdentifier: UUID
  let displaySnapshot: DeviceHIDDisplaySnapshot
  let normalize: @Sendable (CGPoint) throws -> CGPoint
}
