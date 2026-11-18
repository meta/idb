/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBDeviceControl
import Foundation

/// Physical orientation, independent of the application's interface rotation.
public enum DeviceOrientation: String, Sendable, Decodable {
  case unknown
  case portrait
  case portraitUpsideDown
  case landscapeLeft
  case landscapeRight
  case faceUp
  case faceDown

  var isWritable: Bool {
    switch self {
    case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight: true
    case .unknown, .faceUp, .faceDown: false
    }
  }
}

public struct DeviceOrientationCommands: Sendable {
  let input: DeviceHIDCommands

  public func current() async throws -> DeviceOrientation {
    try await input.orientation(nil)
  }

  /// Sets one cardinal physical orientation; success reports the tool's receipt, not UI stability.
  public func set(_ orientation: DeviceOrientation) async throws {
    guard orientation.isWritable else {
      throw DeviceHIDError.preparationFailed("Only portrait, portraitUpsideDown, landscapeLeft and landscapeRight can be set")
    }
    _ = try await input.orientation(orientation)
  }
}

extension Device {
  public var orientation: DeviceOrientationCommands {
    DeviceOrientationCommands(input: hid)
  }
}
