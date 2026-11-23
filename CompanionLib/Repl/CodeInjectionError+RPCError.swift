/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorCodeInjection
import Foundation
import GRPCCore

extension CodeInjectionError {
  /// The status the `repl` method ends with when its session fails. The messages are the ones
  /// `idb-repl` clients have always seen, whatever the library's own descriptions say.
  var rpcError: RPCError {
    switch self {
    case let .socketPathTooLong(path):
      return RPCError(code: .invalidArgument, message: "repl: socket path too long (\(path.utf8.count) bytes): \(path)")
    case let .connectTimedOut(path):
      return RPCError(code: .deadlineExceeded, message: "repl: timed out connecting to control socket at \(path)")
    case .disconnected:
      return RPCError(code: .unavailable, message: "repl: control socket closed before a complete message was received (the test process may have crashed)")
    case .socketCreationFailed:
      return RPCError(code: .internalError, message: "repl: failed to create socket")
    case let .missingGreeting(received):
      return RPCError(code: .internalError, message: "repl: expected a 'greeting' message, got type '\(received ?? "nil")'")
    case let .unexpectedMessage(received):
      return RPCError(code: .internalError, message: "repl: unexpected control-socket message type '\(received ?? "nil")'")
    case .invalidMessage:
      return RPCError(code: .internalError, message: "repl: invalid control-socket message")
    case let .readFailed(errno):
      return RPCError(code: .internalError, message: unsafe "repl: failed to read from control socket: \(String(cString: strerror(errno)))")
    case .writeFailed:
      return RPCError(code: .internalError, message: "repl: failed to write to control socket")
    case .hostCommandDidNotComplete:
      return RPCError(code: .internalError, message: "repl: host command did not complete")
    case let .resourceMissing(name):
      return RPCError(code: .internalError, message: "\(name) not found in the bundled resources")
    case let .socketDirectoryCreationFailed(path):
      return RPCError(code: .internalError, message: "Could not create a private REPL socket directory at \(path)")
    case let .notALaunchableApplication(bundleID, processIdentifier):
      return RPCError(
        code: .internalError,
        message: """
          \(bundleID) is managed by launchd (pid \(processIdentifier)), not launched as an app, \
          so launching it returns the process already running and the REPL dylib is never injected. \
          Target an app bundle instead.
          """)
    case .hostCommandsUnsupported, .executionFailed:
      return RPCError(code: .internalError, message: description)
    @unknown default:
      return RPCError(code: .internalError, message: description)
    }
  }
}

/// Runs `body`, reporting a session failure as the status the `repl` method ends with.
func reportingCodeInjectionErrors<T>(_ body: () async throws -> T) async throws -> T {
  do {
    return try await body()
  } catch let error as CodeInjectionError {
    throw error.rpcError
  }
}
