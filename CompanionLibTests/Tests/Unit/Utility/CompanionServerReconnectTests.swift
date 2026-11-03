/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBControlCore
@testable import FBDeviceControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import MobileDeviceAPI
import Testing
import os

private final class ReconnectNativeDevice: NSObject {
  private struct State {
    var connected = true
    var connectAttempts = 0
    var lookupAttempts = 0
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  var connectAttempts: Int { state.withLock { $0.connectAttempts } }
  var lookupAttempts: Int { state.withLock { $0.lookupAttempts } }

  func disconnect() { state.withLock { $0.connected = false } }

  func resetAttempts() {
    state.withLock { $0 = State(connected: $0.connected) }
  }

  func connect() -> Int32 {
    state.withLock {
      $0.connectAttempts += 1
      return $0.connected ? 0 : 1
    }
  }

  func recordLookup() {
    state.withLock { $0.lookupAttempts += 1 }
  }

  let values: [String: Any] = [
    "UniqueChipID": NSNumber(value: 43),
    "UniqueDeviceID": "reconnect-udid",
    "DeviceName": "Reconnect Phone",
    "ProductType": "iPhone16,1",
    "ProductVersion": "17.0",
  ]
}

@MainActor
private final class ReconnectNotifications {
  static var current: ReconnectNotifications?

  let first = ReconnectNativeDevice()
  let replacement = ReconnectNativeDevice()
  private var manager: AMDeviceManager?
  private var callback: AMDeviceNotificationCallback?
  private var context: UnsafeMutableRawPointer?

  var currentReference: AMDevice? { manager?.currentDeviceList.first?.amDeviceRef }

  private var calls: AMDCalls {
    var calls = CreateZeroedAMDCalls()
    calls.Retain = { ref in
      if let ref { _ = Unmanaged.passRetained(ref) }
    }
    calls.Release = { ref in
      if let ref { Unmanaged.passUnretained(ref).release() }
    }
    calls.Connect = { ref in
      guard let device = ref as? ReconnectNativeDevice else { return 1 }
      return device.connect()
    }
    calls.Disconnect = { _ in 0 }
    calls.IsPaired = { _ in 1 }
    calls.ValidatePairing = { _ in 0 }
    calls.StartSession = { _ in 0 }
    calls.StopSession = { _ in 0 }
    calls.CopyErrorText = { _ in
      Unmanaged.passRetained("This device is no longer connected." as CFString)
    }
    calls.CopyValue = { ref, _, key in
      guard let device = ref as? ReconnectNativeDevice else { return nil }
      let value: AnyObject?
      if let key = key as String? {
        value = device.values[key] as AnyObject?
      } else {
        value = device.values as NSDictionary
      }
      guard let value else { return nil }
      return unsafeBitCast(Unmanaged.passRetained(value), to: Unmanaged<CFString>.self)
    }
    calls.LookupApplications = { ref, _, applications in
      guard let device = ref as? ReconnectNativeDevice else { return 1 }
      device.recordLookup()
      let apps =
        [
          "com.example.reconnect": [
            "CFBundleIdentifier": "com.example.reconnect",
            "CFBundleName": "Reconnect App",
            "ApplicationType": "User",
          ]
        ] as CFDictionary
      applications.pointee = Unmanaged.passRetained(apps)
      return 0
    }
    // Notification registration is synchronous in makeSet on the main actor.
    calls.NotificationSubscribe = { callback, _, _, context, subscription in
      // patternlint-disable-next-line swift-mainactor-assumeisolated
      MainActor.assumeIsolated {
        ReconnectNotifications.current?.callback = callback
        ReconnectNotifications.current?.context = context
        subscription?.pointee = context
        return 0
      }
    }
    calls.NotificationUnsubscribe = { _ in 0 }
    return calls
  }

  func makeSet(logger: any ControlCoreLogger) throws -> DeviceSet {
    let manager = AMDeviceManager(
      calls: calls, work: .main, asyncQueue: .main, ecidFilter: nil, logger: logger)
    self.manager = manager
    let restorableManager = AMRestorableDeviceManager(
      calls: calls, work: .main, asyncQueue: .main, ecidFilter: nil, logger: logger)
    let set = DeviceSet(
      amDeviceManager: manager, restorableDeviceManager: restorableManager,
      logger: logger, delegate: nil)
    try manager.startListening()
    deliver(.connected, device: first)
    return set
  }

  func reconnect() {
    first.disconnect()
    deliver(.disconnected, device: first)
    deliver(.connected, device: replacement)
    first.resetAttempts()
    replacement.resetAttempts()
  }

  func stop() throws {
    try manager?.stopListening()
    callback = nil
    context = nil
  }

  private func deliver(_ status: AMDeviceNotificationType, device: ReconnectNativeDevice) {
    var notification = AMDeviceNotification(amDevice: Unmanaged.passUnretained(device), status: status)
    withUnsafeMutablePointer(to: &notification) { callback?($0, context) }
  }
}

@Suite(.serialized)
struct CompanionServerReconnectTests {
  @Test("D128054638: list-apps reconnects within the same companion session") @MainActor
  func listAppsUsesReconnectedDeviceInSameSession() async throws {
    let notifications = ReconnectNotifications()
    ReconnectNotifications.current = notifications
    defer {
      try? notifications.stop()
      ReconnectNotifications.current = nil
    }
    let logger = IDBLogger(loggers: [])
    try await withCompanionTestSession(
      "reconnect-udid", makingTargetSets: [{ try notifications.makeSet(logger: logger) }],
      logger: logger
    ) { server in
      let request = ClientRequest(message: Idb_ListAppsRequest.with { $0.suppressProcessState = true })
      var options = CallOptions.defaults
      options.timeout = .seconds(5)
      let baseline = try await server.client.list_apps(request: request, options: options)
      try #require(baseline.apps.map(\.bundleID) == ["com.example.reconnect"])
      try #require(notifications.first.lookupAttempts == 1)
      try #require(notifications.replacement.lookupAttempts == 0)

      notifications.reconnect()
      try #require(notifications.currentReference === notifications.replacement)
      var errors: [String] = []
      var listings: [[String]] = []
      for _ in 0..<2 {
        do {
          let response = try await server.client.list_apps(request: request, options: options)
          listings.append(response.apps.map(\.bundleID))
        } catch {
          errors.append(String(describing: error))
        }
      }

      #expect(errors.isEmpty)
      #expect(listings == Array(repeating: ["com.example.reconnect"], count: 2))
      #expect(notifications.first.connectAttempts == 0)
      #expect(notifications.first.lookupAttempts == 0)
      #expect(notifications.replacement.connectAttempts == 2)
      #expect(notifications.replacement.lookupAttempts == 2)
      #expect(!server.stopped.hasHappened)
    }
  }
}
