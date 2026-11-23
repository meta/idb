/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBArtifactStaging
@testable import FBControlCore
import Foundation
import Testing
import os

/// Archives of one app, written by every producer the system has, and the trees
/// extracting them leaves behind.
struct ArchiveCorpus {

  enum Producer: String, CaseIterable, CustomTestStringConvertible {
    case dittoZip
    case dittoZipWithResourceForks
    case zipDeflated
    case zipStored
    case zip64
    case zipToAPipe
    case tarGzip
    case tarUncompressed
    case tarGzipGNU
    case tarGzipUstar
    case tarGzipPax
    case tarGzipWithoutMacMetadata
    case tarGzipInTwoMembers
    /// A tar in a zstd frame, as clients that negotiate zstd send an app.
    case tarZstd
    /// A zip in a zstd frame behind `ArchiveFormat.zstdZipMarker`, as clients that negotiate zstd zip streams send one.
    case zipZstd

    var isZip: Bool {
      switch self {
      case .dittoZip, .dittoZipWithResourceForks, .zipDeflated, .zipStored, .zip64, .zipToAPipe, .zipZstd:
        return true
      case .tarGzip, .tarUncompressed, .tarGzipGNU, .tarGzipUstar, .tarGzipPax, .tarGzipWithoutMacMetadata, .tarGzipInTwoMembers, .tarZstd:
        return false
      }
    }

    /// Compressed with zstd, which `bsdtar` on macOS cannot read, so it is compared against the archive it compresses.
    var isZstd: Bool {
      switch self {
      case .tarZstd, .zipZstd:
        return true
      case .dittoZip, .dittoZipWithResourceForks, .zipDeflated, .zipStored, .zip64, .zipToAPipe, .tarGzip, .tarUncompressed, .tarGzipGNU, .tarGzipUstar, .tarGzipPax,
        .tarGzipWithoutMacMetadata, .tarGzipInTwoMembers:
        return false
      }
    }

    /// A zip stores a hard link as a second copy, and some producers cannot store a symlink or an empty file.
    var keepsHardLinks: Bool { !isZip }

    var testDescription: String { rawValue }
  }

  let root: URL
  private let fileManager = FileManager.default

  init(root: URL) {
    self.root = root
  }

  func run(_ launchPath: String, _ arguments: [String]) throws {
    try ArchiveFixtures.run(launchPath, arguments, in: root)
  }

  /// An app with what installs meet: modes, file and directory symlinks, a framework with a `Versions/Current` link, a hard link, long, spaced and non-ASCII names, an extended attribute, empty files and directories, and contents that do and do not compress across many read buffers.
  @discardableResult
  func makeApp() throws -> URL {
    let app = root.appendingPathComponent("A.app")
    let long = "Real/" + String(repeating: "nested-directory/", count: 8) + "ünïcode file with a long name.txt"
    let framework = app.appendingPathComponent("Frameworks/F.framework")
    for directory in [(long as NSString).deletingLastPathComponent, "Private", "Empty", "Many"] {
      try fileManager.createDirectory(at: app.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    try fileManager.createDirectory(at: framework.appendingPathComponent("Versions/A/Resources"), withIntermediateDirectories: true)
    // Reading a bundle parses its executable's header.
    try fileManager.copyItem(atPath: "/bin/ls", toPath: app.appendingPathComponent("A").path)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("A").path)
    let plist: [String: Any] = ["CFBundleIdentifier": "com.example.corpus", "CFBundleName": "A", "CFBundleExecutable": "A", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
    try Data(String(repeating: "compressible ", count: 300_000).utf8).write(to: app.appendingPathComponent("big.txt"))
    var generator = SplitMix64(seed: 7)
    try Data((0..<1_500_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).write(to: app.appendingPathComponent("random.bin"))
    try Data("long".utf8).write(to: app.appendingPathComponent(long))
    try Data().write(to: app.appendingPathComponent("Real/empty"))
    for index in 0..<200 {
      try Data("file \(index)".utf8).write(to: app.appendingPathComponent("Many/\(index).txt"))
    }
    try Data("secret".utf8).write(to: app.appendingPathComponent("Private/key"))
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: app.appendingPathComponent("Private/key").path)
    // Directories get explicit modes, as bsdtar masks what it extracts with its umask and the in-process extractors do not.
    for relative in try fileManager.subpathsOfDirectory(atPath: app.path) + [""] where try fileManager.attributesOfItem(atPath: app.appendingPathComponent(relative).path)[.type] as? FileAttributeType == .typeDirectory {
      try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent(relative).path)
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: app.appendingPathComponent("Private").path)
    try Data("framework".utf8).write(to: framework.appendingPathComponent("Versions/A/F"))
    try Data("<plist/>".utf8).write(to: framework.appendingPathComponent("Versions/A/Resources/Info.plist"))
    try fileManager.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
    try fileManager.createSymbolicLink(atPath: framework.appendingPathComponent("F").path, withDestinationPath: "Versions/Current/F")
    try fileManager.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")
    try fileManager.createSymbolicLink(atPath: app.appendingPathComponent("link.plist").path, withDestinationPath: "Info.plist")
    try fileManager.createSymbolicLink(atPath: app.appendingPathComponent("LinkDir").path, withDestinationPath: "Real")
    try fileManager.linkItem(atPath: app.appendingPathComponent("A").path, toPath: app.appendingPathComponent("Hardlink").path)
    try run("/usr/bin/xattr", ["-w", "com.example.tag", "value", app.appendingPathComponent("Info.plist").path])
    // A fixed time, so that a producer writes the same bytes on every run and mutations land on the same structures. Deepest first, as setting a child's time moves its directory's.
    let items = try fileManager.subpathsOfDirectory(atPath: app.path).sorted { $0.count > $1.count } + [""]
    for relative in items {
      try run("/usr/bin/touch", ["-h", "-t", "202311142213.20", app.appendingPathComponent(relative).path])
    }
    return app
  }

  /// Writes `A.app` under `root` as `producer` does, returning the archive.
  func archive(_ producer: Producer) throws -> URL {
    let archive = root.appendingPathComponent("A.\(producer.rawValue).\(producer.isZip ? "zip" : "tar")")
    let app = root.appendingPathComponent("A.app").path
    switch producer {
    case .dittoZip:
      try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app, archive.path])
    case .dittoZipWithResourceForks:
      try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app, archive.path])
    case .zipDeflated:
      try run("/usr/bin/zip", ["-qry", archive.path, "A.app"])
    case .zipStored:
      try run("/usr/bin/zip", ["-qry0", archive.path, "A.app"])
    case .zip64:
      try run("/usr/bin/zip", ["-qry", "-fz", archive.path, "A.app"])
    case .zipToAPipe:
      // zip cannot seek back into a pipe, so it writes data descriptors; it follows symlinks there and cannot store an empty file.
      try run("/bin/sh", ["-c", "/usr/bin/zip -qr - A.app -x A.app/Real/empty A.app/LinkDir/empty | /bin/cat > \"$0\"", archive.path])
    case .tarGzip:
      try run("/usr/bin/tar", ["-czf", archive.path, "A.app"])
    case .tarUncompressed:
      try run("/usr/bin/tar", ["-cf", archive.path, "A.app"])
    case .tarGzipGNU:
      try run("/usr/bin/tar", ["--format", "gnutar", "-czf", archive.path, "A.app"])
    case .tarGzipUstar:
      try run("/usr/bin/tar", ["--format", "ustar", "-czf", archive.path, "A.app"])
    case .tarGzipPax:
      try run("/usr/bin/tar", ["--format", "pax", "-czf", archive.path, "A.app"])
    case .tarGzipWithoutMacMetadata:
      try run("/usr/bin/tar", ["--no-mac-metadata", "-czf", archive.path, "A.app"])
    case .tarGzipInTwoMembers:
      let tar = root.appendingPathComponent("two-members.tar")
      try run("/usr/bin/tar", ["-cf", tar.path, "A.app"])
      let contents = try Data(contentsOf: tar)
      let half = contents.count / 2
      try (try gzip(contents.prefix(half)) + gzip(contents.suffix(from: half))).write(to: archive)
    case .tarZstd:
      try ZstdFrame.stored(try Data(contentsOf: reference(producer))).write(to: archive)
    case .zipZstd:
      try (ArchiveFormat.zstdZipMarker + ZstdFrame.stored(try Data(contentsOf: reference(producer)))).write(to: archive)
    }
    return archive
  }

  /// `producer`'s archive, written only if it isn't already, so a shared corpus never rewrites a file another test reads.
  func existingArchive(_ producer: Producer) throws -> URL {
    let url = root.appendingPathComponent("A.\(producer.rawValue).\(producer.isZip ? "zip" : "tar")")
    return fileManager.fileExists(atPath: url.path) ? url : try archive(producer)
  }

  /// What `bsdtar` reads in place of `producer`'s archive: the archive itself, or for zstd the one it compresses.
  func reference(_ producer: Producer) throws -> URL {
    switch producer {
    case .tarZstd:
      return try existingArchive(.tarUncompressed)
    case .zipZstd:
      return try existingArchive(.dittoZip)
    case .dittoZip, .dittoZipWithResourceForks, .zipDeflated, .zipStored, .zip64, .zipToAPipe, .tarGzip, .tarUncompressed, .tarGzipGNU, .tarGzipUstar, .tarGzipPax,
      .tarGzipWithoutMacMetadata, .tarGzipInTwoMembers:
      return root.appendingPathComponent("A.\(producer.rawValue).\(producer.isZip ? "zip" : "tar")")
    }
  }

  private func gzip(_ data: Data) throws -> Data {
    let input = root.appendingPathComponent("member")
    try data.write(to: input)
    try run("/usr/bin/gzip", ["-nf", input.path])
    return try Data(contentsOf: root.appendingPathComponent("member.gz"))
  }
}

extension ArchiveCorpus {

  /// One corpus for the whole bundle. Its app and each producer's archive are written once, on first use, rather than
  /// for every case. Writing them runs `ditto`, `zip` and `tar` and waits on each, and a few hundred cases doing that at
  /// once held up every other suite in the process for minutes.
  static let shared = Shared()

  // SAFETY: `madeApp` and `archives` are only touched under `lock`, which is held while an archive is written so that
  // no case reads one half made.
  // patternlint-disable-next-line unchecked-sendable
  final class Shared: @unchecked Sendable {

    private let lock = NSLock()
    private let corpus = ArchiveCorpus(root: FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveCorpus-\(UUID().uuidString)"))
    private var madeApp = false
    private var archives: [Producer: URL] = [:]

    /// `producer`'s archive, which no test may change.
    func archive(_ producer: Producer) throws -> URL {
      try lock.withLock {
        if !madeApp {
          try FileManager.default.createDirectory(at: corpus.root, withIntermediateDirectories: true)
          try corpus.makeApp()
          madeApp = true
        }
        if let archive = archives[producer] {
          return archive
        }
        // A zstd producer writes the archive it compresses as it goes, so that one may already be on disk; writing it
        // again would change a file a case may be reading.
        let archive = try corpus.existingArchive(producer)
        archives[producer] = archive
        return archive
      }
    }

    /// What `bsdtar` reads in place of `producer`'s archive.
    func reference(_ producer: Producer) throws -> URL {
      _ = try archive(producer)
      return try lock.withLock { try corpus.reference(producer) }
    }
  }
}

/// A seeded generator, so that random contents and mutation offsets are the same on every run.
struct SplitMix64: RandomNumberGenerator {

  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// Serves each registered URL its body, so that tests running in parallel can each download their own archive.
// SAFETY: `URLSession` drives the protocol from its own threads, and a later delivery runs on a dispatch queue; the
// subclass adds no instance state, and its shared state is behind a lock.
// patternlint-disable-next-line unchecked-sendable
final class CorpusURLProtocol: URLProtocol, @unchecked Sendable {

  private static let bodies = OSAllocatedUnfairLock(initialState: [URL: Data]())

  /// A URL that serves `body`.
  static func serving(_ body: Data) -> URL {
    // swiftlint:disable:next force_unwrapping
    let url = URL(string: "https://corpus.invalid/\(UUID().uuidString)")!
    bodies.withLock { $0[url] = body }
    return url
  }

  static var configuration: URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CorpusURLProtocol.self]
    return configuration
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url, let body = Self.bodies.withLock({ $0[url] }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
      return
    }
    // swiftlint:disable:next force_unwrapping
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(body.count)])!
    // Later, as the extractor attaches to the download only once extraction starts.
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(100)) {
      self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      var offset = 0
      while offset < body.count {
        self.client?.urlProtocol(self, didLoad: body.subdata(in: offset..<min(offset + 64 * 1024, body.count)))
        offset += 64 * 1024
      }
      self.client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}
