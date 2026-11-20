/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorControl
import Foundation
import Testing

/// Every command accessor FBSimulatorControl defines on `Simulator`, so the retention rule is
/// checked against all of them rather than a hand-picked few. The libraries that add accessors of
/// their own check those in their own bundles.
enum SimulatorCommandAccessor: CaseIterable, Sendable {
  case application
  case crashLog
  case screenshot
  case location
  case debugServer
  case file
  case log
  case launchCtl
  case xctraceRecord
  case lifecycle
  case power
  case media
  case keychain
  case statusBar
  case dapServer
  case memory
  case audio
  case runtimeTools
  case bootstrapPorts
  case keyboard

  func resolve(on simulator: Simulator) {
    switch self {
    case .application:
      _ = simulator.application
    case .crashLog:
      _ = simulator.crashLog
    case .screenshot:
      _ = simulator.screenshot
    case .location:
      _ = simulator.location
    case .debugServer:
      _ = simulator.debugServer
    case .file:
      _ = simulator.file
    case .log:
      _ = simulator.log
    case .launchCtl:
      _ = simulator.launchCtl
    case .xctraceRecord:
      _ = simulator.xctraceRecord
    case .lifecycle:
      _ = simulator.lifecycle
    case .power:
      _ = simulator.power
    case .media:
      _ = simulator.media
    case .keychain:
      _ = simulator.keychain
    case .statusBar:
      _ = simulator.statusBar
    case .dapServer:
      _ = simulator.dapServer
    case .memory:
      _ = simulator.memory
    case .audio:
      _ = simulator.audio
    case .runtimeTools:
      _ = simulator.runtimeTools
    case .bootstrapPorts:
      _ = simulator.bootstrapPorts
    case .keyboard:
      _ = simulator.keyboard
    }
  }
}

@Suite("Simulator command retention")
struct SimulatorCommandRetentionTests {

  @Test("Resolving a command does not retain the simulator", arguments: SimulatorCommandAccessor.allCases)
  func resolvingACommandDoesNotRetainTheSimulator(_ accessor: SimulatorCommandAccessor) {
    #expect(simulatorSurvives { accessor.resolve(on: $0) } == false)
  }
}
