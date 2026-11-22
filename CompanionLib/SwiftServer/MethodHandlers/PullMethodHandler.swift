/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBArtifactStaging
import FBControlCore
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf

/// Seam over the `IDBCommandExecutor` calls this handler drives, so it can be tested against a double.
protocol FilePulling: Sendable {
  var temporaryDirectory: TemporaryDirectory { get }

  func pullFilePath(_ path: String, destinationPath: String, containerType: String?) async throws -> String
}

extension IDBCommandExecutor: FilePulling {}

struct PullMethodHandler {

  let target: any Target
  let commandExecutor: IDBCommandExecutor

  /// Human byte count for transfer summaries (e.g. "512 B", "1.5 KB").
  static func formatBytes(_ bytes: Int) -> String {
    let value = Double(bytes)
    switch value {
    case ..<1024:
      return "\(bytes) B"
    case ..<(1024 * 1024):
      return String(format: "%.1f KB", value / 1024)
    case ..<(1024 * 1024 * 1024):
      return String(format: "%.1f MB", value / (1024 * 1024))
    default:
      return String(format: "%.1f GB", value / (1024 * 1024 * 1024))
    }
  }

  func handle(request: Idb_PullRequest, responseStream: RPCWriter<Idb_PullResponse>, context: ServerContext) async throws {
    try await Self.pull(request, using: commandExecutor, logger: target.logger, cancellation: context.cancellation) { try await responseStream.send($0) }
  }

  /// Stops when `cancellation` reports the RPC cancelled, as it does when the client goes away.
  static func pull(
    _ request: Idb_PullRequest,
    using commandExecutor: any FilePulling,
    logger: any ControlCoreLogger,
    cancellation: ServerContext.RPCCancellationHandle,
    send: @escaping @Sendable (Idb_PullResponse) async throws -> Void
  ) async throws {
    try await withRPCCancellation(cancellation) {
      if request.dstPath.isEmpty {
        try await sendRawData(request: request, using: commandExecutor, logger: logger, send: send)
      } else {
        try await sendFilePath(request: request, using: commandExecutor, logger: logger, send: send)
      }
    }
  }

  private static func sendRawData(
    request: Idb_PullRequest, using commandExecutor: any FilePulling, logger: any ControlCoreLogger, send: (Idb_PullResponse) async throws -> Void
  ) async throws {
    let path = request.srcPath as NSString
    let fileContainer = FileContainerTranslation.rawFileContainer(from: request.container)
    let url = commandExecutor.temporaryDirectory.temporaryDirectory()
    let tempPath = url.appendingPathComponent(path.lastPathComponent).path

    let filePath = try await commandExecutor.pullFilePath(
      request.srcPath,
      destinationPath: tempPath,
      containerType: fileContainer)

    let archive = try ArchiveOperations.gzippedTarSubprocess(forPath: filePath, logger: logger)

    var totalBytes = 0
    do {
      try await FileDrainWriter.performDrain(archive, logger: logger) { data in
        totalBytes += data.count
        let response = Idb_PullResponse.with { $0.payload.data = data }
        try await send(response)
      }
    } catch {
      logger.info().log("pull failed after streaming \(Self.formatBytes(totalBytes))")
      throw error
    }
    logger.info().log("pull streamed \(Self.formatBytes(totalBytes))")
  }

  private static func sendFilePath(
    request: Idb_PullRequest, using commandExecutor: any FilePulling, logger: any ControlCoreLogger, send: (Idb_PullResponse) async throws -> Void
  ) async throws {
    let fileContainer = FileContainerTranslation.rawFileContainer(from: request.container)

    let filePath = try await commandExecutor.pullFilePath(
      request.srcPath,
      destinationPath: request.dstPath,
      containerType: fileContainer)
    let response = Idb_PullResponse.with {
      $0.payload = .with { $0.source = .filePath(filePath) }
    }
    try await send(response)
    if let byteCount = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? NSNumber)?.intValue {
      logger.info().log("pull saved \(Self.formatBytes(byteCount)) to \(request.dstPath)")
    }
  }
}
