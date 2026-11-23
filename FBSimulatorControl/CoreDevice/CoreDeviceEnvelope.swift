/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import XPC

/// The installed CoreDevice framework version, which every action request declares.
struct CoreDeviceVersion: Encodable, Equatable, Sendable {
  let string: String
  let components: [UInt64]

  /// Parses a dotted version such as `651.13.4`; every component must be an unsigned integer.
  init(_ string: String) throws {
    let parts = string.split(separator: ".", omittingEmptySubsequences: false)
    let components = parts.compactMap { UInt64($0) }
    guard !components.isEmpty, components.count == parts.count else {
      throw SimulatorCoreDeviceError.unavailable("Invalid CoreDevice version \(string)")
    }
    self.string = string
    self.components = components
  }

  /// The version of the CoreDevice framework installed on this host.
  static func installed() throws -> CoreDeviceVersion {
    let url = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework")
    guard let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
      throw SimulatorCoreDeviceError.unsupported("CoreDevice version metadata")
    }
    return try CoreDeviceVersion(version)
  }

  private enum CodingKeys: String, CodingKey {
    case components
    case originalComponentsCount
    case stringValue
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(components, forKey: .components)
    try container.encode(Int64(components.count), forKey: .originalComponentsCount)
    try container.encode(string, forKey: .stringValue)
  }
}

/// The input of an action that takes none. Encodes as an empty dictionary.
struct CoreDeviceEmptyInput: Encodable {}

/// One CoreDevice action request: the DDI envelope every feature shares, around the feature's own
/// input. A fresh invocation identifier is minted per request.
struct CoreDeviceRequest<Input: Encodable>: Encodable {
  let action: String
  let deviceID: String
  let version: CoreDeviceVersion
  let input: Input
  let invocationIdentifier = UUID().uuidString

  private static var protocolVersion: Int64 { 1 }

  private enum CodingKeys: String, CodingKey {
    case action = "CoreDevice.actionIdentifier"
    case deviceID = "CoreDevice.deviceIdentifier"
    case invocationIdentifier = "CoreDevice.invocationIdentifier"
    case protocolVersion = "CoreDevice.CoreDeviceDDIProtocolVersion"
    case version = "CoreDevice.coreDeviceVersion"
    case input = "CoreDevice.input"
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(action, forKey: .action)
    try container.encode(deviceID, forKey: .deviceID)
    try container.encode(invocationIdentifier, forKey: .invocationIdentifier)
    try container.encode(Self.protocolVersion, forKey: .protocolVersion)
    try container.encode(version, forKey: .version)
    try container.encode(input, forKey: .input)
  }

  func encoded() throws -> xpc_object_t {
    try XPCEncoder().encode(self)
  }
}

/// The reply to a CoreDevice action: either a provider error or the feature's output.
enum CoreDeviceReply {
  struct ProviderError: Decodable {
    let domain: String
    let code: Int64
  }

  private enum CodingKeys: String, CodingKey {
    case error = "CoreDevice.error"
    case output = "CoreDevice.output"
  }

  /// A replied error wins over any output beside it.
  private struct Envelope<Output: Decodable>: Decodable {
    let output: Output

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if container.contains(.error) {
        let error = try container.decode(ProviderError.self, forKey: .error)
        throw SimulatorCoreDeviceError.unavailable("\(error.domain) (\(error.code))")
      }
      output = try container.decode(Output.self, forKey: .output)
    }
  }

  /// Decodes the feature's output from a reply, surfacing a provider error as `unavailable` and a
  /// reply the protocol does not describe as `malformed`.
  static func decode<Output: Decodable>(_ type: Output.Type, from reply: xpc_object_t) throws -> Output {
    try SimulatorCoreDevice.decode(Envelope<Output>.self, from: reply).output
  }

  /// Checks a reply whose output carries nothing the caller needs, such as a stream's final reply.
  static func validate(_ reply: xpc_object_t) throws {
    _ = try SimulatorCoreDevice.decode(Envelope<CoreDeviceEmptyOutput>.self, from: reply)
  }

  private struct CoreDeviceEmptyOutput: Decodable {
    init(from decoder: any Decoder) throws {
      _ = try decoder.container(keyedBy: CodingKeys.self)
    }
  }
}
