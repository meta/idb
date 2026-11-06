/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// The same command is encoded as a CLI argument or a socket frame.
@frozen public enum BridgeCommand: Codable, Equatable, Sendable {
  @frozen public enum DNS: Codable, Equatable, Sendable {
    case list
    case set(servers: [String])
    case clear
  }

  @frozen public enum DynamicStore: Codable, Equatable, Sendable {
    case snapshot(key: String)
    case restore(key: String, snapshot: Data)
  }

  @frozen public enum Proxy: Codable, Equatable, Sendable {
    @frozen public enum Kind: String, Codable, Sendable { case http, socks }
    case list
    case set(host: String, port: Int32, kind: Kind)
    case clear
  }

  @frozen public enum Notifications: Codable, Equatable, Sendable {
    case list(bundleID: String?)
    case approve(bundleID: String)
    case revoke(bundleID: String)
    case delivered(bundleID: String)
    case clearDelivered(bundleID: String)
    case sendWithServiceExtension(bundleID: String, jsonPayload: String)
  }

  @frozen public enum Health: Codable, Equatable, Sendable {
    case list(bundleID: String)
    case clear(bundleID: String)
    case approve(bundleID: String, typeIDs: [String])
    case revoke(bundleID: String, typeIDs: [String])
  }

  @frozen public enum LockScreen: Codable, Equatable, Sendable {
    case state
    case lock
    case unlock
  }

  case clearContacts
  case clearPhotos
  case dns(DNS)
  case dynamicStore(DynamicStore)
  case proxy(Proxy)
  case notifications(Notifications)
  case health(Health)
  case lockScreen(LockScreen)
  case accessibility(BridgeAXRequest)
  case ping
  case shutdown

  // Each service's action is keyed `action`, not the `_0` Swift would name an unlabelled payload.
  private enum DnsCodingKeys: String, CodingKey { case _0 = "action" }
  private enum DynamicStoreCodingKeys: String, CodingKey { case _0 = "action" }
  private enum ProxyCodingKeys: String, CodingKey { case _0 = "action" }
  private enum NotificationsCodingKeys: String, CodingKey { case _0 = "action" }
  private enum HealthCodingKeys: String, CodingKey { case _0 = "action" }
  private enum LockScreenCodingKeys: String, CodingKey { case _0 = "action" }
  private enum AccessibilityCodingKeys: String, CodingKey { case _0 = "action" }

  /// Only reads can be replayed after a connection failure with an uncertain outcome.
  public var mayRetry: Bool {
    switch self {
    case .clearContacts, .clearPhotos, .shutdown: false
    case let .dns(command):
      switch command {
      case .list: true
      case .set, .clear: false
      }
    case let .dynamicStore(command):
      switch command {
      case .snapshot: true
      case .restore: false
      }
    case let .proxy(command):
      switch command {
      case .list: true
      case .set, .clear: false
      }
    case let .notifications(command):
      switch command {
      case .list, .delivered: true
      case .approve, .revoke, .clearDelivered, .sendWithServiceExtension: false
      }
    case let .health(command):
      switch command {
      case .list: true
      case .clear, .approve, .revoke: false
      }
    case let .lockScreen(command):
      switch command {
      case .state: true
      case .lock, .unlock: false
      }
    case let .accessibility(request): request.mayRetry
    case .ping: true
    }
  }
}
