/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// A single JSON-RPC 2.0 request as received over a companion connection.
///
/// `id` is absent for notifications; `params` is optional and may be any JSON
/// value. `jsonrpc` is decoded leniently (it should be "2.0") so a malformed or
/// missing version does not drop the whole message.
public struct JSONRPCRequest: Codable, Equatable, Sendable, CustomStringConvertible {
  public let jsonrpc: String?
  public let method: String
  public let params: JSONValue?
  public let id: JSONValue?

  public init(jsonrpc: String? = "2.0", method: String, params: JSONValue? = nil, id: JSONValue? = nil) {
    self.jsonrpc = jsonrpc
    self.method = method
    self.params = params
    self.id = id
  }

  public var description: String {
    "JSONRPCRequest(method: \(method), id: \(id.map(String.init(describing:)) ?? "nil"), params: \(params.map(String.init(describing:)) ?? "nil"))"
  }
}

/// A minimal recursive JSON value, used for the dynamically-typed `params` and
/// `id` fields of a JSON-RPC request where the shape is not known ahead of time.
public enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case let .bool(value):
      try container.encode(value)
    case let .number(value):
      try container.encode(value)
    case let .string(value):
      try container.encode(value)
    case let .array(value):
      try container.encode(value)
    case let .object(value):
      try container.encode(value)
    }
  }
}

/// A single JSON-RPC 2.0 response sent back over a companion connection. Exactly
/// one of `result` / `error` is set. `result` is method-specific; for a `cli`
/// request it is an object `{ "stdout": String, "exitCode": Int }`.
public struct JSONRPCResponse: Codable, Equatable, Sendable {
  public let jsonrpc: String
  public let id: JSONValue?
  public let result: JSONValue?
  public let error: JSONValue?

  public init(id: JSONValue?, result: JSONValue? = nil, error: JSONValue? = nil) {
    self.jsonrpc = "2.0"
    self.id = id
    self.result = result
    self.error = error
  }
}
