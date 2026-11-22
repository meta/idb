/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import Foundation
import IDBGRPCSwift
import SwiftProtobuf

enum CrashLogInfoTranslation {

  static func responseCrashLogInfo(from crash: CrashLogInfo) -> Idb_CrashLogInfo {
    return .with {
      $0.name = crash.name
      $0.bundleID = crash.identifier
      $0.processName = crash.processName
      $0.parentProcessName = crash.parentProcessName
      $0.processIdentifier = UInt64(crash.processIdentifier)
      $0.parentProcessIdentifier = UInt64(crash.parentProcessIdentifier)
      $0.timestamp = UInt64(crash.date.timeIntervalSince1970)
    }
  }
}
