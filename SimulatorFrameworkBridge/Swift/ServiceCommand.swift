/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

private enum BridgeService: String {
  case contacts
  case health
  case dns
  case dynamicStore = "dynamic-store"
  case photos
  case notifications
  case privacy
  case proxy
  case accessibility
  case orientation
  case repl
}

public protocol CommandLineServiceHandling {
  #if !os(tvOS) && !os(watchOS)
  func contacts(_ action: String) -> Int32
  #endif
  #if !os(tvOS)
  func health(_ action: String, bundleID: String?, typeIDs: [String]) -> Int32
  func deliveredNotifications(_ action: String, bundleID: String?) -> Int32
  #endif
  func dns(_ action: String, arguments: [String]) -> Int32
  func dynamicStore(_ action: String, arguments: [String]) -> Int32
  #if !os(watchOS)
  func photos(_ action: String) -> Int32
  #endif
  func notifications(_ action: String, bundleID: String?) -> Int32
  func privacy(_ action: String, arguments: [String]) -> Int32
  func proxy(_ action: String, arguments: [String]) -> Int32
  func accessibility(_ action: String, arguments: [String]) -> Int32
  func orientation(_ action: String, arguments: [String]) -> Int32
  func repl(_ socketPath: String?, libraryPath: String, additionalLibraryPaths: [String]) -> Int32
}

/// The services the guest command line reaches, each reporting to stdout.
public struct CommandLineServices: CommandLineServiceHandling {
  private let deliveredNotificationsDirectory: String?
  private let deliveredNotificationsTimeout: TimeInterval

  /// A nil directory and a non-positive timeout select the delivered-notifications reader's defaults.
  public init(deliveredNotificationsDirectory: String? = nil, deliveredNotificationsTimeout: TimeInterval = 0) {
    self.deliveredNotificationsDirectory = deliveredNotificationsDirectory
    self.deliveredNotificationsTimeout = deliveredNotificationsTimeout
  }

  #if !os(tvOS) && !os(watchOS)
  public func contacts(_ action: String) -> Int32 {
    Int32(ContactsService.handleContactsAction(action: action))
  }
  #endif

  #if !os(tvOS)
  public func health(_ action: String, bundleID: String?, typeIDs: [String]) -> Int32 {
    Int32(HealthSettingsService.handleHealthSettingsAction(action: action, bundleID: bundleID, typeIdentifiers: typeIDs))
  }

  public func deliveredNotifications(_ action: String, bundleID: String?) -> Int32 {
    DeliveredNotificationsService.handleAction(action, bundleID: bundleID, directory: deliveredNotificationsDirectory, timeout: deliveredNotificationsTimeout)
  }
  #endif

  public func dns(_ action: String, arguments: [String]) -> Int32 {
    Int32(DnsService.handleDnsAction(action: action, arguments: arguments))
  }

  public func dynamicStore(_ action: String, arguments: [String]) -> Int32 {
    Int32(DynamicStoreService.handleDynamicStoreAction(action: action, arguments: arguments))
  }

  #if !os(watchOS)
  public func photos(_ action: String) -> Int32 {
    Int32(PhotoLibraryService.handlePhotoLibraryAction(action: action))
  }
  #endif

  public func notifications(_ action: String, bundleID: String?) -> Int32 {
    Int32(NotificationSettingsService.handleNotificationSettingsAction(action: action, bundleID: bundleID))
  }

  public func privacy(_ action: String, arguments: [String]) -> Int32 {
    PrivacyService.handleAction(action, arguments: arguments)
  }

  public func proxy(_ action: String, arguments: [String]) -> Int32 {
    Int32(ProxyService.handleProxyAction(action: action, arguments: arguments))
  }

  public func accessibility(_ action: String, arguments: [String]) -> Int32 {
    AccessibilityService.handleAction(action, arguments: arguments) { data in
      let written = unsafe data.withUnsafeBytes { unsafe fwrite($0.baseAddress, 1, $0.count, stdout) } == data.count
      // A `quiet` stream writes a line per event and runs until it is killed.
      return unsafe written && fputc(10, stdout) != EOF && fflush(stdout) == 0
    }
  }

  public func orientation(_ action: String, arguments: [String]) -> Int32 {
    OrientationService.run(action: action, arguments: arguments)
  }

  public func repl(_ socketPath: String?, libraryPath: String, additionalLibraryPaths: [String]) -> Int32 {
    // The socket server and any library injected code calls through must use the shim's one
    // control connection, so everything loads globally into this process.
    guard let handle = unsafe dlopen((libraryPath as NSString).fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL) else {
      NSLog("Failed to load the shim at %@: %@", libraryPath, Self.lastLoaderError())
      return 1
    }
    for additionalLibraryPath in additionalLibraryPaths {
      guard unsafe dlopen((additionalLibraryPath as NSString).fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL) != nil else {
        NSLog("Failed to load %@: %@", additionalLibraryPath, Self.lastLoaderError())
        return 1
      }
    }
    guard let symbol = unsafe dlsym(handle, "FBReplServeSocket") else {
      NSLog("The shim is missing FBReplServeSocket: %@", Self.lastLoaderError())
      return 1
    }
    typealias Serve = @convention(c) (NSString?, NSArray, ObjCBool) -> Int32
    // The bridge exits when the session ends, so serve a single connection.
    return unsafe unsafeBitCast(symbol, to: Serve.self)(socketPath as NSString?, [] as NSArray, false)
  }

  private static func lastLoaderError() -> String {
    unsafe dlerror().map { unsafe String(cString: $0) } ?? "(null)"
  }
}

public enum BridgeCommandLine {
  private static let serviceNames = "contacts, dns, dynamic-store, photos, notifications, health, privacy, proxy, accessibility, orientation, repl"

  public static func run(arguments: [String], services: any CommandLineServiceHandling = CommandLineServices()) -> Int32 {
    if let status = BridgeRPC.run(arguments: arguments) { return status }
    guard arguments.count >= 3 else {
      NSLog("Usage: %@ <service> <action> [args...]", arguments.first ?? "SimulatorFrameworkBridge")
      NSLog("Services: %@", serviceNames)
      NSLog("Actions: clear, approve, revoke, check, set, list, delivered, clear-delivered, snapshot, restore")
      return 1
    }
    return dispatch(service: arguments[1], action: arguments[2], arguments: Array(arguments.dropFirst(3)), services: services)
  }

  public static func dispatch(service: String, action: String, arguments: [String], services: any CommandLineServiceHandling = CommandLineServices()) -> Int32 {
    let selectedService = BridgeService(rawValue: service)
    switch selectedService {
    case .contacts:
      #if os(tvOS) || os(watchOS)
      NSLog("The %@ service is not available in a %@ guest", service, guestPlatformName)
      return 1
      #else
      return services.contacts(action)
      #endif
    case .health:
      #if os(tvOS)
      NSLog("The %@ service is not available in a %@ guest", service, guestPlatformName)
      return 1
      #else
      return services.health(action, bundleID: arguments.first, typeIDs: Array(arguments.dropFirst()))
      #endif
    case .dns: return services.dns(action, arguments: arguments)
    case .dynamicStore: return services.dynamicStore(action, arguments: arguments)
    case .photos:
      #if os(watchOS)
      NSLog("The %@ service is not available in a %@ guest", service, guestPlatformName)
      return 1
      #else
      return services.photos(action)
      #endif
    case .notifications:
      // `list` on this service means "list the apps' settings", so the delivered notifications of one app
      // are read and cleared with their own verbs.
      if action == "delivered" || action == "clear-delivered" {
        #if os(tvOS)
        NSLog("The notifications %@ action is not available in a %@ guest", action, guestPlatformName)
        return 1
        #else
        return services.deliveredNotifications(action, bundleID: arguments.first)
        #endif
      }
      return services.notifications(action, bundleID: arguments.first)
    case .privacy: return services.privacy(action, arguments: arguments)
    case .proxy: return services.proxy(action, arguments: arguments)
    case .accessibility: return services.accessibility(action, arguments: arguments)
    case .orientation: return services.orientation(action, arguments: arguments)
    case .repl:
      guard action == "start" else {
        NSLog("Unknown repl action: %@", action)
        return 1
      }
      guard arguments.count > 1, !arguments[1].isEmpty else {
        NSLog("repl start requires the shim's path as its second argument")
        return 1
      }
      return services.repl(arguments.first, libraryPath: arguments[1], additionalLibraryPaths: Array(arguments.dropFirst(2)))
    case nil:
      NSLog("Unknown service: %@", service)
      NSLog("Available services: %@", serviceNames)
      return 1
    }
  }
}

/// Names the platform this guest was built for in the messages that refuse a service its SDK lacks.
let guestPlatformName: String = {
  #if os(tvOS)
  return "tvOS"
  #elseif os(watchOS)
  return "watchOS"
  #else
  return "iOS"
  #endif
}()
