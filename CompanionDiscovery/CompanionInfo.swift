/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// The address at which a companion's gRPC server can be reached.
public enum CompanionAddress: Equatable, Sendable {
  case tcp(host: String, port: Int)
  case domainSocket(path: String)
}

// MARK: - Parsing

extension CompanionAddress {
  /// Parses a `host:port` (or `[ipv6]:port`) string into a `.tcp` address, or nil
  /// if malformed. Splits on the last colon so a bracketed IPv6 literal works.
  public static func parse(tcp value: String) -> CompanionAddress? {
    guard let colon = value.lastIndex(of: ":") else { return nil }
    var host = String(value[value.startIndex..<colon])
    let portString = String(value[value.index(after: colon)...])
    guard let port = Int(portString), (1...65535).contains(port) else { return nil }
    if host.hasPrefix("[") && host.hasSuffix("]") {
      host = String(host.dropFirst().dropLast())
    }
    guard !host.isEmpty else { return nil }
    return .tcp(host: host, port: port)
  }

  /// Parses an explicit `--companion`: the path of a companion's unix domain socket, or a
  /// `host:port` as `parse(tcp:)` reads it. A slash marks a path, since no `host:port` has one.
  public static func parse(companion value: String) -> CompanionAddress? {
    if value.contains("/") {
      return .domainSocket(path: value)
    }
    return parse(tcp: value)
  }
}

/// A record of a single running companion, keyed by the simulator/device `udid`.
public struct CompanionInfo: Codable, Equatable, Sendable {
  public let udid: String
  public let isLocal: Bool
  public let pid: Int32?
  public let address: CompanionAddress

  public init(udid: String, isLocal: Bool, pid: Int32?, address: CompanionAddress) {
    self.udid = udid
    self.isLocal = isLocal
    self.pid = pid
    self.address = address
  }

  private enum CodingKeys: String, CodingKey {
    case udid
    case isLocal = "is_local"
    case pid
    case host
    case port
    case path
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    udid = try container.decode(String.self, forKey: .udid)
    isLocal = try container.decodeIfPresent(Bool.self, forKey: .isLocal) ?? true
    pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
    if let host = try container.decodeIfPresent(String.self, forKey: .host) {
      let port = try container.decode(Int.self, forKey: .port)
      address = .tcp(host: host, port: port)
    } else {
      address = .domainSocket(path: try container.decode(String.self, forKey: .path))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(udid, forKey: .udid)
    try container.encode(isLocal, forKey: .isLocal)
    // Always emit "pid" (null when unknown) to match `json_data_companions`.
    if let pid {
      try container.encode(pid, forKey: .pid)
    } else {
      try container.encodeNil(forKey: .pid)
    }
    switch address {
    case let .tcp(host, port):
      try container.encode(host, forKey: .host)
      try container.encode(port, forKey: .port)
    case let .domainSocket(path):
      try container.encode(path, forKey: .path)
    }
  }
}
