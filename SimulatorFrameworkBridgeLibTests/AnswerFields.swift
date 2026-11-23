/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
import Foundation
import SimulatorFrameworkBridgeSupport

/// An answer's fields, for a test that looks at them one by one: what it holds as its own generated coder writes it,
/// beside `ok`. A hit-test's element and a write's application are its `tree` and `pid`; nothing at the point is `empty`.
func answerFields(_ answer: BridgeAXAnswer) -> [String: Any] {
  func fields(_ value: some Encodable) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(value) else { return [:] }
    return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
  }
  func succeeded(_ fields: [String: Any]) -> [String: Any] {
    fields.merging(["ok": true]) { $1 }
  }
  switch answer {
  case let .tree(response): return succeeded(fields(response))
  case let .hitTest(.element(node, pid)): return succeeded(["tree": fields(node), "pid": pid])
  case .hitTest(.empty), .write(.empty): return succeeded(["empty": true])
  case let .write(.written(pid)): return succeeded(["pid": pid])
  case let .setting(response): return succeeded(fields(response))
  case let .displays(inventory): return succeeded(fields(inventory))
  case let .settingSnapshot(snapshot): return succeeded(fields(snapshot))
  case let .quiescence(event): return succeeded(fields(event))
  case let .failure(failure): return fields(failure).merging(["ok": false]) { $1 }
  }
}

extension AccessibilityService {
  /// The fields of the answer to the request `payload` spells as flat parameters.
  static func handleRequest(_ payload: [String: Any]) -> [String: Any] {
    answerFields(answer(payload))
  }
}
