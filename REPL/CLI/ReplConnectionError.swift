/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CompanionDiscovery
import GRPCCore

enum CompanionConnectionSource: String, Equatable {
  case commandLine = "command_line"
  case environment
  case registry
  case localDiscovery = "local_discovery"

  var description: String {
    switch self {
    case .commandLine:
      return "--companion"
    case .environment:
      return "IDB_COMPANION"
    case .registry:
      return "/tmp/idb/state"
    case .localDiscovery:
      return "local discovery"
    }
  }
}

struct ResolvedCompanion: Equatable {
  let address: CompanionAddress
  let source: CompanionConnectionSource

  var endpoint: String {
    switch address {
    case let .tcp(host, port):
      let displayedHost = host.contains(":") ? "[\(host)]" : host
      return "\(displayedHost):\(port)"
    case let .domainSocket(path):
      return path
    }
  }
}

enum ReplConnectionError: Error, Equatable, CustomStringConvertible {
  case unavailable(ResolvedCompanion, detail: String?)
  case timedOut(ResolvedCompanion, detail: String?)
  case unsupported(ResolvedCompanion, detail: String?)

  var description: String {
    switch self {
    case let .unavailable(companion, detail):
      return "Could not reach idb_companion at \(companion.endpoint) (selected via \(companion.source.description))\(formatted(detail)). Verify that the companion is running and reachable, or pass --companion <host:port>."
    case let .timedOut(companion, detail):
      return "Timed out while connecting to idb_companion at \(companion.endpoint) (selected via \(companion.source.description))\(formatted(detail)). Verify that the companion is running and reachable, or pass --companion <host:port>."
    case let .unsupported(companion, detail):
      return "idb_companion at \(companion.endpoint) (selected via \(companion.source.description)) does not support idb-repl\(formatted(detail)). Upgrade or restart the companion, then retry."
    }
  }

  private func formatted(_ detail: String?) -> String {
    guard let detail, !detail.isEmpty else {
      return ""
    }
    return ": \(detail)"
  }
}

func actionableCompanionConnectionError(
  _ error: any Error,
  companion: ResolvedCompanion
) -> any Error {
  if error is CancellationError {
    return error
  }
  guard let rpcError = error as? RPCError else {
    return error
  }
  if rpcError.code == .unimplemented {
    return ReplConnectionError.unsupported(companion, detail: rpcError.message)
  }
  if rpcError.message.hasPrefix("repl:") {
    return error
  }
  if rpcError.code == .unavailable {
    return ReplConnectionError.unavailable(companion, detail: rpcError.message)
  }
  if rpcError.code == .deadlineExceeded {
    return ReplConnectionError.timedOut(companion, detail: rpcError.message)
  }
  return error
}
