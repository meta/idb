/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBControlCore
import FBDeviceControl
import FBXCTestCore
import Foundation
import Testing

/// `terminate` succeeds when there is nothing to stop, and reports every other failure rather than
/// claiming the app was stopped.
struct IDBCommandExecutorTerminateTests {

  @Test
  func terminatingAnAppThatIsNotRunningSucceeds() async throws {
    let harness = try MacInstallHarness()

    try await harness.executor.killApplication("com.example.not-running")
  }

  @Test
  func eachTargetsNotRunningErrorMeansNothingToStop() {
    #expect(IDBCommandExecutor.meansNotRunning(DeviceApplicationError.noProcessID(bundleID: "com.example.app")))
    #expect(IDBCommandExecutor.meansNotRunning(MacDeviceError.applicationNotLaunched(bundleID: "com.example.app")))
    #expect(IDBCommandExecutor.meansNotRunning(NSError(domain: NSPOSIXErrorDomain, code: Int(ESRCH))))
  }

  @Test
  func otherFailuresAreNotMistakenForNothingToStop() {
    #expect(!IDBCommandExecutor.meansNotRunning(DevicectlError.commandFailed(exitCode: "1", arguments: [], stdOut: "", stdErr: "The process could not be terminated")))
    #expect(!IDBCommandExecutor.meansNotRunning(DeviceApplicationError.pidListRequestUnsuccessful))
    #expect(!IDBCommandExecutor.meansNotRunning(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
    #expect(!IDBCommandExecutor.meansNotRunning(NSError(domain: "com.example", code: Int(ESRCH))))
  }
}
