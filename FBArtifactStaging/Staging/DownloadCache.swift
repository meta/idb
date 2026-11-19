/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// What a download cache did for one install from a URL.
public enum DownloadCacheOutcome: String, Equatable, Sendable {
  /// The application was cloned from the cache; nothing was downloaded.
  case hit
  /// The application was downloaded and a copy was kept for the next install of the same URL.
  case stored
  /// The application was downloaded, and keeping a copy failed; the install went ahead without it.
  case storeFailed = "store_failed"
  /// The application was downloaded and not kept: even with every other entry evicted, keeping it would have left less
  /// free space on the cache's volume than the cache must leave, or that free space could not be read.
  case skippedLowDisk = "skipped_low_disk"
  /// The application was downloaded and not kept: the response gave no explicit freshness lifetime, or forbade reuse.
  case notCacheable = "not_cacheable"
}

/// The entries a store removed, to make room or to fit the budget, and how long removing them took.
public struct DownloadCacheEvictions: Equatable, Sendable {
  public let count: Int
  public let milliseconds: Int
}

/// What a download cache did for one install from a URL, and the free space it decided on.
public struct DownloadCacheReport: Equatable, Sendable {
  public let outcome: DownloadCacheOutcome
  /// The free bytes on the cache's volume that the decision to keep the application was made against: what the volume
  /// reported once the evictions making room for it were done. `nil` when it was not read: a hit, a response that could
  /// not be cached, or a volume whose free space could not be read.
  public let freeBytes: Int64?
  /// What the store removed while it decided and kept the application. `nil` when no store ran: a hit, or a response
  /// that could not be cached.
  public let evictions: DownloadCacheEvictions?

  init(outcome: DownloadCacheOutcome, freeBytes: Int64? = nil, evictions: DownloadCacheEvictions? = nil) {
    self.outcome = outcome
    self.freeBytes = freeBytes
    self.evictions = evictions
  }
}

/// Applications downloaded for an install, kept extracted and keyed by the URL they came from, so a later install of
/// the same URL clones them instead of downloading and extracting them again.
///
/// Every process given the same directory shares it: an entry appears whole, by a rename, or not at all. Entries are
/// cloned in and out with `clonefile(2)`, so the directory has to be on the same APFS volume as the staging directory;
/// a clone that fails is a miss, never a failed install. A URL is taken to name the same bytes for as long as its entry
/// lives, and an entry lives no longer than its response said it may be reused: one is kept only when the response gave an
/// explicit freshness lifetime (`Cache-Control: max-age` or `Expires`, less its `Age`), and it is a miss once that lapses.
///
/// Two bounds keep it from filling the disk: its own size stays within `maxBytes`, and it never stores an entry that
/// would leave less than `minFreeBytes` free on its volume, evicting the least recently used entries first to make room.
public struct DownloadCache: Sendable {

  /// The environment variable that names the cache directory. Unset, installs from a URL are never cached.
  public static let directoryVariable = "IDB_INSTALL_CACHE_DIR"
  /// The environment variable that bounds the cache's size, in bytes.
  public static let maxBytesVariable = "IDB_INSTALL_CACHE_MAX_BYTES"
  public static let defaultMaxBytes: Int64 = 20 << 30
  /// The environment variable that sets the free space, in bytes, the cache must leave on its volume.
  public static let minFreeBytesVariable = "IDB_INSTALL_CACHE_MIN_FREE_BYTES"
  public static let defaultMinFreeBytes: Int64 = 50 << 30

  public let directory: URL
  public let maxBytes: Int64
  public let minFreeBytes: Int64
  /// The free bytes on the volume holding a path; the real volume's unless a test stands in for it.
  let freeBytes: @Sendable (URL) -> Int64?

  public init(directory: URL, maxBytes: Int64 = DownloadCache.defaultMaxBytes, minFreeBytes: Int64 = DownloadCache.defaultMinFreeBytes) {
    self.init(directory: directory, maxBytes: maxBytes, minFreeBytes: minFreeBytes, freeBytes: Self.volumeFreeBytes)
  }

  init(directory: URL, maxBytes: Int64, minFreeBytes: Int64, freeBytes: @escaping @Sendable (URL) -> Int64?) {
    self.directory = directory
    self.maxBytes = maxBytes
    self.minFreeBytes = minFreeBytes
    self.freeBytes = freeBytes
  }

  /// What `statfs(2)` reports available to an unprivileged process on the volume holding `url`, or the nearest existing
  /// parent of it; `nil` if that can't be read.
  static func volumeFreeBytes(at url: URL) -> Int64? {
    var path = url
    while !FileManager.default.fileExists(atPath: path.path), path.path != "/" {
      path.deleteLastPathComponent()
    }
    var stats = statfs()
    guard statfs(path.path, &stats) == 0 else {
      return nil
    }
    return Int64(stats.f_bavail) * Int64(stats.f_bsize)
  }

  /// The cache the environment names, or `nil` when it names none.
  public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> DownloadCache? {
    guard let path = environment[directoryVariable], !path.isEmpty else {
      return nil
    }
    let maxBytes = environment[maxBytesVariable].flatMap { Int64($0) }.flatMap { $0 > 0 ? $0 : nil } ?? defaultMaxBytes
    let minFreeBytes = environment[minFreeBytesVariable].flatMap { Int64($0) }.flatMap { $0 >= 0 ? $0 : nil } ?? defaultMinFreeBytes
    return DownloadCache(directory: URL(fileURLWithPath: path), maxBytes: maxBytes, minFreeBytes: minFreeBytes)
  }

  // MARK: - Entries

  /// What identifies an entry: the URL, and the extract options that shaped what it extracted to.
  static func identity(of url: URL, options: InstallOptions) -> String {
    "\(url.absoluteString)\noverrideModificationTime=\(options.overrideModificationTime)"
  }

  /// An entry's name: a 64-bit FNV-1a of its identity. The identity itself is kept beside the entry and compared on every
  /// restore, so two identities that hash alike never share an entry.
  static func name(of identity: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in identity.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
  }

  private func treeURL(_ name: String) -> URL {
    directory.appendingPathComponent(name)
  }

  /// Where the trees of entries evicted to fit the budget wait to be deleted. Renaming a tree there is instant, where
  /// deleting a whole application is not.
  private var trashURL: URL {
    directory.appendingPathComponent(".trash")
  }

  private func identityURL(_ name: String) -> URL {
    directory.appendingPathComponent("\(name).identity")
  }

  /// The file holding when the entry stops being fresh, in seconds since 1970.
  private func expiryURL(_ name: String) -> URL {
    directory.appendingPathComponent("\(name).expires")
  }

  /// The file recording the bytes the entry's tree took when it was stored, as `<inode> <bytes>`.
  private func bytesURL(_ name: String) -> URL {
    directory.appendingPathComponent("\(name).bytes")
  }

  /// The bytes recorded for the entry's tree, if the record names the tree now in place. A process that does not keep
  /// records can replace the tree under the same name and leave an earlier record behind.
  private func recordedBytes(_ name: String) -> Int64? {
    guard let fields = (try? String(contentsOf: bytesURL(name), encoding: .utf8))?.split(separator: " "), fields.count == 2,
      let inode = UInt64(fields[0]), let bytes = Int64(fields[1]), inode == Self.inode(of: treeURL(name))
    else {
      return nil
    }
    return bytes
  }

  /// Records `bytes` for the entry's tree. Without a record the entry is measured when listed, so failing to write one
  /// fails nothing.
  private func record(_ bytes: Int64, inode: UInt64, for name: String) {
    try? "\(inode) \(bytes)".write(to: bytesURL(name), atomically: true, encoding: .utf8)
  }

  /// Measures the entry's tree and records what it found, so the tree is walked once rather than on every store. The
  /// inode is read first: a tree replaced while it is measured leaves a record no later listing trusts.
  private func measure(_ name: String) -> Int64 {
    let tree = treeURL(name)
    guard let inode = Self.inode(of: tree) else {
      return 0
    }
    let bytes = Self.allocatedBytes(of: tree)
    record(bytes, inode: inode, for: name)
    return bytes
  }

  private static func inode(of url: URL) -> UInt64? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      return nil
    }
    return UInt64(info.st_ino)
  }

  /// Whether there is a fresh entry for `identity`. Another process may still evict it before it is restored.
  func contains(_ identity: String, now: Date = Date()) -> Bool {
    let name = Self.name(of: identity)
    guard let expiry = (try? String(contentsOf: expiryURL(name), encoding: .utf8)).flatMap({ TimeInterval($0) }),
      Date(timeIntervalSince1970: expiry) > now
    else {
      return false
    }
    return (try? String(contentsOf: identityURL(name), encoding: .utf8)) == identity
      && FileManager.default.fileExists(atPath: treeURL(name).path)
  }

  /// Clones the entry for `identity` to `destination`, which must not exist yet. `false` if there is no such entry, or
  /// it could not be cloned.
  func restore(_ identity: String, to destination: URL, logger: any ControlCoreLogger) -> Bool {
    let name = Self.name(of: identity)
    guard contains(identity) else {
      return false
    }
    guard clonefile(treeURL(name).path, destination.path, 0) == 0 else {
      logger.info().log("Install cache entry \(name) could not be cloned (\(POSIXError.current)); downloading instead")
      try? FileManager.default.removeItem(at: destination)
      return false
    }
    // An entry's modification time is when it was last used, which is what eviction goes by.
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: identityURL(name).path)
    return true
  }

  /// Clones `tree` into the cache as the entry for `identity`, fresh for `freshness`, then evicts the least recently used
  /// entries until the cache fits in `maxBytes`. An entry another process stored first is left as it is.
  func store(_ tree: URL, as identity: String, freshness: HTTPFreshness?, logger: any ControlCoreLogger) -> DownloadCacheReport {
    guard let lifetime = freshness?.lifetime else {
      return DownloadCacheReport(outcome: .notCacheable)
    }
    let fileManager = FileManager.default
    let name = Self.name(of: identity)
    var removals = Removals()
    // The tree is removed once the install returns, so a kept clone ends up owning all of its blocks.
    let bytes = Self.allocatedBytes(of: tree)
    guard let free = makeRoom(removals: &removals, logger: logger) else {
      logger.info().log("Not keeping \(tree.path) in the install cache: the free space on its volume could not be read")
      return DownloadCacheReport(outcome: .skippedLowDisk, evictions: removals.report)
    }
    // The tree already takes its blocks on this volume, and a clone shares them, so keeping it leaves `free` as it is.
    guard free >= minFreeBytes else {
      logger.info().log("Not keeping \(tree.path) in the install cache: its volume has \(free) bytes free, less than \(minFreeBytes)")
      return DownloadCacheReport(outcome: .skippedLowDisk, freeBytes: free, evictions: removals.report)
    }
    let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      // This store follows a miss, so an entry already under this name has expired, or never held this identity;
      // left in place, the rename below would keep its tree.
      if !contains(identity) {
        remove(Entry(name: name, used: .distantPast, bytes: 0, expiry: nil), deleting: .later, removals: &removals, logger: logger)
      }
      guard clonefile(tree.path, staging.path, 0) == 0 else {
        throw POSIXError.current
      }
      try identity.write(to: identityURL(name), atomically: true, encoding: .utf8)
      if rename(staging.path, treeURL(name).path) != 0 {
        let error = POSIXError.current
        try? fileManager.removeItem(at: staging)
        guard error.code == .ENOTEMPTY || error.code == .EEXIST else {
          throw error
        }
        // The tree another process placed is fresh for as long as its own response said, which it records itself.
        evict(keeping: name, removals: &removals, logger: logger)
        return DownloadCacheReport(outcome: .stored, freeBytes: free, evictions: removals.report)
      }
      if let inode = Self.inode(of: treeURL(name)) {
        record(bytes, inode: inode, for: name)
      }
      // The expiry goes last: an entry is fresh only once its tree is in place.
      try String(Date().addingTimeInterval(lifetime).timeIntervalSince1970).write(to: expiryURL(name), atomically: true, encoding: .utf8)
    } catch {
      try? fileManager.removeItem(at: staging)
      logger.info().log("Could not keep \(tree.path) in the install cache: \(error)")
      return DownloadCacheReport(outcome: .storeFailed, freeBytes: free, evictions: removals.report)
    }
    evict(keeping: name, removals: &removals, logger: logger)
    return DownloadCacheReport(outcome: .stored, freeBytes: free, evictions: removals.report)
  }

  /// The entries one store removed, and the time removing them took.
  private struct Removals {
    var count = 0
    var duration = Duration.zero

    var report: DownloadCacheEvictions {
      DownloadCacheEvictions(count: count, milliseconds: Int((duration / .milliseconds(1)).rounded()))
    }
  }

  /// Evicts the least recently used entries until the cache's volume has `minFreeBytes` free, and returns what the volume
  /// then reports free, which may still fall short. `nil` if the free space can't be read.
  private func makeRoom(removals: inout Removals, logger: any ControlCoreLogger) -> Int64? {
    guard var free = freeBytes(directory) else {
      return nil
    }
    if free < minFreeBytes {
      emptyTrash()
      guard let measured = freeBytes(directory) else {
        return nil
      }
      free = measured
    }
    // Only a deleted tree frees space on the volume, so these are deleted now rather than moved to the trash.
    for entry in entries() where free < minFreeBytes {
      remove(entry, deleting: .now, removals: &removals, logger: logger)
      // Read again rather than credited: an entry that could not be deleted, or whose blocks another clone still shares,
      // frees less than its size.
      guard let measured = freeBytes(directory) else {
        return nil
      }
      free = measured
    }
    return free
  }

  /// Removes every expired entry, then the least recently used ones, never `keeping`, until the cache fits in `maxBytes`.
  private func evict(keeping kept: String, removals: inout Removals, logger: any ControlCoreLogger) {
    let now = Date()
    var live: [Entry] = []
    for entry in entries() where entry.name != kept {
      if let expiry = entry.expiry, expiry > now {
        live.append(entry)
      } else {
        remove(entry, deleting: .later, removals: &removals, logger: logger)
      }
    }
    var total = entries().reduce(0) { $0 + $1.bytes }
    for entry in live where total > maxBytes {
      remove(entry, deleting: .later, removals: &removals, logger: logger)
      total -= entry.bytes
    }
  }

  /// Deletes the trees evicted entries left in the trash. Another process emptying it at the same time is harmless:
  /// each tree is deleted by whichever gets to it.
  func emptyTrash() {
    let fileManager = FileManager.default
    guard let names = try? fileManager.contentsOfDirectory(atPath: trashURL.path) else {
      return
    }
    for name in names {
      try? fileManager.removeItem(at: trashURL.appendingPathComponent(name))
    }
  }

  /// When an evicted entry's tree is deleted.
  private enum TreeDeletion {
    /// Before the removal returns.
    case now
    /// When the trash is next emptied; the tree is renamed into it.
    case later
  }

  private struct Entry {
    let name: String
    let used: Date
    let bytes: Int64
    let expiry: Date?
  }

  /// Every entry, least recently used first.
  private func entries() -> [Entry] {
    let fileManager = FileManager.default
    guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
      return []
    }
    var entries: [Entry] = []
    for identityFile in names where identityFile.hasSuffix(".identity") {
      let name = String(identityFile.dropLast(".identity".count))
      let used = (try? fileManager.attributesOfItem(atPath: identityURL(name).path)[.modificationDate] as? Date) ?? .distantPast
      let expiry = (try? String(contentsOf: expiryURL(name), encoding: .utf8)).flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
      let bytes = recordedBytes(name) ?? measure(name)
      entries.append(Entry(name: name, used: used, bytes: bytes, expiry: expiry))
    }
    return entries.sorted { $0.used < $1.used }
  }

  private func remove(_ entry: Entry, deleting deletion: TreeDeletion, removals: inout Removals, logger: any ControlCoreLogger) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: identityURL(entry.name).path) || fileManager.fileExists(atPath: treeURL(entry.name).path) else {
      return
    }
    let start = ContinuousClock.now
    // The identity goes first, so no reader takes a tree that is being removed for an entry.
    try? fileManager.removeItem(at: identityURL(entry.name))
    try? fileManager.removeItem(at: expiryURL(entry.name))
    try? fileManager.removeItem(at: bytesURL(entry.name))
    if deletion == .now || !moveToTrash(treeURL(entry.name)) {
      try? fileManager.removeItem(at: treeURL(entry.name))
    }
    removals.count += 1
    removals.duration += ContinuousClock.now - start
    logger.info().log("Evicted install cache entry \(entry.name) (\(entry.bytes) bytes)")
  }

  /// Renames `tree` into the trash under a name no other tree takes. `false` when it is not there, or could not be
  /// renamed.
  private func moveToTrash(_ tree: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: tree.path) else {
      return false
    }
    try? FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
    let destination = trashURL.appendingPathComponent("\(tree.lastPathComponent)-\(UUID().uuidString)")
    return rename(tree.path, destination.path) == 0
  }

  static func allocatedBytes(of tree: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(at: tree, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else {
      return 0
    }
    var bytes: Int64 = 0
    for case let file as URL in enumerator {
      bytes += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }
    return bytes
  }
}
