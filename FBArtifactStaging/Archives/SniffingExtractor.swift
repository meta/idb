/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// How an archive that arrived as a stream was unpacked: what its first bytes
/// said it was, and what extracted it.
public struct ExtractionRoute: Equatable, Sendable {

  public enum Extractor: String, Sendable {
    case inProcessTar = "tar_inprocess"
    case bsdTar = "bsdtar"
    /// A zip extracted as it arrived.
    case zipStream = "zip_stream"
    /// A zip extracted from its spooled copy, after extracting it as it arrived failed.
    case zipSpool = "zip_spool"
  }

  public let format: ArchiveFormat
  public let extractor: Extractor

  public init(format: ArchiveFormat, extractor: Extractor) {
    self.format = format
    self.extractor = extractor
  }
}

/// Unpacks a stream by what its first bytes say it is: a zip, compressed or not,
/// as it arrives, and anything else with `tarExtractor`. A file goes to `fileExtractor`.
///
/// A zip records symlinks and permissions only in the central directory at its
/// end, which a reader of the stream never reaches, so a zip stream is spooled as
/// it is extracted and repaired from the spooled copy. A zip the stream reader
/// cannot handle is extracted again from that copy with `fileExtractor`.
public struct SniffingExtractor: ArchiveExtractor {

  private let fileExtractor: any ArchiveExtractor
  private let tarExtractor: any ArchiveExtractor
  private let gzippedTarExtractor: any ArchiveExtractor

  /// Streamed zips and zstd tars are always read in-process; `tars` reads plain tars and, unless `gzippedTars` is
  /// given, gzipped ones.
  public init(files fileExtractor: any ArchiveExtractor, tars tarExtractor: any ArchiveExtractor, gzippedTars: (any ArchiveExtractor)? = nil) {
    self.fileExtractor = fileExtractor
    self.tarExtractor = tarExtractor
    self.gzippedTarExtractor = gzippedTars ?? tarExtractor
  }

  public func extract(
    fromFile path: String,
    to extractPath: String,
    options: ArchiveExtractOptions,
    logger: any ControlCoreLogger
  ) async throws {
    switch Self.format(ofFileAt: path) {
    case .zstd, .zstdZip:
      // `bsdtar` on macOS cannot decompress zstd, so a zstd file is read as the stream it holds.
      let descriptor = unsafe open(path, O_RDONLY | O_CLOEXEC)
      guard descriptor >= 0 else {
        throw POSIXError.current
      }
      defer { close(descriptor) }
      try await extract(from: FileDescriptorSource(descriptor), to: extractPath, options: options, logger: logger)
    case .zip, .gzip, .other, .undetermined, nil:
      try await fileExtractor.extract(fromFile: path, to: extractPath, options: options, logger: logger)
    }
  }

  /// Nothing for a file that cannot be read, which the file extractor reports as it would any other.
  private static func format(ofFileAt path: String) -> ArchiveFormat? {
    guard let handle = FileHandle(forReadingAtPath: path) else {
      return nil
    }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: ArchiveFormat.sniffLength)).map(ArchiveFormat.detect)
  }

  public func extract(
    from source: any ByteSource,
    to extractPath: String,
    options: ArchiveExtractOptions,
    logger: any ControlCoreLogger
  ) async throws {
    let spoolDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: spoolDirectory) }
    try await extract(from: source, spoolingIn: spoolDirectory, to: extractPath, options: options, logger: logger) { _ in }
  }

  /// Spools a zip into `spoolDirectory`, and calls `onRoute` with each route taken:
  /// the one the first bytes chose, then `zipSpool` if a zip falls back to its spooled copy.
  func extract(
    from source: any ByteSource,
    spoolingIn spoolDirectory: URL,
    to extractPath: String,
    options: ArchiveExtractOptions,
    logger: any ControlCoreLogger,
    onRoute: (ExtractionRoute) -> Void
  ) async throws {
    let peekable = HandedOver(source as? PeekableSource ?? PeekableSource(source))
    let head = try await offCooperativePool { try peekable.value.peek(ArchiveFormat.sniffLength) }.get()
    let format = ArchiveFormat.detect(head)
    switch format {
    case .zip, .zstdZip:
      onRoute(ExtractionRoute(format: format, extractor: .zipStream))
      try await extractZipStream(peekable.value, spoolingIn: spoolDirectory, to: extractPath, options: options, logger: logger) {
        onRoute(ExtractionRoute(format: format, extractor: .zipSpool))
      }
    case .zstd:
      // `bsdtar` on macOS cannot decompress zstd, whichever extractor other tars go to.
      onRoute(ExtractionRoute(format: format, extractor: .inProcessTar))
      try await ArchiveExtractors.inProcessTar.extract(from: peekable.value, to: extractPath, options: options, logger: logger)
    case .gzip, .other, .undetermined:
      let extractor = format == .gzip ? gzippedTarExtractor : tarExtractor
      onRoute(ExtractionRoute(format: format, extractor: extractor is BSDTarExtractor ? .bsdTar : .inProcessTar))
      try await extractor.extract(from: peekable.value, to: extractPath, options: options, logger: logger)
    }
  }

  private func extractZipStream(
    _ source: any ByteSource,
    spoolingIn spoolDirectory: URL,
    to extractPath: String,
    options: ArchiveExtractOptions,
    logger: any ControlCoreLogger,
    onSpoolFallback: () -> Void
  ) async throws {
    let spoolPath = spoolDirectory.appendingPathComponent("archive.zip").path
    let source = HandedOver(source)
    let start = Date()
    let streamed = try await offCooperativePool {
      try Self.spool(source.value, to: spoolPath, extractingTo: extractPath, overrideModificationTime: options.overrideModificationTime)
    }.get()
    do {
      let summary = try streamed.get()
      try ZipCentralDirectory(archiveAtPath: spoolPath).repair(extractedAt: extractPath, overrideModificationTime: options.overrideModificationTime)
      logger.log(summary.description(from: "a zip stream", since: start))
      return
    } catch {
      logger.log("Extracting the spooled zip at \(spoolPath), as extracting it as it arrived failed: \(error)")
    }
    onSpoolFallback()
    ArchiveExtraction.removeContents(of: extractPath)
    try await fileExtractor.extract(fromFile: spoolPath, to: extractPath, options: options, logger: logger)
  }

  /// Reads `source` to its end, extracting it as it goes and writing it,
  /// decompressed, to `spoolPath`. Throws if the spooled zip is incomplete;
  /// whether extracting it as it arrived worked is the result.
  private static func spool(
    _ source: any ByteSource,
    to spoolPath: String,
    extractingTo extractPath: String,
    overrideModificationTime: Bool
  ) throws -> Result<ArchiveExtractionSummary, any Error> {
    do {
      guard FileManager.default.createFile(atPath: spoolPath, contents: nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: spoolPath])
      }
      let file = try FileHandle(forWritingTo: URL(fileURLWithPath: spoolPath))
      defer { try? file.close() }
      let tee = TeeSource(try ZstdSource.ifZstd(source), to: file)
      let streamed = Result {
        try ZipStreamExtractor.extract(from: tee, to: extractPath, overrideModificationTime: overrideModificationTime)
      }
      try tee.drain()
      return streamed
    } catch {
      // Leaves nothing writing to the input blocked on it.
      try? source.drain()
      throw error
    }
  }
}
