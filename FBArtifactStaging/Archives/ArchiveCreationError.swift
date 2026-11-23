/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Why an archive of files on disk could not be made.
public enum ArchiveCreationError: Error, Equatable {
  case pathDoesNotExist(path: String)
  /// A file became shorter than its size when archiving began.
  case fileChangedWhileArchiving(path: String)
  /// A file could not be opened, examined or read, with the system's reason.
  case unreadable(path: String, reason: String)
  case compressionFailed

  /// The failure `errno` describes for the call that just failed on `path`.
  static func unreadable(atPath path: String) -> Self {
    unsafe .unreadable(path: path, reason: String(cString: strerror(errno)))
  }
}

extension ArchiveCreationError: LocalizedError {

  public var errorDescription: String? {
    switch self {
    case let .pathDoesNotExist(path):
      return "Path for tarring \(path) doesn't exist"
    case let .fileChangedWhileArchiving(path):
      return "\(path) changed while it was being archived"
    case let .unreadable(path, reason):
      return "\(path) could not be read: \(reason)"
    case .compressionFailed:
      return "The archive could not be compressed"
    }
  }
}
