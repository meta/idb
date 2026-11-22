/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorControl
import FBSimulatorXCTest
import FBXCTestCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf

struct XCTestListBundlesMethodHandler {

  let commandExecutor: IDBCommandExecutor

  func handle(request: Idb_XctestListBundlesRequest, context: ServerContext) async throws -> Idb_XctestListBundlesResponse {
    let descriptors = try commandExecutor.storageManager.xctest.listTestDescriptors()
    return .with {
      $0.bundles = descriptors.map(toBundle(descriptor:))
    }
  }
  private func toBundle(descriptor: XCTestDescriptor) -> Idb_XctestListBundlesResponse.Bundles {
    return .with {
      $0.name = descriptor.name
      $0.bundleID = descriptor.testBundleID
      $0.architectures = Array(descriptor.architectures)
    }
  }
}

struct XCTestListTestsMethodHandler {

  private static let listTestBundleTimeout: TimeInterval = 180.0

  let target: CompanionTarget
  let storageManager: IDBStorageManager

  func handle(request: Idb_XctestListTestsRequest, context: ServerContext) async throws -> Idb_XctestListTestsResponse {
    var resolvedAppPath: String? = request.appPath
    if resolvedAppPath == "" {
      resolvedAppPath = nil
    }

    if let app = resolvedAppPath, storageManager.application.persistedBundleIDs.contains(app) {
      resolvedAppPath = storageManager.application.persistedBundles[app]?.path
    }

    let testDescriptor = try storageManager.xctest.testDescriptor(withID: request.bundleName)
    let tests = try await target.simulator().xctest.listTests(forBundleAtPath: testDescriptor.url.path, timeout: Self.listTestBundleTimeout, withAppAtPath: resolvedAppPath)
    return .with {
      $0.names = tests
    }
  }
}
