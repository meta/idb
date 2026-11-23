/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore

// FBControlCore does not compare screenshot configurations, so it does not carry these conformances;
// the translation tests compare whole values, so they declare them here.

extension ScreenshotScale: @retroactive Equatable {
  public static func == (lhs: ScreenshotScale, rhs: ScreenshotScale) -> Bool {
    switch (lhs, rhs) {
    case (.native, .native):
      return true
    case let (.factor(left), .factor(right)):
      return left == right
    case let (.fit(leftWidth, leftHeight), .fit(rightWidth, rightHeight)):
      return leftWidth == rightWidth && leftHeight == rightHeight
    case (.native, _), (.factor, _), (.fit, _):
      return false
    @unknown default:
      return false
    }
  }
}

extension ScreenshotConfiguration: @retroactive Equatable {
  public static func == (lhs: ScreenshotConfiguration, rhs: ScreenshotConfiguration) -> Bool {
    lhs.encoding == rhs.encoding
      && lhs.cropRect == rhs.cropRect
      && lhs.scale == rhs.scale
      && lhs.unit == rhs.unit
      && lhs.display == rhs.display
  }
}
