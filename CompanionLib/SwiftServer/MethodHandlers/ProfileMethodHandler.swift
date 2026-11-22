/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBArtifactStaging
import FBControlCore
import FBProfilingCore
import FBSimulatorControl
import FBSimulatorProfiling
import Foundation
import GRPCCore
import IDBConcurrency
import IDBGRPCSwift
import SwiftProtobuf

struct ProfileMethodHandler {

  let logger: ControlCoreLogger
  let target: any Target

  func handle(requestStream: RequestStreamReader<Idb_ProfileRequest>, responseStream: RPCWriter<Idb_ProfileResponse>, context: ServerContext) async throws {
    guard case let .start(start) = try await requestStream.requiredNext().control
    else { throw RPCError(code: .failedPrecondition, message: "Expected start control") }
    guard let simulator = target as? Simulator
    else { throw RPCError(code: .unimplemented, message: "Profiling is only supported on simulators") }

    let artifactPath = (target.auxillaryDirectory as NSString).appendingPathComponent("profile-\(UUID().uuidString)\(ProfileTranslation.artifactExtension(of: start))")
    defer { try? FileManager.default.removeItem(atPath: artifactPath) }
    let configuration = try ProfileTranslation.configuration(from: start, artifactPath: artifactPath)
    let profileTarget = try ProfileTranslation.target(from: start.target)

    let operation = try await simulator.profile.profile(configuration, target: profileTarget)
    let result = try await Self.profileUntilFinished(operation: operation, requestStream: requestStream, responseStream: responseStream)
    try await responseStream.send(.with { $0.result = ProfileTranslation.result(result) })

    if start.includeArtifact, let artifact = result.artifact {
      try await Self.sendArtifact(atPath: artifact.path, responseStream: responseStream, logger: logger)
    }
  }

  /// Streams samples until the profiler finishes. A Stop from the client ends it early with what it has, and the client
  /// going away abandons it; the client merely closing its side of the stream does neither, so a client can send Start
  /// alone and wait.
  static func profileUntilFinished(operation: ProfileOperation, requestStream: RequestStreamReader<Idb_ProfileRequest>, responseStream: RPCWriter<Idb_ProfileResponse>) async throws -> ProfileResult {
    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: ProfileResult?.self) { group in
        group.addTask {
          while let request = try await requestStream.next() {
            guard case .stop = request.control
            else { throw RPCError(code: .failedPrecondition, message: "Expected stop control") }
            operation.stop()
            break
          }
          return nil
        }
        group.addTask {
          for await sample in operation.samples {
            try await responseStream.send(.with { $0.sample = ProfileTranslation.sample(sample) })
          }
          return try await operation.result
        }
        do {
          while let next = try await group.next() {
            if let result = next {
              group.cancelAll()
              return result
            }
          }
        } catch {
          // The profiler runs outside the group, so cancelling the group does not end it, and the group cannot exit
          // until the child awaiting its result does.
          operation.cancel()
          throw error
        }
        throw RPCError(code: .internalError, message: "Profile ended without a result")
      }
    } onCancel: {
      operation.cancel()
    }
  }

  /// Streams the artifact at `path` as a single gzipped tar, in chunks.
  static func sendArtifact(atPath path: String, responseStream: RPCWriter<Idb_ProfileResponse>, logger: ControlCoreLogger) async throws {
    let archive = try ArchiveOperations.gzippedTarSubprocess(forPath: path, logger: logger)
    try await FileDrainWriter.performDrain(archive, logger: logger) { data in
      try await responseStream.send(.with { $0.artifact = .with { $0.data = data } })
    }
  }
}
