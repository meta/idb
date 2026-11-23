/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorBridgeProtocol
import Foundation

/// Timing and transport measurements for an axbridge read.
public struct AXBridgeProfile: Sendable, Equatable, Encodable {
  public let elementCount: Int64
  public let totalDuration: CFAbsoluteTime
  public let acquireDuration: CFAbsoluteTime
  public let readDuration: CFAbsoluteTime
  public let serializeDuration: CFAbsoluteTime
  public let traversal: AXTraversal
  public let machRoundTrips: Int64?
  public let hostDecodeDuration: CFAbsoluteTime?
  public let responseBytes: Int64?

  public init(
    elementCount: Int64,
    totalDuration: CFAbsoluteTime,
    acquireDuration: CFAbsoluteTime,
    readDuration: CFAbsoluteTime,
    serializeDuration: CFAbsoluteTime,
    traversal: AXTraversal,
    machRoundTrips: Int64? = nil,
    hostDecodeDuration: CFAbsoluteTime? = nil,
    responseBytes: Int64? = nil
  ) {
    self.elementCount = elementCount
    self.totalDuration = totalDuration
    self.acquireDuration = acquireDuration
    self.readDuration = readDuration
    self.serializeDuration = serializeDuration
    self.traversal = traversal
    self.machRoundTrips = machRoundTrips
    self.hostDecodeDuration = hostDecodeDuration
    self.responseBytes = responseBytes
  }

  enum CodingKeys: String, CodingKey {
    case elementCount = "element_count"
    case totalDurationMs = "total_duration_ms"
    case acquireDurationMs = "acquire_duration_ms"
    case readDurationMs = "read_duration_ms"
    case serializeDurationMs = "serialize_duration_ms"
    case traversal
    case machRoundTrips = "mach_round_trips"
    case hostDecodeDurationMs = "host_decode_duration_ms"
    case responseBytes = "response_bytes"
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(elementCount, forKey: .elementCount)
    try container.encode(totalDuration * 1000, forKey: .totalDurationMs)
    try container.encode(acquireDuration * 1000, forKey: .acquireDurationMs)
    try container.encode(readDuration * 1000, forKey: .readDurationMs)
    try container.encode(serializeDuration * 1000, forKey: .serializeDurationMs)
    try container.encode(traversal.rawValue, forKey: .traversal)
    // Keep optional measurements present as null. Missing means an older producer did not know the
    // field; null means this read could not measure it.
    try container.encode(machRoundTrips, forKey: .machRoundTrips)
    try container.encode(hostDecodeDuration.map { $0 * 1000 }, forKey: .hostDecodeDurationMs)
    try container.encode(responseBytes, forKey: .responseBytes)
  }
}

/// The backend-specific profile carried by a complete accessibility document.
public enum AccessibilityProfile: Sendable, Equatable, Encodable {
  case translator(AccessibilityProfilingData)
  case guestBridge(AXBridgeProfile)

  public var translatorProfile: AccessibilityProfilingData? {
    guard case let .translator(profile) = self else {
      return nil
    }
    return profile
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case let .translator(profile):
      try container.encode(profile)
    case let .guestBridge(profile):
      try container.encode(profile)
    }
  }
}

/// The assistive client a read's translator requests claimed to come from. Reported only for a read that
/// named one, so a read that did not keeps the document it always had.
public struct AccessibilityClientReport: Sendable, Equatable, Encodable {

  /// The tree the target application answers the client with.
  public enum Tree: String, Sendable, Encodable {
    /// The children an application sets in `automationElements`, falling back to the ones XCTest reads.
    case automation
    /// The flattened, labelled leaves VoiceOver reads.
    case voiceOver = "voiceover"
  }

  public let clientType: AXClientType

  public init(clientType: AXClientType) {
    self.clientType = clientType
  }

  public var tree: Tree {
    clientType.deservesAutomation ? .automation : .voiceOver
  }

  /// What a caller should know about the read this client produced, or nil when nothing departs from a
  /// default read's expectations.
  public var caveat: String? {
    guard clientType.deservesAutomation else {
      return nil
    }
    return "The automation tree takes roughly ten times the translator round trips of a default read, is not a superset of the default tree, and its granularity depends on the device's AutomationEnabled accessibility preference. An application that stores automationElements serves them as stored, whatever is on screen."
  }

  enum CodingKeys: String, CodingKey {
    case type
    case tree
    case caveat
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(clientType.name, forKey: .type)
    try container.encode(tree, forKey: .tree)
    try container.encode(caveat, forKey: .caveat)
  }
}

public struct AccessibilityAutomationState: Sendable, Equatable, Encodable {
  public let enabled: Bool
  public let asserted: Bool

  public init(enabled: Bool, asserted: Bool) {
    self.enabled = enabled
    self.asserted = asserted
  }

  enum CodingKeys: String, CodingKey {
    case enabled
    case asserted
  }
}
