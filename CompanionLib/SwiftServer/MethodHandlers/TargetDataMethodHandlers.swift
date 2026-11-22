/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBArtifactStaging
import FBControlCore
import FBSimulatorControl
import FBSimulatorServices
import Foundation
import GRPCCore
import IDBGRPCSwift

struct AddMediaMethodHandler {

  let target: CompanionTarget
  let temporaryDirectory: TemporaryDirectory

  func handle(requestStream: RequestStreamReader<Idb_AddMediaRequest>, context: ServerContext) async throws -> Idb_AddMediaResponse {
    try await MultisourceFileReader.withFilePathURLs(from: requestStream, temporaryDirectory: temporaryDirectory, extractFromSubdir: true) { extractedFileURLs in
      try target.simulator().media.upload(extractedFileURLs)
    }
    return .init()
  }
}

struct ContactsUpdateMethodHandler {

  let target: CompanionTarget
  let temporaryDirectory: TemporaryDirectory

  func handle(request: Idb_ContactsUpdateRequest, context: ServerContext) async throws -> Idb_ContactsUpdateResponse {
    let simulator = try target.simulator()
    try await temporaryDirectory.withArchiveExtracted(request.payload.data) { tempDir in
      try await simulator.contacts.update(tempDir.path)
    }
    return .init()
  }
}

struct ClearKeychainMethodHandler {

  let commandExecutor: IDBCommandExecutor

  func handle(request: Idb_ClearKeychainRequest, context: ServerContext) async throws -> Idb_ClearKeychainResponse {
    try await commandExecutor.clearKeychain()
    return .init()
  }
}
