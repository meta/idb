/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import XPC

/**
 Encodes any `Encodable` value into an `xpc_object_t`, mirroring how `JSONEncoder` produces `Data`.

 Keyed containers become XPC dictionaries and unkeyed containers become XPC arrays, nesting freely.
 Scalars map to the matching XPC scalar: `UInt`/`UInt8…UInt64` → `uint64`, `Int`/`Int8…Int64` →
 `int64`, `Double`/`Float` → `double`, `Bool` → `bool`, `String` → `string`, `Data` → `data`, `UUID`
 → `uuid`. Optional properties that are `nil` are omitted (no key is written), so a model's optionals
 decide which keys appear on the wire; a `nil` element of an array is written as an XPC null so the
 array keeps its shape.
 */
struct XPCEncoder {
  func encode<Value: Encodable>(_ value: Value) throws -> xpc_object_t {
    let encoder = XPCEncoderImpl()
    try encoder.encode(value)
    guard let object = encoder.storage.object else {
      throw EncodingError.invalidValue(
        value, EncodingError.Context(codingPath: [], debugDescription: "Value did not encode any XPC object"))
    }
    return object
  }
}

/// Shared, mutable result slot — a reference so the value-type containers can write the built object.
private final class XPCBox {
  var object: xpc_object_t?
}

private func xpcUUID(_ uuid: UUID) -> xpc_object_t {
  var bytes = uuid.uuid
  return withUnsafePointer(to: &bytes) {
    unsafe $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<uuid_t>.size) { unsafe xpc_uuid_create($0) }
  }
}

private struct XPCEncoderImpl: Encoder {
  let storage: XPCBox
  var codingPath: [any CodingKey]
  var userInfo: [CodingUserInfoKey: Any] { [:] }

  init(storage: XPCBox = XPCBox(), codingPath: [any CodingKey] = []) {
    self.storage = storage
    self.codingPath = codingPath
  }

  /// `Data` and `UUID` have native XPC types, so they are intercepted before their own `Codable`
  /// conformances would turn them into an array of bytes or a string.
  func encode(_ value: some Encodable) throws {
    switch value {
    case let data as Data:
      storage.object = unsafe data.withUnsafeBytes { unsafe xpc_data_create($0.baseAddress, $0.count) }
    case let uuid as UUID:
      storage.object = xpcUUID(uuid)
    default:
      try value.encode(to: self)
    }
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    let dictionary = storage.object ?? xpc_dictionary_create(nil, nil, 0)
    storage.object = dictionary
    return KeyedEncodingContainer(XPCKeyedContainer<Key>(dictionary: dictionary, codingPath: codingPath))
  }

  func singleValueContainer() -> any SingleValueEncodingContainer {
    XPCSingleValueContainer(storage: storage, codingPath: codingPath)
  }

  func unkeyedContainer() -> any UnkeyedEncodingContainer {
    let array = storage.object ?? xpc_array_create(nil, 0)
    storage.object = array
    return XPCUnkeyedContainer(array: array, codingPath: codingPath)
  }
}

/// Encodes one nested value to its own object, for a keyed or unkeyed parent to attach.
private func encodeNested(_ value: some Encodable, codingPath: [any CodingKey]) throws -> xpc_object_t {
  let nested = XPCEncoderImpl(codingPath: codingPath)
  try nested.encode(value)
  guard let object = nested.storage.object else {
    throw EncodingError.invalidValue(
      value, EncodingError.Context(codingPath: codingPath, debugDescription: "Nested value did not encode any XPC object"))
  }
  return object
}

private struct XPCKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
  let dictionary: xpc_object_t
  var codingPath: [any CodingKey]

  func encodeNil(forKey key: Key) throws {} // omit the key entirely

  func encode(_ value: Bool, forKey key: Key) throws { unsafe xpc_dictionary_set_bool(dictionary, key.stringValue, value) }
  func encode(_ value: String, forKey key: Key) throws { unsafe xpc_dictionary_set_string(dictionary, key.stringValue, value) }
  func encode(_ value: Double, forKey key: Key) throws { unsafe xpc_dictionary_set_double(dictionary, key.stringValue, value) }
  func encode(_ value: Float, forKey key: Key) throws { unsafe xpc_dictionary_set_double(dictionary, key.stringValue, Double(value)) }
  func encode(_ value: Int, forKey key: Key) throws { unsafe xpc_dictionary_set_int64(dictionary, key.stringValue, Int64(value)) }
  func encode(_ value: Int8, forKey key: Key) throws { unsafe xpc_dictionary_set_int64(dictionary, key.stringValue, Int64(value)) }
  func encode(_ value: Int16, forKey key: Key) throws { unsafe xpc_dictionary_set_int64(dictionary, key.stringValue, Int64(value)) }
  func encode(_ value: Int32, forKey key: Key) throws { unsafe xpc_dictionary_set_int64(dictionary, key.stringValue, Int64(value)) }
  func encode(_ value: Int64, forKey key: Key) throws { unsafe xpc_dictionary_set_int64(dictionary, key.stringValue, value) }
  func encode(_ value: UInt, forKey key: Key) throws { unsafe xpc_dictionary_set_uint64(dictionary, key.stringValue, UInt64(value)) }
  func encode(_ value: UInt8, forKey key: Key) throws { unsafe xpc_dictionary_set_uint64(dictionary, key.stringValue, UInt64(value)) }
  func encode(_ value: UInt16, forKey key: Key) throws { unsafe xpc_dictionary_set_uint64(dictionary, key.stringValue, UInt64(value)) }
  func encode(_ value: UInt32, forKey key: Key) throws { unsafe xpc_dictionary_set_uint64(dictionary, key.stringValue, UInt64(value)) }
  func encode(_ value: UInt64, forKey key: Key) throws { unsafe xpc_dictionary_set_uint64(dictionary, key.stringValue, value) }

  func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
    unsafe xpc_dictionary_set_value(dictionary, key.stringValue, try encodeNested(value, codingPath: codingPath + [key]))
  }

  func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type, forKey key: Key
  ) -> KeyedEncodingContainer<NestedKey> {
    let nested = xpc_dictionary_create(nil, nil, 0)
    unsafe xpc_dictionary_set_value(dictionary, key.stringValue, nested)
    return KeyedEncodingContainer(XPCKeyedContainer<NestedKey>(dictionary: nested, codingPath: codingPath + [key]))
  }

  func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
    let nested = xpc_array_create(nil, 0)
    unsafe xpc_dictionary_set_value(dictionary, key.stringValue, nested)
    return XPCUnkeyedContainer(array: nested, codingPath: codingPath + [key])
  }

  func superEncoder() -> any Encoder { XPCEncoderImpl(storage: XPCBox(), codingPath: codingPath) }
  func superEncoder(forKey key: Key) -> any Encoder { XPCEncoderImpl(storage: XPCBox(), codingPath: codingPath + [key]) }
}

private struct XPCUnkeyedContainer: UnkeyedEncodingContainer {
  let array: xpc_object_t
  var codingPath: [any CodingKey]

  var count: Int { xpc_array_get_count(array) }

  private var nextPath: [any CodingKey] { codingPath + [XPCIndexKey(intValue: count)] }

  mutating func encodeNil() throws { xpc_array_append_value(array, xpc_null_create()) }

  mutating func encode(_ value: Bool) throws { xpc_array_append_value(array, xpc_bool_create(value)) }
  mutating func encode(_ value: String) throws { xpc_array_append_value(array, value.withCString { unsafe xpc_string_create($0) }) }
  mutating func encode(_ value: Double) throws { xpc_array_append_value(array, xpc_double_create(value)) }
  mutating func encode(_ value: Float) throws { xpc_array_append_value(array, xpc_double_create(Double(value))) }
  mutating func encode(_ value: Int) throws { xpc_array_append_value(array, xpc_int64_create(Int64(value))) }
  mutating func encode(_ value: Int8) throws { xpc_array_append_value(array, xpc_int64_create(Int64(value))) }
  mutating func encode(_ value: Int16) throws { xpc_array_append_value(array, xpc_int64_create(Int64(value))) }
  mutating func encode(_ value: Int32) throws { xpc_array_append_value(array, xpc_int64_create(Int64(value))) }
  mutating func encode(_ value: Int64) throws { xpc_array_append_value(array, xpc_int64_create(value)) }
  mutating func encode(_ value: UInt) throws { xpc_array_append_value(array, xpc_uint64_create(UInt64(value))) }
  mutating func encode(_ value: UInt8) throws { xpc_array_append_value(array, xpc_uint64_create(UInt64(value))) }
  mutating func encode(_ value: UInt16) throws { xpc_array_append_value(array, xpc_uint64_create(UInt64(value))) }
  mutating func encode(_ value: UInt32) throws { xpc_array_append_value(array, xpc_uint64_create(UInt64(value))) }
  mutating func encode(_ value: UInt64) throws { xpc_array_append_value(array, xpc_uint64_create(value)) }

  /// An element that encodes nothing (an `Optional.none`) still occupies its slot, as a null.
  mutating func encode<T: Encodable>(_ value: T) throws {
    let nested = XPCEncoderImpl(codingPath: nextPath)
    try nested.encode(value)
    xpc_array_append_value(array, nested.storage.object ?? xpc_null_create())
  }

  mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
    let path = nextPath
    let nested = xpc_dictionary_create(nil, nil, 0)
    xpc_array_append_value(array, nested)
    return KeyedEncodingContainer(XPCKeyedContainer<NestedKey>(dictionary: nested, codingPath: path))
  }

  mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
    let path = nextPath
    let nested = xpc_array_create(nil, 0)
    xpc_array_append_value(array, nested)
    return XPCUnkeyedContainer(array: nested, codingPath: path)
  }

  mutating func superEncoder() -> any Encoder { XPCEncoderImpl(storage: XPCBox(), codingPath: nextPath) }
}

private struct XPCSingleValueContainer: SingleValueEncodingContainer {
  let storage: XPCBox
  var codingPath: [any CodingKey]

  func encodeNil() throws {} // leaves the slot empty

  mutating func encode(_ value: Bool) throws { storage.object = xpc_bool_create(value) }
  mutating func encode(_ value: String) throws { storage.object = value.withCString { unsafe xpc_string_create($0) } }
  mutating func encode(_ value: Double) throws { storage.object = xpc_double_create(value) }
  mutating func encode(_ value: Float) throws { storage.object = xpc_double_create(Double(value)) }
  mutating func encode(_ value: Int) throws { storage.object = xpc_int64_create(Int64(value)) }
  mutating func encode(_ value: Int8) throws { storage.object = xpc_int64_create(Int64(value)) }
  mutating func encode(_ value: Int16) throws { storage.object = xpc_int64_create(Int64(value)) }
  mutating func encode(_ value: Int32) throws { storage.object = xpc_int64_create(Int64(value)) }
  mutating func encode(_ value: Int64) throws { storage.object = xpc_int64_create(value) }
  mutating func encode(_ value: UInt) throws { storage.object = xpc_uint64_create(UInt64(value)) }
  mutating func encode(_ value: UInt8) throws { storage.object = xpc_uint64_create(UInt64(value)) }
  mutating func encode(_ value: UInt16) throws { storage.object = xpc_uint64_create(UInt64(value)) }
  mutating func encode(_ value: UInt32) throws { storage.object = xpc_uint64_create(UInt64(value)) }
  mutating func encode(_ value: UInt64) throws { storage.object = xpc_uint64_create(value) }

  mutating func encode<T: Encodable>(_ value: T) throws {
    let nested = XPCEncoderImpl(storage: storage, codingPath: codingPath)
    try nested.encode(value)
  }
}

/// The coding-path key for an array element, shared by the encoder and decoder.
struct XPCIndexKey: CodingKey {
  let intValue: Int?
  var stringValue: String { "Index \(intValue ?? 0)" }

  init(intValue: Int) { self.intValue = intValue }
  init?(stringValue: String) { return nil }
}
