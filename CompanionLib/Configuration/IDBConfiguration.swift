/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import IDBTelemetry

public enum IDBConfiguration {

  // Set once at process startup before any request handling, so unsynchronized
  // access is safe.
  public nonisolated(unsafe) static var eventReporter: any EventReporter = EmptyEventReporter.shared
}
