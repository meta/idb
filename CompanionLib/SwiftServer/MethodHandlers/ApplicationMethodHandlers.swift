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
import SwiftProtobuf

struct ListAppsMethodHandler {

  let commandExecutor: IDBCommandExecutor

  func handle(request: Idb_ListAppsRequest, context: ServerContext) async throws -> Idb_ListAppsResponse {
    let persistedBundleIDs = commandExecutor.storageManager.application.persistedBundleIDs
    let fetchAppProcessState = !request.suppressProcessState
    let apps = try await commandExecutor.listApps(fetchAppProcessState)

    return .with {
      $0.apps = apps.map { app, processState in
        .with {
          $0.bundleID = app.bundle.identifier
          $0.name = app.bundle.name
          $0.installType = app.installTypeString
          $0.architectures = app.bundle.binary?.architectures.map(\.rawValue) ?? []
          if let processID = processState as? NSNumber {
            $0.processState = .running
            $0.processIdentifier = processID.uint64Value
          } else {
            $0.processState = .unknown
          }
          $0.debuggable = app.installType == .userDevelopment && persistedBundleIDs.contains(app.bundle.identifier)
        }
      }
    }
  }
}

struct TerminateMethodHandler {

  let commandExecutor: IDBCommandExecutor

  func handle(request: Idb_TerminateRequest, context: ServerContext) async throws -> Idb_TerminateResponse {
    try await commandExecutor.killApplication(request.bundleID)
    return .init()
  }
}

struct UninstallMethodHandler {

  let commandExecutor: IDBCommandExecutor

  func handle(request: Idb_UninstallRequest, context: ServerContext) async throws -> Idb_UninstallResponse {
    try await commandExecutor.uninstallApplication(request.bundleID)
    return .init()
  }
}
