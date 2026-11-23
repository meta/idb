/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

public protocol LogicXCTestReporter: AnyObject {

  func processWaitingForDebugger(processIdentifier pid: pid_t)

  func didBeginExecutingTestPlan()

  func didFinishExecutingTestPlan()

  func testHadOutput(_ output: String)

  func handleEventJSONData(_ data: Data)

  func didCrashDuringTest(_ error: any Error)
}
