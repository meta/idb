/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

private let ScreenShotDataKey = "ScreenShotData"

public enum DeviceScreenshotError: Error {
  case notImageData(response: String, key: String)
}

extension DeviceScreenshotError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .notImageData(response, key):
      return "\(response) is not an NSData for \(key)"
    }
  }
}

public struct DeviceScreenshotCommands: ScreenshotCommands {
  private let device: Device

  public init(device: Device) {
    self.device = device
  }

  // MARK: - Async

  public func take(configuration: ScreenshotConfiguration) async throws -> ScreenshotResult {
    let captured = try await capture(from: device)
    // A device hands back a finished image file rather than a framebuffer, so any crop or scale is
    // applied to the decoded image. A request for the whole screen as PNG -- which is what the
    // device already sent -- skips the round trip entirely.
    return try ScreenshotRenderer.render(
      encoded: captured,
      configuration: configuration,
      screenScale: device.screenInfo.map { Double($0.scale) }
    )
  }

  private func capture(from device: Device) async throws -> Data {
    // From iOS 17 the developer services, the screenshot service among them, are only reachable
    // through CoreDevice.
    if device.osVersion.version.majorVersion >= 17 {
      return try await AppleDevicectlCommandExecutor(device: device).screenshot()
    }
    return try await device.withDeviceLinkClient("com.apple.mobile.screenshotr") { client in
      let response = try await client.processMessage(["MessageType": "ScreenShotRequest"])
      guard let screenshotData = response[ScreenShotDataKey] as? Data else {
        throw DeviceScreenshotError.notImageData(response: String(describing: response), key: ScreenShotDataKey)
      }
      return screenshotData
    }
  }
}
