/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import FBVideoCore
import Foundation

// The simulator's video capability, added onto `Simulator` from outside `FBSimulatorControl` so that
// consumers with no interest in video do not link the encode pipeline.
extension Simulator: VideoTarget {

  public var videoRecording: SimulatorVideoRecordingCommands {
    commandCache.resolve { SimulatorVideoRecordingCommands(simulator: self) }
  }

  public var videoStream: SimulatorVideoStreamCommands {
    SimulatorVideoStreamCommands(simulator: self)
  }
}
