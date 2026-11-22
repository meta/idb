/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation
import SimScopeProtocol

/// Flattening the app's accessibility types onto the wire shape. App-side rather than in
/// `SimScopeProtocol` because `AXNode` and `AXHit` come from idb's frameworks, which the CLI at the
/// other end of the socket has no reason to link.
extension AgentElement {

  init(node: AXNode) {
    self.init(
      depth: node.depth,
      type: node.type,
      label: node.label,
      identifier: node.identifier,
      value: node.value,
      x: node.frame.map { Double($0.minX) },
      y: node.frame.map { Double($0.minY) },
      width: node.frame.map { Double($0.width) },
      height: node.frame.map { Double($0.height) },
      tapX: node.tapPoint.map { Double($0.x) },
      tapY: node.tapPoint.map { Double($0.y) })
  }

  init(hit: AXHit) {
    self.init(
      depth: 0,
      type: hit.type,
      label: hit.label,
      identifier: hit.identifier,
      value: nil,
      x: Double(hit.frame.minX),
      y: Double(hit.frame.minY),
      width: Double(hit.frame.width),
      height: Double(hit.frame.height),
      tapX: Double(hit.frame.midX),
      tapY: Double(hit.frame.midY))
  }
}
