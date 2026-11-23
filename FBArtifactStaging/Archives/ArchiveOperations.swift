/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import os

public let BSDTarPath = "/usr/bin/bsdtar"

/// The compression types available.
public enum CompressionFormat: UInt, Sendable {
  case GZIP = 1
  case ZSTD = 2
}

/// Operations on zip/tar archives.
public enum ArchiveOperations {

  /// A tar made by macOS `tar` carries an AppleDouble entry per file (e.g. for the
  /// `com.apple.provenance` xattr). Restoring them roughly triples extraction time and nothing
  /// in an app bundle's signature depends on them.
  private static let NoMacMetadataFlag = "--no-mac-metadata"

  /// Builds a command to extract from a file on disk.
  static func commandToExtractArchive(
    atPath path: String,
    toPath extractPath: String,
    overrideModificationTime overrideMTime: Bool,
    debugLogging: Bool
  ) -> [String] {
    let flags = flagStringForExtraction(overrideModificationTime: overrideMTime, debugLogging: debugLogging)
    return [flags, NoMacMetadataFlag, "-C", extractPath, "-f", path]
  }

  /// Extracts a tar or zip file archive to a directory. The file can be an uncompressed tar, a
  /// gzipped tar, or a zip.
  static func extractArchive(
    atPath path: String,
    toPath extractPath: String,
    overrideModificationTime overrideMTime: Bool,
    logger: any ControlCoreLogger
  ) async throws -> String {
    let arguments = commandToExtractArchive(
      atPath: path,
      toPath: extractPath,
      overrideModificationTime: overrideMTime,
      debugLogging: false)
    _ = try await Subprocess(executable: BSDTarPath, arguments: arguments)
      .run(output: .logger(logger.debug()), error: .loggerCapturingErrorMessage(logger.debug()), logger: logger)
    return extractPath
  }

  /// Builds a command to extract via stdin.
  static func commandToExtractFromStdIn(
    withExtractPath extractPath: String,
    overrideModificationTime overrideMTime: Bool,
    debugLogging: Bool
  ) -> [String] {
    let flags = flagStringForExtraction(overrideModificationTime: overrideMTime, debugLogging: debugLogging)
    return [flags, NoMacMetadataFlag, "-C", extractPath, "-f", "-"]
  }

  /// Extracts a tar or zip read from `source` to a directory. The stream can be an uncompressed tar, a
  /// gzipped tar, or a zip.
  static func extractArchive(
    from source: any ByteSource,
    toPath extractPath: String,
    overrideModificationTime overrideMTime: Bool,
    logger: any ControlCoreLogger
  ) async throws {
    let arguments = commandToExtractFromStdIn(
      withExtractPath: extractPath,
      overrideModificationTime: overrideMTime,
      debugLogging: false)
    try await run(Subprocess(executable: BSDTarPath, arguments: arguments), output: .logger(logger.debug()), reading: source, logger: logger)
  }

  /// Decompresses a gzip read from `source` to a single file. A plain gzip wrapping a single file is
  /// preferred when there's only a single file to transfer.
  static func extractGzip(
    from source: any ByteSource,
    toPath extractPath: String
  ) async throws {
    let source = HandedOver(source)
    try await offCooperativePool {
      do {
        let file = try ArchiveExtraction.createFile(extractPath)
        defer { close(file) }
        let gzip = try GzipSource(source.value)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
          let count = try buffer.withUnsafeMutableBytes { unsafe try gzip.read(into: $0) }
          guard count > 0 else {
            break
          }
          try buffer.withUnsafeBytes { unsafe try ArchiveExtraction.writeAll(UnsafeRawBufferPointer(rebasing: $0[0..<count]), to: file) }
        }
        try gzip.drain()
      } catch {
        // Leaves nothing writing to the input blocked on it.
        try? source.value.drain()
        throw error
      }
    }.get()
  }

  /// Runs `subprocess` reading `source` on its standard input. Fails on an unsuccessful exit, and
  /// otherwise if the child stopped reading before `source` ended.
  private static func run<Out>(
    _ subprocess: Subprocess,
    output: Subprocess.Output<Out>,
    reading source: any ByteSource,
    logger: any ControlCoreLogger
  ) async throws {
    let writer = StandardInputWriter()
    let standardError = AccumulatingBuffer(capacity: Subprocess.errorMessageLength)
    let source = HandedOver(source)
    async let written = offCooperativePool { try writer.write(from: source.value) }
    do {
      let completed = try await subprocess.run(
        output: output,
        error: .consumer(CompositeDataConsumer(consumers: [standardError, LoggingDataConsumer(logger: logger.debug())])),
        input: .source(writer.input),
        exitPolicy: .any,
        logger: logger)
      try completed.checkExitedCleanly { code in
        ArchiveError.extractorFailed(
          exitCode: code, standardError: String(decoding: standardError.data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
      }
    } catch {
      // The writer reads `source`, which the caller may close once this returns.
      writer.stop()
      // A source that fails ends the child's input early, so the child fails too; the source's failure is the cause.
      if case .failure(let failure as StandardInputWriter.SourceFailure) = await written {
        throw failure.underlying
      }
      throw error
    }
    do {
      try await written.get()
    } catch let failure as StandardInputWriter.SourceFailure {
      throw failure.underlying
    }
  }

  /// Gzips the file at `path`, returning the compressed data.
  public static func createGzipData(
    forPath path: String,
    logger: any ControlCoreLogger
  ) async throws -> Data {
    try await readToEnd {
      let descriptor = unsafe open(path, O_RDONLY | O_CLOEXEC)
      guard descriptor >= 0 else {
        throw ArchiveCreationError.unreadable(atPath: path)
      }
      let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      return (try GzippingSource(FileDescriptorSource(descriptor)), file)
    }
  }

  /// A gzip that writes the compressed file at `path` to its stdout, for the caller to launch and stream.
  public static func gzipSubprocess(forPath path: String) -> Subprocess {
    Subprocess(executable: "/usr/bin/gzip", arguments: ["--to-stdout", path])
  }

  /// A bsdtar that writes a gzipped tar of `path` to its stdout, for the caller to launch and stream.
  public static func gzippedTarSubprocess(
    forPath path: String,
    logger: any ControlCoreLogger
  ) throws -> Subprocess {
    Subprocess(executable: BSDTarPath, arguments: try gzippedTarArguments(forPath: path, logger: logger))
  }

  /// Creates a gzipped tar archive, returning the data of the tar.
  public static func createGzippedTarData(
    forPath path: String,
    logger: any ControlCoreLogger
  ) async throws -> Data {
    try await readToEnd { (try gzippedTar(forPath: path, logger: logger), nil) }
  }

  /// A gzipped tar of a file or directory, laid out as `createGzippedTar` lays it out, written as it is read.
  public static func gzippedTar(forPath path: String, logger: any ControlCoreLogger) throws -> any ByteSource {
    _ = try archiveRoot(forPath: path, logger: logger)
    return try GzippingSource(TarSource(path: path))
  }

  /// Reads a source to its end off the cooperative pool. `owner` is whatever must outlive the reads, such as the
  /// handle whose descriptor the source reads.
  private static func readToEnd(_ makeSource: @escaping () throws -> (any ByteSource, AnyObject?)) async throws -> Data {
    try await offCooperativePool {
      let (source, owner) = try makeSource()
      var data = Data()
      var chunk = [UInt8](repeating: 0, count: 1 << 16)
      while true {
        let count = try chunk.withUnsafeMutableBytes { unsafe try source.read(into: $0) }
        guard count > 0 else {
          break
        }
        data.append(contentsOf: chunk[..<count])
      }
      withExtendedLifetime(owner) {}
      return data
    }.get()
  }

  private static func flagStringForExtraction(overrideModificationTime overrideMTime: Bool, debugLogging: Bool) -> String {
    var flags = ["z", "x", "p"]
    if overrideMTime {
      flags.append("m")
    }
    if debugLogging {
      flags.append("v")
    }
    return "-\(flags.joined())"
  }

  /// A directory is tarred with itself as the root; a file is tarred relative to its parent.
  private static func gzippedTarArguments(forPath path: String, logger: any ControlCoreLogger) throws -> [String] {
    let (directory, fileName) = try archiveRoot(forPath: path, logger: logger)
    return ["-zvc", "-f", "-", "-C", directory, fileName]
  }

  private static func archiveRoot(forPath path: String, logger: any ControlCoreLogger) throws -> (directory: String, fileName: String) {
    var isDirectory: ObjCBool = false
    guard unsafe FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
      throw ArchiveCreationError.pathDoesNotExist(path: path)
    }

    let directory: String
    let fileName: String
    if isDirectory.boolValue {
      directory = path
      fileName = "."
      logger.info().log("\(directory) is a directory, tarring with it as the root.")
      if (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty ?? true {
        logger.info().log("Attempting to tar directory at path \(path), but it has no contents")
      }
    } else {
      directory = (path as NSString).deletingLastPathComponent
      fileName = (path as NSString).lastPathComponent
      logger.info().log("\(path) is a file, tarring relative to it's parent \(directory)")
      let fileSize = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt ?? 0
      if fileSize <= 0 {
        logger.info().log("Attempting to tar file at path \(path), but it has no content")
      }
    }
    return (directory, fileName)
  }
}

/// Copies a source into a child's standard input, reading the next chunk only once the child has
/// taken the last, so a child that reads slowly slows the source rather than filling memory.
private final class StandardInputWriter: Sendable {

  let input = InputSource()
  private let stopped = OSAllocatedUnfairLock(initialState: false)

  /// What `source` threw, as distinct from the child refusing what was written to it.
  struct SourceFailure: Error {
    let underlying: any Error
  }

  /// Blocks its thread until `source` ends, the child stops reading, or `stop()` is called.
  func write(from source: any ByteSource) throws {
    defer { input.finish() }
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    while !stopped.withLock({ $0 }) {
      let count: Int
      do {
        count = try chunk.withUnsafeMutableBytes { unsafe try source.read(into: $0) }
      } catch {
        throw SourceFailure(underlying: error)
      }
      guard count > 0 else {
        return
      }
      try Self.wait { [input, data = Data(chunk[..<count])] in
        try await input.writeAndWait(data)
      }
    }
  }

  /// Ends the child's input after the chunk being written.
  func stop() {
    stopped.withLock { $0 = true }
    input.finish()
  }

  private static func wait(_ operation: @escaping @Sendable () async throws -> Void) throws {
    let finished = DispatchSemaphore(value: 0)
    let result = OSAllocatedUnfairLock<Result<Void, any Error>>(initialState: .success(()))
    Task {
      do {
        try await operation()
      } catch {
        result.withLock { $0 = .failure(error) }
      }
      finished.signal()
    }
    finished.wait()
    try result.withLock { $0 }.get()
  }
}
