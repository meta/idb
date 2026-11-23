/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBArtifactStaging
@testable import FBControlCore
import Foundation
import Testing
import os

/// What staging leaves behind, whether it succeeds, fails or is cancelled: no staging directories, no descriptors open
/// on what it read or wrote, and a call that returns once it is cancelled.
@Suite(.serialized)
struct StagingCleanupTests {

  enum Source: String, CaseIterable, CustomTestStringConvertible {
    case pathToArchive
    case stream
    case remoteURL

    var testDescription: String { rawValue }
  }

  enum Payload: String, CaseIterable, CustomTestStringConvertible {
    case app
    case corrupt

    var testDescription: String { rawValue }
  }

  private let root = TemporaryDirectory(logger: ControlCoreGlobalConfiguration.defaultLogger).temporaryDirectory()
  private let logger = ControlCoreGlobalConfiguration.defaultLogger

  private var stagingRoot: URL { root.appendingPathComponent("staging") }

  private func appArchive() throws -> Data {
    let app = try ArchiveFixtures.makeApp(in: root)
    let archive = root.appendingPathComponent("app.tar.gz")
    try ArchiveFixtures.run("/usr/bin/tar", ["-czf", archive.path, (app as NSString).lastPathComponent], in: root)
    return try Data(contentsOf: archive)
  }

  private func installSource(_ source: Source, _ contents: Data) throws -> (InstallSource, URLSessionConfiguration) {
    switch source {
    case .pathToArchive:
      let path = root.appendingPathComponent("payload-\(UUID().uuidString)")
      try contents.write(to: path)
      return (.localPath(path.path), .default)
    case .stream:
      return (.stream(ChunkSource(contents)), .default)
    case .remoteURL:
      return (.remoteURL(CorpusURLProtocol.serving(contents)), CorpusURLProtocol.configuration)
    }
  }

  /// The descriptors this process has open on anything under `root`. Other suites run in the same process at the same
  /// time, so a count of every descriptor would be theirs as much as staging's.
  static func openDescriptors(under root: URL) -> Set<Int32> {
    let prefix = root.resolvingSymlinksInPath().path
    let descriptors = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []).compactMap(Int32.init)
    return Set(
      descriptors.filter { descriptor in
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else {
          return false
        }
        return URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath().path.hasPrefix(prefix)
      })
  }

  /// Descriptors are closed asynchronously by some of the I/O beneath staging, so this waits for them to settle.
  static func descriptorsSettle(under root: URL) async -> Set<Int32> {
    var leaked = openDescriptors(under: root)
    for _ in 0..<50 where !leaked.isEmpty {
      try? await Task.sleep(for: .milliseconds(100))
      leaked = openDescriptors(under: root)
    }
    return leaked
  }

  private func stagingContents() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
  }

  /// The check sees a descriptor left open on a file under the root, and stops seeing it once it is closed.
  @Test
  func aDescriptorLeftOpenIsSeen() throws {
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    let file = stagingRoot.appendingPathComponent("left-open")
    FileManager.default.createFile(atPath: file.path, contents: Data())
    let descriptor = open(file.path, O_RDONLY)
    #expect(Self.openDescriptors(under: root) == [descriptor])
    close(descriptor)
    try FileManager.default.removeItem(at: file)
    #expect(Self.openDescriptors(under: root).isEmpty)
  }

  @Test(arguments: Source.allCases, Payload.allCases)
  func leavesNothingBehind(_ source: Source, _ payload: Payload) async throws {
    let contents = payload == .app ? try appArchive() : Data(repeating: 0x42, count: 100_000)
    let (installSource, configuration) = try installSource(source, contents)

    // `Result`'s async initializer is newer than the Swift the open-source build compiles with.
    let result: Result<Void, any Error>
    do {
      try await Staging.withMaterialized(
        installSource, as: .application, downloadConfiguration: configuration,
        temporaryDirectory: TemporaryDirectory(rootDirectory: stagingRoot, logger: logger), logger: logger
      ) { _ in }
      result = .success(())
    } catch {
      result = .failure(error)
    }

    switch (payload, result) {
    case (.app, .success), (.corrupt, .failure):
      break
    case (.app, .failure(let error)):
      Issue.record("\(source) failed: \(error)")
    case (.corrupt, .success):
      Issue.record("\(source) staged a corrupt payload")
    }
    #expect(stagingContents().isEmpty, "\(source) \(payload) left \(stagingContents())")
    #expect(await Self.descriptorsSettle(under: root).isEmpty, "\(source) \(payload) left descriptors open")
  }

  /// A stream whose producer ends once staging is cancelled: staging returns promptly and cleans up.
  @Test
  func aCancelledStreamInstallReturnsAndCleansUp() async throws {
    let source = ChunkSource()
    let contents = try appArchive()
    let (chunks, producer) = AsyncThrowingStream.makeStream(of: Data.self)
    producer.yield(contents.prefix(contents.count / 2))
    let pumped = Task { try await source.pump(chunks) }
    let task = Task {
      try await Staging.withMaterialized(
        .stream(source), as: .application, temporaryDirectory: TemporaryDirectory(rootDirectory: stagingRoot, logger: logger), logger: logger
      ) { _ in }
    }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    producer.finish()
    _ = await pumped.result
    let start = ContinuousClock.now
    _ = await task.result
    // Generous for a loaded host; a cancellation that did not end the read would wait on the producer indefinitely.
    #expect(ContinuousClock.now - start < .seconds(60))
    #expect(stagingContents().isEmpty, "left \(stagingContents())")
    #expect(await Self.descriptorsSettle(under: root).isEmpty)
  }
}
