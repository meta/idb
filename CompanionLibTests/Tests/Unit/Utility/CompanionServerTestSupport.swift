/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBControlCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import IDBGRPCSwift
import IDBTelemetry
import Testing

final class TargetSetDouble: TargetSet {
  weak var delegate: (any TargetSetDelegate)?
  private let targets: [String: any TargetInfo]
  private let onRelease: @Sendable () -> Void

  init(targets: [String: any TargetInfo], onRelease: @escaping @Sendable () -> Void = {}) {
    self.targets = targets
    self.onRelease = onRelease
  }

  deinit { onRelease() }

  var allTargetInfos: [any TargetInfo] { Array(targets.values) }
  func target(withUDID udid: String) -> (any TargetInfo)? { targets[udid] }
}

struct CompanionTestSession {
  let client: Idb_CompanionService.Client<HTTP2ClientTransport.Posix>
  let task: Task<Void, Error>
  let stopped: AsyncEvent<Bool>
}

@MainActor
func withCompanionTestSession(
  _ udid: String,
  makingTargetSets makers: [TargetSetMaker],
  logger: IDBLogger,
  idleShutdownTime: TimeInterval? = nil,
  _ body: (CompanionTestSession) async throws -> Void
) async throws {
  let defaults = try #require(UserDefaults(suiteName: "CompanionTestSession.\(UUID().uuidString)"))
  defaults.set("0", forKey: "-grpc-port")
  if let idleShutdownTime { defaults.set(String(idleShutdownTime), forKey: "-idle-shutdown-time") }
  let started = AsyncEvent<Int>()
  let stopped = AsyncEvent<Bool>()
  let task = Task { @MainActor in
    defer { stopped.happen(true) }
    do {
      try await CompanionServerSession.run(
        udid, userDefaults: defaults, makingTargetSets: makers,
        logger: logger, reporter: EmptyEventReporter.shared,
        onStarted: { started.happen($0["grpc_port"] as? Int ?? -1) })
    } catch {
      started.fail(error)
      throw error
    }
  }
  defer { task.cancel() }
  let port = try await started.wait(timeout: 10, waitingFor: "companion server startup")
  try #require(port > 0)
  let transport = try HTTP2ClientTransport.Posix(
    target: .ipv6(address: "::1", port: port), transportSecurity: .plaintext)
  let grpcClient = GRPCClient(transport: transport)
  let connection = Task { try await grpcClient.runConnections() }
  defer {
    grpcClient.beginGracefulShutdown()
    connection.cancel()
  }
  let result: Result<Void, Error>
  do {
    try await body(CompanionTestSession(client: .init(wrapping: grpcClient), task: task, stopped: stopped))
    result = .success(())
  } catch {
    result = .failure(error)
  }
  grpcClient.beginGracefulShutdown()
  let connectionResult = await connection.result
  task.cancel()
  _ = try await stopped.wait(timeout: 10, waitingFor: "companion session shutdown")
  _ = await task.result
  try result.get()
  try connectionResult.get()
}
