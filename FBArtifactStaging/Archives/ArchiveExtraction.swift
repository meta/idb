/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// What an in-process extractor wrote.
public struct ArchiveExtractionSummary: Equatable, Sendable {
  public var files: Int
  public var bytes: UInt64

  func description(from source: String, since start: Date) -> String {
    unsafe "Extracted \(files) files, \(bytes) bytes, from \(source) in-process in \(String(format: "%.2f", Date().timeIntervalSince(start)))s"
  }
}

/// The file system work shared by the in-process extractors.
enum ArchiveExtraction {

  /// Creating a small file is mostly waiting, on the file system and on any
  /// endpoint security agent inspecting it, rather than work for a core.
  static let writerCount = 8

  static func makeDirectory(_ path: String) throws {
    if unsafe mkdir(path, 0o755) == 0 {
      return
    }
    let error = POSIXError.current
    var info = stat()
    guard error.code == .EEXIST, unsafe lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
      throw error
    }
  }

  /// Exclusive: an archive naming a path twice is left to an extractor with an opinion on it.
  static func createFile(_ path: String) throws -> Int32 {
    let fd = unsafe open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard fd >= 0 else {
      throw POSIXError.current
    }
    return fd
  }

  static func writeAll(_ buffer: UnsafeRawBufferPointer, to fd: Int32) throws {
    guard let base = buffer.baseAddress else {
      return
    }
    var offset = 0
    while offset < buffer.count {
      let written = unsafe Darwin.write(fd, base + offset, buffer.count - offset)
      guard written > 0 else {
        throw POSIXError.current
      }
      offset += written
    }
  }

  /// Gives a written file its entry's metadata. Extended attributes are best effort, as for `bsdtar`: some are the system's to set.
  static func finishFile(_ fd: Int32, mode: mode_t?, modified: timespec?, extendedAttributes: [String: Data] = [:]) throws {
    for (name, value) in extendedAttributes {
      _ = unsafe value.withUnsafeBytes { unsafe fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }
    }
    if let mode {
      guard fchmod(fd, mode & 0o7777) == 0 else {
        throw POSIXError.current
      }
    }
    if let modified {
      let times = [modified, modified]
      guard unsafe futimens(fd, times) == 0 else {
        throw POSIXError.current
      }
    }
  }

  static func setTimes(_ modified: timespec, on path: String, flags: Int32 = 0) throws {
    let times = [modified, modified]
    guard unsafe utimensat(AT_FDCWD, path, times, flags) == 0 else {
      throw POSIXError.current
    }
  }

  static func fileTime(_ date: Date) -> timespec {
    let seconds = date.timeIntervalSince1970.rounded(.down)
    return timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000))
  }

  static func isMacMetadata(_ relative: String) -> Bool {
    relative == "__MACOSX" || relative.hasPrefix("__MACOSX/")
  }

  static let appleDoubleMagic = Data([0x00, 0x05, 0x16, 0x07])

  /// A `._` name, which `bsdtar` reads as the metadata of the entry it names.
  static func isAppleDoubleName(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    return name.hasPrefix("._") && name.count > 2
  }

  /// A `._` entry whose named entry is also in the archive.
  static func isAppleDouble(_ path: String, alongside paths: Set<String>) -> Bool {
    let name = (path as NSString).lastPathComponent
    guard name.hasPrefix("._") else {
      return false
    }
    return paths.contains(((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(String(name.dropFirst(2))))
  }

  static func trimmingTrailingSlash(_ path: String) -> String {
    path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  /// Clears a failed extraction before the next extractor writes into the same place.
  /// Best effort: whatever cannot be removed is overwritten, or fails that extractor with its own error.
  static func removeContents(of directory: String) {
    for item in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
      try? FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent(item))
    }
  }

  /// Makes the directories entries are written into, each once, as an archive read forwards names them.
  struct Directories {
    let root: String
    private var created: Set<String> = []

    init(root: String) {
      self.root = root
    }

    mutating func create(_ relative: String) throws {
      guard !relative.isEmpty, !created.contains(relative) else {
        return
      }
      try create((relative as NSString).deletingLastPathComponent)
      try makeDirectory((root as NSString).appendingPathComponent(relative))
      created.insert(relative)
    }
  }
}

extension POSIXError {
  static var current: POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
