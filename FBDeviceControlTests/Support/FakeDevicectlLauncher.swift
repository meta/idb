/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Stands in for `xcrun devicectl`: records each invocation's arguments and runs a shell fixture
/// in its place, so the commands see a real process exit, real output and real files.
actor FakeDevicectlLauncher: SubprocessLauncher {

  /// What one invocation does. The fixture runs under `/bin/sh -c`, with `$1` set to the value of
  /// `--json-output` and `$2` to the value of `--destination`, each empty when absent.
  struct Reply: Sendable {
    let script: String

    /// Writes `json` to the `--json-output` file and exits zero.
    static func json(_ json: String) -> Reply {
      Reply(script: "printf '%s' '\(json)' > \"$1\"")
    }

    /// Writes `contents` to the `--destination` file and exits zero.
    static func destination(_ contents: String) -> Reply {
      Reply(script: "printf '%s' '\(contents)' > \"$2\"")
    }

    /// Copies the file at `path` to the `--destination` file and exits zero.
    static func copyToDestination(_ path: String) -> Reply {
      Reply(script: "/bin/cp '\(path)' \"$2\"")
    }

    /// Exits zero without writing anything.
    static let succeed = Reply(script: "exit 0")

    /// Writes `message` to standard error and exits with `code`.
    static func fail(code: Int32, message: String) -> Reply {
      Reply(script: "printf '%s' '\(message)' >&2; exit \(code)")
    }
  }

  nonisolated let supportsStandardInput = true
  private var replies: [Reply]
  private(set) var executables: [String] = []
  private(set) var invocations: [[String]] = []

  init(replies: [Reply]) {
    self.replies = replies
  }

  func spawn(_ subprocess: Subprocess, standardInput: Int32?, standardOutput: Int32?, standardError: Int32?, logger: (any ControlCoreLogger)?) async throws -> LaunchedProcess {
    executables.append(subprocess.executable)
    invocations.append(subprocess.arguments)
    let reply = replies.isEmpty ? Reply.fail(code: 99, message: "unexpected devicectl invocation") : replies.removeFirst()
    let fixture = Subprocess(
      executable: "/bin/sh",
      arguments: ["-c", reply.script, "devicectl-fixture", Self.value(of: "--json-output", in: subprocess.arguments), Self.value(of: "--destination", in: subprocess.arguments)])
    return try await HostSubprocessLauncher().spawn(fixture, standardInput: standardInput, standardOutput: standardOutput, standardError: standardError, logger: logger)
  }

  static func value(of option: String, in arguments: [String]) -> String {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
      return ""
    }
    return arguments[index + 1]
  }
}
