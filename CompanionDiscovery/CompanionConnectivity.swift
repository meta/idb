/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unknown platform")
#endif

/// Liveness checks for companions.
public enum CompanionConnectivity {
  /// Whether a companion is currently listening on the given domain socket path.
  public static func isDomainSocketBound(path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else {
      return false
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      return false
    }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.utf8.count < capacity else {
      return false
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { rawPointer in
      unsafe rawPointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        _ = unsafe strncpy(destination, path, capacity - 1)
      }
    }

    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &addr) { addrPointer in
      unsafe addrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        unsafe Platform.connect(fd, sockaddrPointer, length)
      }
    }
    return result == 0
  }
}
