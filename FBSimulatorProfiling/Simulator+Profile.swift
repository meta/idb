/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl

// The simulator's profilers, added onto `Simulator` from outside `FBSimulatorControl` so that
// consumers with no interest in profiling do not link them.
extension Simulator {

  public var profile: SimulatorProfileCommands {
    SimulatorProfileCommands(simulator: self)
  }
}
