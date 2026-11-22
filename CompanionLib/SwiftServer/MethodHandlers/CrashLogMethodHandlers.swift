/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf

struct CrashListMethodHandler {

  let target: CompanionTarget

  func handle(request: Idb_CrashLogQuery, context: ServerContext) async throws -> Idb_CrashLogResponse {
    let predicate = CrashLogQueryTranslation.predicate(from: request)
    let crashes = try await target.crashLog.crashes(matching: predicate, useCache: false)
    return Idb_CrashLogResponse.with {
      $0.list = crashes.map(CrashLogInfoTranslation.responseCrashLogInfo(from:))
    }
  }
}

struct CrashShowMethodHandler {

  let target: CompanionTarget

  func handle(request: Idb_CrashShowRequest, context: ServerContext) async throws -> Idb_CrashShowResponse {
    guard !request.name.isEmpty else {
      throw RPCError(code: .invalidArgument, message: "Missing crash name")
    }

    let predicate = CrashLogPredicate.name(request.name)
    let crashArray = try await target.crashLog.crashes(matching: predicate, useCache: true)
    if crashArray.count > 1 {
      throw IDBCommandError.multipleCrashLogs(predicateDescription: String(describing: predicate))
    }
    guard let first = crashArray.first else {
      throw IDBCommandError.noCrashLogs(predicateDescription: String(describing: predicate))
    }
    let crash = try first.obtainCrashLog()
    return .with {
      $0.info = CrashLogInfoTranslation.responseCrashLogInfo(from: crash.info)
      $0.contents = crash.contents
    }
  }
}

struct CrashDeleteMethodHandler {

  let target: CompanionTarget

  func handle(request: Idb_CrashLogQuery, context: ServerContext) async throws -> Idb_CrashLogResponse {
    let predicate = CrashLogQueryTranslation.predicate(from: request)
    let crashes = try await target.crashLog.prune(matching: predicate)
    return .with {
      $0.list = crashes.map(CrashLogInfoTranslation.responseCrashLogInfo(from:))
    }
  }
}
