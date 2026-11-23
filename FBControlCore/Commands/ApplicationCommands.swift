/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

public protocol ApplicationLaunching {

  func launch(_ configuration: ApplicationLaunchConfiguration) async throws -> any LaunchedApplication
}

public protocol ApplicationCommands: ApplicationLaunching {

  func install(atPath path: String) async throws -> InstalledApplication

  func uninstall(bundleID: String) async throws

  func kill(bundleID: String) async throws

  func installed() async throws -> [InstalledApplication]

  func installed(bundleID: String) async throws -> InstalledApplication

  func running() async throws -> [String: pid_t]

  func processID(forBundleID bundleID: String) async throws -> pid_t
}
