/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
import FBControlCore
import FBSimulatorControl
import Foundation

public enum SimulatorNotificationError: Error {
  case jsonNotUTF8
  case jsonNotADictionary
  case selectorUnavailable
  case undecodableDeliveredNotification(line: String, reason: String)
  case serviceExtensionUnsupported
  case serviceExtensionFailed(String)
}

extension SimulatorNotificationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .jsonNotUTF8:
      return "Failed to encode notification json as UTF-8"
    case .jsonNotADictionary:
      return "Failed to deserialize notification json: not a dictionary"
    case .selectorUnavailable:
      return "SimDevice doesn't have sendPushNotificationForBundleID selector"
    case .serviceExtensionUnsupported:
      return "Notification service extension delivery requires an iPhone or iPad simulator and a valid app bundle identifier"
    case let .serviceExtensionFailed(reason):
      return "Notification service extension delivery failed: \(reason)"
    case let .undecodableDeliveredNotification(line, reason):
      return "Failed to decode delivered notification '\(line)': \(reason)"
    }
  }
}

public struct SimulatorNotificationCommands {

  private let simulator: Simulator

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  public func sendPush(forBundleID bundleID: String, jsonPayload: String, processServiceExtension: Bool = false) async throws {
    if processServiceExtension {
      guard [.iPhone, .iPad].contains(simulator.productFamily), SimulatorFrameworkBridgeStaging.bundleIdentity(bundleID) != nil else {
        throw SimulatorNotificationError.serviceExtensionUnsupported
      }
      let result = try await simulator.frameworkBridge(.notifications(.sendWithServiceExtension(bundleID: bundleID, jsonPayload: jsonPayload)))
      guard result.exitCode == 0 else {
        throw SimulatorNotificationError.serviceExtensionFailed(result.error ?? "The guest could not process the notification")
      }
      guard result.answers.count == 1, case .notificationServiceExtension = result.answers[0] else {
        throw SimulatorNotificationError.serviceExtensionFailed("The guest returned no NSE processing outcome")
      }
      return
    }

    guard let data = jsonPayload.data(using: .utf8) else {
      throw SimulatorNotificationError.jsonNotUTF8
    }
    guard let jsonObj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SimulatorNotificationError.jsonNotADictionary
    }

    guard simulator.device.responds(to: NSSelectorFromString("sendPushNotificationForBundleID:jsonPayload:error:")) else {
      throw SimulatorNotificationError.selectorUnavailable
    }

    try simulator.device.sendPushNotification(forBundleID: bundleID, jsonPayload: jsonObj)
  }

  /// The notifications an app has had delivered to it.
  ///
  /// Reads what the system retained rather than what is on screen, so the app does
  /// not have to be running and nothing here launches or foregrounds it. A test that
  /// killed an app to exercise its push path can therefore still assert on what
  /// arrived.
  public func deliveredNotifications(forBundleID bundleID: String) async throws -> [DeliveredNotification] {
    let output = try await simulator.runSimulatorFrameworkBridge(.notifications(.delivered(bundleID: bundleID)))
    return try DeliveredNotification.records(fromBridgeOutput: output)
  }

  /// Withdraws every notification the system is holding for an app.
  ///
  /// The counterpart to `deliveredNotifications`, and reaches the same records: the app
  /// does not have to be running, and nothing here launches or foregrounds it. Clearing
  /// is what lets a test start from a known inbox rather than from whatever earlier runs
  /// left behind, since a delivered notification outlives the app that received it.
  public func clearDeliveredNotifications(forBundleID bundleID: String) async throws {
    try await simulator.runSimulatorFrameworkBridge(.notifications(.clearDelivered(bundleID: bundleID)))
  }

}

/// One notification the system retained for an app.
public struct DeliveredNotification: Codable, Sendable {
  public let bundleID: String
  public let identifier: String
  public let title: String
  public let subtitle: String
  public let body: String
  public let threadIdentifier: String
  /// Seconds since the Unix epoch; absent when the record carried no date.
  public let date: Double?

  private enum CodingKeys: String, CodingKey {
    case bundleID = "bundleID"
    case identifier
    case title
    case subtitle
    case body
    case threadIdentifier
    case date
  }

  /// The records in one run of the guest's delivered-notifications output.
  ///
  /// A line that will not decode fails the call rather than being passed over. The guest
  /// prints records to stdout and nothing else -- its diagnostics go through NSLog -- so
  /// such a line means the contract broke, not that there is nothing to read; dropping it
  /// would answer with a list shorter than the app's without saying so, which reads as an
  /// app that received fewer notifications than it did.
  static func records(fromBridgeOutput output: String) throws -> [DeliveredNotification] {
    let decoder = JSONDecoder()
    return try output.split(separator: "\n").map { line in
      do {
        return try decoder.decode(DeliveredNotification.self, from: Data(line.utf8))
      } catch {
        throw SimulatorNotificationError.undecodableDeliveredNotification(
          line: String(line),
          reason: "\(error)")
      }
    }
  }
}
