/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// Why a control socket's directory could not be used.
public enum ControlSocketError: Error, LocalizedError {
  case directoryNotPrivate(path: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case let .directoryNotPrivate(path, reason):
      return "The control socket directory \(path) is not private to this user: \(reason)"
    }
  }
}

/// Where the app listens and the CLI dials, when neither was told otherwise.
public enum ControlSocket {

  /// The environment variable both ends read, so a second SimScope can be given its own socket
  /// without either side passing a flag.
  public static let pathVariable = "SIMSCOPE_CONTROL_SOCKET"

  /// The per-device socket, derived from a base path by suffixing the UDID before the extension:
  /// `control.sock` becomes `control-<UDID>.sock`, beside it. Deterministic from two things an agent
  /// already knows — the base path and the device — so addressing a window never needs a lookup.
  public static func path(forUDID udid: String, beside base: String) -> String {
    let url = URL(fileURLWithPath: base)
    let stem = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension.isEmpty ? "sock" : url.pathExtension
    return url.deletingLastPathComponent().appendingPathComponent("\(stem)-\(udid).\(ext)").path
  }

  /// Short by necessity, not by taste. `sockaddr_un` caps a socket path at 104 bytes, and the
  /// per-device path is the base with a 36-character UDID spliced into it — under Application
  /// Support that came to 107 for an ordinary home directory, so addressing a second device could
  /// never bind, only fail. `/tmp` leaves the whole family a wide margin.
  ///
  /// The cost is a directory every local user can write to, which is what `prepareDirectory(for:)`
  /// answers; a socket here is per-session state and has nothing to lose to tmp reaping.
  public static var defaultPath: String {
    if let override = ProcessInfo.processInfo.environment[pathVariable], !override.isEmpty {
      return override
    }
    return "/tmp/simscope/control.sock"
  }

  /// Creates the socket's parent directory `0700`, or confirms an existing one is this user's.
  ///
  /// On a world-writable `/tmp` the directory is the only thing between an agent and a listener
  /// planted by somebody else, so one that is already there is checked rather than adopted: another
  /// user's directory — or a symlink into one — is a hijack, and binding into it would hand them the
  /// session. Refusing is the only safe answer, and it is the caller's to report.
  public static func prepareDirectory(for socketPath: String) throws {
    let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path

    var info = stat()
    // `lstat`, so a symlink is judged as itself rather than as whatever it points at.
    guard unsafe lstat(directory, &info) == 0 else {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      return
    }
    guard info.st_mode & S_IFMT == S_IFDIR else {
      throw ControlSocketError.directoryNotPrivate(path: directory, reason: "not a directory")
    }
    guard info.st_uid == getuid() else {
      throw ControlSocketError.directoryNotPrivate(
        path: directory, reason: "owned by uid \(info.st_uid), not \(getuid())")
    }
    guard info.st_mode & 0o077 == 0 else {
      throw unsafe ControlSocketError.directoryNotPrivate(
        path: directory, reason: String(format: "mode %03o is readable or writable by others", info.st_mode & 0o777))
    }
  }
}
