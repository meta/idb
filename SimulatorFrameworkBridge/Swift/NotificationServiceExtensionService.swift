/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if os(iOS)
import FBSimulatorBridgeProtocol
import Foundation
#if canImport(SimulatorFrameworkBridgeRuntime)
@_implementationOnly import SimulatorFrameworkBridgeRuntime
#endif

enum NotificationServiceExtensionService {
  static func send(bundleID: String, jsonPayload: String, output: BridgeOutput) -> Int32 {
    let result = FBNotificationServiceExtensionClient.send(bundleID: bundleID, jsonPayload: jsonPayload)
    switch result.status {
    case .delivered:
      return output.write(.notificationServiceExtension(.delivered)) ? 0 : 1
    case .suppressed:
      return output.write(.notificationServiceExtension(.suppressed)) ? 0 : 1
    case .failed:
      return Int32(output.failure(result.failure ?? "Notification service extension processing failed"))
    @unknown default:
      return Int32(output.failure("Unknown notification service extension outcome"))
    }
  }
}
#endif
