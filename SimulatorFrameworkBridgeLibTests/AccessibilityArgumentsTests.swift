/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import SimulatorFrameworkBridgeSupport
import Testing

@Suite
struct AccessibilityArgumentsTests {
  @Test
  func requestPreservesFlagValuesAndFoundationCoercion() {
    let request = AXBridgeArguments.request(
      action: "perform",
      arguments: [
        "--pid", "12suffix", "--max-depth", "nonsense", "--max-nodes", "-3",
        "--traversal", "semantic", "--client-type", "4", "--explain-unreachable", "true",
        "--attributes", "label,,value,", "--x", "1.5tail", "--y", "bad",
        "--method", "window-server", "--action", "press", "--value", "",
        "--setting", "voiceover", "--enabled", "false", "--assert-key", "label", "--assert-value", "Hello",
      ])
    let expected: [String: Any] = [
      "verb": "perform", "pid": 12, "maxDepth": 0, "maxNodes": -3,
      "traversal": "semantic", "clientType": 4, "explainUnreachable": true,
      "attributes": ["label", "", "value", ""], "x": 1.5, "y": 0,
      "method": "window-server", "action": "press", "value": "", "setting": "voiceover",
      "enabled": false, "assertKey": "label", "assertValue": "Hello",
    ]
    #expect(request as NSDictionary == expected as NSDictionary)
  }

  @Test
  func requestUsesLastDuplicateAndIgnoresUnknownAndDanglingFlags() {
    let request = AXBridgeArguments.request(
      action: "describe",
      arguments: [
        "--pid", "10", "--unknown", "ignored", "--pid", "20", "--max-depth",
      ])
    #expect(request as NSDictionary == ["verb": "describe", "pid": 20] as NSDictionary)
    #expect(
      AXBridgeArguments.request(action: "settings-get", arguments: []) as NSDictionary == ["verb": "settings-get"] as NSDictionary)
  }

  @Test
  func enabledOnlyCoercesExactBooleanSpellings() {
    for (input, expected): (String, Any) in [("true", true), ("false", false), ("YES", "YES"), ("1", "1"), ("", "")] {
      let request = AXBridgeArguments.request(action: "settings-set", arguments: ["--enabled", input])
      #expect(request as NSDictionary == ["verb": "settings-set", "enabled": expected] as NSDictionary)
    }
  }

  @Test
  func automationModeHonorsBothValuesAndPreservesOmission() {
    for (input, expected) in [("1", true), ("0", false)] {
      let request = AXBridgeArguments.request(action: "describe", arguments: ["--automation-mode", input])
      #expect(request["automationMode"] as? Bool == expected)
    }
    #expect(AXBridgeArguments.request(action: "describe", arguments: ["--pid", "42"])["automationMode"] == nil)
  }
}
