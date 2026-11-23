/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation

/// Reads and overrides what the simulated device draws in its status bar.
public struct SimulatorStatusBarCommands {

  private let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Overrides

  public func current() async throws -> StatusBarOverride {
    var timeString: NSString?
    var dataNetworkType: NSNumber?
    var wiFiMode: NSNumber?
    var wiFiBars: NSNumber?
    var cellularMode: NSNumber?
    var operatorName: NSString?
    var cellularBars: NSNumber?
    var batteryState: NSNumber?
    var batteryLevel: NSNumber?
    var showNotCharging: NSNumber?
    unsafe try simulator.device.currentStatusBarOverrides(
      forTime: &timeString,
      dataNetworkType: &dataNetworkType,
      wiFiMode: &wiFiMode,
      wiFiBars: &wiFiBars,
      cellularMode: &cellularMode,
      operatorName: &operatorName,
      cellularBars: &cellularBars,
      batteryState: &batteryState,
      batteryLevel: &batteryLevel,
      showNotCharging: &showNotCharging)
    var override = StatusBarOverride()
    override.timeString = timeString as String?
    override.dataNetworkType = dataNetworkType?.intValue
    override.wiFiMode = wiFiMode?.intValue
    override.wiFiBars = wiFiBars?.intValue
    override.cellularMode = cellularMode?.intValue
    override.cellularBars = cellularBars?.intValue
    override.operatorName = operatorName as String?
    override.batteryState = batteryState?.intValue
    override.batteryLevel = batteryLevel?.intValue
    override.showNotCharging = showNotCharging?.boolValue
    return override
  }

  public func set(_ override: StatusBarOverride?) async throws {
    guard let override else {
      // clearStatusBarOverrides:(NSUInteger)flags sends @{@"OverridesToClear": @(flags)} via MIG.
      // Bit 31 (0x80000000) = clear all. Pass NSUIntegerMax to clear everything.
      try simulator.device.clearStatusBarOverrides(UInt.max)
      return
    }
    if let timeString = override.timeString {
      try simulator.device.overrideStatusBarTime(timeString)
    }
    if let dataNetworkType = override.dataNetworkType {
      try simulator.device.overrideStatusBarDataNetworkType(dataNetworkType)
    }
    if override.wiFiMode != nil || override.wiFiBars != nil {
      let mode = override.wiFiMode ?? 3
      let bars = override.wiFiBars ?? 3
      try simulator.device.overrideStatusBarWiFiMode(mode, bars: bars)
    }
    if override.cellularMode != nil || override.operatorName != nil || override.cellularBars != nil {
      let mode = override.cellularMode ?? 3
      let name = override.operatorName ?? ""
      let bars = override.cellularBars ?? 4
      try simulator.device.overrideStatusBarCellularMode(mode, operatorName: name, bars: bars)
    }
    if override.batteryState != nil || override.batteryLevel != nil || override.showNotCharging != nil {
      let state = override.batteryState ?? 2
      let level = override.batteryLevel ?? 100
      let notCharging = override.showNotCharging ?? false
      try simulator.device.overrideStatusBarBatteryState(state, batteryLevel: level, showNotCharging: notCharging)
    }
  }

  // MARK: - In-call

  private static let inCallNotification = "com.apple.iphonesimulator.toggleincallstatusbar"

  /// Shows the in-call status bar if hidden, hides it if shown.
  public func toggleInCall() async throws {
    try simulator.device.postDarwinNotification(Self.inCallNotification)
  }
}
