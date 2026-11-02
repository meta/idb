/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation

public enum ShimulatorWireProtocol {
  public static let currentVersion = 1

  public static func socketDirectory(userID: uid_t = getuid()) -> String {
    "/tmp/idb-shimulator-\(userID)"
  }

  public static func socketPath(capability: String, simulatorUDID: String, userID: uid_t = getuid()) -> String {
    let name = simulatorUDID.replacingOccurrences(of: "-", with: "").uppercased()
    return "\(socketDirectory(userID: userID))/\(name).\(capability).sock"
  }

}

@frozen public enum ShimulatorProtocolError: Error, Equatable, Sendable, CustomStringConvertible {
  case unsupportedVersion(Int)

  public var description: String {
    switch self {
    case let .unsupportedVersion(version):
      "Shimulator protocol version \(version) is not version \(ShimulatorWireProtocol.currentVersion)"
    }
  }
}

private struct ShimulatorEnvelope: Decodable {
  let version: Int

  static func decode<Message: Decodable>(_ type: Message.Type, from data: Data) throws -> Message {
    let version = try JSONDecoder().decode(Self.self, from: data).version
    guard version == ShimulatorWireProtocol.currentVersion else {
      throw ShimulatorProtocolError.unsupportedVersion(version)
    }
    return try JSONDecoder().decode(type, from: data)
  }
}

public struct ShimulatorRequest<Parameters: Codable & Sendable>: Codable, Sendable {
  public let version: Int
  public let parameters: Parameters

  public init(version: Int = ShimulatorWireProtocol.currentVersion, parameters: Parameters) {
    self.version = version
    self.parameters = parameters
  }

  public static func decode(_ data: Data) throws -> Self {
    try ShimulatorEnvelope.decode(Self.self, from: data)
  }
}

extension ShimulatorRequest: Equatable where Parameters: Equatable {}

@frozen public enum ShimulatorResponseState: String, Codable, Equatable, Sendable {
  case accepted
  case completed
  case failed
}

public struct ShimulatorResponse: Codable, Equatable, Sendable {
  public let version: Int
  public let processIdentifier: Int32
  public let processName: String
  public let state: ShimulatorResponseState
  public let message: String?
  /// What a capability reports beyond its state, encoded as that capability defines; absent from a capability
  /// that reports nothing more, and from a process that predates it.
  public let payload: Data?

  public init(
    version: Int = ShimulatorWireProtocol.currentVersion,
    processIdentifier: Int32,
    processName: String,
    state: ShimulatorResponseState,
    message: String? = nil,
    payload: Data? = nil
  ) {
    self.version = version
    self.processIdentifier = processIdentifier
    self.processName = processName
    self.state = state
    self.message = message
    self.payload = payload
  }

  public static func decode(_ data: Data) throws -> Self {
    try ShimulatorEnvelope.decode(Self.self, from: data)
  }
}
