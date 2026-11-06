/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// One answer a command gives. A command can answer with several, such as one per section or per delivered
/// notification. Each travels as its kind keyed to what it holds: `{"health":{"answer":{…}}}`.
@frozen public enum BridgeAnswer: Codable, Equatable, Sendable {
  case accessibility(BridgeAXAnswer)
  case notificationSettings(BridgeNotificationSettings)
  case deliveredNotification(BridgeDeliveredNotification)
  case health(BridgeHealthAnswer)
  case networkConfiguration(BridgeNetworkConfiguration)
  /// A dynamic-store key's value, as a binary property list.
  case dynamicStoreSnapshot(Data)
  case lockScreen(BridgeLockScreenState)
  case notificationServiceExtension(BridgeNotificationServiceExtensionOutcome)

  // Swift names an unlabelled payload `_0`; these name it for what it holds.
  private enum AccessibilityCodingKeys: String, CodingKey { case _0 = "answer" }
  private enum NotificationSettingsCodingKeys: String, CodingKey { case _0 = "settings" }
  private enum DeliveredNotificationCodingKeys: String, CodingKey { case _0 = "notification" }
  private enum HealthCodingKeys: String, CodingKey { case _0 = "answer" }
  private enum NetworkConfigurationCodingKeys: String, CodingKey { case _0 = "configuration" }
  private enum DynamicStoreSnapshotCodingKeys: String, CodingKey { case _0 = "propertyList" }
  private enum LockScreenCodingKeys: String, CodingKey { case _0 = "state" }
  private enum NotificationServiceExtensionCodingKeys: String, CodingKey { case _0 = "outcome" }

  /// The answer as the host reports it: one line of JSON, its keys sorted.
  public func jsonLine() throws -> String {
    switch self {
    case let .accessibility(answer): try Self.line(answer)
    case let .notificationSettings(settings): try Self.line(settings)
    case let .deliveredNotification(notification): try Self.line(notification)
    case let .health(answer): try Self.line(answer)
    case let .networkConfiguration(configuration): try configuration.jsonLine()
    case let .dynamicStoreSnapshot(propertyList): try Self.line(propertyList)
    case let .lockScreen(state): try Self.line(state)
    case let .notificationServiceExtension(outcome): try Self.line(outcome)
    }
  }

  private static func line(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}

/// SpringBoard's lock state.
public struct BridgeLockScreenState: Codable, Equatable, Sendable {
  public let locked: Bool

  public init(locked: Bool) {
    self.locked = locked
  }
}

/// An application's notification settings, or that it has none. A setting the runtime does not carry is absent.
public struct BridgeNotificationSettings: Codable, Equatable, Sendable {
  public struct Settings: Equatable, Sendable {
    public let allowsNotifications: Bool
    public let authorizationStatus: UInt
    /// Nil on a runtime whose sections carry no such setting.
    public let showsInNotificationCenter: Bool?
    public let showsInLockScreen: Bool?

    public init(allowsNotifications: Bool, authorizationStatus: UInt, showsInNotificationCenter: Bool?, showsInLockScreen: Bool?) {
      self.allowsNotifications = allowsNotifications
      self.authorizationStatus = authorizationStatus
      self.showsInNotificationCenter = showsInNotificationCenter
      self.showsInLockScreen = showsInLockScreen
    }
  }

  public let bundleID: String
  /// Whether the application has a notification section; the settings are present only when it does.
  public let found: Bool
  public let allowsNotifications: Bool?
  public let authorizationStatus: UInt?
  public let showsInNotificationCenter: Bool?
  public let showsInLockScreen: Bool?

  public init(bundleID: String, settings: Settings?) {
    self.bundleID = bundleID
    found = settings != nil
    allowsNotifications = settings?.allowsNotifications
    authorizationStatus = settings?.authorizationStatus
    showsInNotificationCenter = settings?.showsInNotificationCenter
    showsInLockScreen = settings?.showsInLockScreen
  }

  /// Nil when the application has no notification section.
  public var settings: Settings? {
    guard found, let allowsNotifications, let authorizationStatus else { return nil }
    return Settings(
      allowsNotifications: allowsNotifications, authorizationStatus: authorizationStatus, showsInNotificationCenter: showsInNotificationCenter,
      showsInLockScreen: showsInLockScreen)
  }
}

/// A notification an application has delivered. Absent text is empty.
public struct BridgeDeliveredNotification: Codable, Equatable, Sendable {
  public let bundleID: String
  public let identifier: String
  public let title: String
  public let subtitle: String
  public let body: String
  public let threadIdentifier: String
  /// Seconds since 1970, when the notification has a date.
  public let date: Double?

  public init(bundleID: String, identifier: String, title: String, subtitle: String, body: String, threadIdentifier: String, date: Double?) {
    self.bundleID = bundleID
    self.identifier = identifier
    self.title = title
    self.subtitle = subtitle
    self.body = body
    self.threadIdentifier = threadIdentifier
    self.date = date
  }
}

/// A sample type's authorization for an application.
public struct BridgeHealthRecord: Codable, Equatable, Sendable {
  public let identifier: String?
  public let sharingAuthorizationAllowed: Bool?
  public let readingAuthorizationAllowed: Bool?

  public init(identifier: String?, sharingAuthorizationAllowed: Bool?, readingAuthorizationAllowed: Bool?) {
    self.identifier = identifier
    self.sharingAuthorizationAllowed = sharingAuthorizationAllowed
    self.readingAuthorizationAllowed = readingAuthorizationAllowed
  }
}

/// What a health action did. Each action reports the fields it has; one it does not have, or an error it did not
/// meet, is absent.
public struct BridgeHealthAnswer: Codable, Equatable, Sendable {
  @frozen public enum Action: String, Codable, Sendable {
    case approve
    case revoke
    case clear
    case list
  }

  @frozen public enum WriteAction: String, Sendable {
    case approve
    case revoke

    var action: Action { self == .approve ? .approve : .revoke }
  }

  @frozen public enum CompletionStatus: String, Codable, Sendable {
    /// The daemon did not complete the stage in time.
    case timedOut
  }

  public static let nothingResolvedError = "no resolvable HK types in request"
  public static let noAuthorizationSpellingError = "HKAuthorizationStore declares no known setAuthorizationStatuses: spelling"

  public let action: Action
  public let bundleID: String
  public let ok: Bool
  public let error: String?
  public let completionStatus: CompletionStatus?
  public let resolvedTypes: [String]?
  public let unresolvedTypes: [String]?
  public let seedError: String?
  public let setError: String?
  /// Reported even when the fetch also reported an error.
  public let records: [BridgeHealthRecord]?

  public init(
    action: Action, bundleID: String, ok: Bool, error: String? = nil, completionStatus: CompletionStatus? = nil, resolvedTypes: [String]? = nil,
    unresolvedTypes: [String]? = nil, seedError: String? = nil, setError: String? = nil, records: [BridgeHealthRecord]? = nil
  ) {
    self.action = action
    self.bundleID = bundleID
    self.ok = ok
    self.error = error
    self.completionStatus = completionStatus
    self.resolvedTypes = resolvedTypes
    self.unresolvedTypes = unresolvedTypes
    self.seedError = seedError
    self.setError = setError
    self.records = records
  }

  /// An authorization write that ran: `ok` when both the seed and the write succeeded, with each stage's error.
  public static func write(
    action: WriteAction, bundleID: String, ok: Bool, resolvedTypes: [String], unresolvedTypes: [String], seedError: String?, setError: String?
  ) -> Self {
    Self(
      action: action.action, bundleID: bundleID, ok: ok, resolvedTypes: resolvedTypes, unresolvedTypes: unresolvedTypes, seedError: seedError,
      setError: setError)
  }

  /// An authorization write that named no type the runtime knows, so nothing was written.
  public static func nothingResolved(action: WriteAction, bundleID: String, unresolvedTypes: [String]) -> Self {
    Self(action: action.action, bundleID: bundleID, ok: false, error: nothingResolvedError, unresolvedTypes: unresolvedTypes)
  }

  /// An authorization write on a runtime whose authorization store has no setter this guest knows.
  public static func noAuthorizationSpelling(action: WriteAction, bundleID: String, resolvedTypes: [String], unresolvedTypes: [String]) -> Self {
    Self(
      action: action.action, bundleID: bundleID, ok: false, error: noAuthorizationSpellingError, resolvedTypes: resolvedTypes,
      unresolvedTypes: unresolvedTypes)
  }

  public static func clear(bundleID: String, ok: Bool, error: String?) -> Self {
    Self(action: .clear, bundleID: bundleID, ok: ok, error: error)
  }

  public static func list(bundleID: String, ok: Bool, error: String?, records: [BridgeHealthRecord]) -> Self {
    Self(action: .list, bundleID: bundleID, ok: ok, error: error, records: records)
  }

  /// A stage the daemon did not complete in time; `error` names the stage.
  public static func timedOut(action: Action, bundleID: String, error: String) -> Self {
    Self(action: action, bundleID: bundleID, ok: false, error: error, completionStatus: .timedOut)
  }
}

/// What a network configuration store holds. The store keeps whatever was written to it, so its contents travel as
/// the property list they are, restricted to what JSON can report.
public struct BridgeNetworkConfiguration: Codable, Equatable, Sendable {
  /// The contents as a binary property list.
  public let propertyList: Data

  /// Refuses contents JSON cannot hold, such as a date or data, since the host reports them as JSON.
  public init(_ contents: Any) throws {
    guard JSONSerialization.isValidJSONObject([contents]) else { throw BridgeProtocolError.invalidJSONValue }
    propertyList = try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0)
  }

  /// The contents as one line of JSON, its keys sorted.
  func jsonLine() throws -> String {
    let contents = try PropertyListSerialization.propertyList(from: propertyList, format: nil)
    return String(decoding: try JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
  }
}
