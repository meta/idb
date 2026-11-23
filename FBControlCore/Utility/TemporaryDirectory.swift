/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

enum TemporaryDirectoryError: Error, LocalizedError {
  case creationFailed(directory: URL, underlying: any Error)

  public var errorDescription: String? {
    switch self {
    case let .creationFailed(directory, _):
      return "Failed to create Temp Dir \(directory)"
    }
  }
}

/// A value over the root it manages.
public struct TemporaryDirectory: Sendable {

  // MARK: - Properties

  public let logger: any ControlCoreLogger

  private let rootTemporaryDirectory: URL

  // MARK: - Initializers

  public init(logger: any ControlCoreLogger) {
    let temporaryDirectory = TemporaryDirectory.uniqueTemporaryDirectoryURL()
    do {
      try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
    } catch {
      logger.error().log("Failed to create temporary directory \(temporaryDirectory): \(error)")
    }
    self.init(rootDirectory: temporaryDirectory, logger: logger)
  }

  /// The user's own temporary directory, which depends only on the uid, not on `TMPDIR`. `nil` if the system does not
  /// report one.
  public static func userDirectoryPath() -> String? {
    let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
    guard size > 0 else {
      return nil
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard unsafe confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) == size else {
      return nil
    }
    // `confstr` reports a size that includes the terminator, which has to come off before decoding.
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private static func uniqueTemporaryDirectoryURL() -> URL {
    let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
    return URL(fileURLWithPath: base)
      .appendingPathComponent("IDB")
      .appendingPathComponent(UUID().uuidString)
  }

  init(rootDirectory: URL, logger: any ControlCoreLogger) {
    self.rootTemporaryDirectory = rootDirectory
    self.logger = logger
  }

  // MARK: - Public Methods

  public func cleanOnExit() {
    do {
      try FileManager.default.removeItem(at: rootTemporaryDirectory)
      logger.debug().log("Successfully removed temporal directory: \(rootTemporaryDirectory)")
    } catch {
      logger.error().log("Couldn't remove temporary directory: \(rootTemporaryDirectory) (\(error.localizedDescription))")
    }
  }

  public func ephemeralTemporaryDirectory() -> URL {
    return rootTemporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  // MARK: - Scoped

  /// Creates a temporary directory that exists for exactly the scope of `body`: deleted when
  /// `body` returns or throws.
  public func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let tempDirectory = ephemeralTemporaryDirectory()
    logger.log("Creating Temp Dir \(tempDirectory)")
    do {
      try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true, attributes: nil)
    } catch {
      throw TemporaryDirectoryError.creationFailed(directory: tempDirectory, underlying: error)
    }
    defer { delete(tempDirectory) }
    return try await body(tempDirectory)
  }

  /// Returns the unique file inside each immediate subdirectory of `extractionDirectory`.
  public func files(inSubdirectoriesOf extractionDirectory: URL) throws -> [URL] {
    let subfolders = try StorageUtils.files(inDirectory: extractionDirectory)
    return try subfolders.map { try StorageUtils.findUniqueFile(inDirectory: $0) }
  }

  private func delete(_ url: URL) {
    do {
      try FileManager.default.removeItem(at: url)
      logger.log("Deleted Temp Dir \(url)")
    } catch {
      logger.log("Failed to delete Temp Dir \(url): \(error)")
    }
  }

  // MARK: - Temporary Directory

  public func temporaryDirectory() -> URL {
    let tempDirectory = ephemeralTemporaryDirectory()
    logger.log("Creating Temp Dir \(tempDirectory)")
    do {
      try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true, attributes: nil)
    } catch {
      logger.log("Failed to create Temp Dir \(tempDirectory) with error \(error)")
    }
    return tempDirectory
  }

}
