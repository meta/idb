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
  /// free space on the cache's volume than the cache must leave.
  case skippedLowDisk = "skipped_low_disk"
  /// The application was downloaded and not kept: the response gave no explicit freshness lifetime, or forbade reuse.
  case notCacheable = "not_cacheable"
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

  private func identityURL(_ name: String) -> URL {
    directory.appendingPathComponent("\(name).identity")
  }

  /// The file holding when the entry stops being fresh, in seconds since 1970.
  private func expiryURL(_ name: String) -> URL {
    directory.appendingPathComponent("\(name).expires")
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
  func store(_ tree: URL, as identity: String, freshness: HTTPFreshness?, logger: any ControlCoreLogger) -> DownloadCacheOutcome {
    guard let lifetime = freshness?.lifetime else {
      return .notCacheable
    }
    let fileManager = FileManager.default
    let name = Self.name(of: identity)
    // The tree is removed once the install returns, so a kept clone ends up owning all of its blocks.
    guard makeRoom(for: Self.allocatedBytes(of: tree), logger: logger) else {
      logger.info().log("Not keeping \(tree.path) in the install cache: its volume would have less than \(minFreeBytes) bytes free")
      return .skippedLowDisk
    }
    let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      // This store follows a miss, so an entry already under this name has expired, or never held this identity;
      // left in place, the rename below would keep its tree.
      if !contains(identity) {
        remove(Entry(name: name, used: .distantPast, bytes: 0, expiry: nil), logger: logger)
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
        evict(keeping: name, logger: logger)
        return .stored
      }
      // The expiry goes last: an entry is fresh only once its tree is in place.
      try String(Date().addingTimeInterval(lifetime).timeIntervalSince1970).write(to: expiryURL(name), atomically: true, encoding: .utf8)
    } catch {
      try? fileManager.removeItem(at: staging)
      logger.info().log("Could not keep \(tree.path) in the install cache: \(error)")
      return .storeFailed
    }
    evict(keeping: name, logger: logger)
    return .stored
  }

  /// Evicts the least recently used entries until storing `bytes` more would leave `minFreeBytes` free on the cache's
  /// volume. `false` if it still would not, or the free space can't be read.
  private func makeRoom(for bytes: Int64, logger: any ControlCoreLogger) -> Bool {
    guard var free = freeBytes(directory) else {
      return false
    }
    for entry in entries() where free - bytes < minFreeBytes {
      remove(entry, logger: logger)
      // Only what the removal actually freed: whatever it could not delete still takes space.
      free += entry.bytes - Self.allocatedBytes(of: treeURL(entry.name))
    }
    return free - bytes >= minFreeBytes
  }

  /// Removes every expired entry, then the least recently used ones, never `keeping`, until the cache fits in `maxBytes`.
  private func evict(keeping kept: String, logger: any ControlCoreLogger) {
    let now = Date()
    var live: [Entry] = []
    for entry in entries() where entry.name != kept {
      if let expiry = entry.expiry, expiry > now {
        live.append(entry)
      } else {
        remove(entry, logger: logger)
      }
    }
    var total = entries().reduce(0) { $0 + $1.bytes }
    for entry in live where total > maxBytes {
      remove(entry, logger: logger)
      total -= entry.bytes
    }
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
      entries.append(Entry(name: name, used: used, bytes: Self.allocatedBytes(of: treeURL(name)), expiry: expiry))
    }
    return entries.sorted { $0.used < $1.used }
  }

  private func remove(_ entry: Entry, logger: any ControlCoreLogger) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: identityURL(entry.name).path) || fileManager.fileExists(atPath: treeURL(entry.name).path) else {
      return
    }
    // The identity goes first, so no reader takes a tree that is being removed for an entry.
    try? fileManager.removeItem(at: identityURL(entry.name))
    try? fileManager.removeItem(at: expiryURL(entry.name))
    try? fileManager.removeItem(at: treeURL(entry.name))
    logger.info().log("Evicted install cache entry \(entry.name) (\(entry.bytes) bytes)")
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
