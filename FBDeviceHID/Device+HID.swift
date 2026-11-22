/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

internal import FBControlCore
import FBDeviceControl

extension Device {
  /// Physical-device input, isolated from the simulator's HID implementation.
  public var hid: DeviceHIDCommands {
    commandCache.resolve { DeviceHIDCommands(device: self) }
  }
}
