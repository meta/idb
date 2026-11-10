/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation

/// Build information from a bounded regular file, not proof of what a running process loaded.
enum BundleBuildIdentity {
  private static let maximumBytes = 16 * 1024
  private static let maximumUUIDBytes = 128

  static func buildUUID(inBundleAt bundlePath: String) -> String? {
    for relativePath in ["BuildInfo.json", "Contents/Resources/BuildInfo.json"] {
      let path = (bundlePath as NSString).appendingPathComponent(relativePath)
      guard let data = readRegularFile(at: path),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let uuid = object["build_uuid"] as? String,
        !uuid.isEmpty, uuid.utf8.count <= maximumUUIDBytes
      else { continue }
      return uuid
    }
    return nil
  }

  private static func readRegularFile(at path: String) -> Data? {
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { _ = Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_size > 0, metadata.st_size <= maximumBytes
    else { return nil }
    var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
    let complete = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let base = buffer.baseAddress else { return false }
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
    var latest = stat()
    guard complete, fstat(descriptor, &latest) == 0,
      latest.st_size == metadata.st_size,
      latest.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
      latest.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec
    else { return nil }
    return Data(bytes)
  }
}
