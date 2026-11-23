/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

@frozen public enum IPCError: Error, Equatable {
  case invalidFrameSize(Int)
  case pathTooLong(path: String, limit: Int)
  case closed
  case timedOut
  case failed(operation: String, errno: Int32)
  case sharedDirectory(path: String)
}

extension IPCError: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .invalidFrameSize(size):
      "invalid frame size \(size)"
    case let .pathTooLong(path, limit):
      "socket path is \(path.utf8.count) bytes, over the \(limit)-byte sockaddr_un limit: \(path)"
    case .closed:
      "socket closed by peer"
    case .timedOut:
      "socket timed out"
    case let .failed(operation, code):
      unsafe "\(operation) failed: \(String(cString: strerror(code)))"
    case let .sharedDirectory(path):
      "\(path) is not private to this user"
    }
  }
}

public enum IPCFrame {
  public static let maximumSize = 16 * 1024 * 1024

  public static func header(forSize size: Int) throws -> Data {
    guard size > 0, size <= maximumSize else { throw IPCError.invalidFrameSize(size) }
    var length = UInt32(size).bigEndian
    return withUnsafeBytes(of: &length) { unsafe Data($0) }
  }

  public static func size(fromHeader header: Data) throws -> Int {
    guard header.count == 4 else { throw IPCError.invalidFrameSize(header.count) }
    let size = header.reduce(0) { ($0 << 8) | Int($1) }
    guard size > 0, size <= maximumSize else { throw IPCError.invalidFrameSize(size) }
    return size
  }
}
