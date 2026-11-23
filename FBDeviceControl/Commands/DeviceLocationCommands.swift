/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

private let StartCommand: UInt32 = 0x00000000

public struct DeviceLocationCommands: LocationCommands {
  private let device: Device

  public init(device: Device) {
    self.device = device
  }

  // MARK: - Async

  public func set(longitude: Double, latitude: Double) async throws {
    _ = try await device.developerDiskImage.ensureMounted()
    try await device.withServiceConnection("com.apple.dt.simulatelocation") { connection in
      var start = StartCommand
      let startData = unsafe Data(bytes: &start, count: MemoryLayout<UInt32>.size)
      try connection.send(startData)

      try connection.send(withLengthHeader: Data("\(latitude)".utf8))
      try connection.send(withLengthHeader: Data("\(longitude)".utf8))
    }
  }
}
