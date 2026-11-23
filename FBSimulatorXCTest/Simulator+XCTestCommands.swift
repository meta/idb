/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import FBXCTestCore
import Foundation

// The simulator's test capability, added onto `Simulator` from outside `FBSimulatorControl` so
// that consumers with no interest in running tests do not link FBXCTestCore.
extension Simulator: LogicTestTarget {

  public var xctest: SimulatorXCTestCommands {
    commandCache.resolve { SimulatorXCTestCommands(simulator: self) }
  }

  public var subprocessLauncher: any SubprocessLauncher {
    SimulatorSubprocessLauncher(simulator: self)
  }
}
