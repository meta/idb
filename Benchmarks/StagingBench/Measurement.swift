/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import ArgumentParser
import FBArtifactStaging
import FBControlCore
import Foundation
import os

/// Where the archive arrives from, as each of staging's callers hands it over.
enum BenchSource: String, Codable, CaseIterable {
  /// A path on the host, as a local install.
  case path
  /// In memory in 64 KiB frames, as a gRPC client streams it.
  case stream64K = "stream-64k"
  /// In memory in 1 MiB frames.
  case stream1M = "stream-1m"
  /// Over HTTP from a server on this host, as a URL install.
  case url
  /// From a pipe that another thread writes the file into, read from its descriptor, as `cat app.ipa | idb2 install -`.
  case pipe

  static func parse(_ value: String) throws -> BenchSource {
    guard let source = BenchSource(rawValue: value) else {
      throw ValidationError("Unknown source \(value)")
    }
    return source
  }
}

struct BenchCase: Codable, Hashable {
  let source: BenchSource
  let format: BenchFormat
  let shape: FixtureShape
  let contents: FixtureContents

  var name: String { "\(source.rawValue) \(format.rawValue) \(shape.name) \(contents.rawValue)" }
}

/// One staging of one case.
struct Measurement: Codable {
  let label: String
  let benchCase: BenchCase
  /// The archive's size on the wire.
  let archiveBytes: Int
  let wallSeconds: Double
  /// User and system time of this process and any children it waited for, such as `bsdtar`.
  let cpuSeconds: Double
  let peakRSSBytes: Int
  /// The extractors staging reported taking, in order.
  let routes: [String]
  /// How the zstd fixtures were compressed: by `zstd`, or as stored blocks when none is installed.
  let zstd: String
  let failure: String?

  /// The app's size per second, so that formats compare on what they deliver rather than on how well they compress.
  var megabytesPerSecond: Double { Double(benchCase.shape.megabytes) / wallSeconds }

  var summary: String {
    let outcome = failure.map { "FAILED \($0)" } ?? (unsafe String(format: "%.0f MB/s, %.2fs CPU, %d MB peak", megabytesPerSecond, cpuSeconds, peakRSSBytes >> 20))
    return "[\(label)] \(benchCase.name): \(outcome) \(routes)"
  }

  // MARK: - Spawning

  static func spawn(binary: String, benchCase: BenchCase, archive: URL, label: String) throws -> Measurement {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = [
      "measure", "--source", benchCase.source.rawValue, "--format", benchCase.format.rawValue, "--megabytes", "\(benchCase.shape.megabytes)",
      "--files", "\(benchCase.shape.files)", "--contents", benchCase.contents.rawValue, "--archive", archive.path, "--label", label,
    ]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let line = data.split(separator: UInt8(ascii: "\n")).last else {
      throw ValidationError("\(binary) measure exited \(process.terminationStatus) for \(benchCase.name)")
    }
    return try JSONDecoder().decode(Measurement.self, from: Data(line))
  }

  // MARK: - Measuring

  static func measure(_ benchCase: BenchCase, archive: URL, label: String) async throws -> Measurement {
    let logger = ControlCoreGlobalConfiguration.systemLogger(writingToStderr: false, debugLogging: false)
    let temporaryDirectory = TemporaryDirectory(logger: logger)
    let archiveBytes = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int ?? 0
    let routes = OSAllocatedUnfairLock<[String]>(initialState: [])
    let onEvent: @Sendable (InstallEvent) -> Void = { event in
      if case .route(let route) = event {
        routes.withLock { $0.append(route.extractor.rawValue) }
      }
    }
    let options = InstallOptions()

    // Everything a source needs before the clock starts: frames in memory, a server listening.
    let prepared = try await PreparedSource(benchCase.source, archive: archive)
    defer { prepared.stop() }

    let usageBefore = ResourceUsage.now()
    let start = ContinuousClock.now
    var failure: String?
    do {
      try await prepared.stage(options: options, temporaryDirectory: temporaryDirectory, logger: logger, onEvent: onEvent)
    } catch {
      failure = "\(error)"
    }
    let wall = ContinuousClock.now - start
    let usageAfter = ResourceUsage.now()

    return Measurement(
      label: label, benchCase: benchCase, archiveBytes: archiveBytes,
      wallSeconds: Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18,
      cpuSeconds: usageAfter.cpuSeconds - usageBefore.cpuSeconds, peakRSSBytes: usageAfter.peakRSSBytes,
      routes: routes.withLock { $0 }, zstd: Fixtures.zstdCompressor == nil ? "stored" : "zstd -3", failure: failure)
  }
}

/// A source ready to stage, with whatever it holds open until `stop`.
final class PreparedSource: Sendable {

  private let source: BenchSource
  private let archive: URL
  private let frames: [Data]
  private let server: LocalHTTPServer?

  init(_ source: BenchSource, archive: URL) async throws {
    self.source = source
    self.archive = archive
    switch source {
    case .stream64K, .stream1M:
      let contents = try Data(contentsOf: archive)
      let size = source == .stream64K ? 64 << 10 : 1 << 20
      frames = stride(from: 0, to: contents.count, by: size).map { contents.subdata(in: $0..<min($0 + size, contents.count)) }
      server = nil
    case .url:
      frames = []
      server = try await LocalHTTPServer.serving(archive)
    case .path, .pipe:
      frames = []
      server = nil
    }
  }

  func stop() {
    server?.stop()
  }

  func stage(
    options: InstallOptions, temporaryDirectory: TemporaryDirectory, logger: any ControlCoreLogger, onEvent: @escaping @Sendable (InstallEvent) -> Void
  ) async throws {
    switch source {
    case .path:
      try await Self.stage(
        .localPath(archive.path), options: options, temporaryDirectory: temporaryDirectory, logger: logger, onEvent: onEvent
      )
    case .url:
      guard let server else {
        throw ValidationError("the URL source has no server")
      }
      try await Self.stage(
        .remoteURL(server.url), options: options, temporaryDirectory: temporaryDirectory, logger: logger, onEvent: onEvent
      )
    case .stream64K, .stream1M:
      let frames = self.frames
      try await stream(
        AsyncThrowingStream { continuation in
          frames.forEach { continuation.yield($0) }
          continuation.finish()
        }, options: options, temporaryDirectory: temporaryDirectory, logger: logger, onEvent: onEvent)
    case .pipe:
      // As sime2e reads standard input: straight from the descriptor.
      let readEnd = try Self.pipe(of: archive)
      defer { close(readEnd) }
      try await Self.stage(
        .stream(FileDescriptorSource(readEnd)), options: options, temporaryDirectory: temporaryDirectory, logger: logger,
        onEvent: onEvent
      )
    }
  }

  /// What the benchmark installs: nothing, so that the time is staging's alone.
  private struct Staged: InstalledName {
    var installedName: String { "staged" }
  }

  /// Stages `source` with no install after it. Staged as a dSYM, whose identification is a listing of what was
  /// extracted, so the measurement is fetch, decompress and extract.
  private static func stage(
    _ source: InstallSource, options: InstallOptions, temporaryDirectory: TemporaryDirectory, logger: any ControlCoreLogger,
    onEvent: @escaping @Sendable (InstallEvent) -> Void
  ) async throws {
    _ = try await Staging.install(
      source, as: .dsym, options: options, temporaryDirectory: temporaryDirectory, logger: logger, onEvent: onEvent
    ) { _, _ in Staged() }
  }

  /// Pumps `chunks` into staging as the companion and sime2e do: concurrently, through the source staging reads.
  private func stream(
    _ chunks: AsyncThrowingStream<Data, any Error>, options: InstallOptions, temporaryDirectory: TemporaryDirectory, logger: any ControlCoreLogger,
    onEvent: @escaping @Sendable (InstallEvent) -> Void
  ) async throws {
    let source = ChunkSource()
    async let pumped: Void = source.pump(chunks)
    do {
      try await Self.stage(
        .stream(source), options: options, temporaryDirectory: temporaryDirectory, logger: logger, onEvent: onEvent
      )
    } catch {
      source.abandon()
      try? await pumped
      throw error
    }
    source.abandon()
    do {
      try await pumped
    } catch is ChunkSource.ReaderClosed {}
  }

  /// The read end of a kernel pipe another thread writes the archive into, as a shell pipeline feeds standard input.
  /// A write that fails, which happens once staging stops reading, ends the archive there.
  private static func pipe(of archive: URL) throws -> Int32 {
    var descriptors: [Int32] = [0, 0]
    guard unsafe Darwin.pipe(&descriptors) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
    Thread {
      defer { close(writeEnd) }
      guard let input = FileHandle(forReadingAtPath: archive.path) else {
        return
      }
      while let chunk = try? input.read(upToCount: 1 << 16), !chunk.isEmpty, writeAll(chunk, to: writeEnd) {}
    }.start()
    return readEnd
  }

  private static func writeAll(_ chunk: Data, to descriptor: Int32) -> Bool {
    unsafe chunk.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else {
        return true
      }
      var offset = 0
      while offset < bytes.count {
        let written = unsafe write(descriptor, base + offset, bytes.count - offset)
        if written < 0 && errno == EINTR {
          continue
        }
        guard written > 0 else {
          return false
        }
        offset += written
      }
      return true
    }
  }
}

/// This process's CPU time, including children it has waited for, and its peak resident memory.
struct ResourceUsage {
  let cpuSeconds: Double
  let peakRSSBytes: Int

  static func now() -> ResourceUsage {
    var own = rusage()
    var children = rusage()
    unsafe getrusage(RUSAGE_SELF, &own)
    unsafe getrusage(RUSAGE_CHILDREN, &children)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
    let cpu = seconds(own.ru_utime) + seconds(own.ru_stime) + seconds(children.ru_utime) + seconds(children.ru_stime)
    // Bytes on macOS.
    return ResourceUsage(cpuSeconds: cpu, peakRSSBytes: Int(own.ru_maxrss))
  }
}
