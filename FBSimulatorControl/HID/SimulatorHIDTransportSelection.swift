/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

// MARK: - Transport selection policy

/// Decides which HID transport a caller that did not request one gets, and whether the legacy Indigo
/// path is functional.
///
/// Deliberately not a probe of whether `dtuhidd` is *resident*: it is a demand-launched,
/// pressured-exit job, so it is normally not running even on a simulator that routes all HID through
/// it. This decides only what to *prefer*; whether `dtuhidd` can actually be reached is settled where
/// it is observable, by `SimulatorDTUHIDConnection.connect(using:serviceName:)` round-tripping a
/// liveness barrier, since the service lookup succeeds whether or not the daemon can run.
enum SimulatorHIDTransportSelection {

  /// The first CoreSimulator version to inject `dtuhidd` into the guest. Older toolchains have no
  /// DTUHID transport at all.
  static let firstDTUHIDCoreSimulatorVersion = "1155.4"

  /// Whether `coreSimulatorVersion` is new enough to ship `dtuhidd`. Compared numerically, so that
  /// `1155.10` sorts above `1155.4` rather than lexicographically below it.
  static func shipsDTUHID(coreSimulatorVersion: String?) -> Bool {
    guard let coreSimulatorVersion else {
      return false
    }
    return coreSimulatorVersion.compare(firstDTUHIDCoreSimulatorVersion, options: .numeric) != .orderedAscending
  }

  /// Whether the guest drops legacy Indigo input.
  ///
  /// A property of the CoreSimulator version alone. From 1155.4 the guest drops it for the whole boot,
  /// independent of `dtuhidd` residency and of which other HID clients (Device Hub included) are
  /// attached; restarting `backboardd` does not restore it. Button and keyboard events are always
  /// dropped. Touch is unreliable: dropped on some boots and intermittently within one. The tvOS
  /// trackpad is the exception.
  static func isLegacyInputSuppressed(coreSimulatorVersion: String?) -> Bool {
    shipsDTUHID(coreSimulatorVersion: coreSimulatorVersion)
  }

  /// The transport to prefer when a caller does not request one. The toolchain is the only condition;
  /// every product family, Apple TV included, can be driven over DTUHID.
  static func defaultTransport(coreSimulatorVersion: String?) -> SimulatorHIDTransportType {
    guard shipsDTUHID(coreSimulatorVersion: coreSimulatorVersion) else {
      return .indigo
    }
    return .dtuhid
  }
}

// MARK: - Legacy input suppression

extension Simulator {

  /// Whether this simulator's guest drops legacy Indigo input: on Xcode 27 (CoreSimulator-1155.4) and
  /// later it is delivered byte-correctly and has no effect. See
  /// `SimulatorHIDTransportSelection.isLegacyInputSuppressed(coreSimulatorVersion:)`.
  var isLegacyInputSuppressed: Bool {
    SimulatorHIDTransportSelection.isLegacyInputSuppressed(
      coreSimulatorVersion: SimulatorControlFrameworkLoader.loadedCoreSimulatorVersion)
  }

  /// The HID transport to prefer when a caller does not request one: DTUHID once the toolchain ships
  /// `dtuhidd`, the legacy Indigo path otherwise. `SimulatorHIDTransport.negotiate(for:requested:)`
  /// reports an unreachable `dtuhidd` rather than falling back to Indigo.
  var defaultHIDTransport: SimulatorHIDTransportType {
    SimulatorHIDTransportSelection.defaultTransport(
      coreSimulatorVersion: SimulatorControlFrameworkLoader.loadedCoreSimulatorVersion)
  }
}

// MARK: - Loaded CoreSimulator version

private extension SimulatorControlFrameworkLoader {

  /// The version of the CoreSimulator framework actually loaded in-process (e.g. `"1155.4"`), read
  /// from the bundle that vends `SimDevice`, or `nil` if it is not loaded. CoreSimulator is a system
  /// framework that the Xcode installer overwrites, so the loaded framework can differ from the
  /// selected Xcode; behaviour gated on a CoreSimulator version must consult this, not the Xcode one.
  static var loadedCoreSimulatorVersion: String? {
    guard let simDeviceClass = NSClassFromString("SimDevice") else {
      return nil
    }
    return Bundle(for: simDeviceClass).infoDictionary?["CFBundleVersion"] as? String
  }
}
