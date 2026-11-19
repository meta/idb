/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBDeviceControl
import Foundation
import Testing

@Suite("JSON-serializable filtering of device-reported collections")
struct CollectionOperationsTests {

  @Test("A dictionary keeps its serializable values, recursively")
  func recursiveFilteredJSONDictionary() {
    let input: [String: Any] = [
      "string": "hello",
      "number": 42,
      "nested": ["inner": "value"],
      "nonSerializable": NSDate(),
      "array": [1, "two", NSDate()] as [Any],
    ]
    let result = CollectionOperations.recursiveFilteredJSONSerializableRepresentation(of: input)

    #expect(result["string"] as? String == "hello")
    #expect(result["number"] as? Int == 42)
    #expect(result["nested"] != nil)
    #expect(result["nonSerializable"] == nil)
    #expect((result["array"] as? [Any])?.count == 2)
  }

  @Test("An array keeps its serializable elements, recursively")
  func recursiveFilteredJSONArray() {
    let input: [Any] = ["hello", 42, NSDate(), ["key": "value"]]
    let result = CollectionOperations.recursiveFilteredJSONSerializableRepresentation(of: input)

    #expect(result.count == 3)
    #expect(result[0] as? String == "hello")
    #expect(result[1] as? Int == 42)
    #expect(result[2] is [String: String])
  }
}
