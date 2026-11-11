/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import os

/// Where an artifact to install comes from.
public enum InstallSource {

  /// A path to the artifact itself, which needs no unpacking, or to an archive
  /// containing it.
  case localPath(String)

  /// An artifact or an archive containing it, to fetch over HTTP. With a `ConnectionOverride`, the connection goes
  /// to its address instead of the one the URL's host resolves to.
  case remoteURL(URL, connectingTo: ConnectionOverride? = nil)

  /// An artifact or an archive containing it, which the caller's source reads as
  /// it arrives: a zip or a tar, either of them compressed or not, told apart by
  /// its first bytes. A dylib may also be the file itself, or the file gzipped.
  case stream(any ByteSource)
}

/// How to get from a source to an installable bundle.
public struct InstallOptions: Sendable {

  /// Discard the modification times recorded in the archive.
  public var overrideModificationTime: Bool

  public init(overrideModificationTime: Bool = false) {
    self.overrideModificationTime = overrideModificationTime
  }

  fileprivate var extractOptions: ArchiveExtractOptions {
    ArchiveExtractOptions(overrideModificationTime: overrideModificationTime)
  }
}

/// What staging an install source leaves on disk while its body runs.
enum StagedTree: Sendable {

  /// A directory holding what an archive held, removed once the body returns.
  case extracted(URL)

  /// A single decompressed file, removed once the body returns.
  case file(URL)

  /// The caller's own item, which staging leaves where it is.
  case inPlace(URL)

  var url: URL {
    switch self {
    case .extracted(let url), .file(let url), .inPlace(let url):
      return url
    }
  }

  /// Whether the item outlives the body, so storage can link to it rather than move it.
  var isInPlace: Bool {
    switch self {
    case .inPlace:
      return true
    case .extracted, .file:
      return false
    }
  }
}

/// What staging learned about how it fetched and unpacked a source, beyond the progress of its stages.
enum StagingReport: Equatable, Sendable {
  case route(ExtractionRoute)
  /// A download that completed. One that failed carries its report in its `InstallError.transferFailed`.
  case download(DownloadReport)
  /// What the download cache did for an application from a URL, when there is a cache.
  case cache(DownloadCacheOutcome)
}

/// Everything an install reports as it goes, in order.
public enum InstallEvent: Sendable {
  /// A stage started, made progress or finished. A stage that fails reports no terminal event; the failure is the
  /// thrown error.
  case progress(InstallProgressEvent)
  /// How a streamed or downloaded archive is unpacked, once decided, and again if it changes.
  case route(ExtractionRoute)
  /// A download that completed. One that failed carries its report in its `InstallError.transferFailed`.
  case download(DownloadReport)
  /// What the download cache did for an application from a URL, when there is a cache.
  case cache(DownloadCacheOutcome)
}

/// What an installed artifact is known by on the target, for the install stage's completion.
public protocol InstalledName {
  var installedName: String { get }
}

/// Gets an install source onto disk for every kind of artifact: fetching,
/// decompressing and extracting it into a directory that lives as long as the
/// caller's body, and reporting the extract stage as it goes.
public enum Staging {

  /// Stages `source`, which holds an artifact of `kind`, and calls `body` with what it left on disk.
  ///
  /// `onProgress` reports stages that start and stages that finish. A stage that
  /// fails reports no terminal event; the failure is the thrown error.
  ///
  /// `onReport` reports how a streamed or downloaded archive is unpacked once that is
  /// decided, so a failed extraction has reported it too, and again if it changes.
  static func withMaterialized<T>(
    _ source: InstallSource,
    as kind: ArtifactKind,
    options: InstallOptions = InstallOptions(),
    totalStart: Date = Date(),
    downloadConfiguration: URLSessionConfiguration = .default,
    cache: DownloadCache? = nil,
    temporaryDirectory: TemporaryDirectory,
    logger: any ControlCoreLogger,
    onProgress: @escaping @Sendable (InstallProgressEvent) -> Void = { _ in },
    onReport: @escaping @Sendable (StagingReport) -> Void = { _ in },
    _ body: (StagedTree) async throws -> T
  ) async throws -> T {
    if case .localPath(let path) = source {
      let unpacksPath: Bool
      do {
        unpacksPath = try unpacks(source, as: kind)
      } catch {
        // A file that can't be read can't be identified, here or by anything after.
        throw InstallError.unidentifiable(kind: kind, underlying: error)
      }
      if !unpacksPath {
        return try await body(.inPlace(URL(fileURLWithPath: path)))
      }
    }
    return try await temporaryDirectory.withTemporaryDirectory { stagingDirectory in
      let tree = try await stage(
        source, as: kind, in: stagingDirectory, options: options, totalStart: totalStart,
        downloadConfiguration: downloadConfiguration, cache: cache, temporaryDirectory: temporaryDirectory,
        logger: logger, onProgress: onProgress, onReport: onReport)
      return try await body(tree)
    }
  }

  /// Stages `source`, identifies the artifact of `kind` in it and installs that with `install`, reporting every stage,
  /// how an archive was unpacked and how a download went through `onEvent`.
  ///
  /// `install` is told whether the artifact is in place; one that is not is deleted once `install` returns.
  ///
  /// With a `cache`, an application from a URL is cloned from it when it holds that URL, and kept in it otherwise.
  public static func install<Installed: InstalledName>(
    _ source: InstallSource,
    as kind: ArtifactKind,
    options: InstallOptions = InstallOptions(),
    downloadConfiguration: URLSessionConfiguration = .default,
    cache: DownloadCache? = nil,
    temporaryDirectory: TemporaryDirectory,
    logger: any ControlCoreLogger,
    onEvent: @escaping @Sendable (InstallEvent) -> Void = { _ in },
    _ install: (_ artifact: Artifact, _ inPlace: Bool) async throws -> Installed
  ) async throws -> Installed {
    let totalStart = Date()
    let onProgress: @Sendable (InstallProgressEvent) -> Void = { onEvent(.progress($0)) }
    return try await withMaterialized(
      source, as: kind, options: options, totalStart: totalStart, downloadConfiguration: downloadConfiguration,
      cache: cache, temporaryDirectory: temporaryDirectory, logger: logger, onProgress: onProgress,
      onReport: { report in
        switch report {
        case .route(let route):
          onEvent(.route(route))
        case .download(let download):
          onEvent(.download(download))
        case .cache(let outcome):
          onEvent(.cache(outcome))
        }
      }
    ) { tree in
      let artifact: Artifact
      do {
        artifact = try kind.identify(in: tree, logger: logger)
      } catch let error as InstallError {
        throw error
      } catch {
        // The kinds other than an application identify through storage helpers shared with callers that aren't
        // installing anything, so they report failures unclassified; this is the boundary that knows better.
        throw InstallError.unidentifiable(kind: kind, underlying: error)
      }
      let installStart = Date()
      onProgress(.installStarted(timing: .measure(stageStart: installStart, totalStart: totalStart), artifactPath: artifact.url.path))
      let installed = try await install(artifact, tree.isInPlace)
      onProgress(
        .installCompleted(
          timing: .measure(stageStart: installStart, totalStart: totalStart), artifactPath: artifact.url.path, name: installed.installedName))
      return installed
    }
  }

  /// Extracts the archive `source` reads into a temporary directory that lives as long as `body`, for a payload of files
  /// rather than an artifact, such as a push. The extractor is chosen from the archive's first bytes as an install's is,
  /// a failure is an `InstallError`, and the extract stage and route are reported through `onEvent`.
  public static func extract<T>(
    _ source: any ByteSource,
    temporaryDirectory: TemporaryDirectory,
    logger: any ControlCoreLogger,
    onEvent: @escaping @Sendable (InstallEvent) -> Void = { _ in },
    _ body: (URL) async throws -> T
  ) async throws -> T {
    let totalStart = Date()
    return try await temporaryDirectory.withTemporaryDirectory { directory in
      try await temporaryDirectory.withTemporaryDirectory { spoolDirectory in
        try await runExtractStage(to: directory.path, totalStart: totalStart, onProgress: { onEvent(.progress($0)) }) {
          try await ArchiveExtractors.default.extract(
            from: source, spoolingIn: spoolDirectory, to: directory.path, options: ArchiveExtractOptions(), logger: logger
          ) { onEvent(.route($0)) }
        }
      }
      return try await body(directory)
    }
  }

  /// Whether staging `source` unpacks it. What is unpacked belongs to staging,
  /// which removes it afterwards, so the body may move it away; anything else is
  /// the caller's own, and must be left where it is.
  ///
  /// The same rule for every kind: a directory is the artifact, and so is a file
  /// for a kind whose artifact can be one -- a dylib or a test run -- unless its
  /// first bytes say it is an archive or compressed. Any other file is an archive.
  /// Throws if those first bytes can't be read.
  static func unpacks(_ source: InstallSource, as kind: ArtifactKind) throws -> Bool {
    guard case .localPath(let path) = source else {
      return true
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      return false
    }
    guard kind.canBeAFile else {
      return true
    }
    // Not `FileHandle(forReadingFrom:)`, whose error for an unreadable file says it couldn't be saved.
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      let posix = POSIXError.current
      throw CocoaError(posix.code == .EACCES ? .fileReadNoPermission : .fileReadUnknown, userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: posix])
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let head = (try? handle.read(upToCount: 512)) ?? Data()
    switch ArchiveFormat.detect(head) {
    case .zip, .zstdZip, .zstd, .gzip:
      return true
    case .other:
      return head.count >= 263 && head[head.startIndex + 257..<head.startIndex + 262].elementsEqual(Array("ustar".utf8))
    case .undetermined:
      return false
    }
  }

  // MARK: - Stages

  private static func stage(
    _ source: InstallSource,
    as kind: ArtifactKind,
    in stagingDirectory: URL,
    options: InstallOptions,
    totalStart: Date,
    downloadConfiguration: URLSessionConfiguration,
    cache: DownloadCache?,
    temporaryDirectory: TemporaryDirectory,
    logger: any ControlCoreLogger,
    onProgress: @escaping @Sendable (InstallProgressEvent) -> Void,
    onReport: @escaping @Sendable (StagingReport) -> Void
  ) async throws -> StagedTree {
    let extractPath = stagingDirectory.path
    switch source {
    case .localPath(let path):
      return try await runExtractStage(to: extractPath, totalStart: totalStart, onProgress: onProgress) {
        if case .dylib(let name) = kind {
          let descriptor = open(path, O_RDONLY | O_CLOEXEC)
          guard descriptor >= 0 else {
            throw POSIXError.current
          }
          defer { close(descriptor) }
          if let file = try await stageSingleFile(PeekableSource(FileDescriptorSource(descriptor)), named: name, in: stagingDirectory) {
            return .file(file)
          }
        }
        try await ArchiveExtractors.default.extract(fromFile: path, to: extractPath, options: options.extractOptions, logger: logger)
        return .extracted(stagingDirectory)
      }
    case .stream(let source):
      return try await temporaryDirectory.withTemporaryDirectory { spoolDirectory in
        try await runExtractStage(to: extractPath, totalStart: totalStart, onProgress: onProgress) {
          try await stagePayload(
            source, as: kind, with: ArchiveExtractors.default, in: stagingDirectory, spoolingIn: spoolDirectory,
            options: options, logger: logger, onReport: onReport)
        }
      }
    case .remoteURL(let url, let connectionOverride):
      // Only applications are cached: they are what a client installs from the same URL over and over.
      let cache: DownloadCache? = if case .application = kind { cache } else { nil }
      let identity = DownloadCache.identity(of: url, options: options)
      if let cache, try await offCooperativePool({ cache.contains(identity) }).get() {
        let restored = stagingDirectory.appendingPathComponent("cached")
        let hit = try await runExtractStage(to: restored.path, totalStart: totalStart, onProgress: onProgress) {
          try await offCooperativePool { cache.restore(identity, to: restored, logger: logger) }.get()
        }
        if hit {
          onReport(.cache(.hit))
          return .extracted(restored)
        }
      }
      let freshness = OSAllocatedUnfairLock<HTTPFreshness?>(initialState: nil)
      let tree = try await temporaryDirectory.withTemporaryDirectory { spoolDirectory in
        let staged = OSAllocatedUnfairLock<StagedTree?>(initialState: nil)
        try await download(
          url, connectingTo: connectionOverride, extractingTo: extractPath, totalStart: totalStart,
          configuration: downloadConfiguration, logger: logger, onProgress: onProgress,
          onReport: { report in
            if case .download(let downloaded) = report {
              freshness.withLock { $0 = downloaded.freshness }
            }
            onReport(report)
          }
        ) { spool in
          let tree = try await spool.reading { source in
            try await stagePayload(
              source, as: kind, with: ArchiveExtractors.inProcess, in: stagingDirectory, spoolingIn: spoolDirectory,
              options: options, logger: logger, onReport: onReport)
          }
          staged.withLock { $0 = tree }
        }
        return staged.withLock { $0 } ?? .extracted(stagingDirectory)
      }
      if let cache {
        let lifetime = freshness.withLock { $0 }
        let outcome = try await offCooperativePool { cache.store(tree.url, as: identity, freshness: lifetime, logger: logger) }.get()
        onReport(.cache(outcome))
      }
      return tree
    }
  }

  /// Stages what `source` reads with `extractor`, unless `kind` is a dylib that arrives as a single file. A zip is
  /// spooled into `spoolDirectory` as it is extracted.
  ///
  /// A download is read from its spool, a file the in-process extractors read faster than `bsdtar` whatever the
  /// format, so downloads are extracted entirely in-process; a stream takes the default extractor's routes.
  private static func stagePayload(
    _ source: any ByteSource,
    as kind: ArtifactKind,
    with extractor: SniffingExtractor,
    in stagingDirectory: URL,
    spoolingIn spoolDirectory: URL,
    options: InstallOptions,
    logger: any ControlCoreLogger,
    onReport: @escaping @Sendable (StagingReport) -> Void
  ) async throws -> StagedTree {
    let peekable = PeekableSource(source)
    if case .dylib(let name) = kind, let file = try await stageSingleFile(peekable, named: name, in: stagingDirectory) {
      return .file(file)
    }
    try await extractor.extract(
      from: peekable, spoolingIn: spoolDirectory, to: stagingDirectory.path, options: options.extractOptions, logger: logger
    ) { onReport(.route($0)) }
    return .extracted(stagingDirectory)
  }

  /// A dylib arrives as the file itself or gzipped, which writes it into `directory` as `name`; anything else is an
  /// archive holding it, and `nil`. A gzip can't be told from a gzipped tar by its first bytes, so for a dylib a gzip
  /// is taken to be the one file, as clients send them.
  private static func stageSingleFile(_ source: PeekableSource, named name: String, in directory: URL) async throws -> URL? {
    let handedOver = HandedOver(source)
    let head = try await offCooperativePool { try handedOver.value.peek(ArchiveFormat.sniffLength) }.get()
    let file = directory.appendingPathComponent(name)
    if ArchiveFormat.detect(head) == .gzip {
      try await ArchiveOperations.extractGzip(from: source, toPath: file.path)
      return file
    }
    guard isMachO(head) else {
      return nil
    }
    try await offCooperativePool {
      FileManager.default.createFile(atPath: file.path, contents: nil)
      let output = try FileHandle(forWritingTo: file)
      defer { try? output.close() }
      var chunk = [UInt8](repeating: 0, count: 1 << 16)
      while case let count = try chunk.withUnsafeMutableBytes({ try handedOver.value.read(into: $0) }), count > 0 {
        try output.write(contentsOf: chunk[..<count])
      }
    }.get()
    return file
  }

  /// Whether `head` starts a Mach-O file, thin or fat, of either byte order.
  private static func isMachO(_ head: Data) -> Bool {
    guard head.count >= 4 else {
      return false
    }
    let magic = head.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    return [0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA, 0xCAFE_BABF, 0xBFBA_FECA].contains(magic)
  }

  /// `extract` reads the transfer as it arrives rather than waiting for a
  /// complete file, so the download and extract stages overlap and each times
  /// against its own start.
  ///
  /// A download connecting to an override still takes its idle timeout from `configuration`.
  private static func download(
    _ url: URL,
    connectingTo connectionOverride: ConnectionOverride?,
    extractingTo extractPath: String,
    totalStart: Date,
    configuration: URLSessionConfiguration,
    logger: any ControlCoreLogger,
    onProgress: @escaping @Sendable (InstallProgressEvent) -> Void,
    onReport: @escaping @Sendable (StagingReport) -> Void,
    extract: @escaping @Sendable (DownloadSpool) async throws -> Void
  ) async throws {
    let downloadStart = Date()
    onProgress(.downloadStarted(timing: .measure(stageStart: downloadStart, totalStart: totalStart), url: url))

    // SAFETY: written only from the download's callback queue, which is serial,
    // and read once after awaiting the transfer, which that same queue resolves
    // after delivering its last chunk.
    // patternlint-disable-next-line swift-nonisolated-unsafe
    nonisolated(unsafe) var progress = DownloadProgressState(startedAt: downloadStart)
    let onEvent: @Sendable (DataDownloadEvent) -> Void = { event in
      switch event {
      case .response(let expectedContentLength):
        progress.observe(expectedContentLength: expectedContentLength)
      case .data(let byteCount):
        guard let update = progress.track(byteCount: byteCount) else {
          return
        }
        onProgress(
          .downloadProgress(
            timing: .measure(stageStart: downloadStart, totalStart: totalStart),
            bytesDownloaded: update.bytesDownloaded,
            totalBytes: update.totalBytes))
      }
    }
    let download: any DownloadInput =
      if let connectionOverride {
        NetworkDownloadInput(
          url: url, connectingTo: connectionOverride, idleTimeout: configuration.timeoutIntervalForRequest, logger: logger,
          onEvent: onEvent)
      } else {
        DataDownloadInput(url: url, configuration: configuration, logger: logger, onEvent: onEvent)
      }

    let extractionFailure = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)
    // An extraction that has failed has no use for the rest of the transfer.
    @Sendable func extractStoppingTheDownloadOnFailure() async throws {
      do {
        try await extract(download.spool)
      } catch {
        extractionFailure.withLock { $0 = error }
        download.cancel()
        throw error
      }
    }

    try await runExtractStage(to: extractPath, totalStart: totalStart, onProgress: onProgress) {
      try await withTaskCancellationHandler {
        async let extraction: Void = extractStoppingTheDownloadOnFailure()
        // The transfer's outcome first: the extractor only sees bytes and then an
        // end of file, so a failed transfer looks to it like a short archive. A
        // transfer stopped because the extraction failed reports the extraction.
        let report: DownloadReport
        do {
          report = try await download.completed()
        } catch {
          throw (download.failedOnItsOwn ? nil : extractionFailure.withLock { $0 }) ?? error
        }
        onReport(.download(report))
        onProgress(
          .downloadCompleted(
            timing: .measure(stageStart: downloadStart, totalStart: totalStart),
            totalBytes: progress.downloadedBytes))
        try await extraction
      } onCancel: {
        download.cancel()
      }
    }
  }

  @discardableResult
  private static func runExtractStage<T>(
    to extractPath: String,
    totalStart: Date,
    onProgress: @escaping @Sendable (InstallProgressEvent) -> Void,
    operation: () async throws -> T
  ) async throws -> T {
    let stageStart = Date()
    onProgress(.extractStarted(timing: .measure(stageStart: stageStart, totalStart: totalStart), destinationPath: extractPath))
    let result: T
    do {
      result = try await operation()
    } catch let error as InstallError {
      // Already classified: the transfer is awaited inside this stage, and a
      // dropped connection is not a corrupt archive.
      throw error
    } catch {
      // The extractor is shared with callers that are not installing anything, so
      // it reports failures unclassified; this is the boundary that knows better.
      throw InstallError.extractionFailed(underlying: error)
    }
    onProgress(.extractCompleted(timing: .measure(stageStart: stageStart, totalStart: totalStart), destinationPath: extractPath))
    return result
  }
}
