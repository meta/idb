/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBControlCore
import Foundation
import IDBConcurrency
import IDBTelemetry

public enum CompanionServerSession {
  public static func run(
    _ udid: String,
    userDefaults: UserDefaults,
    makingTargetSets makers: [TargetSetMaker],
    logger: IDBLogger,
    reporter: EventReporter,
    onStarted: ([String: Any]) -> Void
  ) async throws {
    let terminateOffline = userDefaults.bool(forKey: "-terminate-offline")
    let idleShutdownTime = userDefaults.string(forKey: "-idle-shutdown-time").flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }

    try await TargetProvider.withTarget(withUDID: udid, makingTargetSets: makers, warmUp: true, logger: logger) { target in

      reporter.addMetadata([
        "udid": udid,
        "target_type": target.targetType.stringRepresentation.lowercased(),
      ])
      reporter.report(EventReporterSubject(forEvent: "launched"))

      let temporaryDirectory = TemporaryDirectory(logger: logger)
      let storageManager = try IDBStorageManager(target: target, logger: logger)

      let ports = IDBPortsConfiguration(arguments: userDefaults)

      // The gRPC domain socket this companion serves on, if any. Removing it
      // the instant shutdown begins stops clients from discovering a
      // companion that is already shutting down.
      let registeredSocketPath: String?
      if case let .unixDomainSocket(path) = ports.swiftServerTarget {
        registeredSocketPath = path
      } else {
        registeredSocketPath = nil
      }
      let removeRegisteredSocket: @Sendable () -> Void = {
        if let registeredSocketPath {
          Darwin.unlink(registeredSocketPath)
        }
      }

      let commandExecutor = IDBCommandExecutor(
        target: target,
        storageManager: storageManager,
        temporaryDirectory: temporaryDirectory,
        debugserverPort: in_port_t(ports.debugserverPort),
        logger: logger
      )

      let idleMonitor = idleShutdownTime.map {
        IdleMonitor(idleTime: $0, logger: logger, onShutdownStarted: removeRegisteredSocket)
      }

      let swiftServer = try GRPCSwiftServer(
        target: target,
        commandExecutor: commandExecutor,
        reporter: reporter,
        logger: logger,
        ports: ports,
        idleMonitor: idleMonitor,
        onShutdownStarted: removeRegisteredSocket
      )

      let serverDescription = try await swiftServer.start()
      onStarted(serverDescription)

      defer {
        temporaryDirectory.cleanOnExit()
        removeRegisteredSocket()
      }

      if let idleMonitor, let idleShutdownTime {
        logger.info().log("Companion will shut down after \(Int(idleShutdownTime))s of inactivity")
        idleMonitor.start()
      }
      if terminateOffline {
        logger.info().log("Companion will terminate when target goes offline")
      } else {
        logger.info().log("Companion will stay alive if target goes offline")
      }

      // `Task.select` cancels the race tasks on caller cancellation, but a winner leaves
      // the others running.
      let serverClosed = Task { try await swiftServer.waitUntilClosed() }
      var raceTasks: [Task<Void, Error>] = [serverClosed]
      if let idleMonitor {
        raceTasks.append(Task { try await idleMonitor.waitUntilExpired() })
      }
      if terminateOffline {
        // Target lifecycle operations serialize their access on the target's work queue.
        // patternlint-disable-next-line swift-nonisolated-unsafe
        nonisolated(unsafe) let target = target
        raceTasks.append(Task { try await awaitTargetOffline(target, logger: logger) })
      }
      let result = await Task.select(raceTasks).result
      raceTasks.forEach { $0.cancel() }
      let drainResult = await serverClosed.result
      if case let .failure(error) = drainResult,
        !(error is CancellationError)
      {
        logger.error().log("Server shutdown failed: \(error)")
      }
      try result.get()
    }
  }

  private static func awaitTargetOffline(_ target: any Target, logger: ControlCoreLogger) async throws {
    try await target.lifecycle.resolveLeavesState(.booted)
    target.logger.log("Target is no longer booted, companion going offline")
  }
}
