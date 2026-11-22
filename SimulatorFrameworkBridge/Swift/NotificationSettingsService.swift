/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
import Foundation

#if canImport(SimulatorFrameworkBridgeRuntime)
internal import SimulatorFrameworkBridgeRuntime
#endif
private let UNAuthorizationStatusNotDetermined: UInt = 0
private let UNAuthorizationStatusAuthorized: UInt = 2

private func printSectionJSON(bundleID: String, section: FBNotificationSection, output: BridgeOutput?) -> Bool {
  if let output {
    guard section.isFound else { return output.write(.notificationSettings(BridgeNotificationSettings(bundleID: bundleID, settings: nil))) }
    let values: FBNotificationSectionValues
    do { values = try section.readValues() } catch {
      output.failure("Could not read notification settings: \(error.localizedDescription)")
      return false
    }
    return output.write(
      .notificationSettings(
        BridgeNotificationSettings(
          bundleID: bundleID,
          settings: .init(
            allowsNotifications: values.allowsNotifications, authorizationStatus: UInt(values.authorizationStatus),
            showsInNotificationCenter: values.showsInNotificationCenter?.boolValue, showsInLockScreen: values.showsInLockScreen?.boolValue))))
  }
  // The existing C output stops the bundle identifier at its first NUL.
  let printedBundleID = String(bundleID.prefix { $0 != "\0" })
  guard section.isFound else {
    // patternlint-disable-next-line avoid-print-to-prevent-production-overhead
    print("{\"bundleID\":\"\(printedBundleID)\",\"found\":false}")
    return true
  }
  guard let values = try? section.readValues() else {
    return false
  }
  let allowed = values.allowsNotifications ? "true" : "false"
  let center = values.showsInNotificationCenter.map { $0.boolValue ? "true" : "false" } ?? "null"
  let lockScreen = values.showsInLockScreen.map { $0.boolValue ? "true" : "false" } ?? "null"
  // patternlint-disable-next-line avoid-print-to-prevent-production-overhead
  print("{\"bundleID\":\"\(printedBundleID)\",\"found\":true,\"allowsNotifications\":\(allowed),\"authorizationStatus\":\(values.authorizationStatus),\"showsInNotificationCenter\":\(center),\"showsInLockScreen\":\(lockScreen)}")
  return true
}

public enum NotificationSettingsService {
  public static func handleNotificationSettingsAction(action: String?, bundleID: String?) -> Int {
    handleNotificationSettingsAction(action: action, bundleID: bundleID, output: nil)
  }

  static func handleNotificationSettingsAction(action: String?, bundleID: String?, output: BridgeOutput?) -> Int {
    guard let client = FBNotificationSettingsClient.live() else {
      return output?.failure("The notification settings private API is unavailable") ?? 1
    }
    return handleNotificationSettingsActionWithClient(action: action, bundleID: bundleID, client: client, output: output)
  }

  public static func handleNotificationSettingsActionWithGateway(action: String?, bundleID: String?, gateway: Any, output: BridgeOutput? = nil) -> Int {
    handleNotificationSettingsActionWithClient(action: action, bundleID: bundleID, client: FBNotificationSettingsClient(gateway: gateway), output: output)
  }
}

private func handleNotificationSettingsActionWithClient(
  action: String?,
  bundleID: String?,
  client: FBNotificationSettingsClient,
  output: BridgeOutput?
) -> Int {
  do {
    let selectedAction = action.flatMap(NotificationSettingsAction.init(rawValue:))
    if selectedAction == .check || selectedAction == .list {
      if let bundleID {
        let section = try client.section(forIdentifier: bundleID)
        guard printSectionJSON(bundleID: bundleID, section: section, output: output) else {
          return 1
        }
      } else {
        let identifiers = try client.allSectionIDs()
        for sectionID in identifiers {
          let section = try client.section(forIdentifier: sectionID)
          guard printSectionJSON(bundleID: sectionID, section: section, output: output) else {
            return 1
          }
        }
      }
      return 0
    }

    guard let bundleID else {
      NSLog("[NotificationSettings] bundleID required for %@", action ?? "(null)")
      return 1
    }

    var section = try client.section(forIdentifier: bundleID)
    if selectedAction == .approve {
      if !section.isFound {
        section = try client.createSection(forIdentifier: bundleID)
        NSLog("[NotificationSettings] Created new section info for %@", bundleID)
      }
      try section.setAllowsNotifications(true)
      try section.setAuthorizationStatus(UNAuthorizationStatusAuthorized)
      try section.setAlertType(1)
      try section.setLockScreenSetting(1)
      try section.setNotificationCenterSetting(1)
      let absent = try section.setEffectiveVisibility(true)
      if !absent.isEmpty {
        NSLog(
          "[NotificationSettings] This runtime's BBSectionInfo has no %@, so %@ is authorized but may not retain its notifications",
          absent.joined(separator: " or "),
          bundleID
        )
      }
    } else if selectedAction == .revoke {
      guard section.isFound else {
        NSLog("[NotificationSettings] No section info for %@, nothing to revoke.", bundleID)
        return 0
      }
      try section.setAllowsNotifications(false)
      try section.setAuthorizationStatus(UNAuthorizationStatusNotDetermined)
    } else {
      NSLog("[NotificationSettings] Unknown action: %@. Use approve, revoke, or check.", action ?? "(null)")
      return 1
    }

    try client.write(section, forIdentifier: bundleID)
    NSLog("[NotificationSettings] %@ notifications for %@", action ?? "(null)", bundleID)
    return 0
  } catch {
    return output?.failure("Notification settings failed: \(error.localizedDescription)") ?? 1
  }
}
