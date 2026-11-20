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
  ) async throws -> (
    identifier: String, outcomes: [DownloadCacheOutcome], freeBytes: [Int64?], evictions: [DownloadCacheEvictions?], downloaded: Bool, marker: String
  ) {
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
    let reports = seen.compactMap { event -> DownloadCacheReport? in
      if case .cache(let report) = event { return report }
      return nil
    }
    let downloaded = seen.contains { event in
      if case .progress(.downloadStarted) = event { return true }
      return false
    }
    return (installed.identifier, reports.map(\.outcome), reports.map(\.freeBytes), reports.map(\.evictions), downloaded, marker.withLock { $0 })
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
  func aStoreReportsTheEntriesItEvictedToFitTheBudget() async throws {
    let first = try await serve(identifier: "com.example.evicted")
    let second = try await serve(identifier: "com.example.evicting")
    defer {
      first.stop()
      second.stop()
    }
    let cache = DownloadCache(directory: cacheDirectory, maxBytes: 1, minFreeBytes: 0)

    let kept = try await install(first.url, cache: cache)
    let evicting = try await install(second.url, cache: cache)

    #expect(kept.evictions.map { $0?.count } == [0])
    #expect(evicting.outcomes == [.stored])
    #expect(evicting.evictions.map { $0?.count } == [1])
    #expect(evicting.evictions.allSatisfy { ($0?.milliseconds ?? -1) >= 0 })
  }

  private var trashDirectory: URL { cacheDirectory.appendingPathComponent(".trash") }

  private func trashed() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: trashDirectory.path)) ?? []
  }

  @Test
  func anEntryEvictedToFitTheBudgetLeavesTheCacheWithItsTreeInTheTrash() async throws {
    let first = try await serve(identifier: "com.example.trashed")
    let second = try await serve(identifier: "com.example.kept")
    defer {
      first.stop()
      second.stop()
    }
    let cache = DownloadCache(directory: cacheDirectory, maxBytes: 1, minFreeBytes: 0)
    _ = try await install(first.url, cache: cache)
    let firstName = DownloadCache.name(of: DownloadCache.identity(of: first.url, options: InstallOptions()))

    _ = try await install(second.url, cache: cache)

    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(firstName).path))
    #expect(trashed().count == 1)
    #expect(trashed().allSatisfy { $0.hasPrefix(firstName) })
    #expect(!cache.contains(DownloadCache.identity(of: first.url, options: InstallOptions())))
  }

  @Test
  func theNextInstallThatDownloadsDeletesTheTrash() async throws {
    let first = try await serve(identifier: "com.example.one")
    let second = try await serve(identifier: "com.example.two")
    let third = try await serve(identifier: "com.example.three")
    defer {
      first.stop()
      second.stop()
      third.stop()
    }
    let cache = DownloadCache(directory: cacheDirectory, maxBytes: 1, minFreeBytes: 0)
    _ = try await install(first.url, cache: cache)
    _ = try await install(second.url, cache: cache)
    // What a process killed before it emptied the trash leaves there.
    try FileManager.default.createDirectory(at: trashDirectory.appendingPathComponent("abandoned/Payload"), withIntermediateDirectories: true)

    let result = try await install(third.url, cache: cache)

    #expect(result.outcomes == [.stored])
    // Only what this store evicted, the second entry; the earlier trash went while it downloaded.
    #expect(trashed().count == 1)
    #expect(trashed().allSatisfy { $0.hasPrefix(DownloadCache.name(of: DownloadCache.identity(of: second.url, options: InstallOptions()))) })
  }

  @Test
  func aHitLeavesTheTrashAsItIs() async throws {
    let first = try await serve(identifier: "com.example.left")
    let second = try await serve(identifier: "com.example.again")
    defer {
      first.stop()
      second.stop()
    }
    let cache = DownloadCache(directory: cacheDirectory, maxBytes: 1, minFreeBytes: 0)
    _ = try await install(first.url, cache: cache)
    _ = try await install(second.url, cache: cache)

    let hit = try await install(second.url, cache: cache)

    #expect(hit.outcomes == [.hit])
    #expect(trashed().count == 1)
  }

  @Test
  func makingRoomDeletesTheTrashBeforeDeletingAnEntry() throws {
    let minFree: Int64 = 1 << 30
    let freeSpace = FreeSpace()
    let cache = DownloadCache(directory: cacheDirectory, maxBytes: 1, minFreeBytes: minFree) { [cacheDirectory] _ in
      freeSpace.capacity.withLock { $0 } - DownloadCache.allocatedBytes(of: cacheDirectory)
    }
    func tree(_ name: String) throws -> URL {
      let tree = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
      try Data(count: 64 << 10).write(to: tree.appendingPathComponent("payload"))
      return tree
    }
    let identities = ["a", "b", "c"].map { "https://example.invalid/\($0)\noverrideModificationTime=false" }
    let fresh = HTTPFreshness(lifetime: 600)
    _ = cache.store(try tree("a"), as: identities[0], freshness: fresh, logger: logger)
    // Evicts the first entry to fit the budget, into the trash.
    _ = cache.store(try tree("b"), as: identities[1], freshness: fresh, logger: logger)
    let firstName = DownloadCache.name(of: identities[0])
    let secondName = DownloadCache.name(of: identities[1])
    #expect(trashed().allSatisfy { $0.hasPrefix(firstName) })
    // One byte short of the minimum, until the trash goes.
    freeSpace.capacity.withLock { $0 = minFree - 1 + DownloadCache.allocatedBytes(of: cacheDirectory) }

    let report = cache.store(try tree("c"), as: identities[2], freshness: fresh, logger: logger)

    #expect(report.outcome == .stored)
    // Had the second entry been deleted to make room instead, the first entry's tree would still be in the trash.
    #expect(trashed().count == 1)
    #expect(trashed().allSatisfy { $0.hasPrefix(secondName) })
  }

  @Test
  func onlyAStoreReportsEvictions() async throws {
    let cached = try await serve(identifier: "com.example.hit")
    let uncacheable = try await serve(identifier: "com.example.uncacheable", headers: [])
    defer {
      cached.stop()
      uncacheable.stop()
    }
    let cache = DownloadCache(directory: cacheDirectory, minFreeBytes: 0)
    _ = try await install(cached.url, cache: cache)

    let hit = try await install(cached.url, cache: cache)
    let notCacheable = try await install(uncacheable.url, cache: cache)

    #expect(hit.outcomes == [.hit])
    #expect(hit.evictions == [nil])
    #expect(notCacheable.outcomes == [.notCacheable])
    #expect(notCacheable.evictions == [nil])
  }

  @Test
  func theBudgetCountsAnEntryAtTheSizeRecordedWhenItWasStored() async throws {
    let first = try await serve(identifier: "com.example.recorded")
    let second = try await serve(identifier: "com.example.later")
    defer {
      first.stop()
      second.stop()
    }
    let cache = DownloadCache(directory: cacheDirectory, maxBytes: 1 << 30, minFreeBytes: 0)
    _ = try await install(first.url, cache: cache)
    let firstIdentity = DownloadCache.identity(of: first.url, options: InstallOptions())
    let firstName = DownloadCache.name(of: firstIdentity)
    // Recorded past the budget, though its tree is far smaller.
    try record(bytes: 1 << 31, for: firstName)

    _ = try await install(second.url, cache: cache)

    #expect(!cache.contains(firstIdentity))
    #expect(cache.contains(DownloadCache.identity(of: second.url, options: InstallOptions())))
  }

  @Test
  func aRecordLeftForAnEarlierTreeIsNotTrusted() async throws {
    let first = try await serve(identifier: "com.example.replaced")
    let second = try await serve(identifier: "com.example.beside")
    defer {
      first.stop()
      second.stop()
    }
    let cache = DownloadCache(directory: cacheDirectory, maxBytes: 1 << 30, minFreeBytes: 0)
    _ = try await install(first.url, cache: cache)
    let firstIdentity = DownloadCache.identity(of: first.url, options: InstallOptions())
    let firstName = DownloadCache.name(of: firstIdentity)
    try record(bytes: 1 << 31, for: firstName)
    // A process that keeps no records puts another tree in place under the same name.
    let tree = cacheDirectory.appendingPathComponent(firstName)
    let moved = root.appendingPathComponent("moved-\(UUID().uuidString)")
    try FileManager.default.moveItem(at: tree, to: moved)
    try FileManager.default.copyItem(at: moved, to: tree)

    _ = try await install(second.url, cache: cache)

    #expect(cache.contains(firstIdentity))
  }

  /// Records `bytes` for the tree now in place under `name`.
  private func record(bytes: Int64, for name: String) throws {
    let tree = cacheDirectory.appendingPathComponent(name)
    let inode = try #require(try FileManager.default.attributesOfItem(atPath: tree.path)[.systemFileNumber] as? UInt64)
    try "\(inode) \(bytes)".write(to: cacheDirectory.appendingPathComponent("\(name).bytes"), atomically: true, encoding: .utf8)
  }

  @Test
  func anEntryWithoutARecordedSizeIsMeasured() async throws {
    let first = try await serve(identifier: "com.example.unrecorded")
    let second = try await serve(identifier: "com.example.after")
    defer {
      first.stop()
      second.stop()
    }
    _ = try await install(first.url, cache: DownloadCache(directory: cacheDirectory, minFreeBytes: 0))
    let firstIdentity = DownloadCache.identity(of: first.url, options: InstallOptions())
    let firstName = DownloadCache.name(of: firstIdentity)
    try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent("\(firstName).bytes"))
    // Room for one entry of about this size, so the older one goes only if its tree is measured.
    let entryBytes = DownloadCache.allocatedBytes(of: cacheDirectory.appendingPathComponent(firstName))
    let cache = DownloadCache(directory: cacheDirectory, maxBytes: entryBytes + entryBytes / 2, minFreeBytes: 0)

    _ = try await install(second.url, cache: cache)

    #expect(!cache.contains(firstIdentity))
    #expect(cache.contains(DownloadCache.identity(of: second.url, options: InstallOptions())))
  }

  @Test
  func anEntryMeasuredForWantOfARecordIsRecordedThen() async throws {
    let first = try await serve(identifier: "com.example.backfilled")
    let second = try await serve(identifier: "com.example.third")
    defer {
      first.stop()
      second.stop()
    }
    let cache = DownloadCache(directory: cacheDirectory, maxBytes: 1 << 30, minFreeBytes: 0)
    _ = try await install(first.url, cache: cache)
    let firstIdentity = DownloadCache.identity(of: first.url, options: InstallOptions())
    let firstName = DownloadCache.name(of: firstIdentity)
    let recordURL = cacheDirectory.appendingPathComponent("\(firstName).bytes")
    // As an entry stored by a companion that keeps no records.
    try FileManager.default.removeItem(at: recordURL)

    _ = try await install(second.url, cache: cache)

    let tree = cacheDirectory.appendingPathComponent(firstName)
    let inode = try #require(try FileManager.default.attributesOfItem(atPath: tree.path)[.systemFileNumber] as? UInt64)
    #expect((try? String(contentsOf: recordURL, encoding: .utf8)) == "\(inode) \(DownloadCache.allocatedBytes(of: tree))")
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

    #expect(cache.store(tree, as: identity, freshness: HTTPFreshness(lifetime: 600), logger: logger).outcome == .stored)
    #expect(cache.store(tree, as: identity, freshness: HTTPFreshness(lifetime: 60_000), logger: logger).outcome == .stored)

    #expect(cache.contains(identity, now: Date().addingTimeInterval(500)))
    #expect(!cache.contains(identity, now: Date().addingTimeInterval(700)))
  }

  /// The size of a volume holding nothing but the test's cache, which the test sets. What the volume reports free is
  /// that size less what the cache takes, so a removal frees only what it actually deleted.
  private final class FreeSpace: Sendable {
    let capacity = OSAllocatedUnfairLock<Int64>(initialState: .max)
  }

  private func cache(minFreeBytes: Int64, freeSpace: FreeSpace) -> DownloadCache {
    DownloadCache(directory: cacheDirectory, maxBytes: DownloadCache.defaultMaxBytes, minFreeBytes: minFreeBytes) { [cacheDirectory] _ in
      freeSpace.capacity.withLock { $0 } - DownloadCache.allocatedBytes(of: cacheDirectory)
    }
  }

  @Test
  func anApplicationThatWouldLeaveTooLittleFreeSpaceIsNotKept() async throws {
    let server = try await serve(identifier: "com.example.full")
    defer { server.stop() }
    let freeSpace = FreeSpace()
    freeSpace.capacity.withLock { $0 = (1 << 30) - 1 }
    let cache = cache(minFreeBytes: 1 << 30, freeSpace: freeSpace)

    let result = try await install(server.url, cache: cache)

    #expect(result.outcomes == [.skippedLowDisk])
    #expect(result.freeBytes == [(1 << 30) - 1])
    #expect(result.identifier == "com.example.full")
    #expect(!cache.contains(DownloadCache.identity(of: server.url, options: InstallOptions())))
  }

  @Test
  func anApplicationIsKeptWhenTheVolumeHasTheMinimumFree() async throws {
    let server = try await serve(identifier: "com.example.exact")
    defer { server.stop() }
    let freeSpace = FreeSpace()
    freeSpace.capacity.withLock { $0 = 1 << 30 }
    // The extracted tree is already on the volume, so keeping it does not take its bytes again.
    let cache = cache(minFreeBytes: 1 << 30, freeSpace: freeSpace)

    let result = try await install(server.url, cache: cache)

    #expect(result.outcomes == [.stored])
    #expect(result.freeBytes == [1 << 30])
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
    // One byte short of the minimum, until the older entry goes.
    let capacity = minFree - 1 + DownloadCache.allocatedBytes(of: cacheDirectory)
    freeSpace.capacity.withLock { $0 = capacity }

    let result = try await install(second.url, cache: cache)

    #expect(result.outcomes == [.stored])
    // What the volume reports once the older entry is gone.
    #expect(result.freeBytes == [capacity])
    #expect(result.evictions.map { $0?.count } == [1])
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
    // Short of the minimum by half the stuck entry, so there is room only if its bytes were counted as freed.
    freeSpace.capacity.withLock { $0 = minFree - entryBytes / 2 + DownloadCache.allocatedBytes(of: cacheDirectory) }

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
    #expect(result.freeBytes == [nil])
  }

  @Test(arguments: [
    ("invalid", DownloadCache.defaultMaxBytes, DownloadCache.defaultMinFreeBytes),
    ("0", DownloadCache.defaultMaxBytes, Int64(0)),
    ("-1", DownloadCache.defaultMaxBytes, DownloadCache.defaultMinFreeBytes),
    ("9223372036854775808", DownloadCache.defaultMaxBytes, DownloadCache.defaultMinFreeBytes),
    ("9223372036854775807", Int64.max, Int64.max),
    ("1", Int64(1), Int64(1)),
  ])
  func theEnvironmentBoundsTheCache(_ value: String, maxBytes: Int64, minFreeBytes: Int64) {
    let cache = DownloadCache.fromEnvironment([
      DownloadCache.directoryVariable: "/tmp/c",
      DownloadCache.maxBytesVariable: value,
      DownloadCache.minFreeBytesVariable: value,
    ])
    #expect(cache?.maxBytes == maxBytes)
    #expect(cache?.minFreeBytes == minFreeBytes)
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
