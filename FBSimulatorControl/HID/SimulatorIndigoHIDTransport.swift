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

/**
 The legacy HID transport (IndigoHIDRegistrationPort), the default on toolchains that predate `dtuhidd`.
 On later toolchains only the tvOS trackpad still works over it.

 Builds `IndigoMessage` payloads with `SimulatorIndigoHID` and delivers them through the runtime-only
 `SimDeviceLegacyHIDClient` (owned by `SimulatorIndigoHIDClient`). Guest-side:
 `SimHIDVirtualServiceManager` dispatches on eventKind + target. See `Indigo.h` for wire format.

 An `actor`, so sends are serialized by actor isolation (no `@unchecked Sendable`).
 */
actor SimulatorIndigoHIDTransport {

  /// Delivers the built Indigo message bytes to the simulator. `Sendable`, so `disconnect()` can
  /// reach it from a `nonisolated` context.
  private let indigoClient: SimulatorIndigoHIDClient
  /// The Indigo payload builder (touch, button, keyboard).
  private let indigo: SimulatorIndigoHID
  /// The dimensions of the main screen.
  private let mainScreenSize: CGSize
  /// The scale of the main screen.
  private let mainScreenScale: Float
  /// Whether the guest drops legacy input, captured from `Simulator.isLegacyInputSuppressed` when the
  /// transport is built. Touch, button and keyboard sends fail loudly on it rather than reporting
  /// success for input that has no effect; the DTUHID transport is the workaround.
  private let legacyInputSuppressed: Bool
  /// The product family of the target, captured at construction. Touchscreen touches are a no-op on
  /// tvOS (it has no digitizer), so the touch primitives reject `AppleTV` rather than failing silently.
  private let productFamily: ProductFamily

  /// Creates a transport for the provided Simulator, registering a HID client.
  /// Will fail if a HID Port could not be registered for the provided Simulator.
  /// Registration may need to occur prior to booting.
  init(simulator: Simulator) throws {
    self.init(
      indigoClient: try SimulatorIndigoHIDClient(for: simulator.device),
      indigo: try SimulatorIndigoHID(),
      mainScreenSize: simulator.device.deviceType.mainScreenSize,
      mainScreenScale: simulator.device.deviceType.mainScreenScale,
      legacyInputSuppressed: simulator.isLegacyInputSuppressed,
      productFamily: simulator.productFamily)
  }

  init(
    indigoClient: SimulatorIndigoHIDClient,
    indigo: SimulatorIndigoHID,
    mainScreenSize: CGSize,
    mainScreenScale: Float,
    legacyInputSuppressed: Bool,
    productFamily: ProductFamily
  ) {
    self.indigoClient = indigoClient
    self.indigo = indigo
    self.mainScreenSize = mainScreenSize
    self.mainScreenScale = mainScreenScale
    self.legacyInputSuppressed = legacyInputSuppressed
    self.productFamily = productFamily
  }

  // MARK: - Sends

  nonisolated func disconnect() {
    indigoClient.disconnect()
  }

  /// Returns once every message sent so far has been acknowledged, throwing the first delivery failure.
  nonisolated func acknowledged() async throws {
    try await indigoClient.acknowledged()
  }

  func sendTouch(
    direction: SimulatorHIDDirection, x: Double, y: Double, edge: SimulatorHIDEdge, display: SimulatorHIDDisplay? = nil
  ) async throws {
    guard productFamily.hasTouchscreen else {
      throw SimulatorHIDError.touchUnsupportedOnAppleTV
    }
    try requireLegacyInput("Touch")
    try requireUnnamedDisplay(display)
    let point = try display?.geometry.unrotatedPoint(from: CGPoint(x: x, y: y)) ?? CGPoint(x: x, y: y)
    try await indigoClient.send(
      indigo.touchScreenSize(
        display?.geometry.bounds.size ?? mainScreenSize,
        screenScale: display.map { Float($0.geometry.scale) } ?? mainScreenScale,
        direction: direction, x: point.x, y: point.y, edge: display?.geometry.unrotatedEdge(edge) ?? edge))
  }

  func sendTwoFingerTouch(direction: SimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint, display: SimulatorHIDDisplay? = nil) async throws {
    guard productFamily.hasTouchscreen else {
      throw SimulatorHIDError.touchUnsupportedOnAppleTV
    }
    try requireLegacyInput("Touch")
    try requireUnnamedDisplay(display)
    let first = try display?.geometry.unrotatedPoint(from: finger1) ?? finger1
    let second = try display?.geometry.unrotatedPoint(from: finger2) ?? finger2
    try await indigoClient.send(
      indigo.twoFingerTouchScreenSize(
        display?.geometry.bounds.size ?? mainScreenSize,
        screenScale: display.map { Float($0.geometry.scale) } ?? mainScreenScale,
        direction: direction, finger1: first, finger2: second))
  }

  /// On Xcode 27 (CoreSimulator-1155.4)+ button and keyboard events deliver byte-correctly but have no
  /// effect, and touch is dropped unpredictably. Nothing observable from here tells a delivered send from
  /// a dropped one, so none is reported as a success.
  private func requireLegacyInput(_ operation: String) throws {
    if legacyInputSuppressed {
      throw SimulatorHIDError.legacyInputSuppressed(operation: operation)
    }
  }

  private func requireUnnamedDisplay(_ display: SimulatorHIDDisplay?) throws {
    if case .selected = display {
      throw SimulatorDisplayInteractionError.unsupportedCapability("explicit display routing over Indigo")
    }
  }

  func sendButton(direction: SimulatorHIDDirection, button: SimulatorHIDButton) async throws {
    try requireLegacyInput("Button")
    try await indigoClient.send(indigo.button(with: direction, button: button))
  }

  func sendKeyboard(direction: SimulatorHIDDirection, keyCode: UInt32) async throws {
    try requireLegacyInput("Keyboard")
    try await indigoClient.send(indigo.keyboard(with: direction, keyCode: keyCode))
  }

  /// Delivers a Siri Remote focus action as the keyboard usage the tvOS focus engine consumes, which is
  /// the only encoding the legacy path has for it — so it is subject to the same Xcode 27 suppression.
  func sendRemoteButton(direction: SimulatorHIDDirection, button: SimulatorHIDRemoteButton) async throws {
    try await sendKeyboard(direction: direction, keyCode: button.keyboardUsage)
  }

  // No tvOS guard — the trackpad is exactly what Apple TV targets need (unlike the touchscreen). No
  // suppression guard either: the tvOS guest still honours Indigo trackpad events on Xcode 27.
  func sendTrackpad(point: SimulatorTrackpadPoint, phase: SimulatorTrackpadPhase) async throws {
    try await indigoClient.send(indigo.trackpad(point: CGPoint(x: point.x, y: point.y), phase: phase))
  }
}
