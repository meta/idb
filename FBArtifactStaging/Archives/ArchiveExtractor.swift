/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// How to unpack, as opposed to what to unpack.
public struct ArchiveExtractOptions: Sendable {

  /// Discard the modification times recorded in the archive, stamping everything
  /// written with the current time instead.
  public var overrideModificationTime: Bool

  public init(overrideModificationTime: Bool = false) {
    self.overrideModificationTime = overrideModificationTime
  }
}

/// Unpacks an archive into a directory.
///
/// Extraction is behind a protocol so the mechanism can be replaced without any
/// caller changing. A file and a stream are distinct because a file can be seeked,
/// so a format that keeps its index at the end of the archive can be read in full,
/// whereas a stream can only be read forwards.
public protocol ArchiveExtractor: Sendable {

  func extract(
    fromFile path: String,
    to extractPath: String,
    options: ArchiveExtractOptions,
    logger: any ControlCoreLogger
  ) async throws

  /// Extracts what `source` reads, which is already open and may already have been read from.
  func extract(
    from source: any ByteSource,
    to extractPath: String,
    options: ArchiveExtractOptions,
    logger: any ControlCoreLogger
  ) async throws
}

/// Unpacks by running `bsdtar` as a subprocess, reading either a file it is
/// pointed at or its own stdin.
public struct BSDTarExtractor: ArchiveExtractor {

  public init() {}

  public func extract(
    fromFile path: String,
    to extractPath: String,
    options: ArchiveExtractOptions,
    logger: any ControlCoreLogger
  ) async throws {
    _ = try await ArchiveOperations.extractArchive(
      atPath: path,
      toPath: extractPath,
      overrideModificationTime: options.overrideModificationTime,
      logger: logger)
  }

  public func extract(
    from source: any ByteSource,
    to extractPath: String,
    options: ArchiveExtractOptions,
    logger: any ControlCoreLogger
  ) async throws {
    try await ArchiveOperations.extractArchive(
      from: source,
      toPath: extractPath,
      overrideModificationTime: options.overrideModificationTime,
      logger: logger)
  }
}

/// Unpacks a complete zip file in-process with `ZipExtractor`, and anything
/// else, including a zip `ZipExtractor` cannot read, with `fallback`.
/// `extractPath` must start empty: everything in it is removed before `fallback` runs.
public struct InProcessZipExtractor: ArchiveExtractor {

  private let fallback: any ArchiveExtractor

  public init(fallback: any ArchiveExtractor) {
    self.fallback = fallback
  }

  public func extract(
    fromFile path: String,
    to extractPath: String,
    options: ArchiveExtractOptions,
    logger: any ControlCoreLogger
  ) async throws {
    guard Self.isZip(atPath: path) else {
      return try await fallback.extract(fromFile: path, to: extractPath, options: options, logger: logger)
    }
    let start = Date()
    do {
      let summary = try await offCooperativePool {
        try ZipExtractor.extract(archiveAtPath: path, to: extractPath, overrideModificationTime: options.overrideModificationTime)
      }.get()
      logger.log(summary.description(from: path, since: start))
      return
    } catch {
      logger.log("Extracting \(path) again with \(type(of: fallback)), as extracting it in-process failed: \(error)")
    }
    ArchiveExtraction.removeContents(of: extractPath)
    try await fallback.extract(fromFile: path, to: extractPath, options: options, logger: logger)
  }

  /// A zip is read in-process only from a complete file, so a stream goes to `fallback`.
  public func extract(
    from source: any ByteSource,
    to extractPath: String,
    options: ArchiveExtractOptions,
    logger: any ControlCoreLogger
  ) async throws {
    try await fallback.extract(from: source, to: extractPath, options: options, logger: logger)
  }

  private static func isZip(atPath path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else {
      return false
    }
    defer { try? handle.close() }
    return ArchiveFormat.detect((try? handle.read(upToCount: ArchiveFormat.detectableLength)) ?? Data()) == .zip
  }
}

/// Unpacks a tar stream in-process with `TarStreamExtractor`, and anything else
/// with `fallback`. A stream that turns out not to be a tar is passed on to
/// `fallback` as read, already decompressed.
public struct InProcessTarExtractor: ArchiveExtractor {

  private let fallback: any ArchiveExtractor

  public init(fallback: any ArchiveExtractor) {
    self.fallback = fallback
  }

  public func extract(
    fromFile path: String,
    to extractPath: String,
    options: ArchiveExtractOptions,
    logger: any ControlCoreLogger
  ) async throws {
    try await fallback.extract(fromFile: path, to: extractPath, options: options, logger: logger)
  }

  public func extract(
    from source: any ByteSource,
    to extractPath: String,
    options: ArchiveExtractOptions,
    logger: any ControlCoreLogger
  ) async throws {
    let start = Date()
    let source = HandedOver(source)
    let result = await offCooperativePool {
      try TarStreamExtractor.extract(
        from: source.value, to: extractPath,
        overrideModificationTime: options.overrideModificationTime)
    }
    switch try result.get() {
    case .notTar(let read):
      logger.log("Extracting a stream that is not a tar with \(type(of: fallback))")
      try await fallback.extract(from: read, to: extractPath, options: options, logger: logger)
    case .extracted(let summary, let waits):
      logger.log(unsafe "\(summary.description(from: "a tar stream", since: start)), waiting \(String(format: "%.2f", waits.input))s for input and \(String(format: "%.2f", waits.writers))s for writers")
    }
  }
}

/// Runs `work` off the cooperative pool, for work that blocks its thread.
///
/// Each call gets a thread of its own. The global queues run only a bounded number of threads at once, and blocking
/// work there that waits on other blocking work, such as a reader on a pipe whose writer is another call, deadlocks
/// once every one of those threads is waiting.
func offCooperativePool<T>(_ work: @escaping () throws -> T) async -> Result<T, any Error> {
  let work = HandedOver(work)
  return await withCheckedContinuation { (continuation: CheckedContinuation<HandedOver<Result<T, Error>>, Never>) in
    let thread = Thread {
      continuation.resume(returning: HandedOver(Result { try work.value() }))
    }
    thread.qualityOfService = .userInitiated
    thread.start()
  }.value
}

/// A value passed from one thread to another, and used by one at a time.
struct HandedOver<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}

/// The extractors available, and which one is used.
public enum ArchiveExtractors {

  public static let bsdTar: any ArchiveExtractor = BSDTarExtractor()

  public static let inProcessTar: any ArchiveExtractor = InProcessTarExtractor(fallback: bsdTar)

  public static let inProcessZip: any ArchiveExtractor = InProcessZipExtractor(fallback: inProcessTar)

  /// A zip file and every stream in-process, with `bsdtar` for anything they cannot read.
  public static let inProcess = SniffingExtractor(files: inProcessZip, tars: inProcessTar)

  /// The extractor for a stream, unless a caller names another. Its route depends on the archive's first bytes alone,
  /// never on what a client declared. A zip, a zstd zip or a zstd tar can only be read in-process. A plain tar is read
  /// in-process, which is several times faster than `bsdtar` for one. A gzipped tar goes to `bsdtar`, which reads one
  /// from a stream faster than the in-process extractor does for the archive an app usually is, of many files that
  /// compress, though slower for a few large ones. A download, read from a file, is faster in-process throughout.
  public static let `default` = SniffingExtractor(files: inProcessZip, tars: inProcessTar, gzippedTars: bsdTar)
}
