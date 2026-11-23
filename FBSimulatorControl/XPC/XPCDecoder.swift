/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import XPC

/**
 Decodes an `xpc_object_t` into any `Decodable` value, the counterpart of `XPCEncoder` and the
 mirror of how `JSONDecoder` reads `Data`.

 XPC dictionaries feed keyed containers and XPC arrays feed unkeyed containers. Scalars are matched
 strictly to the XPC type the model asks for: `Bool` from bool, `String` from string, `Double`/`Float`
 from double, the signed integers from int64 and the unsigned integers from uint64 (each range-checked),
 `Data` from data and `UUID` from uuid. Nothing is coerced, so a provider that sends `1` where a model
 expects `true` is reported as a type mismatch rather than accepted.

 An absent key decodes as `nil` for an optional property. An XPC null is not a typed value: it is a
 type mismatch for anything except `XPCValue`, which captures any object as it is, and it is the one
 thing an array element can be `nil` as. Strings must be valid UTF-8.

 Failures are `DecodingError`s carrying the coding path, so a caller can report which field of which
 reply was wrong.
 */
struct XPCDecoder {
  func decode<Value: Decodable>(_ type: Value.Type, from object: xpc_object_t) throws -> Value {
    try XPCDecoderImpl(object: object, codingPath: []).decode(type)
  }
}

/// Any XPC object, as a sum type, for the fields a model has to inspect leniently rather than
/// require. Strings are read lossily here; a model that needs a validated string decodes `String`.
indirect enum XPCValue: Equatable, Sendable, Decodable {
  case bool(Bool)
  case string(String)
  case int64(Int64)
  case uint64(UInt64)
  case double(Double)
  case data(Data)
  case uuid(UUID)
  case null
  case array([XPCValue])
  case dictionary([String: XPCValue])
  /// An object with no scalar representation (a connection, an error, a file descriptor), by type name.
  case other(String)

  init(_ object: xpc_object_t) {
    switch unsafe xpc_get_type(object) {
    case unsafe XPC_TYPE_BOOL: self = .bool(xpc_bool_get_value(object))
    case unsafe XPC_TYPE_STRING: self = unsafe .string(xpc_string_get_string_ptr(object).map { unsafe String(cString: $0) } ?? "")
    case unsafe XPC_TYPE_INT64: self = .int64(xpc_int64_get_value(object))
    case unsafe XPC_TYPE_UINT64: self = .uint64(xpc_uint64_get_value(object))
    case unsafe XPC_TYPE_DOUBLE: self = .double(xpc_double_get_value(object))
    case unsafe XPC_TYPE_DATA: self = .data(XPCScalar.data(object))
    case unsafe XPC_TYPE_UUID: self = .uuid(XPCScalar.uuid(object))
    case unsafe XPC_TYPE_NULL: self = .null
    case unsafe XPC_TYPE_ARRAY:
      self = .array((0..<xpc_array_get_count(object)).map { XPCValue(xpc_array_get_value(object, $0)) })
    case unsafe XPC_TYPE_DICTIONARY:
      var values: [String: XPCValue] = [:]
      unsafe xpc_dictionary_apply(object) { key, value in
        unsafe values[String(cString: key)] = XPCValue(value)
        return true
      }
      self = .dictionary(values)
    default: self = .other(XPCScalar.typeName(object))
    }
  }

  /// Only `XPCDecoder` can produce an `XPCValue`; it intercepts the type before this is reached.
  init(from decoder: any Decoder) throws {
    throw DecodingError.dataCorrupted(
      DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "XPCValue can only be decoded from an XPC object"))
  }
}

// MARK: - Scalars

/// The strict scalar reads every container shares.
private enum XPCScalar {
  static func typeName(_ object: xpc_object_t) -> String {
    unsafe String(cString: xpc_type_get_name(xpc_get_type(object)))
  }

  static func require(_ object: xpc_object_t, _ type: xpc_type_t, _ name: String, _ expected: Any.Type, _ codingPath: [any CodingKey]) throws {
    guard unsafe xpc_get_type(object) == type else {
      throw DecodingError.typeMismatch(
        expected,
        DecodingError.Context(codingPath: codingPath, debugDescription: "Expected \(name), found \(typeName(object))"))
    }
  }

  static func bool(_ object: xpc_object_t, _ codingPath: [any CodingKey]) throws -> Bool {
    unsafe try require(object, XPC_TYPE_BOOL, "bool", Bool.self, codingPath)
    return xpc_bool_get_value(object)
  }

  static func double(_ object: xpc_object_t, _ codingPath: [any CodingKey]) throws -> Double {
    unsafe try require(object, XPC_TYPE_DOUBLE, "double", Double.self, codingPath)
    return xpc_double_get_value(object)
  }

  static func string(_ object: xpc_object_t, _ codingPath: [any CodingKey]) throws -> String {
    unsafe try require(object, XPC_TYPE_STRING, "string", String.self, codingPath)
    guard let pointer = unsafe xpc_string_get_string_ptr(object),
      let string = unsafe String(data: Data(bytes: pointer, count: xpc_string_get_length(object)), encoding: .utf8)
    else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: codingPath, debugDescription: "String is not valid UTF-8"))
    }
    return string
  }

  static func signed<T: FixedWidthInteger & SignedInteger>(_ type: T.Type, _ object: xpc_object_t, _ codingPath: [any CodingKey]) throws -> T {
    unsafe try require(object, XPC_TYPE_INT64, "int64", type, codingPath)
    return try exactly(type, xpc_int64_get_value(object), codingPath)
  }

  static func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type, _ object: xpc_object_t, _ codingPath: [any CodingKey]) throws -> T {
    unsafe try require(object, XPC_TYPE_UINT64, "uint64", type, codingPath)
    return try exactly(type, xpc_uint64_get_value(object), codingPath)
  }

  private static func exactly<T: FixedWidthInteger, Source: BinaryInteger>(_ type: T.Type, _ value: Source, _ codingPath: [any CodingKey]) throws -> T {
    guard let converted = T(exactly: value) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: codingPath, debugDescription: "\(value) does not fit in \(type)"))
    }
    return converted
  }

  static func data(_ object: xpc_object_t, _ codingPath: [any CodingKey]) throws -> Data {
    unsafe try require(object, XPC_TYPE_DATA, "data", Data.self, codingPath)
    return data(object)
  }

  static func data(_ object: xpc_object_t) -> Data {
    guard let bytes = unsafe xpc_data_get_bytes_ptr(object) else { return Data() }
    return unsafe Data(bytes: bytes, count: xpc_data_get_length(object))
  }

  static func uuid(_ object: xpc_object_t, _ codingPath: [any CodingKey]) throws -> UUID {
    unsafe try require(object, XPC_TYPE_UUID, "uuid", UUID.self, codingPath)
    return uuid(object)
  }

  static func uuid(_ object: xpc_object_t) -> UUID {
    guard let bytes = unsafe xpc_uuid_get_bytes(object) else { return UUID(uuid: UUID_NULL) }
    return unsafe UUID(uuid: UnsafeRawPointer(bytes).load(as: uuid_t.self))
  }
}

// MARK: - Decoder

private struct XPCDecoderImpl: Decoder {
  let object: xpc_object_t
  var codingPath: [any CodingKey]
  var userInfo: [CodingUserInfoKey: Any] { [:] }

  /// `Data`, `UUID` and `XPCValue` are read straight from the object, ahead of their own `Decodable`
  /// conformances, which would expect an array of bytes, a string, or nothing at all.
  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    if type is Data.Type, let data = try XPCScalar.data(object, codingPath) as? T {
      return data
    }
    if type is UUID.Type, let uuid = try XPCScalar.uuid(object, codingPath) as? T {
      return uuid
    }
    if type is XPCValue.Type, let value = XPCValue(object) as? T {
      return value
    }
    return try T(from: self)
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    unsafe try XPCScalar.require(object, XPC_TYPE_DICTIONARY, "dictionary", [String: Any].self, codingPath)
    return KeyedDecodingContainer(XPCKeyedDecodingContainer<Key>(dictionary: object, codingPath: codingPath))
  }

  func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
    unsafe try XPCScalar.require(object, XPC_TYPE_ARRAY, "array", [Any].self, codingPath)
    return XPCUnkeyedDecodingContainer(array: object, codingPath: codingPath)
  }

  func singleValueContainer() throws -> any SingleValueDecodingContainer {
    XPCSingleValueDecodingContainer(object: object, codingPath: codingPath)
  }
}

private struct XPCKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
  let dictionary: xpc_object_t
  var codingPath: [any CodingKey]

  var allKeys: [Key] {
    var keys: [Key] = []
    unsafe xpc_dictionary_apply(dictionary) { key, _ in
      if let key = unsafe Key(stringValue: String(cString: key)) { keys.append(key) }
      return true
    }
    return keys
  }

  func contains(_ key: Key) -> Bool {
    unsafe xpc_dictionary_get_value(dictionary, key.stringValue) != nil
  }

  private func value(_ key: Key) throws -> xpc_object_t {
    guard let value = unsafe xpc_dictionary_get_value(dictionary, key.stringValue) else {
      throw DecodingError.keyNotFound(
        key, DecodingError.Context(codingPath: codingPath, debugDescription: "Missing key \(key.stringValue)"))
    }
    return value
  }

  private func path(_ key: Key) -> [any CodingKey] { codingPath + [key] }

  /// A present key never reads as nil, so an XPC null under an optional property is a mismatch
  /// rather than an absence.
  func decodeNil(forKey key: Key) throws -> Bool {
    _ = try value(key)
    return false
  }

  func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try XPCScalar.bool(value(key), path(key)) }
  func decode(_ type: String.Type, forKey key: Key) throws -> String { try XPCScalar.string(value(key), path(key)) }
  func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try XPCScalar.double(value(key), path(key)) }
  func decode(_ type: Float.Type, forKey key: Key) throws -> Float { Float(try XPCScalar.double(value(key), path(key))) }
  func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try XPCScalar.signed(type, value(key), path(key)) }
  func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try XPCScalar.signed(type, value(key), path(key)) }
  func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try XPCScalar.signed(type, value(key), path(key)) }
  func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try XPCScalar.signed(type, value(key), path(key)) }
  func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try XPCScalar.signed(type, value(key), path(key)) }
  func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try XPCScalar.unsigned(type, value(key), path(key)) }
  func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try XPCScalar.unsigned(type, value(key), path(key)) }
  func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try XPCScalar.unsigned(type, value(key), path(key)) }
  func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try XPCScalar.unsigned(type, value(key), path(key)) }
  func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try XPCScalar.unsigned(type, value(key), path(key)) }

  func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
    try XPCDecoderImpl(object: value(key), codingPath: path(key)).decode(type)
  }

  func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
    try XPCDecoderImpl(object: value(key), codingPath: path(key)).container(keyedBy: type)
  }

  func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
    try XPCDecoderImpl(object: value(key), codingPath: path(key)).unkeyedContainer()
  }

  func superDecoder() throws -> any Decoder { XPCDecoderImpl(object: dictionary, codingPath: codingPath) }
  func superDecoder(forKey key: Key) throws -> any Decoder { XPCDecoderImpl(object: try value(key), codingPath: path(key)) }
}

private struct XPCUnkeyedDecodingContainer: UnkeyedDecodingContainer {
  let array: xpc_object_t
  var codingPath: [any CodingKey]
  private(set) var currentIndex = 0

  init(array: xpc_object_t, codingPath: [any CodingKey]) {
    self.array = array
    self.codingPath = codingPath
  }

  var count: Int? { xpc_array_get_count(array) }
  var isAtEnd: Bool { currentIndex >= xpc_array_get_count(array) }

  private var currentPath: [any CodingKey] { codingPath + [XPCIndexKey(intValue: currentIndex)] }

  private mutating func next(_ expected: Any.Type) throws -> (object: xpc_object_t, codingPath: [any CodingKey]) {
    guard !isAtEnd else {
      throw DecodingError.valueNotFound(
        expected, DecodingError.Context(codingPath: currentPath, debugDescription: "Array has no element at index \(currentIndex)"))
    }
    defer { currentIndex += 1 }
    return (xpc_array_get_value(array, currentIndex), currentPath)
  }

  /// An XPC null element is the array form of `nil`, and is consumed by reading it as such.
  mutating func decodeNil() throws -> Bool {
    guard !isAtEnd else {
      throw DecodingError.valueNotFound(
        Any?.self, DecodingError.Context(codingPath: currentPath, debugDescription: "Array has no element at index \(currentIndex)"))
    }
    guard unsafe xpc_get_type(xpc_array_get_value(array, currentIndex)) == XPC_TYPE_NULL else { return false }
    currentIndex += 1
    return true
  }

  mutating func decode(_ type: Bool.Type) throws -> Bool {
    let next = try next(type)
    return try XPCScalar.bool(next.object, next.codingPath)
  }
  mutating func decode(_ type: String.Type) throws -> String {
    let next = try next(type)
    return try XPCScalar.string(next.object, next.codingPath)
  }
  mutating func decode(_ type: Double.Type) throws -> Double {
    let next = try next(type)
    return try XPCScalar.double(next.object, next.codingPath)
  }
  mutating func decode(_ type: Float.Type) throws -> Float {
    let next = try next(type)
    return Float(try XPCScalar.double(next.object, next.codingPath))
  }
  mutating func decode(_ type: Int.Type) throws -> Int {
    let next = try next(type)
    return try XPCScalar.signed(type, next.object, next.codingPath)
  }
  mutating func decode(_ type: Int8.Type) throws -> Int8 {
    let next = try next(type)
    return try XPCScalar.signed(type, next.object, next.codingPath)
  }
  mutating func decode(_ type: Int16.Type) throws -> Int16 {
    let next = try next(type)
    return try XPCScalar.signed(type, next.object, next.codingPath)
  }
  mutating func decode(_ type: Int32.Type) throws -> Int32 {
    let next = try next(type)
    return try XPCScalar.signed(type, next.object, next.codingPath)
  }
  mutating func decode(_ type: Int64.Type) throws -> Int64 {
    let next = try next(type)
    return try XPCScalar.signed(type, next.object, next.codingPath)
  }
  mutating func decode(_ type: UInt.Type) throws -> UInt {
    let next = try next(type)
    return try XPCScalar.unsigned(type, next.object, next.codingPath)
  }
  mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
    let next = try next(type)
    return try XPCScalar.unsigned(type, next.object, next.codingPath)
  }
  mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
    let next = try next(type)
    return try XPCScalar.unsigned(type, next.object, next.codingPath)
  }
  mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
    let next = try next(type)
    return try XPCScalar.unsigned(type, next.object, next.codingPath)
  }
  mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
    let next = try next(type)
    return try XPCScalar.unsigned(type, next.object, next.codingPath)
  }

  mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
    let next = try next(type)
    return try XPCDecoderImpl(object: next.object, codingPath: next.codingPath).decode(type)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
    let next = try next([String: Any].self)
    return try XPCDecoderImpl(object: next.object, codingPath: next.codingPath).container(keyedBy: type)
  }

  mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
    let next = try next([Any].self)
    return try XPCDecoderImpl(object: next.object, codingPath: next.codingPath).unkeyedContainer()
  }

  mutating func superDecoder() throws -> any Decoder {
    let next = try next(Any.self)
    return XPCDecoderImpl(object: next.object, codingPath: next.codingPath)
  }
}

private struct XPCSingleValueDecodingContainer: SingleValueDecodingContainer {
  let object: xpc_object_t
  var codingPath: [any CodingKey]

  func decodeNil() -> Bool { unsafe xpc_get_type(object) == XPC_TYPE_NULL }

  func decode(_ type: Bool.Type) throws -> Bool { try XPCScalar.bool(object, codingPath) }
  func decode(_ type: String.Type) throws -> String { try XPCScalar.string(object, codingPath) }
  func decode(_ type: Double.Type) throws -> Double { try XPCScalar.double(object, codingPath) }
  func decode(_ type: Float.Type) throws -> Float { Float(try XPCScalar.double(object, codingPath)) }
  func decode(_ type: Int.Type) throws -> Int { try XPCScalar.signed(type, object, codingPath) }
  func decode(_ type: Int8.Type) throws -> Int8 { try XPCScalar.signed(type, object, codingPath) }
  func decode(_ type: Int16.Type) throws -> Int16 { try XPCScalar.signed(type, object, codingPath) }
  func decode(_ type: Int32.Type) throws -> Int32 { try XPCScalar.signed(type, object, codingPath) }
  func decode(_ type: Int64.Type) throws -> Int64 { try XPCScalar.signed(type, object, codingPath) }
  func decode(_ type: UInt.Type) throws -> UInt { try XPCScalar.unsigned(type, object, codingPath) }
  func decode(_ type: UInt8.Type) throws -> UInt8 { try XPCScalar.unsigned(type, object, codingPath) }
  func decode(_ type: UInt16.Type) throws -> UInt16 { try XPCScalar.unsigned(type, object, codingPath) }
  func decode(_ type: UInt32.Type) throws -> UInt32 { try XPCScalar.unsigned(type, object, codingPath) }
  func decode(_ type: UInt64.Type) throws -> UInt64 { try XPCScalar.unsigned(type, object, codingPath) }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try XPCDecoderImpl(object: object, codingPath: codingPath).decode(type)
  }
}
