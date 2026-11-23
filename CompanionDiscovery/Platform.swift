/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unknown platform")
#endif

/// Platform-neutral wrappers for C library functions whose bare names resolve to
/// unrelated members in scope on some platforms (notably macOS), so they must be
/// module-qualified. Centralizing the per-platform `#if` here keeps it out of the
/// call sites.
enum Platform {
  @discardableResult
  static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 {
    #if os(macOS)
    return Darwin.kill(pid, signal)
    #elseif canImport(Glibc)
    return Glibc.kill(pid, signal)
    #elseif canImport(Musl)
    return Musl.kill(pid, signal)
    #endif
  }

  static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if os(macOS)
    return unsafe Darwin.connect(fd, address, length)
    #elseif canImport(Glibc)
    return Glibc.connect(fd, address, length)
    #elseif canImport(Musl)
    return Musl.connect(fd, address, length)
    #endif
  }
}
