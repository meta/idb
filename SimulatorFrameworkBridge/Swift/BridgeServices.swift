/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
import Foundation

public enum BridgeServices {
  public static func execute(_ command: BridgeCommand) -> BridgeResult {
    let output = BridgeOutput()
    return output.finish(status: run(command, output: output))
  }

  private static func run(_ command: BridgeCommand, output: BridgeOutput) -> Int32 {
    switch command {
    case .ping, .shutdown:
      return 0
    case .clearContacts:
      #if os(tvOS) || os(watchOS)
      return unavailable("The contacts service", output: output)
      #else
      return Int32(ContactsService.handleContactsAction(action: "clear", output: output))
      #endif
    case .clearPhotos:
      #if os(watchOS)
      return unavailable("The photos service", output: output)
      #else
      return Int32(PhotoLibraryService.handlePhotoLibraryAction(action: "clear", output: output))
      #endif
    case let .dns(command):
      let action: String
      let arguments: [String]
      switch command {
      case .list:
        action = "list"
        arguments = []
      case .clear:
        action = "clear"
        arguments = []
      case let .set(servers):
        action = "set"
        arguments = servers
      }
      return Int32(DnsService.handleDnsAction(action: action, arguments: arguments, output: output))
    case let .dynamicStore(command):
      switch command {
      case let .snapshot(key):
        return Int32(DynamicStoreService.handleDynamicStoreAction(action: "snapshot", arguments: [key], input: { Data() }, output: output))
      case let .restore(key, snapshot):
        return Int32(DynamicStoreService.handleDynamicStoreAction(action: "restore", arguments: [key], input: { snapshot }, output: output))
      }
    case let .proxy(command):
      let action: String
      let arguments: [String]
      switch command {
      case .list:
        action = "list"
        arguments = []
      case .clear:
        action = "clear"
        arguments = []
      case let .set(host, port, kind):
        action = "set"
        arguments = [host, String(port), kind.rawValue]
      }
      return Int32(ProxyService.handleProxyAction(action: action, arguments: arguments, output: output))
    case let .notifications(command):
      let action: String
      let bundleID: String?
      switch command {
      case let .list(identifier):
        action = "list"
        bundleID = identifier
      case let .approve(identifier):
        action = "approve"
        bundleID = identifier
      case let .revoke(identifier):
        action = "revoke"
        bundleID = identifier
      case let .delivered(identifier):
        #if os(tvOS)
        return unavailable("The notifications delivered action", output: output)
        #else
        return DeliveredNotificationsService.handleAction("delivered", bundleID: identifier, directory: nil, timeout: 0, output: output)
        #endif
      case let .sendWithServiceExtension(identifier, jsonPayload):
        #if os(iOS)
        return NotificationServiceExtensionService.send(bundleID: identifier, jsonPayload: jsonPayload, output: output)
        #else
        return unavailable("Notification service extension delivery", output: output)
        #endif
      case let .clearDelivered(identifier):
        #if os(tvOS)
        return unavailable("The notifications clear-delivered action", output: output)
        #else
        return DeliveredNotificationsService.handleAction("clear-delivered", bundleID: identifier, directory: nil, timeout: 0, output: output)
        #endif
      }
      return Int32(NotificationSettingsService.handleNotificationSettingsAction(action: action, bundleID: bundleID, output: output))
    case let .health(command):
      #if os(tvOS)
      return unavailable("The health service", output: output)
      #else
      let action: String
      let bundleID: String
      let types: [String]
      switch command {
      case let .list(identifier):
        action = "list"
        bundleID = identifier
        types = []
      case let .clear(identifier):
        action = "clear"
        bundleID = identifier
        types = []
      case let .approve(identifier, identifiers):
        action = "approve"
        bundleID = identifier
        types = identifiers
      case let .revoke(identifier, identifiers):
        action = "revoke"
        bundleID = identifier
        types = identifiers
      }
      return Int32(HealthSettingsService.handleHealthSettingsAction(action: action, bundleID: bundleID, typeIdentifiers: types, output: output))
      #endif
    case let .lockScreen(command):
      #if os(tvOS) || os(watchOS)
      return unavailable("The lock screen service", output: output)
      #else
      return lockScreen(command, output: output)
      #endif
    case let .accessibility(request):
      return accessibility(AccessibilityService.handleRequest(request), output: output)
    }
  }

  /// The answer to an accessibility frame whose parameters are not a request, in the response a malformed request has
  /// always had.
  public static func undecodedAccessibility(_ error: BridgeAXRequestError) -> BridgeResult {
    accessibilityResult(.failure(AccessibilityService.failure(error)))
  }

  /// Commands that answer with a stream of results rather than one; nil for every other command.
  public static func stream(_ command: BridgeCommand) -> BridgeStreamStart? {
    guard case let .accessibility(request) = command, let start = AccessibilityService.stream(request) else { return nil }
    switch start {
    case let .stream(events):
      return .stream(AccessibilityResultStream(events: events))
    case let .failure(response):
      return .result(accessibilityResult(.failure(response)))
    }
  }

  /// The answer goes in the frame as it is, so nothing encodes or parses it twice.
  private static func accessibility(_ answer: BridgeAXAnswer, output: BridgeOutput) -> Int32 {
    output.write(accessibility: answer)
    return answer.succeeded ? 0 : 1
  }

  fileprivate static func accessibilityResult(_ answer: BridgeAXAnswer) -> BridgeResult {
    let output = BridgeOutput()
    return output.finish(status: accessibility(answer, output: output))
  }

  private static func unavailable(_ subject: String, output: BridgeOutput) -> Int32 {
    Int32(output.failure("\(subject) is not available in a \(guestPlatformName) guest"))
  }

  #if !os(tvOS) && !os(watchOS)
  private static func lockScreen(_ command: BridgeCommand.LockScreen, output: BridgeOutput) -> Int32 {
    let result =
      switch command {
      case .state: LockScreenService.state()
      case .lock: LockScreenService.lock()
      case .unlock: LockScreenService.unlock()
      }
    switch result {
    case let .success(status):
      return output.write(.lockScreen(BridgeLockScreenState(locked: status.locked, passcodeEnabled: status.passcodeEnabled))) ? 0 : 1
    case let .failure(error):
      return Int32(output.failure(error.localizedDescription))
    }
  }
  #endif
}

private final class AccessibilityResultStream: BridgeResultStream {
  private let events: any AccessibilityAnswerStream

  init(events: any AccessibilityAnswerStream) {
    self.events = events
  }

  func run(emit: @escaping (BridgeResult) -> Bool) {
    events.run { emit(BridgeServices.accessibilityResult($0)) }
  }

  func cancel() {
    events.cancel()
  }
}
