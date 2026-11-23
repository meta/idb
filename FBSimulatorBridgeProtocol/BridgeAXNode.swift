/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

extension BridgeAXWire.Node: CodingKey {}

/// One element of a tree the guest read, keyed on the wire by `BridgeAXWire.Node`. Every attribute is optional:
/// a read carries only what it fetched, and an attribute the accessibility server could not answer arrives as
/// null, which decodes the same as absent.
public struct BridgeAXNode: Codable, Equatable, Sendable {
  public var elementType: BridgeAXScalar?
  public var elementBaseType: BridgeAXScalar?
  public var label: BridgeAXScalar?
  public var value: BridgeAXScalar?
  public var identifier: BridgeAXScalar?
  public var frame: BridgeAXRect?
  public var automationType: BridgeAXScalar?
  /// The `UIAccessibilityTraits` bitmask as XCTest's vocabulary answers it.
  public var xcTraits: UInt64?
  /// Nil when the read did not carry the key; a leaf the guest read carries an empty list.
  public var children: [BridgeAXNode]?
  public var windowDisplayID: UInt32?
  public var isVisible: Bool?
  /// `(-1, -1)` when the accessibility server believes no touch reaches the element, carried as it came.
  public var visiblePoint: BridgeAXPoint?
  public var centerPoint: BridgeAXPoint?
  public var userInteractionEnabled: Bool?
  /// What a display-wide hit-test at this unreachable element's centre found.
  @BridgeAXIndirect public var explainedBy: BridgeAXNode?
  public var isEnabled: Bool?
  public var translatorRole: Int?
  public var translatorSubrole: Int?
  /// The `UIAccessibilityTraits` bitmask as the translator answers it.
  public var traits: UInt64?
  public var elementIdentity: UInt64?
  /// The attributes that failed to read, mapped to why.
  public var attributeReadFailures: [String: String]?

  /// The wire spells each attribute as the accessibility server names it.
  public typealias CodingKeys = BridgeAXWire.Node

  public init() {}
}

/// Stores a value out of line, so a node can hold an optional node of its own type. It is coded as the value itself.
@propertyWrapper
public struct BridgeAXIndirect<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
  private indirect enum Storage: Equatable, Sendable {
    case value(Value)
  }

  private var storage: Storage

  public init(wrappedValue: Value) {
    storage = .value(wrappedValue)
  }

  public var wrappedValue: Value {
    get {
      switch storage {
      case let .value(value): value
      }
    }
    set { storage = .value(newValue) }
  }

  public init(from decoder: any Decoder) throws {
    self.init(wrappedValue: try Value(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try wrappedValue.encode(to: encoder)
  }
}

// An optional indirect value is coded as an optional field: absent when nil.
extension KeyedDecodingContainer {
  public func decode<Value>(_ type: BridgeAXIndirect<Value?>.Type, forKey key: Key) throws -> BridgeAXIndirect<Value?> {
    BridgeAXIndirect(wrappedValue: try decodeIfPresent(Value.self, forKey: key))
  }
}

extension KeyedEncodingContainer {
  public mutating func encode<Value>(_ value: BridgeAXIndirect<Value?>, forKey key: Key) throws {
    try encodeIfPresent(value.wrappedValue, forKey: key)
  }
}

/// An attribute whose type is whatever the accessibility server answered. The guest passes strings and numbers
/// through and describes anything else, so these four kinds are all it can carry. The element-type and automation-type
/// attributes arrive as a class name or as an `XCUIElementType` number.
@frozen public enum BridgeAXScalar: Codable, Equatable, Sendable {
  case string(String)
  case bool(Bool)
  case integer(Int64)
  case number(Double)

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    // Strings first: nearly every attribute is one, so the common case never throws.
    if let string = try? value.decode(String.self) {
      self = .string(string)
    } else if let bool = try? value.decode(Bool.self) {
      self = .bool(bool)
    } else if let integer = try? value.decode(Int64.self) {
      self = .integer(integer)
    } else {
      self = .number(try value.decode(Double.self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case let .string(string): try value.encode(string)
    case let .bool(bool): try value.encode(bool)
    case let .integer(integer): try value.encode(integer)
    case let .number(number): try value.encode(number)
    }
  }
}

/// A `CGRect` dictionary representation. JSON has no infinity or NaN, so a non-finite coordinate (routine for an
/// off-screen or still-laying-out element) is held as nil, and left out of the frame.
public struct BridgeAXRect: Codable, Equatable, Sendable {
  @frozen public enum CodingKeys: String, CodingKey {
    case x = "X"
    case y = "Y"
    case width = "Width"
    case height = "Height"
  }

  public var x: Double?
  public var y: Double?
  public var width: Double?
  public var height: Double?

  public init(x: Double?, y: Double?, width: Double?, height: Double?) {
    self.x = x.finite
    self.y = y.finite
    self.width = width.finite
    self.height = height.finite
  }

}

/// A `CGPoint` dictionary representation, with non-finite coordinates as `BridgeAXRect` holds them.
public struct BridgeAXPoint: Codable, Equatable, Sendable {
  @frozen public enum CodingKeys: String, CodingKey {
    case x = "X"
    case y = "Y"
  }

  public var x: Double?
  public var y: Double?

  public init(x: Double?, y: Double?) {
    self.x = x.finite
    self.y = y.finite
  }

}

extension Optional where Wrapped == Double {
  /// Nil for a value JSON cannot carry.
  fileprivate var finite: Double? {
    flatMap { $0.isFinite ? $0 : nil }
  }
}
