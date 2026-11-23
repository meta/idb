/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import SimulatorFrameworkBridgeSupport
import Testing

@Suite
struct NotificationExceptionTests {
  @Test
  func privateExceptionsAtCommandBoundary() {
    for operation in [
      "lookup", "write", "list", "allowsNotifications", "authorizationStatus",
      "setAllowsNotifications", "setAuthorizationStatus", "setAlertType", "setLockScreenSetting", "setNotificationCenterSetting",
    ] {
      let result = FBNotificationCommandExceptionResult(operation) {
        Int32(NotificationSettingsService.handleNotificationSettingsActionWithGateway(action: $0, bundleID: $1, gateway: $2))
      }
      #expect(result as NSDictionary == ["status": 1] as NSDictionary)
    }
  }
}
