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

/// What a download cache does for installs from a URL.
@Suite
struct DownloadCacheTests {

  private struct Installed: InstalledName {
    let identifier: String
    var installedName: String { identifier }
  }

  private let root = TemporaryDirectory(logger: ControlCoreGlobalConfiguration.defaultLogger).temporaryDirectory()
  private let logger = ControlCoreGlobalConfiguration.defaultLogger

  private var cacheDirectory: URL { root.appendingPathComponent("cache") }

  // MARK: - Fixtures

  /// A gzipped tar laid out like an `.ipa`, holding an application with `identifier` and a `marker` file.
  private func archive(identifier: String) async throws -> URL {
    let payload = root.appendingPathComponent("payload-\(UUID().uuidString)")
    let app = payload.appendingPathComponent("Payload/Sample.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    // Reading a bundle parses its executable's header, so it has to be a real Mach-O.
    try FileManager.default.copyItem(atPath: "/bin/ls", toPath: app.appendingPathComponent("Sample").path)
    let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Sample", "CFBundleName": "Sample"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
    try Data("original".utf8).write(to: app.appendingPathComponent("marker"))
    let file = root.appendingPathComponent("archive-\(UUID().uuidString).tgz")
    try await ArchiveOperations.createGzippedTarData(forPath: payload.path, logger: logger).write(to: file)
    return file
  }

  /// A server for an archive of an application with `identifier`, whose responses may be reused for an hour unless
  /// `headers` says otherwise.
  private func serve(identifier: String, headers: [String] = ["Cache-Control: max-age=3600"]) async throws -> LocalHTTPServer {
    try await LocalHTTPServer.serving(try await archive(identifier: identifier), extraHeaders: headers)
  }

  private func temporaryDirectory() -> TemporaryDirectory {
    TemporaryDirectory(rootDirectory: root.appendingPathComponent("staging-\(UUID().uuidString)"), logger: logger)
  }

  /// Installs `kind` from `url` with `cache`, returning the installed identifier, the cache outcomes and whether a
  /// download started. `mutate` runs on the staged application before it is reported installed.
  private func install(
    _ url: URL, as kind: ArtifactKind = .application, cache: DownloadCache?, options: InstallOptions = InstallOptions(),
    mutate: (URL) throws -> Void = { _ in }
  ) async throws -> (identifier: String, outcomes: [DownloadCacheOutcome], downloaded: Bool, marker: String) {
    let events = OSAllocatedUnfairLock<[InstallEvent]>(initialState: [])
    let marker = OSAllocatedUnfairLock<String>(initialState: "")
    // URLSession's own HTTP cache would answer a repeat request for a small archive itself.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    let installed = try await Staging.install(
      .remoteURL(url), as: kind, options: options, downloadConfiguration: configuration, cache: cache,
      temporaryDirectory: temporaryDirectory(), logger: logger,
      onEvent: { event in events.withLock { $0.append(event) } }
    ) { artifact, _ in
      let markerFile = artifact.url.appendingPathComponent("marker")
      marker.withLock { $0 = (try? String(contentsOf: markerFile, encoding: .utf8)) ?? "" }
      try mutate(artifact.url)
      return Installed(identifier: (NSDictionary(contentsOf: artifact.url.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String) ?? "")
    }
    let seen = events.withLock { $0 }
    let outcomes = seen.compactMap { event -> DownloadCacheOutcome? in
      if case .cache(let outcome) = event { return outcome }
      return nil
    }
    let downloaded = seen.contains { event in
      if case .progress(.downloadStarted) = event { return true }
      return false
    }
    return (installed.identifier, outcomes, downloaded, marker.withLock { $0 })
  }

  // MARK: - Tests

  @Test
  func aSecondInstallOfTheSameURLIsClonedFromTheCacheWithoutDownloading() async throws {
    let server = try await serve(identifier: "com.example.cached")
    let cache = DownloadCache(directory: cacheDirectory, minFreeBytes: 0)

    let first = try await install(server.url, cache: cache)
    server.stop()
    let second = try await install(server.url, cache: cache)

    #expect(first.outcomes == [.stored])
    #expect(first.downloaded)
    #expect(second.outcomes == [.hit])
    #expect(!second.downloaded)
    #expect(second.identifier == "com.example.cached")
  }

  @Test
  func changesAnInstallMakesToItsBundleNeverReachTheCache() async throws {
    let server = try await serve(identifier: "com.example.mutated")
    defer { server.stop() }
    let cache = DownloadCache(directory: cacheDirectory, minFreeBytes: 0)

    _ = try await install(server.url, cache: cache) { app in
      try Data("changed".utf8).write(to: app.appendingPathComponent("marker"))
    }
    let second = try await install(server.url, cache: cache) { app in
      try Data("changed again".utf8).write(to: app.appendingPathComponent("marker"))
    }
    let third = try await install(server.url, cache: cache)

    #expect(second.marker == "original")
    #expect(third.marker == "original")
  }

  @Test
  func withoutACacheNothingIsKept() async throws {
    let server = try await serve(identifier: "com.example.uncached")
    defer { server.stop() }

    let result = try await install(server.url, cache: nil)

    #expect(result.outcomes.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.path))
  }

  @Test
  func differentExtractOptionsDoNotShareAnEntry() async throws {
    let server = try await serve(identifier: "com.example.options")
    defer { server.stop() }
    let cache = DownloadCache(directory: cacheDirectory, minFreeBytes: 0)

    _ = try await install(server.url, cache: cache)
    let other = try await install(server.url, cache: cache, options: InstallOptions(overrideModificationTime: true))

    #expect(other.outcomes == [.stored])
    #expect(other.downloaded)
  }

  @Test
  func anEntryWhoseIdentityDiffersIsAMiss() throws {
    let cache = DownloadCache(directory: cacheDirectory, minFreeBytes: 0)
    let identity = "https://example.invalid/a\noverrideModificationTime=false"
    let name = DownloadCache.name(of: identity)
    try FileManager.default.createDirectory(at: cacheDirectory.appendingPathComponent(name), withIntermediateDirectories: true)
    try "https://example.invalid/b\noverrideModificationTime=false".write(
      to: cacheDirectory.appendingPathComponent("\(name).identity"), atomically: true, encoding: .utf8)

    #expect(!cache.contains(identity))
    #expect(!cache.restore(identity, to: root.appendingPathComponent("restored"), logger: logger))
  }

  @Test
  func storingPastTheBudgetEvictsTheLeastRecentlyUsedEntry() async throws {
    let first = try await serve(identifier: "com.example.first")
    let second = try await serve(identifier: "com.example.second")
    defer {
      first.stop()
      second.stop()
    }
    // Smaller than any one entry, so only the newest survives each store.
    let cache = DownloadCache(directory: cacheDirectory, maxBytes: 1, minFreeBytes: 0)

    _ = try await install(first.url, cache: cache)
    _ = try await install(second.url, cache: cache)

    #expect(!cache.contains(DownloadCache.identity(of: first.url, options: InstallOptions())))
    #expect(cache.contains(DownloadCache.identity(of: second.url, options: InstallOptions())))
  }

  @Test
  func aResponseWithoutAFreshnessLifetimeIsNotKept() async throws {
    let server = try await serve(identifier: "com.example.uncacheable", headers: [])
    defer { server.stop() }
    let cache = DownloadCache(directory: cacheDirectory, minFreeBytes: 0)

    let first = try await install(server.url, cache: cache)
    let second = try await install(server.url, cache: cache)

    #expect(first.outcomes == [.notCacheable])
    #expect(second.outcomes == [.notCacheable])
    #expect(second.downloaded)
  }

  @Test
  func anExpiredEntryIsDownloadedAgainAndReplacedByWhatTheURLServesNow() async throws {
    let served = try await archive(identifier: "com.example.v1")
    let server = try await LocalHTTPServer.serving(served, extraHeaders: ["Cache-Control: max-age=3600"])
    defer { server.stop() }
    let cache = DownloadCache(directory: cacheDirectory, minFreeBytes: 0)
    _ = try await install(server.url, cache: cache)
    let name = DownloadCache.name(of: DownloadCache.identity(of: server.url, options: InstallOptions()))
    try "0".write(to: cacheDirectory.appendingPathComponent("\(name).expires"), atomically: true, encoding: .utf8)
    // The same URL now serves another version.
    try FileManager.default.removeItem(at: served)
    try FileManager.default.moveItem(at: try await archive(identifier: "com.example.v2"), to: served)

    let afterExpiry = try await install(server.url, cache: cache)
    let next = try await install(server.url, cache: cache)

    #expect(afterExpiry.downloaded)
    #expect(afterExpiry.outcomes == [.stored])
    #expect(afterExpiry.identifier == "com.example.v2")
    #expect(next.outcomes == [.hit])
    #expect(next.identifier == "com.example.v2")
  }

  @Test
  func anEntryIsFreshOnlyUntilItsResponseSaidItMayBeReused() async throws {
    let server = try await serve(identifier: "com.example.lifetime", headers: ["Cache-Control: max-age=600", "Age: 100"])
    defer { server.stop() }
    let cache = DownloadCache(directory: cacheDirectory, minFreeBytes: 0)
    _ = try await install(server.url, cache: cache)
    let identity = DownloadCache.identity(of: server.url, options: InstallOptions())

    #expect(cache.contains(identity, now: Date().addingTimeInterval(400)))
    #expect(!cache.contains(identity, now: Date().addingTimeInterval(600)))
  }

  @Test
  func aStoreThatFindsAnEntryAlreadyInPlaceLeavesThatEntrysExpiry() throws {
    let cache = DownloadCache(directory: cacheDirectory, minFreeBytes: 0)
    let identity = "https://example.invalid/a\noverrideModificationTime=false"
    let tree = root.appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    try Data("app".utf8).write(to: tree.appendingPathComponent("marker"))

    #expect(cache.store(tree, as: identity, freshness: HTTPFreshness(lifetime: 600), logger: logger) == .stored)
    #expect(cache.store(tree, as: identity, freshness: HTTPFreshness(lifetime: 60_000), logger: logger) == .stored)

    #expect(cache.contains(identity, now: Date().addingTimeInterval(500)))
    #expect(!cache.contains(identity, now: Date().addingTimeInterval(700)))
  }

  /// The free space a test's cache sees, which the test sets.
  private final class FreeSpace: Sendable {
    let bytes = OSAllocatedUnfairLock<Int64>(initialState: .max)
  }

  private func cache(minFreeBytes: Int64, freeSpace: FreeSpace) -> DownloadCache {
    DownloadCache(directory: cacheDirectory, maxBytes: DownloadCache.defaultMaxBytes, minFreeBytes: minFreeBytes) { _ in
      freeSpace.bytes.withLock { $0 }
    }
  }

  @Test
  func anApplicationThatWouldLeaveTooLittleFreeSpaceIsNotKept() async throws {
    let server = try await serve(identifier: "com.example.full")
    defer { server.stop() }
    let freeSpace = FreeSpace()
    freeSpace.bytes.withLock { $0 = 1 << 30 }
    let cache = cache(minFreeBytes: 1 << 30, freeSpace: freeSpace)

    let result = try await install(server.url, cache: cache)

    #expect(result.outcomes == [.skippedLowDisk])
    #expect(result.identifier == "com.example.full")
    #expect(!cache.contains(DownloadCache.identity(of: server.url, options: InstallOptions())))
  }

  @Test
  func makingRoomForANewEntryEvictsTheLeastRecentlyUsedOne() async throws {
    let first = try await serve(identifier: "com.example.older")
    let second = try await serve(identifier: "com.example.newer")
    defer {
      first.stop()
      second.stop()
    }
    let minFree: Int64 = 1 << 30
    let freeSpace = FreeSpace()
    let cache = cache(minFreeBytes: minFree, freeSpace: freeSpace)
    _ = try await install(first.url, cache: cache)
    let firstIdentity = DownloadCache.identity(of: first.url, options: InstallOptions())
    let entryBytes = DownloadCache.allocatedBytes(of: cacheDirectory.appendingPathComponent(DownloadCache.name(of: firstIdentity)))
    // One byte short of room for another entry of the same size, until the older one goes.
    freeSpace.bytes.withLock { $0 = minFree + entryBytes - 1 }

    let result = try await install(second.url, cache: cache)

    #expect(result.outcomes == [.stored])
    #expect(!cache.contains(firstIdentity))
    #expect(cache.contains(DownloadCache.identity(of: second.url, options: InstallOptions())))
  }

  @Test
  func anEntryThatCouldNotBeRemovedFreesNoRoom() async throws {
    let first = try await serve(identifier: "com.example.stuck")
    let second = try await serve(identifier: "com.example.next")
    defer {
      first.stop()
      second.stop()
    }
    let minFree: Int64 = 1 << 30
    let freeSpace = FreeSpace()
    let cache = cache(minFreeBytes: minFree, freeSpace: freeSpace)
    _ = try await install(first.url, cache: cache)
    let stuck = cacheDirectory.appendingPathComponent(DownloadCache.name(of: DownloadCache.identity(of: first.url, options: InstallOptions())))
    let entryBytes = DownloadCache.allocatedBytes(of: stuck)
    // Nothing can be deleted from a directory without write permission.
    try setDirectoryPermissions(0o555, under: stuck)
    defer { try? setDirectoryPermissions(0o755, under: stuck) }
    // Room for another entry of about the same size only if the stuck one's bytes were counted as freed.
    freeSpace.bytes.withLock { $0 = minFree + entryBytes / 2 }

    let result = try await install(second.url, cache: cache)

    #expect(result.outcomes == [.skippedLowDisk])
  }

  private func setDirectoryPermissions(_ permissions: Int, under root: URL) throws {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
    var directories = [root]
    while let url = enumerator?.nextObject() as? URL {
      if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        directories.append(url)
      }
    }
    for directory in directories {
      try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: directory.path)
    }
  }

  @Test
  func anUnreadableFreeSpaceKeepsNothing() async throws {
    let server = try await serve(identifier: "com.example.unknown")
    defer { server.stop() }
    let cache = DownloadCache(directory: cacheDirectory, maxBytes: DownloadCache.defaultMaxBytes, minFreeBytes: 0) { _ in nil }

    let result = try await install(server.url, cache: cache)

    #expect(result.outcomes == [.skippedLowDisk])
  }

  @Test
  func theEnvironmentNamesTheCache() {
    #expect(DownloadCache.fromEnvironment([:]) == nil)
    #expect(DownloadCache.fromEnvironment([DownloadCache.directoryVariable: ""]) == nil)
    let cache = DownloadCache.fromEnvironment([DownloadCache.directoryVariable: "/tmp/c", DownloadCache.maxBytesVariable: "1024"])
    #expect(cache?.directory.path == "/tmp/c")
    #expect(cache?.maxBytes == 1024)
    #expect(cache?.minFreeBytes == DownloadCache.defaultMinFreeBytes)
    #expect(DownloadCache.fromEnvironment([DownloadCache.directoryVariable: "/tmp/c", DownloadCache.minFreeBytesVariable: "0"])?.minFreeBytes == 0)
    #expect(DownloadCache.fromEnvironment([DownloadCache.directoryVariable: "/tmp/c", DownloadCache.maxBytesVariable: "-1"])?.maxBytes == DownloadCache.defaultMaxBytes)
  }
}
