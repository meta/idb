/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBVideoCore
import Foundation

public struct DeviceVideoStreamCommands: VideoStreamCommands {
  private let device: Device

  public init(device: Device) {
    self.device = device
  }

  // MARK: - Async

  public func create(configuration: VideoStreamConfiguration, to consumer: any DataConsumer) async throws -> any VideoStreamOperation {
    let session = try await DeviceVideo.captureSession(for: device)
    let stream = try DeviceVideoStream(session: session, configuration: configuration, logger: device.logger)
    try await stream.startStreaming(consumer)
    return stream
  }
}
