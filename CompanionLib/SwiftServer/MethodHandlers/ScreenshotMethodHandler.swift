/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import GRPCCore
import IDBGRPCSwift

struct ScreenshotMethodHandler {

  let target: CompanionTarget
  let commandExecutor: IDBCommandExecutor

  func handle(request: Idb_ScreenshotRequest, context: ServerContext) async throws -> Idb_ScreenshotResponse {
    let configuration = try ScreenshotRequestTranslation.configuration(from: request)
    do {
      let observe: (@Sendable () async throws -> ScreenshotAppSample)?
      if request.includeAppContext, let simulator = target as? Simulator {
        observe = { try await ScreenshotAppObserver.observe(simulator) }
      } else {
        observe = nil
      }
      return try await Self.takeScreenshot(
        includeAppContext: request.includeAppContext, targetUDID: target.udid,
        cancellation: context.cancellation, observe: observe,
        capture: { [commandExecutor] in try await commandExecutor.screenshot(configuration: configuration) })
    } catch let error as ScreenshotGeometryError {
      // The crop is resolved against the screen that was actually captured, so a rect that
      // overhangs it can only be discovered here, once the target has been asked.
      throw ScreenshotRequestTranslation.status(for: error)
    } catch let error as ScreenshotRenderError {
      // Otherwise a failed crop, scale or encode reaches the caller as an UNKNOWN with no message.
      throw ScreenshotRequestTranslation.status(for: error)
    }
  }

  static func takeScreenshot(
    includeAppContext: Bool,
    targetUDID: String,
    cancellation: ServerContext.RPCCancellationHandle,
    observe: (@Sendable () async throws -> ScreenshotAppSample)?,
    capture: @escaping @Sendable () async throws -> ScreenshotResult
  ) async throws -> Idb_ScreenshotResponse {
    try await withRPCCancellation(cancellation) {
      try await ScreenshotAppContextCapture.take(
        includeAppContext: includeAppContext, targetUDID: targetUDID, observe: observe, capture: capture)
    }
  }
}
