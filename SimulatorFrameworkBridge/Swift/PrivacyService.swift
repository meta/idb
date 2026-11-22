/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

#if canImport(SimulatorFrameworkBridgeRuntime)
internal import SimulatorFrameworkBridgeRuntime
#endif

public enum PrivacyService {
  private static let services = [
    "camera": "kTCCServiceCamera",
    "microphone": "kTCCServiceMicrophone",
    "photos": "kTCCServicePhotos",
    "contacts": "kTCCServiceAddressBook",
  ]

  public static func handleAction(_ action: String, arguments: [String]) -> Int32 {
    execute(action: action, arguments: arguments) { bundleID, services, approved in
      let outcome = FBPrivacyBinding.updateBundleID(bundleID, services: services, approved: approved)
      switch outcome.status {
      case .completed: return nil
      case .unavailable, .failed: return outcome.failureReason ?? "TCC operation failed"
      @unknown default: return "Unknown TCC operation result"
      }
    }
  }

  static func execute(
    action: String,
    arguments: [String],
    update: (String, [String], Bool) -> String?
  ) -> Int32 {
    guard action == "approve" || action == "revoke", arguments.count >= 2,
      let bundleID = arguments.first, !bundleID.isEmpty
    else {
      NSLog("Usage: privacy <approve|revoke> <bundleID> <camera|microphone|photos|contacts>...")
      return 1
    }
    var resolved: [String] = []
    for name in arguments.dropFirst() {
      guard let service = services[name] else {
        NSLog("Unknown privacy service: %@", name)
        return 1
      }
      if !resolved.contains(service) {
        resolved.append(service)
      }
    }
    if let failure = update(bundleID, resolved, action == "approve") {
      NSLog("[Privacy] %@", failure)
      return 1
    }
    return 0
  }
}
