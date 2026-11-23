/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// A tar of a file or a directory tree, read as it is written so no more than a header and a buffer are ever held.
///
/// Laid out as `bsdtar -c -C <parent> <name>` and `bsdtar -c -C <directory> .` lay it out, so extraction is unchanged:
/// a directory is archived as `./` with its entries beneath it, a file by its name alone, and a file reached again
/// through a hard link as a link to the first name. macOS metadata (extended attributes, AppleDouble members) is not
/// written, as nothing extracting an archive the companion sends restores it.
final class TarSource: ByteSource {

  private struct Node {
    let name: String
    let path: String
  }

  private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
  }

  private struct OpenFile {
    let descriptor: Int32
    let path: String
    var remaining: Int
    let padding: Int
  }

  private static let blockSize = 512
  /// The largest size an octal header field holds; anything larger is carried in a pax record.
  private static let largestOctalSize = 0o77777777777

  private var pending: [Node]
  private var hardLinks: [FileIdentity: String] = [:]
  private var output: [UInt8] = []
  private var outputStart = 0
  private var file: OpenFile?
  private var trailerWritten = false
  private var rootPending: Bool

  /// A directory, followed if `path` is a symlink to one, is archived as `./`; anything else by its last path component.
  init(path: String) {
    var isDirectory: ObjCBool = false
    if unsafe FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
      pending = [Node(name: "./", path: path)]
      rootPending = true
    } else {
      pending = [Node(name: (path as NSString).lastPathComponent, path: path)]
      rootPending = false
    }
  }

  deinit {
    if let file {
      close(file.descriptor)
    }
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    var written = 0
    while written < buffer.count {
      if outputStart < output.count {
        let count = min(output.count - outputStart, buffer.count - written)
        output.withUnsafeBytes { output in
          unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[written..<written + count]).copyMemory(from: UnsafeRawBufferPointer(rebasing: output[outputStart..<outputStart + count]))
        }
        outputStart += count
        written += count
        continue
      }
      if var current = file {
        let count = unsafe try readFile(&current, into: UnsafeMutableRawBufferPointer(rebasing: buffer[written...]))
        written += count
        file = current
        if current.remaining == 0 {
          close(current.descriptor)
          file = nil
          emit([UInt8](repeating: 0, count: current.padding))
        }
        continue
      }
      if let node = pending.popLast() {
        try archive(node)
        continue
      }
      guard !trailerWritten else {
        break
      }
      trailerWritten = true
      emit([UInt8](repeating: 0, count: 2 * Self.blockSize))
    }
    return written
  }

  // MARK: - Entries

  private func archive(_ node: Node) throws {
    var status = stat()
    let isRoot = rootPending
    rootPending = false
    // The root directory is followed through a symlink, as `-C <directory> .` follows it; everything beneath is not.
    guard unsafe (isRoot ? stat(node.path, &status) : lstat(node.path, &status)) == 0 else {
      throw ArchiveCreationError.unreadable(atPath: node.path)
    }
    let mode = Int(status.st_mode) & 0o7777
    let modificationTime = max(0, Int(status.st_mtimespec.tv_sec))
    switch status.st_mode & S_IFMT {
    case S_IFDIR:
      let name = node.name.hasSuffix("/") ? node.name : node.name + "/"
      emitHeader(name: name, type: "5", mode: mode, status: status, modificationTime: modificationTime)
      let children = try Self.children(ofDirectory: node.path)
      pending.append(contentsOf: children.reversed().map { Node(name: name + $0, path: (node.path as NSString).appendingPathComponent($0)) })
    case S_IFLNK:
      let target = try FileManager.default.destinationOfSymbolicLink(atPath: node.path)
      emitHeader(name: node.name, type: "2", mode: mode, status: status, modificationTime: modificationTime, linkTarget: target)
    case S_IFREG:
      let identity = FileIdentity(device: status.st_dev, inode: status.st_ino)
      if status.st_nlink > 1 {
        if let first = hardLinks[identity] {
          emitHeader(name: node.name, type: "1", mode: mode, status: status, modificationTime: modificationTime, linkTarget: first)
          return
        }
        hardLinks[identity] = node.name
      }
      let size = Int(status.st_size)
      emitHeader(name: node.name, type: "0", mode: mode, status: status, modificationTime: modificationTime, size: size)
      guard size > 0 else {
        return
      }
      let descriptor = unsafe open(node.path, O_RDONLY | O_CLOEXEC)
      guard descriptor >= 0 else {
        throw ArchiveCreationError.unreadable(atPath: node.path)
      }
      file = OpenFile(descriptor: descriptor, path: node.path, remaining: size, padding: Self.padding(size))
    case S_IFIFO:
      emitHeader(name: node.name, type: "6", mode: mode, status: status, modificationTime: modificationTime)
    default:
      // Sockets and devices cannot be extracted anywhere an archive the companion sends is used.
      return
    }
  }

  private static func children(ofDirectory path: String) throws -> [String] {
    guard let directory = unsafe opendir(path) else {
      throw ArchiveCreationError.unreadable(atPath: path)
    }
    defer { unsafe closedir(directory) }
    var children: [String] = []
    while true {
      // `readdir` returns nil at the end and on failure alike, telling them apart only by `errno`.
      errno = 0
      guard let entry = unsafe readdir(directory) else {
        guard errno == 0 else {
          throw ArchiveCreationError.unreadable(atPath: path)
        }
        return children.sorted()
      }
      let name = unsafe withUnsafeBytes(of: entry.pointee.d_name) { unsafe String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
      if name != "." && name != ".." {
        children.append(name)
      }
    }
  }

  private func readFile(_ file: inout OpenFile, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    let wanted = min(file.remaining, buffer.count)
    while true {
      let count = unsafe Darwin.read(file.descriptor, buffer.baseAddress, wanted)
      if count > 0 {
        file.remaining -= count
        return count
      }
      if count == 0 {
        // The header already carries the size, so a file that shrinks while it is read cannot be archived.
        throw ArchiveCreationError.fileChangedWhileArchiving(path: file.path)
      }
      guard errno == EINTR else {
        throw ArchiveCreationError.unreadable(atPath: file.path)
      }
    }
  }

  // MARK: - Headers

  private func emitHeader(name: String, type: Character, mode: Int, status: stat, modificationTime: Int, size: Int = 0, linkTarget: String = "") {
    var records: [(String, String)] = []
    if name.utf8.count > 100 {
      records.append(("path", name))
    }
    if linkTarget.utf8.count > 100 {
      records.append(("linkpath", linkTarget))
    }
    if size > Self.largestOctalSize {
      records.append(("size", String(size)))
    }
    if !records.isEmpty {
      let body = Self.paxBody(records)
      let paxName = "./PaxHeader/" + String(decoding: (name as NSString).lastPathComponent.utf8.prefix(80), as: UTF8.self)
      emit(Self.header(name: paxName, type: "x", mode: 0o644, uid: 0, gid: 0, size: body.count, modificationTime: modificationTime, linkTarget: ""))
      emit(body + [UInt8](repeating: 0, count: Self.padding(body.count)))
    }
    emit(Self.header(name: name, type: type, mode: mode, uid: Int(status.st_uid), gid: Int(status.st_gid), size: min(size, Self.largestOctalSize), modificationTime: modificationTime, linkTarget: linkTarget))
  }

  private func emit(_ bytes: [UInt8]) {
    if outputStart == output.count {
      output = bytes
      outputStart = 0
    } else {
      output.append(contentsOf: bytes)
    }
  }

  private static func header(name: String, type: Character, mode: Int, uid: Int, gid: Int, size: Int, modificationTime: Int, linkTarget: String) -> [UInt8] {
    var header = [UInt8](repeating: 0, count: blockSize)
    func field(_ offset: Int, _ length: Int, _ bytes: some Sequence<UInt8>) {
      for (index, byte) in bytes.prefix(length).enumerated() {
        header[offset + index] = byte
      }
    }
    func octal(_ offset: Int, _ length: Int, _ value: Int) {
      let digits = String(value, radix: 8)
      field(offset, length - 1, (String(repeating: "0", count: max(0, length - 1 - digits.count)) + digits).utf8)
    }
    field(0, 100, name.utf8)
    octal(100, 8, mode)
    octal(108, 8, min(uid, 0o7777777))
    octal(116, 8, min(gid, 0o7777777))
    octal(124, 12, size)
    octal(136, 12, min(modificationTime, largestOctalSize))
    header[156] = type.asciiValue ?? UInt8(ascii: "0")
    field(157, 100, linkTarget.utf8)
    field(257, 6, "ustar\0".utf8)
    field(263, 2, "00".utf8)
    field(148, 8, "        ".utf8)
    let checksum = header.reduce(0) { $0 + Int($1) }
    octal(148, 7, checksum)
    header[154] = 0
    return header
  }

  /// pax records are `<length> <key>=<value>\n`, where the length counts the whole record, its own digits included.
  private static func paxBody(_ records: [(String, String)]) -> [UInt8] {
    var body: [UInt8] = []
    for (key, value) in records {
      let content = " \(key)=\(value)\n"
      var length = content.utf8.count
      while String(length).utf8.count + content.utf8.count != length {
        length = String(length).utf8.count + content.utf8.count
      }
      body.append(contentsOf: "\(length)\(content)".utf8)
    }
    return body
  }

  private static func padding(_ size: Int) -> Int {
    (blockSize - size % blockSize) % blockSize
  }
}
