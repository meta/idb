/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBArtifactStaging
import FBControlCore
import Foundation
import Testing

/// The executor's lookup the REPL's build check runs on: an installed app's bundle path and main
/// executable UUID, read back through the same storage an install goes through.
@Suite
struct IDBCommandExecutorReplIdentityTests {

  @Test
  func anInstalledAppReportsItsPathAndExecutableUUIDAndItsBuildInfoIsReadable() async throws {
    let harness = try MacInstallHarness()
    let app = try harness.makeBundle(named: "Sample", extension: "app", identifier: "com.example.sample")
    try JSONSerialization.data(withJSONObject: ["build_uuid": "BUILD-1234"]).write(to: app.appendingPathComponent("BuildInfo.json"))
    let artifact = try await harness.executor.install(.application(makeDebuggable: false), from: .stream(try await harness.gzippedTar(of: app)))

    let installed = try await harness.executor.replInstalledApplication(bundleID: "com.example.sample")
    #expect(installed.bundlePath == artifact.path.path)
    #expect(installed.executableUUID as NSUUID? == artifact.uuid)

    let identity = ReplAppIdentity(bundlePath: installed.bundlePath, executableUUID: installed.executableUUID)
    #expect(identity.buildUUID == "BUILD-1234")
    #expect(ReplBuildIdentityCheck.verify(ReplBuildExpectation(buildUUID: "build-1234"), against: identity, bundleID: "com.example.sample") == .accepted)
  }

  @Test
  func anAppThatIsNotInstalledThrows() async throws {
    let harness = try MacInstallHarness()
    await #expect(throws: (any Error).self) {
      try await harness.executor.replInstalledApplication(bundleID: "com.example.absent")
    }
  }
}
