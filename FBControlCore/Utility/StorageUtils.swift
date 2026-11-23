/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

enum StorageUtilsError: Error {
  case notExactlyOneFileWithExtension(count: Int, fileExtension: String, url: URL)
  case notExactlyOneFile(found: [URL])
  case directoryListFailed(directory: URL, underlying: any Error)
}

extension StorageUtilsError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .notExactlyOneFileWithExtension(count, fileExtension, url):
      return "\(count) files with extension .\(fileExtension) in \(url)"
    case let .notExactlyOneFile(found):
      return "Expected one top level file, found \(found.count): \(CollectionInformation.oneLineDescription(from: found))"
    case let .directoryListFailed(directory, _):
      return "Failed to list files in directory \(directory)"
    }
  }
}

public enum StorageUtils {

  // MARK: - Finding Files

  public static func bucketFiles(withExtensions extensions: Set<String>, inDirectory directory: URL) throws -> [String: Set<URL>] {
    var files: [String: Set<URL>] = [:]
    for ext in extensions {
      files[ext] = Set()
    }

    let contents = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: .skipsSubdirectoryDescendants
    )

    for file in contents {
      let ext = file.pathExtension
      if extensions.contains(ext) {
        files[ext]?.insert(file)
      }
    }

    return files
  }

  public static func findFile(withExtension ext: String, at url: URL) throws -> URL {
    let files = try findFiles(withExtension: ext, at: url)
    guard let file = files.first, files.count == 1 else {
      throw StorageUtilsError.notExactlyOneFileWithExtension(count: files.count, fileExtension: ext, url: url)
    }
    return file
  }

  public static func findFiles(withExtension ext: String, at url: URL) throws -> Set<URL> {
    let buckets = try bucketFiles(withExtensions: Set([ext]), inDirectory: url)
    return buckets[ext] ?? Set()
  }

  public static func findUniqueFile(inDirectory directory: URL) throws -> URL {
    let filesInDirectory = try files(inDirectory: directory)
    if filesInDirectory.count != 1 {
      throw StorageUtilsError.notExactlyOneFile(found: filesInDirectory)
    }
    return filesInDirectory[0]
  }

  public static func files(inDirectory directory: URL) throws -> [URL] {
    do {
      return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    } catch {
      throw StorageUtilsError.directoryListFailed(directory: directory, underlying: error)
    }
  }

  public static func bundle(inDirectory directory: URL) throws -> BundleDescriptor {
    let uniqueFile = try findUniqueFile(inDirectory: directory)
    return try BundleDescriptor(path: uniqueFile.path)
  }
}
