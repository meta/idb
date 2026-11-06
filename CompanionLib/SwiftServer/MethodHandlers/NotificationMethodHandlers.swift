/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import GRPCCore
import IDBGRPCSwift

struct SendNotificationMethodHandler {

  let target: CompanionTarget

  func handle(request: Idb_SendNotificationRequest, context: ServerContext) async throws -> Idb_SendNotificationResponse {
    let simulator = try target.simulator()
    try await withRPCCancellation(context.cancellation) {
      try await simulator.notification.sendPush(
        forBundleID: request.bundleID, jsonPayload: request.jsonPayload,
        processServiceExtension: request.processServiceExtension)
    }
    return .init()
  }
}

struct DeliveredNotificationsMethodHandler {

  let target: CompanionTarget

  func handle(request: Idb_DeliveredNotificationsRequest, context: ServerContext) async throws -> Idb_DeliveredNotificationsResponse {
    let notifications = try await target.simulator().notification.deliveredNotifications(forBundleID: request.bundleID)
    return .with {
      $0.notifications = notifications.map { notification in
        Idb_DeliveredNotification.with {
          $0.bundleID = notification.bundleID
          $0.identifier = notification.identifier
          $0.title = notification.title
          $0.subtitle = notification.subtitle
          $0.body = notification.body
          $0.threadIdentifier = notification.threadIdentifier
          if let date = notification.date {
            $0.date = date
          }
        }
      }
    }
  }
}

struct ClearDeliveredNotificationsMethodHandler {

  let target: CompanionTarget

  func handle(request: Idb_ClearDeliveredNotificationsRequest, context: ServerContext) async throws -> Idb_ClearDeliveredNotificationsResponse {
    try await target.simulator().notification.clearDeliveredNotifications(forBundleID: request.bundleID)
    return .init()
  }
}
