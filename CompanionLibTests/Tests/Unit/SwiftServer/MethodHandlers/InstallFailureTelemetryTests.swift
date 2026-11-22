/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBArtifactStaging
@preconcurrency import FBControlCore
import Foundation
import IDBGRPCSwift
import SwiftProtobuf
import Testing

/// What an install that fails between staging and installing reports: the stage it failed in and what failed.
@Suite
struct InstallFailureTelemetryTests {

  private let harness: MacInstallHarness
  private let handler: InstallMethodHandler

  init() throws {
    harness = try MacInstallHarness()
    handler = InstallMethodHandler(
      commandExecutor: harness.executor,
      targetLogger: ControlCoreGlobalConfiguration.systemLogger(writingToStderr: false, debugLogging: false))
  }

  /// Streams a tar of `item` as `destination`, returning the columns the install reported and whether it failed.
  private func columns(streaming item: URL, as destination: Idb_InstallRequest.Destination) async throws -> (normals: [String: String], failed: Bool) {
    let payload = try harness.tarData(of: item)
    let rest = AsyncThrowingStream<Data, any Error> { $0.finish() }
    let request = InstallRequest(
      header: InstallHeader(destination: destination, payload: .with { $0.data = payload }),
      payload: .data(head: payload, rest: rest))
    let call = CallTelemetry()
    var failed = false
    do {
      try await CallTelemetry.$current.withValue(call) {
        _ = try await handler.install(request)
      }
    } catch {
      failed = true
    }
    return (call.normals, failed)
  }

  private func directoryHolding(_ name: String) throws -> URL {
    let file = try harness.makeFile(named: name)
    return file.deletingLastPathComponent()
  }

  /// An archive with no app in it fails identifying one, between extracting and installing.
  @Test
  func anArchiveWithNoAppFailsWithNoStage() async throws {
    let (normals, failed) = try await columns(streaming: try directoryHolding("README"), as: .app)
    #expect(failed)
    #expect(normals["failure_stage"] == "identify")
    #expect(normals["failure_kind"] == "no_installable_bundle")
  }

  /// As for an app, and the failure is named for what it is rather than for the type that refused it.
  @Test
  func anArchiveWithNoTestBundleFailsWithNoStageAndATypeName() async throws {
    let (normals, failed) = try await columns(streaming: try directoryHolding("README"), as: .xctest)
    #expect(failed)
    #expect(normals["failure_stage"] == "identify")
    #expect(normals["failure_kind"] == "unidentifiable")
  }

  /// As for a test bundle.
  @Test
  func anArchiveWithNoFrameworkFailsWithNoStageAndATypeName() async throws {
    let (normals, failed) = try await columns(streaming: try directoryHolding("README"), as: .framework)
    #expect(failed)
    #expect(normals["failure_stage"] == "identify")
    #expect(normals["failure_kind"] == "unidentifiable")
  }
}
