/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import Foundation

/// Selects which transport a `SimulatorHID` uses for the touch / button / keyboard primitives.
public enum SimulatorHIDTransportType: Equatable, Sendable {
  /// The legacy Indigo path via SimulatorKit's runtime-only `SimDeviceLegacyHIDClient`.
  case indigo
  /// The modern DTUHID path via the `dtuhidd` daemon (Xcode 27 / iOS 26+).
  case dtuhid
}

/// The transports driving a target: the one carrying the Indigo-family HID primitives — touch,
/// two-finger touch, button and keyboard — and, where a target needs both, the Indigo transport
/// running alongside it.
///
/// An enum over the concrete transports rather than an existential, so each capability lives only on
/// the transport that has it (`flush` on DTUHID, `sendTrackpad` on Indigo). What both carry is
/// `SimulatorHIDPrimitives`, reached through `primitives`.
///
/// Device orientation, the hinge, lock, shake and the in-call status bar are not carried here at all:
/// they are commands on the `Simulator` (`orientation`, `hinge`, `hardware`, `statusBar`).
///
/// A target can need both at once, which is `mixed`. `dtuhidd` exposes no trackpad, so an Apple TV
/// driven over DTUHID still reaches its Siri Remote trackpad over Indigo. Mixing is otherwise pointless:
/// on a toolchain that ships `dtuhidd` the guest does not reliably deliver Indigo touch, button or
/// keyboard input, so the trackpad is all Indigo can be relied on for there.
enum SimulatorHIDTransport: Sendable {
  /// Indigo alone, carrying the primitives and the trackpad.
  case indigo(SimulatorIndigoHIDTransport)
  /// DTUHID alone, carrying the primitives. No trackpad is reachable.
  case dtuhid(SimulatorDigitizerHIDTransport)
  /// Both, mixed on one target: DTUHID carrying the primitives, Indigo carrying only the trackpad.
  case mixed(dtuhid: SimulatorDigitizerHIDTransport, indigo: SimulatorIndigoHIDTransport)

  // MARK: - Negotiation

  /// A requested transport is never substituted — it is established or the error surfaces. With no
  /// request, `defaultHIDTransport` is established, and its errors surface the same way. There is no
  /// fallback: the default is DTUHID exactly on the toolchains whose guest does not reliably deliver
  /// Indigo touch, button or keyboard input, so an unreachable `dtuhidd` is reported rather than traded
  /// for a transport that silently loses input. Reachability is settled where it is observable, by
  /// `SimulatorDTUHIDConnection.connect(using:serviceName:)` round-tripping a barrier past its retries,
  /// since `dtuhidd` is demand-launched.
  static func negotiate(
    for simulator: Simulator, requested: SimulatorHIDTransportType?
  ) async throws -> SimulatorHIDTransport {
    try await negotiate(requested: requested, preferred: simulator.defaultHIDTransport) {
      try await establish($0, for: simulator)
    }
  }

  /// The policy of `negotiate(for:requested:)`, apart from the `Simulator` the transports are
  /// established against.
  static func negotiate<Transport>(
    requested: SimulatorHIDTransportType?,
    preferred: SimulatorHIDTransportType,
    establish: (SimulatorHIDTransportType) async throws -> Transport
  ) async throws -> Transport {
    if let requested {
      return try await establish(requested)
    }
    let transport = try await establish(preferred)
    ControlCoreGlobalConfiguration.defaultLogger.log("Negotiated the \(preferred) HID transport")
    return transport
  }

  private static func establish(
    _ type: SimulatorHIDTransportType, for simulator: Simulator
  ) async throws -> SimulatorHIDTransport {
    switch type {
    case .indigo:
      return .indigo(try SimulatorIndigoHIDTransport(simulator: simulator))
    case .dtuhid:
      let dtuhid = try await SimulatorDigitizerHIDTransport.connect(to: simulator)
      guard let indigo = indigoAlongsideDTUHID(for: simulator) else {
        return .dtuhid(dtuhid)
      }
      return .mixed(dtuhid: dtuhid, indigo: indigo)
    }
  }

  /// The Indigo transport to run alongside DTUHID, for a target that needs both.
  ///
  /// Only Apple TV does. It is the only family with a trackpad, which `dtuhidd` does not expose and the
  /// guest still honours over Indigo; every other Indigo input is unreliable on toolchains that ship
  /// `dtuhidd`.
  ///
  /// Absent rather than fatal when it cannot be registered, since it carries the trackpad alone — a
  /// failure should cost a pan, not every other input on the target.
  private static func indigoAlongsideDTUHID(for simulator: Simulator) -> SimulatorIndigoHIDTransport? {
    guard simulator.productFamily == .appleTV else {
      return nil
    }
    return try? SimulatorIndigoHIDTransport(simulator: simulator)
  }

  // MARK: - Capabilities

  /// The Indigo transport in play, if any.
  var indigo: SimulatorIndigoHIDTransport? {
    switch self {
    case let .indigo(indigo): return indigo
    case .dtuhid: return nil
    case let .mixed(_, indigo): return indigo
    }
  }

  /// The DTUHID transport in play, if any.
  var dtuhid: SimulatorDigitizerHIDTransport? {
    switch self {
    case .indigo: return nil
    case let .dtuhid(dtuhid): return dtuhid
    case let .mixed(dtuhid, _): return dtuhid
    }
  }

  /// Tears down every transport held.
  func disconnect() {
    switch self {
    case let .indigo(indigo):
      indigo.disconnect()
    case let .dtuhid(dtuhid):
      dtuhid.disconnect()
    case let .mixed(dtuhid, indigo):
      dtuhid.disconnect()
      indigo.disconnect()
    }
  }

  /// The transport carrying the primitives: DTUHID wherever it is in play.
  var primitives: any SimulatorHIDPrimitives {
    switch self {
    case let .indigo(indigo): return indigo
    case let .dtuhid(dtuhid), let .mixed(dtuhid, _): return dtuhid
    }
  }

  /// Only DTUHID has anything to drain; what Indigo was sent is settled by `acknowledged()`.
  func flush() async throws {
    try await dtuhid?.flush()
  }

  /// Only Indigo sends without waiting for its acknowledgements; each DTUHID send already waits on its
  /// own barrier.
  func acknowledged() async throws {
    try await indigo?.acknowledged()
  }

  /// Indigo only: the tvOS trackpad rides a dedicated Indigo service that `dtuhidd` does not expose (its
  /// digitizer targets are displays and its scroll targets rotary devices).
  func sendTrackpad(point: SimulatorTrackpadPoint, phase: SimulatorTrackpadPhase) async throws {
    guard let indigo else {
      throw SimulatorHIDError.notImplementedOnDTUHIDTransport(
        operation: "trackpad pan — the tvOS Siri Remote trackpad is not exposed by dtuhidd")
    }
    try await indigo.sendTrackpad(point: point, phase: phase)
  }
}

/// The Indigo-family HID primitives, which both transports carry.
protocol SimulatorHIDPrimitives: Actor {
  /// Sends a single-finger touch at the given point (in points). `edge` tags the contact as
  /// originating at a screen edge, which is how the guest recognises a system edge gesture.
  func sendTouch(direction: SimulatorHIDDirection, x: Double, y: Double, edge: SimulatorHIDEdge, display: SimulatorHIDDisplay?) async throws
  /// Sends a two-finger touch (for multi-touch gestures) at the given points (in points).
  func sendTwoFingerTouch(direction: SimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint, display: SimulatorHIDDisplay?) async throws
  func sendButton(direction: SimulatorHIDDirection, button: SimulatorHIDButton) async throws
  func sendKeyboard(direction: SimulatorHIDDirection, keyCode: UInt32) async throws
  /// Sends a tvOS Siri Remote focus action.
  func sendRemoteButton(direction: SimulatorHIDDirection, button: SimulatorHIDRemoteButton) async throws
}

extension SimulatorIndigoHIDTransport: SimulatorHIDPrimitives {}
extension SimulatorDigitizerHIDTransport: SimulatorHIDPrimitives {}
