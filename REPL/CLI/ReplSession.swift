/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import ArgumentParser
import CompanionDiscovery
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import IDBGRPCSwift
import IDBTelemetry
import ReplCompiler
import SwiftProtobuf

/// The options needed to establish a REPL session, gathered from the CLI so both
/// `ReplRunner` (the interactive/one-shot subcommands) and `ReplayCommand` can drive a
/// `ReplSession` the same way.
struct ReplSessionConfig {
  var udid: String?
  var toolchainPath: String?
  var idbCompanionBinary: String?
  var companion: String?
  var plaintext: Bool
  var reportPath: String?
  var reportFailures: Bool
  var reason: String?
  var mode: ReplSessionMode = .interactive
}

/// What compiling a submission needs, resolved once the companion has reported the
/// target's device type and OS version: the toolchain, the triple floored at the runtime
/// version, the SDK, the extra compiler and linker arguments, and the interfaces the
/// companion generated.
struct ReplCompileEnvironment {
  var toolchain: String
  var targetTriple: String
  var sdkPath: String
  var compilerArguments: [String]
  var linkerArguments: [String]
  var interfaceSearchPaths: [String]
  var autoImportModules: [String]
}

/// The outcome of executing one block of code: the output the target returned (already
/// prefixed `Result:` or `Exception:`), the next run index the companion reported
/// (negative once the session has ended), and the filenames of any artifacts captured
/// during the run (empty unless a report is being written).
struct ExecutionResult {
  var output: String
  var nextIndex: Int
  var artifactFilenames: [String]
  /// `output` carries the reason for failures.
  var success = true
}

/// The build an execute says the served app must be; empty strings mean no expectation.
struct BuildExpectation {
  var buildUUID = ""
  var executableUUID = ""
  var isEmpty: Bool { buildUUID.isEmpty && executableUUID.isEmpty }
}

/// A live REPL session against a companion: owns the gRPC stream and compile parameters
/// and, when a report path is configured, records each run. Used sequentially from a
/// single task, so it is a plain (non-Sendable) reference type.
final class ReplSession {

  /// The connected target's device type (e.g. `iphone`), reported at handshake.
  let deviceType: String
  /// The connected target's runtime OS version, reported at handshake.
  let osVersion: String
  /// The companion's id for this REPL session (empty when the companion reports none).
  let sessionID: String
  /// Whether the app was freshly launched at this session's start (app context only;
  /// false otherwise). `replay` reproduces this to start from the same state.
  let freshLaunch: Bool
  /// Whether the companion honours an expected build UUID on an execute; an older one would load
  /// the dylib unchecked, so a session with an expectation refuses to send to it.
  let verifiesBuildUUID: Bool
  /// The index the next executed block will use; advanced after each completed run.
  private(set) var nextRunIndex: Int

  private let config: ReplSessionConfig
  private let reporter: EventReporter
  /// When the session began connecting; the `session_end` event's duration
  /// measures from here.
  private let startedAt: Date
  /// How many blocks this session attempted to execute (successes and
  /// failures alike); reported on the `session_end` event.
  private var runsExecuted = 0
  private let connection: ReplConnection
  private let compileEnvironment: ReplCompileEnvironment
  private let reportWriter: ReplReportWriter?

  private init(
    config: ReplSessionConfig,
    reporter: EventReporter,
    startedAt: Date,
    connection: ReplConnection,
    deviceType: String,
    osVersion: String,
    sessionID: String,
    freshLaunch: Bool,
    verifiesBuildUUID: Bool,
    nextRunIndex: Int,
    compileEnvironment: ReplCompileEnvironment,
    reportWriter: ReplReportWriter?
  ) {
    self.config = config
    self.reporter = reporter
    self.startedAt = startedAt
    self.connection = connection
    self.deviceType = deviceType
    self.osVersion = osVersion
    self.sessionID = sessionID
    self.freshLaunch = freshLaunch
    self.verifiesBuildUUID = verifiesBuildUUID
    self.nextRunIndex = nextRunIndex
    self.compileEnvironment = compileEnvironment
    self.reportWriter = reportWriter
  }

  /// Connects to the companion, opens the `repl` stream, and returns once the companion
  /// reports the REPL ready. Opens the session report when a report path is configured.
  static func start(context: Context, config: ReplSessionConfig) async throws -> ReplSession {
    // @oss-disable

    let reporter = ReplTelemetry.makeReporter()
    var sessionMetadata = [
      "context": context.telemetryName,
      "mode": config.mode.rawValue,
    ]
    if let udid = config.udid {
      sessionMetadata["udid"] = udid
    }
    if config.companion != nil || !localCompanionDiscoverySupported {
      sessionMetadata["connection"] = "remote"
    }
    if let reason = config.reason {
      sessionMetadata["reason"] = reason
    }
    reporter.addMetadata(sessionMetadata)

    let sessionStart = Date()
    let connection: ReplConnection
    let deviceType: String
    let osVersion: String
    let readyRunIndex: UInt32
    let sessionID: String
    let verifiesBuildUUID: Bool
    let compileEnvironment: ReplCompileEnvironment
    var resolvedCompanion: ResolvedCompanion?
    do {
      let toolchain = try resolveToolchainPath(explicit: config.toolchainPath)

      let companion = try await resolveCompanion(config: config)
      resolvedCompanion = companion
      reporter.addMetadata(["connection_source": companion.source.rawValue])

      connection = try await ReplConnection.open(
        transport: try .http2NIOPosix(
          target: connectionTarget(for: companion.address),
          transportSecurity: try channelTransportSecurity(
            for: companion.address, tls: planCompanionClientTLS(plaintext: config.plaintext))))

      // Create a marker file so the companion can detect whether it shares our
      // filesystem (it checks this path's existence; see Start.probe_file_path).
      let probeFilePath = try sessionDirectory.filePath(named: "shared-fs-probe")
      FileManager.default.createFile(atPath: probeFilePath, contents: Data())

      try await connection.send(
        .with {
          $0.control = .start(
            .with {
              $0.context = context.proto
              $0.probeFilePath = probeFilePath
              if case let .test(bundlePath) = context {
                $0.testBundlePath = bundlePath
              }
              if case let .app(bundleID, reuseSession) = context {
                $0.appBundleID = bundleID
                $0.reuseSession = reuseSession
              }
            })
        })

      // The companion launches the test and connects to the shim before it is ready.
      let first = try await connection.nextResponse()
      guard let firstEvent = first?.event, case let .ready(ready) = firstEvent else {
        throw ReplExecutionError.notReady
      }
      deviceType = ready.deviceType
      osVersion = ready.osVersion
      readyRunIndex = ready.nextRunIndex
      sessionID = ready.sessionID
      verifiesBuildUUID = ready.verifiesBuildUuid
      replSessionInfo.sharedFilesystem = ready.sharedFilesystem
      var readyMetadata = ["device_type": deviceType]
      if !sessionID.isEmpty {
        readyMetadata["session_id"] = sessionID
      }
      reporter.addMetadata(readyMetadata)

      // Interfaces arrive as contents (the companion may not share our filesystem); they
      // are materialized here and auto-imported. Reported on stderr to keep one-shot
      // stdout clean.
      var modules: [String] = []
      var interfaceDirectory: String?
      if !ready.generatedInterfaces.isEmpty {
        FileHandle.standardError.write(Data("idb-repl: received generated interface(s):\n".utf8))
        for interface in ready.generatedInterfaces {
          let path = try sessionDirectory.filePath(named: "\(interface.moduleName).swiftinterface")
          try interface.contents.write(toFile: path, atomically: true, encoding: .utf8)
          interfaceDirectory = (path as NSString).deletingLastPathComponent
          modules.append(interface.moduleName)
          FileHandle.standardError.write(Data("  \(interface.moduleName)\n".utf8))
        }
      }

      // Deployment target is floored at the runtime OS version (see `resolveTargetTriple`).
      let platform = try Platform(deviceType: deviceType)
      let environment = ReplCompileEnvironment(
        toolchain: toolchain,
        targetTriple: try resolveTargetTriple(platform: platform, runtimeOSVersion: osVersion),
        sdkPath: try resolveSDKPath(platform: platform),
        compilerArguments: try resolveCompilerArguments(platform: platform),
        linkerArguments: try resolveLinkerArguments(platform: platform, runtimeOSVersion: osVersion),
        interfaceSearchPaths: interfaceDirectory.map { [$0] } ?? [],
        autoImportModules: modules)
      FileHandle.standardError.write(Data("idb-repl: compiling injected code for \(environment.targetTriple)\n".utf8))
      compileEnvironment = environment
    } catch {
      let reportedError =
        resolvedCompanion.map {
          actionableCompanionConnectionError(error, companion: $0)
        } ?? error
      reporter.report(
        ReplRunTelemetry.subject(
          name: "start_session", start: sessionStart, failure: "\(reportedError)", stage: .connect))
      throw reportedError
    }
    reporter.report(ReplRunTelemetry.subject(name: "start_session", start: sessionStart, failure: nil))

    // Freshly launched iff the companion resumes numbering from zero (no runs from a
    // reattached REPL).
    let freshLaunch = (readyRunIndex == 0)

    // Best-effort: a report that cannot be opened disables reporting without stopping
    // the REPL.
    var reportWriter: ReplReportWriter?
    if let reportPath = config.reportPath {
      let writer = ReplReportWriter(path: reportPath)
      if let resolvedPath = writer.open(
        meta: context.sessionMeta(freshLaunch: freshLaunch),
        target: "\(deviceType) \(osVersion)",
        reason: config.reason,
        sessionID: sessionID,
        startedAt: Date())
      {
        FileHandle.standardError.write(Data("idb-repl: writing session report to \(resolvedPath)\n".utf8))
        reportWriter = writer
      }
    }

    return ReplSession(
      config: config,
      reporter: reporter,
      startedAt: sessionStart,
      connection: connection,
      deviceType: deviceType,
      osVersion: osVersion,
      sessionID: sessionID,
      freshLaunch: freshLaunch,
      verifiesBuildUUID: verifiesBuildUUID,
      nextRunIndex: Int(readyRunIndex),
      compileEnvironment: compileEnvironment,
      reportWriter: reportWriter)
  }

  /// Compiles `code`, injects and executes it against the target, and records the run.
  /// Errors are re-thrown after telemetry (and, under `--report-failures`, the report)
  /// has recorded them.
  func execute(code: String) async throws -> ExecutionResult {
    let index = nextRunIndex
    let start = Date()
    runsExecuted += 1
    // Advanced as the run progresses, so a failure row records the phase the
    // run was in when it failed.
    var stage = ReplRunStage.compile
    do {
      let parameters = ReplCompileParameters(
        targetTriple: compileEnvironment.targetTriple,
        sdkPath: compileEnvironment.sdkPath,
        toolchainPath: compileEnvironment.toolchain,
        compilerArguments: compileEnvironment.compilerArguments,
        interfaceSearchPaths: compileEnvironment.interfaceSearchPaths,
        autoImportModules: compileEnvironment.autoImportModules,
        linkerArguments: compileEnvironment.linkerArguments)
      let dylib: Data
      let symbol: String
      switch try ReplCompiler.compile(userCode: code, index: index, parameters: parameters, workingDirectory: sessionDirectory.path) {
      case let .success(dylibPath, compiledSymbol):
        dylib = try Data(contentsOf: URL(fileURLWithPath: dylibPath))
        symbol = compiledSymbol
      case let .failure(compilerOutput):
        throw ReplExecutionError.compileFailed(compilerOutput)
      }
      let result = try await inject(dylib: dylib, symbol: symbol, stage: &stage)
      reportWriter?.recordRun(index: index, code: code, output: result.output, artifactFilenames: result.artifactFilenames, at: Date())
      reporter.report(
        ReplRunTelemetry.subject(
          name: "run",
          start: start,
          ints: ReplRunTelemetry.codeMetrics(code),
          failure: nil))
      return result
    } catch {
      if config.reportFailures, case let ReplExecutionError.compileFailed(compilerOutput) = error {
        reportWriter?.recordCompileFailure(index: index, code: code, compilerOutput: compilerOutput, at: Date())
      }
      reporter.report(
        ReplRunTelemetry.subject(
          name: "run",
          start: start,
          ints: ReplRunTelemetry.codeMetrics(code),
          failure: "\(error)",
          stage: stage))
      throw error
    }
  }

  /// Injects a dylib built elsewhere and has the target call `symbol`: a function of
  /// no arguments returning a `malloc`'d C string, the contract idb-repl's own
  /// submissions meet. Nothing is compiled, and the run is not written to a report,
  /// since a report replays source.
  /// `expectedBuildUUID` and `expectedExecutableUUID`, when given, make the companion load the
  /// dylib only into an app of that build (its `BuildInfo.json` build UUID, its main executable's
  /// UUID); a companion that cannot check them is refused before anything is sent.
  func execute(dylibAt path: String, symbol: String, expectedBuildUUID: String? = nil, expectedExecutableUUID: String? = nil) async throws -> ExecutionResult {
    let start = Date()
    runsExecuted += 1
    var stage = ReplRunStage.readDylibFile
    do {
      let expectation = BuildExpectation(buildUUID: expectedBuildUUID ?? "", executableUUID: expectedExecutableUUID ?? "")
      if !expectation.isEmpty, !verifiesBuildUUID {
        throw ReplExecutionError.buildIdentityUnverifiable
      }
      let dylib = try Data(contentsOf: URL(fileURLWithPath: path))
      let result = try await inject(dylib: dylib, symbol: symbol, expectation: expectation, stage: &stage)
      reporter.report(
        ReplRunTelemetry.subject(
          name: "run_dylib",
          start: start,
          ints: ["dylib_size": dylib.count],
          failure: nil))
      return result
    } catch {
      reporter.report(
        ReplRunTelemetry.subject(
          name: "run_dylib",
          start: start,
          failure: "\(error)",
          stage: stage))
      throw error
    }
  }

  /// Sends `dylib` to the companion and returns what the target's call of `symbol`
  /// produced. `stage` moves from inject to execute as the run progresses, so a
  /// failure records the phase it was in.
  private func inject(dylib: Data, symbol: String, expectation: BuildExpectation = BuildExpectation(), stage: inout ReplRunStage) async throws -> ExecutionResult {
    stage = .inject
    try await connection.send(
      .with {
        $0.control = .execute(
          .with {
            $0.dylib = dylib
            $0.symbol = symbol
            $0.expectedBuildUuid = expectation.buildUUID
            $0.expectedExecutableUuid = expectation.executableUUID
          })
      })
    stage = .execute
    switch try await connection.nextResponse()?.event {
    case let .result(result) where result.rejection != .notRejected:
      // The companion refused to load the dylib; the session is intact. Its
      // output is already prefixed for printing as a result, not as an error.
      let prefix = "Error: "
      throw ReplExecutionError.rejected(result.output.hasPrefix(prefix) ? String(result.output.dropFirst(prefix.count)) : result.output)
    case let .result(result):
      let artifactFilenames = await Self.transferArtifacts(result.artifacts, connection: connection, into: reportWriter)
      let rawNext = Int(result.nextRunIndex)
      nextRunIndex = rawNext >= 0 ? rawNext : 0
      return ExecutionResult(output: result.output, nextIndex: rawNext, artifactFilenames: artifactFilenames, success: result.success)
    case let .stopped(stopped):
      throw ReplExecutionError.sessionStopped(stopped.desc)
    case .ready:
      throw ReplExecutionError.unexpectedReady
    case .none:
      throw ReplExecutionError.streamClosed
    }
  }

  /// Reports `session_end` (duration and run count — so sessions that never ran code
  /// are visible) and tears the session down.
  func finish() async {
    reporter.report(
      ReplRunTelemetry.subject(
        name: "session_end", start: startedAt, ints: ["runs": runsExecuted], failure: nil))
    reportWriter?.close()
    await connection.close()
    sessionDirectory.cleanup()
  }

  // MARK: - Connection

  /// `--companion` (a `host:port` or a socket path) bypasses discovery. macOS otherwise discovers or starts a
  /// local companion; other platforms select a remote companion from `IDB_COMPANION` or
  /// the companion registry.
  private static func resolveCompanion(config: ReplSessionConfig) async throws -> ResolvedCompanion {
    switch planCompanionRoute(companion: config.companion) {
    case let .explicit(companion):
      guard let address = CompanionAddress.parse(companion: companion) else {
        throw ValidationError(
          "--companion expects host:port, e.g. 127.0.0.1:10882, or the path of a companion's socket (got '\(companion)')")
      }
      return ResolvedCompanion(address: address, source: .commandLine)
    case .discoverLocal:
      let idleShutdownTime = 5 * 60
      if let udid = config.udid {
        let address = try await companionManager(config: config)
          .companionInfo(forUDID: udid, idleShutdownTime: idleShutdownTime).address
        return ResolvedCompanion(address: address, source: .localDiscovery)
      }
      let address = try await companionManager(config: config)
        .defaultCompanion(idleShutdownTime: idleShutdownTime).address
      return ResolvedCompanion(address: address, source: .localDiscovery)
    case .selectRemote:
      do {
        let environmentCompanion = ProcessInfo.processInfo.environment["IDB_COMPANION"]
        if environmentCompanion != nil {
          return ResolvedCompanion(
            address: try selectRemoteCompanion(
              environmentCompanion: environmentCompanion,
              companions: [],
              udid: config.udid),
            source: .environment)
        }
        return ResolvedCompanion(
          address: try selectRemoteCompanion(
            environmentCompanion: nil,
            companions: CompanionRegistry().companions(),
            udid: config.udid),
          source: .registry)
      } catch let error as RemoteCompanionSelectionError {
        throw ValidationError(error.description)
      }
    }
  }

  private static func companionManager(config: ReplSessionConfig) -> CompanionManager {
    if let idbCompanionBinary = config.idbCompanionBinary {
      return CompanionManager(companionPath: idbCompanionBinary)
    }
    return CompanionManager()
  }

  /// Maps a discovered companion's address to a connection target.
  private static func connectionTarget(for address: CompanionAddress) -> any ResolvableTarget {
    switch address {
    case let .domainSocket(path):
      return .unixDomainSocket(path: path)
    case let .tcp(host, port):
      return .dns(host: host, port: port)
    }
  }

  // MARK: - Artifacts

  /// Retrieves each artifact and returns the filenames that landed beside the report
  /// (empty when no report is being written; without a report they go to the ephemeral
  /// session directory). With a shared filesystem the file is moved; otherwise it is
  /// pulled over gRPC from the AUXILLARY container and removed from the companion.
  /// Best-effort per artifact.
  private static func transferArtifacts(_ artifacts: [Idb_ReplResponse.Result.Artifact], connection: ReplConnection, into reportWriter: ReplReportWriter?) async -> [String] {
    guard !artifacts.isEmpty else {
      return []
    }

    let reportArtifactsDirectory = reportWriter?.artifactsDirectory()
    let directory: String
    if let reportArtifactsDirectory {
      directory = reportArtifactsDirectory
    } else if let sessionArtifacts = try? sessionDirectory.artifactsDirectory() {
      directory = sessionArtifacts
    } else {
      FileHandle.standardError.write(Data("idb-repl: could not prepare an artifacts directory\n".utf8))
      return []
    }
    // Only files stored beside the report can be linked from it.
    let linkable = reportArtifactsDirectory != nil

    var filenames: [String] = []
    for artifact in artifacts {
      do {
        let localPath: String
        if replSessionInfo.sharedFilesystem {
          localPath = try moveArtifact(hostPath: artifact.hostPath, into: directory)
        } else {
          localPath = try await pullArtifact(containerPath: artifact.containerPath, connection: connection, into: directory)
        }
        FileHandle.standardError.write(Data("idb-repl: saved artifact to \(localPath)\n".utf8))
        if linkable {
          filenames.append((localPath as NSString).lastPathComponent)
        }
      } catch {
        FileHandle.standardError.write(Data("idb-repl: could not retrieve artifact \(artifact.hostPath): \(error)\n".utf8))
      }
    }
    return filenames
  }

  /// Moves a companion-written artifact (visible because we share the filesystem)
  /// into `directory`.
  private static func moveArtifact(hostPath: String, into directory: String) throws -> String {
    let destination = (directory as NSString).appendingPathComponent((hostPath as NSString).lastPathComponent)
    try? FileManager.default.removeItem(atPath: destination)
    try FileManager.default.moveItem(atPath: hostPath, toPath: destination)
    return destination
  }

  /// Pulls an artifact from the companion's AUXILLARY container (streamed back as a
  /// gzipped tar), extracts it into `directory`, and removes the companion copy.
  private static func pullArtifact(containerPath: String, connection: ReplConnection, into directory: String) async throws -> String {
    let request = Idb_PullRequest.with {
      $0.srcPath = containerPath
      $0.dstPath = "" // empty: stream the bytes back rather than copy them host-side
      $0.container = .with { $0.kind = .auxillary }
    }
    let archive = try await connection.client.pull(request) { response in
      var archive = Data()
      for try await chunk in response.messages {
        archive.append(chunk.payload.data)
      }
      return archive
    }

    let name = (containerPath as NSString).lastPathComponent
    let destination = (directory as NSString).appendingPathComponent(name)
    let archivePath = (directory as NSString).appendingPathComponent(name + ".tar.gz")
    try archive.write(to: URL(fileURLWithPath: archivePath))
    defer { try? FileManager.default.removeItem(atPath: archivePath) }
    try extractArchive(at: archivePath, into: directory)

    _ = try? await connection.client.rm(
      Idb_RmRequest.with {
        $0.paths = [containerPath]
        $0.container = .with { $0.kind = .auxillary }
      })
    return destination
  }

  private static func extractArchive(at archivePath: String, into directory: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-xzf", archivePath, "-C", directory]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ArtifactTransferError.extractionFailed(archivePath)
    }
  }
}
