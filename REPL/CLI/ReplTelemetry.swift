/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import IDBTelemetry

enum ReplTelemetry {

  static func makeReporter() -> any EventReporter {
    // @oss-disable
      // @oss-disable
    // @oss-disable
    return EmptyEventReporter.shared
  }
}
