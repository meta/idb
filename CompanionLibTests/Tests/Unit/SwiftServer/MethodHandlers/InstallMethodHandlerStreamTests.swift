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

/// Installs streamed payloads through the handler onto the host Mac.
@Suite
struct InstallMethodHandlerStreamTests {

  private struct StreamFailed: Error {}

  private let harness: MacInstallHarness
  private let handler: InstallMethodHandler

  init() throws {
    harness = try MacInstallHarness()
    handler = InstallMethodHandler(
      commandExecutor: harness.executor,
      targetLogger: ControlCoreGlobalConfiguration.systemLogger(writingToStderr: false, debugLogging: false))
  }

  private static func request(_ destination: Idb_InstallRequest.Destination, head: Data, rest: AsyncThrowingStream<Data, any Error>) -> InstallRequest {
    InstallRequest(
      header: InstallHeader(destination: destination, payload: .with { $0.data = head }),
      payload: .data(head: head, rest: rest))
  }

  /// `payload` as a client streams it, in frames.
  private static func request(_ destination: Idb_InstallRequest.Destination, streaming payload: Data, compression: CompressionFormat = .GZIP) -> InstallRequest {
    let frames = stride(from: payload.startIndex, to: payload.endIndex, by: 64 * 1024).map { payload[$0..<min($0 + 64 * 1024, payload.endIndex)] }
    let rest = AsyncThrowingStream<Data, any Error> { continuation in
      frames.dropFirst().forEach { continuation.yield(Data($0)) }
      continuation.finish()
    }
    var request = Self.request(destination, head: Data(frames[0]), rest: rest)
    request.header.compression = compression
    return request
  }

  @Test
  func aZstdZipAppStreamIsInstalled() async throws {
    let app = try harness.makeBundle(named: "Sample", extension: "app", identifier: "com.example.sample")
    let payload = ArchiveFormat.zstdZipMarker + MacInstallHarness.zstd(try harness.zipData(of: app))

    let artifact = try await handler.install(Self.request(.app, streaming: payload))

    #expect(artifact.name == "com.example.sample")
  }

  @Test
  func aZstdTarDsymStreamIsInstalled() async throws {
    let dsym = try harness.makeBundle(named: "Sample", extension: "dSYM", identifier: "com.example.sample")
    let payload = MacInstallHarness.zstd(try harness.tarData(of: dsym))

    let artifact = try await handler.install(Self.request(.dsym, streaming: payload, compression: .ZSTD))

    #expect(artifact.name == "Sample.dSYM")
  }

  @Test
  func aZstdTarFrameworkStreamIsInstalled() async throws {
    let framework = try harness.makeBundle(named: "Sample", extension: "framework", identifier: "com.example.framework")
    let payload = MacInstallHarness.zstd(try harness.tarData(of: framework))

    let artifact = try await handler.install(Self.request(.framework, streaming: payload, compression: .ZSTD))

    #expect(artifact.name == "com.example.framework")
  }

  @Test
  func whenTheClientStreamFailsPartwayThroughATar() async throws {
    let framework = try harness.makeBundle(named: "Sample", extension: "framework", identifier: "com.example.framework")
    let archive = try await harness.gzippedTarData(of: framework)
    let rest = AsyncThrowingStream<Data, any Error> { continuation in
      continuation.finish(throwing: StreamFailed())
    }
    await #expect {
      _ = try await handler.install(Self.request(.framework, head: archive.prefix(archive.count / 2), rest: rest))
    } throws: { error in
      error is StreamFailed
    }
  }

  @Test
  func whenTheClientStreamFailsPartwayThroughAZstdZip() async throws {
    let app = try harness.makeBundle(named: "Sample", extension: "app", identifier: "com.example.sample")
    let payload = ArchiveFormat.zstdZipMarker + MacInstallHarness.zstd(try harness.zipData(of: app))
    let rest = AsyncThrowingStream<Data, any Error> { continuation in
      continuation.finish(throwing: StreamFailed())
    }
    await #expect {
      _ = try await handler.install(Self.request(.app, head: payload.prefix(payload.count / 2), rest: rest))
    } throws: { error in
      error is StreamFailed
    }
  }

  /// Asking for the archive's modification times to be discarded applies to every kind, not only to an application.
  @Test
  func aStreamedDsymCanHaveItsArchivedModificationTimesDiscarded() async throws {
    let dsym = try harness.makeBundle(named: "Times", extension: "dSYM", identifier: "com.example.times")
    let old = Date(timeIntervalSince1970: 1_000_000_000)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dsym.appendingPathComponent("Info.plist").path)
    var request = Self.request(.dsym, streaming: try harness.tarData(of: dsym))
    request.header.overrideModificationTime = true

    let artifact = try await handler.install(request)

    let storage = harness.executor.storageManager.dsym.basePath
    let plists = (FileManager.default.enumerator(atPath: storage.path)?.allObjects as? [String] ?? [])
      .filter { $0.hasSuffix("\(artifact.name)/Info.plist") }
    #expect(!plists.isEmpty, "no \(artifact.name)/Info.plist under \(storage.path)")
    for plist in plists {
      let modified = try FileManager.default.attributesOfItem(atPath: storage.appendingPathComponent(plist).path)[.modificationDate] as? Date
      #expect(modified.map { $0 > old.addingTimeInterval(86_400) } == true, "\(plist) kept \(String(describing: modified))")
    }
  }
}
