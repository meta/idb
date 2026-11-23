/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorBridgeProtocol
import FBSimulatorControl
import Foundation

package struct AXBridgeOneshotTransport: AXBridgeTransport, Sendable {
  private let transport: SimulatorFrameworkBridgeOneshotTransport

  package init(simulator: Simulator) {
    transport = SimulatorFrameworkBridgeOneshotTransport(simulator: simulator)
  }

  package init(transport: SimulatorFrameworkBridgeOneshotTransport) {
    self.transport = transport
  }

  /// A missing guest binary is raised as the persistent transport raises it, so a write that never left the
  /// host is not mistaken for one that was sent.
  package func send(_ request: AXBridgeRequest) async throws -> AXBridgeReply {
    do {
      let response = try await transport.exchange(BridgeRequest(command: request.command))
      return AXBridgeReply(answer: try response.result.accessibilityAnswer(), frameBytes: response.frameBytes)
    } catch let error as DecodingError {
      throw AXBridgeReply.unparseable(error, answering: request)
    } catch SimulatorFrameworkBridgeError.binaryMissing {
      throw AXBridgeError.bridgeUnavailable
    }
  }
}
