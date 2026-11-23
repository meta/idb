/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation

public enum IPCSocket {
  public static let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
  public static let ownerOnlyPermissions = 0o700

  public static func connect(path: String, timeoutSeconds: Int) throws -> Int32? {
    var address = try self.address(path: path)
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { return nil }
    let connected = withUnsafePointer(to: &address) {
      unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        unsafe Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      close(fileDescriptor)
      return nil
    }
    var noSigPipe: Int32 = 1
    unsafe setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    setTimeout(fileDescriptor, seconds: timeoutSeconds)
    return fileDescriptor
  }

  public static func setTimeout(_ fileDescriptor: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    unsafe setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    unsafe setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }

  public static func writeFrame(_ fileDescriptor: Int32, _ payload: Data) throws {
    try writeAll(fileDescriptor, IPCFrame.header(forSize: payload.count))
    try writeAll(fileDescriptor, payload)
  }

  public static func readFrame(_ fileDescriptor: Int32) throws -> Data {
    let length = try IPCFrame.size(fromHeader: readAll(fileDescriptor, count: 4))
    return try readAll(fileDescriptor, count: length)
  }

  public static func prepareDirectory(_ path: String) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      atPath: path,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: ownerOnlyPermissions]
    )
    try manager.setAttributes([.posixPermissions: ownerOnlyPermissions], ofItemAtPath: path)
  }

  public static func requirePrivateDirectory(_ directory: String, creating: Bool) throws {
    if creating, unsafe mkdir(directory, mode_t(ownerOnlyPermissions)) != 0, errno != EEXIST {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var status = stat()
    guard unsafe lstat(directory, &status) == 0 else {
      if errno == ENOENT, !creating { return }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid() else {
      throw IPCError.sharedDirectory(path: directory)
    }
    if status.st_mode & 0o077 != 0 {
      guard creating, unsafe chmod(directory, mode_t(ownerOnlyPermissions)) == 0 else {
        throw IPCError.sharedDirectory(path: directory)
      }
    }
  }
  static func address(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < pathCapacity else { throw IPCError.pathTooLong(path: path, limit: pathCapacity) }
    withUnsafeMutableBytes(of: &address.sun_path) {
      unsafe $0.copyBytes(from: bytes)
      unsafe $0[bytes.count] = 0
    }
    return address
  }

  private static func writeAll(_ fileDescriptor: Int32, _ data: Data) throws {
    unsafe try data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let written = unsafe send(fileDescriptor, base + offset, buffer.count - offset, MSG_NOSIGNAL)
        if written < 0 {
          if errno == EINTR { continue }
          throw IPCError.failed(operation: "write", errno: errno)
        }
        guard written > 0 else { throw IPCError.closed }
        offset += written
      }
    }
  }

  private static func readAll(_ fileDescriptor: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    unsafe try data.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < count {
        let received = unsafe recv(fileDescriptor, base + offset, count - offset, 0)
        if received < 0 {
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK { throw IPCError.timedOut }
          throw IPCError.failed(operation: "read", errno: errno)
        }
        guard received > 0 else { throw IPCError.closed }
        offset += received
      }
    }
    return data
  }
}

public final class IPCListener {
  public let fileDescriptor: Int32
  private let lockFileDescriptor: Int32
  private let path: String

  public static func bind(path: String, backlog: Int32) throws -> IPCListener? {
    // Bound and listening under a sibling name, then renamed into place: a client woken by the
    // socket's appearance would otherwise connect between bind and listen, be refused, and wait for
    // its next recheck. The sibling's name is as long as the socket's, so it fits wherever that does.
    let name = (path as NSString).lastPathComponent
    let bindingPath = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(
      "." + name.dropLast())
    var address = try IPCSocket.address(path: bindingPath)
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { throw IPCError.failed(operation: "socket", errno: errno) }
    // Keep the inode stable: unlinking a lock file lets another starter lock a different inode.
    let lockFileDescriptor = unsafe open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
    guard lockFileDescriptor >= 0 else {
      let error = IPCError.failed(operation: "open lock", errno: errno)
      close(fileDescriptor)
      throw error
    }
    guard flock(lockFileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
      let contended = errno == EWOULDBLOCK
      let error = IPCError.failed(operation: "lock", errno: errno)
      close(lockFileDescriptor)
      close(fileDescriptor)
      if contended { return nil }
      throw error
    }
    unsafe unlink(bindingPath)
    let bound = withUnsafePointer(to: &address) {
      unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        unsafe Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    let failedOperation: String? =
      if bound != 0 {
        "bind"
      } else if listen(fileDescriptor, backlog) != 0 {
        "listen"
      } else if unsafe rename(bindingPath, path) != 0 {
        "rename"
      } else {
        nil
      }
    if let failedOperation {
      let error = IPCError.failed(operation: failedOperation, errno: errno)
      if bound == 0 { unsafe unlink(bindingPath) }
      close(lockFileDescriptor)
      close(fileDescriptor)
      throw error
    }
    return IPCListener(fileDescriptor: fileDescriptor, lockFileDescriptor: lockFileDescriptor, path: path)
  }

  private init(fileDescriptor: Int32, lockFileDescriptor: Int32, path: String) {
    self.fileDescriptor = fileDescriptor
    self.lockFileDescriptor = lockFileDescriptor
    self.path = path
  }

  deinit {
    unsafe unlink(path)
    close(lockFileDescriptor)
    close(fileDescriptor)
  }
}
