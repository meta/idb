/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import os

/// Extracts a complete zip file from its central directory, writing several
/// files at once: an app bundle is tens of thousands of small files, and
/// creating them one after another, as `bsdtar` does, takes about twice as
/// long.
///
/// What it writes matches `bsdtar -xp --no-mac-metadata` of the same file:
/// modes are applied, symlinks are made, and `__MACOSX` and AppleDouble entries
/// for another entry are skipped. The exception is the AppleDouble entry for a
/// symlink, which `bsdtar` writes out as a file, and which is skipped here too.
public enum ZipExtractor {

  @discardableResult
  public static func extract(archiveAtPath archivePath: String, to root: String, overrideModificationTime: Bool = false) throws -> ArchiveExtractionSummary {
    let plan = try Plan(ZipCentralDirectory(archiveAtPath: archivePath).entries)
    let archive = open(archivePath, O_RDONLY | O_CLOEXEC)
    guard archive >= 0 else {
      throw POSIXError.current
    }
    defer { close(archive) }

    for directory in plan.directoriesToCreate {
      try ArchiveExtraction.makeDirectory((root as NSString).appendingPathComponent(directory))
    }
    let width = ArchiveExtraction.writerCount
    let failure = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)
    let written = OSAllocatedUnfairLock(initialState: ArchiveExtractionSummary(files: 0, bytes: 0))
    DispatchQueue.concurrentPerform(iterations: width) { worker in
      for index in stride(from: worker, to: plan.files.count, by: width) {
        guard failure.withLock({ $0 == nil }) else {
          return
        }
        do {
          let file = plan.files[index]
          if try writeFile(file, from: archive, under: root, overrideModificationTime: overrideModificationTime) {
            written.withLock {
              $0.files += 1
              $0.bytes += file.entry.size
            }
          }
        } catch {
          failure.withLock { $0 = $0 ?? error }
        }
      }
    }
    if let error = failure.withLock({ $0 }) {
      throw error
    }
    // Last, so that nothing is written through one.
    for (entry, relative) in plan.symlinks {
      var target = Data()
      try decode(entry, from: archive) { target.append(contentsOf: $0) }
      guard let destination = String(data: target, encoding: .utf8) else {
        throw ArchiveError.corrupt("symlink target of \(relative)")
      }
      guard symlink(destination, (root as NSString).appendingPathComponent(relative)) == 0 else {
        throw POSIXError.current
      }
    }
    // Deepest first, as a directory's mode may deny writing into it, and after
    // everything else, as writing into a directory changes its time.
    for (entry, relative) in plan.directories.sorted(by: { $0.relative.count > $1.relative.count }) {
      let path = (root as NSString).appendingPathComponent(relative)
      if !overrideModificationTime, let modified = entry.modified {
        try ArchiveExtraction.setTimes(ArchiveExtraction.fileTime(modified), on: path)
      }
      if let mode = entry.mode, mode != 0 {
        guard chmod(path, mode & 0o7777) == 0 else {
          throw POSIXError.current
        }
      }
    }
    return written.withLock { $0 }
  }

  // MARK: - Private

  private struct Plan {
    var directories: [(entry: ZipCentralDirectory.Entry, relative: String)] = []
    var files: [(entry: ZipCentralDirectory.Entry, relative: String, appleDoubleCandidate: Bool)] = []
    var symlinks: [(entry: ZipCentralDirectory.Entry, relative: String)] = []
    var directoriesToCreate: [String] = []

    init(_ entries: [ZipCentralDirectory.Entry]) throws {
      let paths = Set(entries.map { ArchiveExtraction.trimmingTrailingSlash($0.path) })
      var create: Set<String> = []
      func createAncestors(of relative: String) {
        var parent = (relative as NSString).deletingLastPathComponent
        while !parent.isEmpty, create.insert(parent).inserted {
          parent = (parent as NSString).deletingLastPathComponent
        }
      }
      for entry in entries {
        let relative = try ZipCentralDirectory.safeRelativePath(entry.path)
        if relative.isEmpty || ArchiveExtraction.isMacMetadata(relative) {
          continue
        }
        guard entry.flags & 1 == 0 else {
          throw ArchiveError.unsupported("\(relative) is encrypted")
        }
        let type = (entry.mode ?? 0) & S_IFMT
        if entry.path.hasSuffix("/") || type == S_IFDIR {
          directories.append((entry, relative))
          create.insert(relative)
          createAncestors(of: relative)
          continue
        }
        guard entry.method == 0 || entry.method == 8 else {
          throw ArchiveError.unsupported("\(relative) uses compression method \(entry.method)")
        }
        switch type {
        case S_IFLNK:
          symlinks.append((entry, relative))
        case S_IFREG, 0:
          files.append((entry, relative, ArchiveExtraction.isAppleDouble(relative, alongside: paths)))
        default:
          throw ArchiveError.unsupported("\(relative) has file type \(type)")
        }
        createAncestors(of: relative)
      }
      directoriesToCreate = create.sorted { $0.count < $1.count }
    }
  }

  /// Returns whether the file was written, rather than skipped as AppleDouble.
  private static func writeFile(
    _ file: (entry: ZipCentralDirectory.Entry, relative: String, appleDoubleCandidate: Bool),
    from archive: Int32,
    under root: String,
    overrideModificationTime: Bool
  ) throws -> Bool {
    let path = (root as NSString).appendingPathComponent(file.relative)
    if file.appleDoubleCandidate {
      var contents = Data()
      try decode(file.entry, from: archive) { contents.append(contentsOf: $0) }
      if contents.starts(with: ArchiveExtraction.appleDoubleMagic) {
        return false
      }
      try write(to: path, entry: file.entry, overrideModificationTime: overrideModificationTime) { output in
        try contents.withUnsafeBytes { try output($0) }
      }
      return true
    }
    try write(to: path, entry: file.entry, overrideModificationTime: overrideModificationTime) { output in
      try decode(file.entry, from: archive, into: output)
    }
    return true
  }

  private static func write(
    to path: String,
    entry: ZipCentralDirectory.Entry,
    overrideModificationTime: Bool,
    contents: ((UnsafeRawBufferPointer) throws -> Void) throws -> Void
  ) throws {
    let fd = try ArchiveExtraction.createFile(path)
    defer { close(fd) }
    try contents { try ArchiveExtraction.writeAll($0, to: fd) }
    let mode = entry.mode.flatMap { $0 & 0o7777 == 0 ? nil : $0 }
    try ArchiveExtraction.finishFile(fd, mode: mode, modified: overrideModificationTime ? nil : entry.modified.map(ArchiveExtraction.fileTime))
  }

  /// Calls `output` with the entry's contents in order, checking their size and CRC.
  private static func decode(_ entry: ZipCentralDirectory.Entry, from archive: Int32, into output: (UnsafeRawBufferPointer) throws -> Void) throws {
    var header = [UInt8](repeating: 0, count: 30)
    guard pread(archive, &header, 30, off_t(entry.localHeaderOffset)) == 30, Data(header).uint32(at: 0) == ZipSignature.localHeader else {
      throw ArchiveError.corrupt("no local header for \(entry.path)")
    }
    let dataOffset = entry.localHeaderOffset + 30 + UInt64(Data(header).uint16(at: 26)) + UInt64(Data(header).uint16(at: 28))
    var decoded: (crc32: UInt32, size: UInt64) = (0, 0)
    if entry.compressedSize > 0 {
      let input = PeekableSource(FileRangeSource(archive, offset: dataOffset, length: entry.compressedSize), capacity: 1 << 20)
      decoded = try ZipEntryData.decode(entry.path, method: entry.method, compressedSize: entry.compressedSize, from: input, into: output)
    }
    guard decoded.size == entry.size, decoded.crc32 == entry.crc32 else {
      throw ArchiveError.corrupt("\(entry.path) does not match its size or CRC")
    }
  }
}
