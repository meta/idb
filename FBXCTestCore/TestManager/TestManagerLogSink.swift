/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// What the DTX connection and the IDE interface log to.
protocol TestManagerLogSink: AnyObject {
  func log(_ message: String)
}

final class ControlCoreLoggerSink: TestManagerLogSink {
  private let logger: any ControlCoreLogger

  init(_ logger: any ControlCoreLogger) {
    self.logger = logger
  }

  func log(_ message: String) {
    logger.log(message)
  }
}
