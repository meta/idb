/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBArtifactStaging
import FBControlCore
@_spi(IDBRepl) import FBSimulatorCodeInjection
import Foundation
import GRPCCore
import IDBConcurrency
import IDBGRPCSwift
import ReplProtocol
import SwiftProtobuf

struct ReplMethodHandler {

  let commandExecutor: IDBCommandExecutor
  let targetLogger: any ControlCoreLogger
  /// Owns the in-progress screen recording, which can outlive a single `repl`
  /// stream (in the app context). Shared across streams for one target.
  let recordingCoordinator: ReplRecordingCoordinator

  func handle(requestStream: RequestStreamReader<Idb_ReplRequest>, responseStream: RPCWriter<Idb_ReplResponse>, context: ServerContext) async throws {
    guard case let .start(start) = try await requestStream.requiredNext().control
    else { throw RPCError(code: .failedPrecondition, message: "repl expected a Start message at the beginning of the stream") }

    targetLogger.debug().log("REPL session context: \(start.context)")

    let session: CodeInjectionSession
    // Only the app context has an app whose exit should end a recording; the
    // test/simulator hosts are disposable and drop any recording at teardown. For
    // the app context an empty bundle id means "use the companion's bundled
    // ReplHost app": resolve (and install) it once here, then thread the resolved
    // id onward so the socket path and the app-exit/recording watcher key off a
    // real id rather than "".
    let appBundleID: String?
    switch start.context {
    case .test:
      session = try await reportingCodeInjectionErrors { try await commandExecutor.replStartTest(bundlePath: start.testBundlePath) }
      appBundleID = nil
    case .app:
      let bundleID =
        start.appBundleID.isEmpty
        ? try await commandExecutor.ensureReplHostAppInstalled()
        : start.appBundleID
      session = try await reportingCodeInjectionErrors { try await commandExecutor.replStartApp(bundleID: bundleID, reuseSession: start.reuseSession) }
      appBundleID = bundleID
    case .simulator, .UNRECOGNIZED:
      session = try await reportingCodeInjectionErrors { try await commandExecutor.replStartSimulator() }
      appBundleID = nil
    }

    // Detect whether we share the driver's filesystem: the driver sends a path it
    // created locally; if we can see it, captured artifacts can be moved rather
    // than pulled back over gRPC.
    let sharedFilesystem = !start.probeFilePath.isEmpty && FileManager.default.fileExists(atPath: start.probeFilePath)

    try await serve(session: session, sharedFilesystem: sharedFilesystem, context: start.context, appBundleID: appBundleID, requestStream: requestStream, responseStream: responseStream)
  }

  /// Bridges the gRPC repl stream to a code-injection session: reports `ready`,
  /// forwards each `Execute` (a dylib plus a symbol) to the session and streams
  /// back the result, and on stop/EOF closes the session (which ends the served
  /// process) and reports `stopped`.
  private func serve(session: CodeInjectionSession, sharedFilesystem: Bool, context: Idb_ReplRequest.Start.Context, appBundleID: String?, requestStream: RequestStreamReader<Idb_ReplRequest>, responseStream: RPCWriter<Idb_ReplResponse>) async throws {
    // Per-session scratch directory for the dylibs received over the wire. It
    // lives on the host filesystem, which the simulator process can read.
    let scratchDirectory = (NSTemporaryDirectory() as NSString).appendingPathComponent("idb_repl_\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: scratchDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: scratchDirectory) }

    // Per-session directory for captured artifacts (screenshots, recordings). It
    // lives under the target's auxillary directory -- a real companion-host path
    // that is also the pull-able AUXILLARY container -- and is removed at the end
    // of the session.
    let artifactsSessionID = UUID().uuidString
    let artifactsContainerBase = "idb-repl-artifacts/" + artifactsSessionID
    let artifactsDirectory = URL(fileURLWithPath: commandExecutor.auxillaryDirectory)
      .appendingPathComponent("idb-repl-artifacts")
      .appendingPathComponent(artifactsSessionID)
    try FileManager.default.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: artifactsDirectory) }
    let hostState = ReplHostCommandState(stagingDirectory: artifactsDirectory, containerRelativeBase: artifactsContainerBase)

    // The host greets us with the .swiftinterface paths it generated in-process
    // (empty in the simulator context). Combine them with the pre-built interface
    // of the `IDB` module that libReplIDB implements. We read each file's contents here and
    // forward those (not the paths) to the driver, which may not share a
    // filesystem with the companion; the driver materializes them locally.
    let interfacePaths = session.generatedInterfacePaths + commandExecutor.replIDBInterfacePaths
    let generatedInterfaces: [Idb_ReplResponse.Ready.GeneratedInterface] = interfacePaths.compactMap { path in
      guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        targetLogger.error().log("Failed to read generated interface at \(path); skipping")
        return nil
      }
      let moduleName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
      return .with {
        $0.moduleName = moduleName
        $0.contents = contents
      }
    }

    targetLogger.debug().log("REPL session ready on socket \(session.socketPath)")
    try await responseStream.send(
      .with {
        $0.event = .ready(
          .with {
            $0.deviceType = commandExecutor.replDeviceType
            $0.osVersion = commandExecutor.replOSVersion
            $0.generatedInterfaces = generatedInterfaces
            $0.nextRunIndex = session.nextRunIndex
            $0.sharedFilesystem = sharedFilesystem
            $0.sessionID = session.sessionID
            $0.verifiesBuildUuid = true
          })
      })

    // Services nested `host_command`s the served process sends back while an
    // execute is running (e.g. `IDB.tap`), mapping them to IDBCommandExecutor.
    let dispatcher = HostCommandDispatcher(commandExecutor: commandExecutor, state: hostState, recordingCoordinator: recordingCoordinator, appBundleID: appBundleID)

    var runIndex = 0
    bridge: for try await request in requestStream {
      switch request.control {
      case .start:
        throw RPCError(code: .failedPrecondition, message: "repl session already started")

      case let .execute(execute):
        // A driver that names the build it built the dylib for gets a load only
        // if the served app is that build; nothing is written otherwise.
        let expectation = ReplBuildExpectation(execute)
        if !expectation.isEmpty,
          case let .rejected(rejection, message) = ReplBuildIdentityCheck.verify(expectation, against: await appIdentity(bundleID: appBundleID), bundleID: appBundleID)
        {
          targetLogger.info().log("REPL execute refused: \(message)")
          try await responseStream.send(
            .with {
              $0.event = .result(
                .with {
                  $0.success = false
                  $0.output = "Error: \(message)"
                  $0.rejection = rejection
                  $0.nextRunIndex = Int32(clamping: session.nextRunIndex)
                })
            })
          continue bridge
        }

        let dylibPath = (scratchDirectory as NSString).appendingPathComponent("run-\(runIndex).dylib")
        runIndex += 1
        try execute.dylib.write(to: URL(fileURLWithPath: dylibPath))

        // Artifacts captured during this execute are named with the REPL run index
        // the driver assigned (the `idb_repl_<n>` entry-point symbol).
        hostState.beginRun(index: Self.replRunIndex(fromSymbol: execute.symbol) ?? runIndex)

        let (result, nextRunIndex) = try await reportingCodeInjectionErrors {
          try await session.run(dylibAtPath: dylibPath, symbol: execute.symbol) { commandData in
            guard let command = try? PropertyListDecoder().decode(ReplCommand.self, from: commandData) else {
              return .failure(HostCommandError.message("repl: could not decode host command"))
            }
            return await dispatcher.run(command)
          }
        }
        let artifacts = hostState.runArtifacts.map { artifact in
          Idb_ReplResponse.Result.Artifact.with {
            $0.hostPath = artifact.hostPath
            $0.containerPath = artifact.containerPath
          }
        }
        try await responseStream.send(
          .with {
            $0.event = .result(
              .with {
                switch result {
                case let .success(output):
                  $0.success = true
                  $0.output = output
                case let .failure(error):
                  $0.success = false
                  $0.output = "Error: \(error)"
                }
                $0.nextRunIndex = nextRunIndex
                $0.artifacts = artifacts
              })
          })

      case .stop, .none:
        break bridge
      }
    }

    // The app context's app (and any recording it started) outlives this stream, so
    // leave the recording running -- a reconnect can still stop it, and the app-exit
    // watcher drops it otherwise. The test/simulator hosts are disposable, so a
    // still-running recording is dropped now.
    switch context {
    case .app:
      break
    case .test, .simulator, .UNRECOGNIZED:
      await recordingCoordinator.dropActiveRecording()
    }

    // Closing the session ends the served process's accept loop, so it exits;
    // wait for it (bounded), then report the session stopped.
    let thirtySeconds: UInt64 = 30 * 1_000_000_000
    try? await Task.timeout(nanoseconds: thirtySeconds) {
      try await session.close()
    }
    try await responseStream.send(.with { $0.event = .stopped(.with { $0.desc = "REPL session ended" }) })
  }

  /// The identity of the app the session serves, nil for the contexts that serve none. An app
  /// that cannot be found reads as an app whose identity is unknown, which the check rejects.
  private func appIdentity(bundleID: String?) async -> ReplAppIdentity? {
    guard let bundleID else {
      return nil
    }
    do {
      let app = try await commandExecutor.replInstalledApplication(bundleID: bundleID)
      return ReplAppIdentity(bundlePath: app.bundlePath, executableUUID: app.executableUUID)
    } catch {
      targetLogger.error().log("REPL could not read the installed app \(bundleID) to check its build: \(error)")
      return ReplAppIdentity(buildUUID: nil, executableUUID: nil)
    }
  }

  /// Extracts the REPL run index the driver encoded in an execute's entry-point
  /// symbol (`idb_repl_<index>`), or nil if it is not in that form.
  private static func replRunIndex(fromSymbol symbol: String) -> Int? {
    guard let suffix = symbol.split(separator: "_").last else {
      return nil
    }
    return Int(suffix)
  }
}
