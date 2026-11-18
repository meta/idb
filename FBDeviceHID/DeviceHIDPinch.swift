/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation

extension DeviceHIDTouchSequence {
  /// A bounded horizontal two-finger recipe, not a remote gesture-recognition guarantee.
  public static func pinch(x: Double, y: Double, scale: Double, duration: TimeInterval = 0.5, radius: Double = 100) throws -> Self {
    guard x.isFinite, y.isFinite, x >= 0, y >= 0,
      scale.isFinite, scale > 0, radius.isFinite, radius > 0,
      duration.isFinite, duration >= 0, duration < 5
    else { throw DeviceHIDError.preparationFailed("Pinch center must be finite and nonnegative, scale and radius positive, and duration finite, nonnegative and less than five seconds") }
    let endRadius = radius * scale
    let count = floor(abs(endRadius - radius) / 10)
    // Each paired sample has a delay; the duplicate endpoint and final up also count.
    guard endRadius.isFinite, endRadius > 0, count.isFinite, count <= Double((maximumEvents - 5) / 2) else {
      throw DeviceHIDError.preparationFailed("Pinch exceeds the bounded physical sample count or radius range")
    }
    let steps = max(2, Int(count))
    let delay = duration / Double(steps + 2)
    let dr = (endRadius - radius) / Double(steps)
    let radii = [radius] + (1...steps).map { radius + dr * Double($0) } + [endRadius]
    let positions = try radii.map { radius -> DeviceHIDPosition in
      let first = CGPoint(x: x - radius, y: y)
      let second = CGPoint(x: x + radius, y: y)
      guard first.x.isFinite, second.x.isFinite, first.x >= 0, second.x > first.x else {
        throw DeviceHIDError.preparationFailed("Both pinch points must remain finite, nonnegative and distinct")
      }
      return DeviceHIDPosition(point: first, delay: delay, secondPoint: second)
    }
    return Self(contacts: [DeviceHIDTouchContact(positions: positions)], duration: duration)
  }
}
