/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Extracts a zip read forwards as it arrives, from each entry's local header,
/// decoding on the calling thread and writing several files at once.
///
/// Like `bsdtar` reading a pipe, it cannot know what only the central directory
/// at the end records: every entry is written as a regular file or directory
/// with the default mode, and `._` files are kept.
/// `ZipCentralDirectory.repair(extractedAt:)` applies the rest once the whole zip
/// is at hand.
public enum ZipStreamExtractor {

  @discardableResult
  public static func extract(from source: any ByteSource, to root: String, overrideModificationTime: Bool = false) throws -> ArchiveExtractionSummary {
    var reader = Reader(source)
    let writer = ParallelFileWriter(overrideModificationTime: overrideModificationTime)
    var directories: [(path: String, modified: Date?)] = []
    var summary = ArchiveExtractionSummary(files: 0, bytes: 0)
    do {
      var created = ArchiveExtraction.Directories(root: root)
      var seen: Set<String> = []
      while let header = try LocalHeader(reading: &reader) {
        let relative = try ZipCentralDirectory.safeRelativePath(header.path)
        defer { seen.insert(ArchiveExtraction.trimmingTrailingSlash(relative)) }
        if header.path.hasSuffix("/") {
          unsafe try reader.decode(header) { _ in }
          if !relative.isEmpty {
            try created.create(relative)
            directories.append(((root as NSString).appendingPathComponent(relative), header.modified))
          }
          continue
        }
        if ArchiveExtraction.isMacMetadata(relative) {
          unsafe try reader.decode(header) { _ in }
          continue
        }
        // `ditto` puts each file's AppleDouble entry straight after it, so skipping
        // it here saves creating a file that the repair would only remove.
        var appleDoubleCandidate: Data?
        if ArchiveExtraction.isAppleDouble(relative, alongside: seen) {
          var contents = Data()
          unsafe try reader.decode(header) { unsafe contents.append(contentsOf: $0) }
          if contents.starts(with: ArchiveExtraction.appleDoubleMagic) {
            continue
          }
          appleDoubleCandidate = contents
        }
        try created.create((relative as NSString).deletingLastPathComponent)
        var size: UInt64 = 0
        unsafe try writer.write((root as NSString).appendingPathComponent(relative), modified: header.modified.map(ArchiveExtraction.fileTime)) { output in
          guard let contents = appleDoubleCandidate else {
            size = unsafe try reader.decode(header, into: output)
            return
          }
          unsafe try contents.withUnsafeBytes { unsafe try output($0) }
          size = UInt64(contents.count)
        }
        summary.files += 1
        summary.bytes += size
      }
      try reader.drain()
    } catch {
      writer.fail(error)
      // Closing the pipe early would fail the writer, or raise SIGPIPE in it; the
      // fallback extracts the spooled copy, which is only complete at the end anyway.
      try? reader.drain()
    }
    try writer.finish()
    if !overrideModificationTime {
      for (path, modified) in directories.reversed() {
        if let modified {
          try ArchiveExtraction.setTimes(ArchiveExtraction.fileTime(modified), on: path)
        }
      }
    }
    return summary
  }

  // MARK: - Private

  private struct LocalHeader {
    var path: String
    var flags: UInt16
    var method: UInt16
    var crc32: UInt32
    var compressedSize: UInt64
    var size: UInt64
    var zip64 = false
    var modified: Date?

    /// Nil at the central directory, which follows the last entry.
    init?(reading reader: inout Reader) throws {
      guard let signature = try reader.peekSignature() else {
        return nil
      }
      switch signature {
      case ZipSignature.localHeader:
        break
      case ZipSignature.centralDirectoryEntry, ZipSignature.endOfCentralDirectory, ZipSignature.zip64EndOfCentralDirectory:
        return nil
      default:
        throw ArchiveError.corrupt("no local header where one should be")
      }
      let fixed = try reader.read(30)
      let nameLength = Int(fixed.uint16(at: 26))
      let extraLength = Int(fixed.uint16(at: 28))
      let variable = try reader.read(nameLength + extraLength)
      guard let path = String(data: variable.prefix(nameLength), encoding: .utf8) else {
        throw ArchiveError.unsupported("an entry name that is not UTF-8")
      }
      self.path = path
      flags = fixed.uint16(at: 6)
      method = fixed.uint16(at: 8)
      crc32 = fixed.uint32(at: 14)
      compressedSize = UInt64(fixed.uint32(at: 18))
      size = UInt64(fixed.uint32(at: 22))
      modified = ZipCentralDirectory.dosDate(date: fixed.uint16(at: 12), time: fixed.uint16(at: 10))
      guard flags & 1 == 0 else {
        throw ArchiveError.unsupported("\(path) is encrypted")
      }
      guard method == 0 || method == 8 else {
        throw ArchiveError.unsupported("\(path) uses compression method \(method)")
      }
      // A stored entry's end can only be found from its size.
      guard method == 8 || flags & 8 == 0 else {
        throw ArchiveError.unsupported("\(path) is stored with its size after it")
      }
      try applyExtraFields(Data(variable.suffix(extraLength)))
    }

    private mutating func applyExtraFields(_ extra: Data) throws {
      var offset = 0
      while offset + 4 <= extra.count {
        let id = extra.uint16(at: offset)
        let size = Int(extra.uint16(at: offset + 2))
        let data = offset + 4
        guard data + size <= extra.count else {
          throw ArchiveError.corrupt("\(path) has a truncated extra field")
        }
        switch id {
        case 0x0001 where size >= 16:
          // In a local header, both sizes are present, uncompressed first.
          zip64 = true
          self.size = extra.uint64(at: data)
          compressedSize = extra.uint64(at: data + 8)
        default:
          modified = ZipCentralDirectory.modified(fromExtraField: id, in: extra, at: data, size: size) ?? modified
        }
        offset = data + size
      }
    }
  }

  private struct Reader {
    private let input: PeekableSource

    init(_ source: any ByteSource) {
      input = PeekableSource(source, capacity: 1 << 20)
    }

    private mutating func ensure(_ count: Int) throws {
      guard try input.buffer(atLeast: count) else {
        throw ArchiveError.corrupt("the zip ends early")
      }
    }

    /// Nil at the end of the input.
    mutating func peekSignature() throws -> UInt32? {
      guard try input.buffer(atLeast: 4) else {
        return nil
      }
      return unsafe input.withAvailable { unsafe Data($0[0..<4]) }.uint32(at: 0)
    }

    mutating func read(_ count: Int) throws -> Data {
      try ensure(count)
      defer { input.consume(count) }
      return unsafe input.withAvailable { unsafe Data($0[0..<count]) }
    }

    mutating func drain() throws {
      try input.drain()
    }

    /// Calls `output` with the entry's contents in order, checking their size and
    /// CRC, and returns their size.
    @discardableResult
    mutating func decode(_ header: LocalHeader, into output: (UnsafeRawBufferPointer) throws -> Void) throws -> UInt64 {
      let decoded = unsafe try ZipEntryData.decode(header.path, method: header.method, compressedSize: header.compressedSize, from: input, into: output)
      var expected = (crc32: header.crc32, size: header.size)
      if header.flags & 8 != 0 {
        if try peekSignature() == ZipSignature.dataDescriptor {
          input.consume(4)
        }
        let width = header.zip64 ? 8 : 4
        let descriptor = try read(4 + 2 * width)
        expected = (descriptor.uint32(at: 0), header.zip64 ? descriptor.uint64(at: 12) : UInt64(descriptor.uint32(at: 8)))
      }
      guard decoded.size == expected.size, decoded.crc32 == expected.crc32 else {
        throw ArchiveError.corrupt("\(header.path) does not match its size or CRC")
      }
      return decoded.size
    }
  }
}
