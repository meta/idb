/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// Why injecting code into a Simulator process failed.
public enum CodeInjectionError: Error, Equatable {
  /// A file injection needs is missing: the shim, or the guest bridge that hosts `.simulator`.
  case resourceMissing(name: String)
  /// The private directory that holds an app's control socket could not be created, or is not
  /// private to this user.
  case socketDirectoryCreationFailed(path: String)
  /// The bundle identifier names a process launchd manages, such as SpringBoard, rather than an app
  /// that is launched with the shim injected.
  case notALaunchableApplication(bundleID: String, processIdentifier: pid_t)
  /// The control socket's path does not fit in `sockaddr_un`.
  case socketPathTooLong(path: String)
  /// The host never served its control socket.
  case connectTimedOut(path: String)
  case socketCreationFailed
  /// The host closed the control socket mid-exchange, for example because it crashed.
  case disconnected
  /// The host's first message was not its greeting.
  case missingGreeting(received: String?)
  case unexpectedMessage(received: String?)
  case invalidMessage
  case readFailed(errno: Int32)
  case writeFailed
  /// A host command the injected code sent could not be answered.
  case hostCommandDidNotComplete
  /// The injected code sent a host command, and the session executing it handles none.
  case hostCommandsUnsupported
  /// The host could not run the injected code: the dylib did not load, its entry point is missing,
  /// or the code reported failure.
  case executionFailed(message: String)
}

extension CodeInjectionError: CustomStringConvertible, LocalizedError {
  public var description: String {
    switch self {
    case let .resourceMissing(name):
      return "\(name) not found in the bundled resources"
    case let .socketDirectoryCreationFailed(path):
      return "Could not create a private control-socket directory at \(path)"
    case let .notALaunchableApplication(bundleID, processIdentifier):
      return """
        \(bundleID) is managed by launchd (pid \(processIdentifier)), not launched as an app, so launching it \
        returns the process already running and the shim is never injected. Target an app bundle instead.
        """
    case let .socketPathTooLong(path):
      return "Control socket path too long (\(path.utf8.count) bytes): \(path)"
    case let .connectTimedOut(path):
      return "Timed out connecting to the control socket at \(path)"
    case .socketCreationFailed:
      return "Failed to create a socket"
    case .disconnected:
      return "The host closed the control socket before a complete message was received (it may have crashed)"
    case let .missingGreeting(received):
      return "Expected the host's greeting, got a '\(received ?? "nil")' message"
    case let .unexpectedMessage(received):
      return "Unexpected control-socket message '\(received ?? "nil")'"
    case .invalidMessage:
      return "Invalid control-socket message"
    case let .readFailed(errno):
      return unsafe "Failed to read from the control socket: \(String(cString: strerror(errno)))"
    case .writeFailed:
      return "Failed to write to the control socket"
    case .hostCommandDidNotComplete:
      return "A host command did not complete"
    case .hostCommandsUnsupported:
      return "This session handles no host commands"
    case let .executionFailed(message):
      return message
    }
  }

  public var errorDescription: String? { description }
}
