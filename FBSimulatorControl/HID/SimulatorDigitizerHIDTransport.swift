/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import CoreSimulator
import FBControlCore
import Foundation

/// Tracks the per-contact phase so that a stream of Indigo `.down`/`.up` events maps onto the
/// `dtuhidd` `start` / `position` / `end` model: the first `.down` is a `start`, subsequent `.down`s
/// (a drag/swipe) are `position`s, and `.up` is the `end`.
///
/// `dtuhidd` forgets a contact when its connection is interrupted, so a `.down` that would continue a
/// contact started under an earlier `interruptions` count throws instead of moving a contact the guest
/// no longer has. The next `.down` starts afresh.
struct DigitizerContactTracker {
  /// The connection's interruption count when the contact started, while one is down.
  private var startedAt: Int?

  mutating func eventType(for direction: SimulatorHIDDirection, interruptions: Int) throws -> DigitizerEventType {
    switch direction {
    case .down:
      guard let startedAt else {
        startedAt = interruptions
        return .start
      }
      guard startedAt == interruptions else {
        self.startedAt = nil
        throw SimulatorHIDError.dtuhidGestureInterrupted
      }
      return .position
    case .up:
      startedAt = nil
      return .end
    }
  }
}

/**
 The DTUHID digitizer transport (Xcode 27 / macOS 26 / iOS 26+).

 Drives the modern `dtuhidd` daemon's digitizer service: touches, buttons and keys cross the
 host→guest boundary as plain-XPC dictionaries, each built as an `Encodable` model (e.g.
 `IndigoDigitizerEvent`) wrapped in a `DTUHIDMessage` envelope and serialized with `XPCEncoder`.

 The connection, its liveness probe and its drain are `SimulatorDTUHIDConnection`'s; this type is the
 digitizer encoding over it, and an actor so the contact state it tracks is isolated.
 */
actor SimulatorDigitizerHIDTransport {

  static let serviceName = "com.apple.coredevice.feature.remote.hid.digitizer"

  private let connection: SimulatorDTUHIDConnection
  private let mainScreenSize: CGSize
  private let mainScreenScale: Float
  private let productFamily: ProductFamily
  private var contact = DigitizerContactTracker()
  private var twoFingerContact = DigitizerContactTracker()

  // MARK: - Initializers

  /// Connects to the simulator's DTUHID digitizer service. See `SimulatorDTUHIDConnection.connect`.
  static func connect(to simulator: Simulator) async throws -> SimulatorDigitizerHIDTransport {
    SimulatorDigitizerHIDTransport(
      connection: try await SimulatorDTUHIDConnection.connect(using: simulator.xpc, serviceName: serviceName),
      mainScreenSize: simulator.device.deviceType.mainScreenSize,
      mainScreenScale: simulator.device.deviceType.mainScreenScale,
      productFamily: simulator.productFamily)
  }

  init(
    connection: SimulatorDTUHIDConnection,
    mainScreenSize: CGSize,
    mainScreenScale: Float,
    productFamily: ProductFamily
  ) {
    self.connection = connection
    self.mainScreenSize = mainScreenSize
    self.mainScreenScale = mainScreenScale
    self.productFamily = productFamily
  }

  // MARK: - Sends

  nonisolated func disconnect() {
    connection.disconnect()
  }

  func flush() async throws {
    try await connection.flush()
  }

  func sendTouch(
    direction: SimulatorHIDDirection, x: Double, y: Double, edge: SimulatorHIDEdge, display: SimulatorHIDDisplay? = nil
  ) async throws {
    guard productFamily.hasTouchscreen else {
      throw SimulatorHIDError.touchUnsupportedOnAppleTV
    }
    let ratio =
      try display?.geometry.normalizedPoint(CGPoint(x: x, y: y))
      ?? SimulatorIndigoHID.screenRatio(
        from: CGPoint(x: x, y: y), screenSize: mainScreenSize, screenScale: mainScreenScale)
    let event = IndigoDigitizerEvent(
      pointOne: DigitizerPoint(x: Double(ratio.x), y: Double(ratio.y)),
      eventType: try contact.eventType(for: direction, interruptions: connection.interruptions),
      edge: UInt64((display?.geometry.unrotatedEdge(edge) ?? edge).rawValue),
      target: display?.digitizerTarget ?? 0)
    try await send(messageType: "IndigoDigitizerEvent", payload: event)
  }

  func sendTwoFingerTouch(direction: SimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint, display: SimulatorHIDDisplay? = nil) async throws {
    guard productFamily.hasTouchscreen else {
      throw SimulatorHIDError.touchUnsupportedOnAppleTV
    }
    let r1 = try display?.geometry.normalizedPoint(finger1) ?? SimulatorIndigoHID.screenRatio(from: finger1, screenSize: mainScreenSize, screenScale: mainScreenScale)
    let r2 = try display?.geometry.normalizedPoint(finger2) ?? SimulatorIndigoHID.screenRatio(from: finger2, screenSize: mainScreenSize, screenScale: mainScreenScale)
    let event = IndigoDigitizerEvent(
      pointOne: DigitizerPoint(x: Double(r1.x), y: Double(r1.y)),
      pointTwo: DigitizerPoint(x: Double(r2.x), y: Double(r2.y)),
      eventType: try twoFingerContact.eventType(for: direction, interruptions: connection.interruptions),
      target: display?.digitizerTarget ?? 0)
    try await send(messageType: "IndigoDigitizerEvent", payload: event)
  }

  func sendButton(direction: SimulatorHIDDirection, button: SimulatorHIDButton) async throws {
    guard let usage = button.identity.consumerUsage else {
      throw SimulatorHIDError.notImplementedOnDTUHIDTransport(
        operation: "sendButton(.applePay) — Apple Pay is a double side-button press, not a single HID usage; send two .sideButton presses instead")
    }
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoButtonEvent",
      payload: IndigoButtonEvent(usagePage: UInt64(usage.page), usageCode: UInt64(usage.code), state: state))
  }

  /// Sends a button only an Apple Watch has; every other family is refused.
  func sendWatchButton(direction: SimulatorHIDDirection, button: SimulatorWatchButton) async throws {
    guard productFamily == .appleWatch else {
      throw SimulatorHIDError.watchButtonUnsupportedOnProductFamily(button: button.name, family: productFamily)
    }
    let usage = button.consumerUsage
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoButtonEvent",
      payload: IndigoButtonEvent(usagePage: UInt64(usage.page), usageCode: UInt64(usage.code), state: state))
  }

  func sendKeyboard(direction: SimulatorHIDDirection, keyCode: UInt32) async throws {
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoKeyboardButtonEvent",
      payload: IndigoKeyboardButtonEvent(usageCode: UInt64(keyCode), state: state))
  }

  /// Sends the keyboard usage the tvOS focus engine consumes. `dtuhidd` also advertises
  /// `com.apple.coredevice.feature.remote.hid.tvremote`, whose accepted usages are undocumented.
  func sendRemoteButton(direction: SimulatorHIDDirection, button: SimulatorHIDRemoteButton) async throws {
    try await sendKeyboard(direction: direction, keyCode: button.keyboardUsage)
  }

  // MARK: - Sending

  /// Nothing suspends between a contact tracker assigning an event type and the write, so concurrent
  /// sends cannot deliver an `.end` ahead of the `.start` it followed.
  private func send(messageType: String, payload: some Encodable) async throws {
    try connection.write(messageType: messageType, payload: payload)
    await connection.awaitSendBarrier()
  }
}
