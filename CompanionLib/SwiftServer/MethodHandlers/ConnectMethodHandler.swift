/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import IDBTelemetry

struct ConnectMethodHandler {

  let reporter: EventReporter
  let logger: IDBLogger
  let target: any Target

  func handle(request: Idb_ConnectRequest, context: ServerContext) async throws -> Idb_ConnectResponse {
    self.reporter.addMetadata(request.metadata)
    let isLocal = FileManager.default.fileExists(atPath: request.localFilePath)

    return Idb_ConnectResponse.with {
      $0.companion = .with {
        $0.udid = target.udid
        $0.isLocal = isLocal
        $0.setStreamCapabilities()
        $0.screenshotAppContext = true

        do {
          $0.metadata = try JSONSerialization.data(withJSONObject: reporter.metadata, options: [])
        } catch {
          logger.error().log("Error while serializing metadata \(error.localizedDescription)")
        }
      }
    }
  }
}
