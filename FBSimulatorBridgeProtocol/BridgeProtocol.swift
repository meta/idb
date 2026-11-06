/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

@frozen public enum BridgeProtocolError: Error, Equatable {
  case invalidJSONValue
  case unsupportedVersion(Int)
  case mismatchedResponse
}

public struct BridgeRequest: Codable, Equatable, Sendable {
  public static let currentVersion = 7
  public let version: Int
  public let id: String
  public let command: BridgeCommand

  public init(command: BridgeCommand, id: String = UUID().uuidString) {
    version = Self.currentVersion
    self.id = id
    self.command = command
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(self)
  }

  public var arguments: [String] {
    get throws {
      ["rpc", String(decoding: try encoded(), as: UTF8.self)]
    }
  }

  public static func decode(_ data: Data) throws -> Self {
    // The version is checked before the command so a newer command shape reports the version gap,
    // not a decoding failure.
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == currentVersion else { throw BridgeProtocolError.unsupportedVersion(envelope.version) }
    return try JSONDecoder().decode(Self.self, from: data)
  }

  /// The identity a request carries even when the rest of it cannot be decoded, so a reply can still name it.
  public static func identity(of data: Data) -> String? {
    (try? JSONDecoder().decode(Identity.self, from: data))?.id
  }

  private struct Envelope: Decodable {
    let version: Int
    let id: String
  }

  private struct Identity: Decodable {
    let id: String?
  }
}

public struct BridgeResult: Codable, Equatable, Sendable {
  public let exitCode: Int32
  public let error: String?
  /// The command's answers, in the order it gave them.
  public let answers: [BridgeAnswer]

  public init(exitCode: Int32, error: String? = nil, answers: [BridgeAnswer] = []) {
    self.exitCode = exitCode
    self.error = error
    self.answers = answers
  }

  /// An accessibility command's answer.
  public var accessibility: BridgeAXAnswer? {
    answers.lazy.compactMap { answer -> BridgeAXAnswer? in
      guard case let .accessibility(accessibility) = answer else { return nil }
      return accessibility
    }.first
  }

  /// A dynamic-store snapshot's property list.
  public var propertyList: Data? {
    answers.lazy.compactMap { answer -> Data? in
      guard case let .dynamicStoreSnapshot(propertyList) = answer else { return nil }
      return propertyList
    }.first
  }
}

extension BridgeResult {
  /// The command's output as the host reports it: each answer a line of JSON, its keys sorted.
  public var jsonLines: String {
    get throws {
      try answers.map { try $0.jsonLine() + "\n" }.joined()
    }
  }

  /// What the host reports for the command, whether it succeeded or failed: its error, then its output.
  public var reportedOutput: String {
    get throws {
      try [error, jsonLines].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
  }
}

public struct BridgeResponse: Codable, Equatable, Sendable {
  public let version: Int
  public let id: String?
  public let result: BridgeResult

  public init(request: BridgeRequest, result: BridgeResult) {
    self.init(id: request.id, result: result)
  }

  public init(id: String?, result: BridgeResult) {
    version = BridgeRequest.currentVersion
    self.id = id
    self.result = result
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(self)
  }

  /// Decodes the response to `request`, refusing one at another version or for another request.
  public static func decode(_ data: Data, for request: BridgeRequest) throws -> Self {
    let response = try JSONDecoder().decode(Self.self, from: data)
    try check(version: response.version, id: response.id, for: request)
    return response
  }

  /// Checks `data` is the response to `request`, at this version, without decoding its result.
  public static func validate(_ data: Data, for request: BridgeRequest) throws {
    let identity = try JSONDecoder().decode(Identity.self, from: data)
    try check(version: identity.version, id: identity.id, for: request)
  }

  private static func check(version: Int, id: String?, for request: BridgeRequest) throws {
    guard version == BridgeRequest.currentVersion else { throw BridgeProtocolError.unsupportedVersion(version) }
    guard id == request.id else { throw BridgeProtocolError.mismatchedResponse }
  }

  private struct Identity: Decodable {
    let version: Int
    let id: String?
  }
}
