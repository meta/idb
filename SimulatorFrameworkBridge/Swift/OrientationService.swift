/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

#if canImport(SimulatorFrameworkBridgeRuntime)
internal import SimulatorFrameworkBridgeRuntime
#endif

public enum OrientationService {
  public static func run(action: String, arguments: [String]) -> Int32 {
    guard action == "get", arguments.isEmpty else {
      NSLog("Usage: orientation get")
      return 1
    }
    guard let orientation = FBDeviceStateClient.currentOrientation() else { return 1 }
    // patternlint-disable-next-line avoid-print-to-prevent-production-overhead
    print("{\"orientation\":\(orientation.intValue)}")
    return 0
  }
}
