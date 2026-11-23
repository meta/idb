/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import FBDeviceControl
import Foundation
import GRPCCore
import IDBConcurrency
import IDBGRPCSwift
import SwiftProtobuf

/// Launches an application and, for a waiting client, streams its output until the app exits,
/// ending the response after the client sends Stop or the exit is observed.
struct LaunchMethodHandler: @unchecked Sendable {

  let target: CompanionTarget
  let commandExecutor: IDBCommandExecutor

  func handle(requestStream: RequestStreamReader<Idb_LaunchRequest>, responseStream: RPCWriter<Idb_LaunchResponse>, context: ServerContext) async throws {
    var consumers: [ResponseForwardingConsumer] = []
    defer { consumers.forEach { $0.stopForwarding() } }

    let request = try await requestStream.requiredNext()
    guard case let .start(start) = request.control else {
      throw RPCError(code: .failedPrecondition, message: "Application not started yet")
    }
    var stdOut = ApplicationOutput.nullDevice
    var stdErr = ApplicationOutput.nullDevice

    let responseWriter = FIFOStreamWriter(stream: responseStream)
    if start.waitFor {
      let stdOutConsumer = Self.pipeOutput(interface: .stdout) { try responseWriter.send($0) }
      consumers.append(stdOutConsumer)
      stdOut = .consumer(stdOutConsumer)

      let stdErrConsumer = Self.pipeOutput(interface: .stderr) { try responseWriter.send($0) }
      consumers.append(stdErrConsumer)
      stdErr = .consumer(stdErrConsumer)
    }

    var environment = start.env
    var launchMode: ApplicationLaunchMode = start.foregroundIfRunning ? .foregroundIfRunning : .failIfRunning
    if start.enableRepl {
      // Setup the launch for the REPL (inject the shim, the idb command API in libReplIDB, and the
      // IDB_REPL_* vars) and force a relaunch so an already-running, un-injected app picks them up.
      let replEnvironment = try await commandExecutor.replAppLaunchEnvironment(bundleID: start.bundleID)
      for (key, value) in replEnvironment {
        if key == "DYLD_INSERT_LIBRARIES", let existing = environment[key], !existing.isEmpty {
          environment[key] = "\(existing):\(value)"
        } else {
          environment[key] = value
        }
      }
      launchMode = .relaunchIfRunning
    }
    let call = CallTelemetry.current
    let unprepared = environment
    environment = await LaunchStage.audioInjection.measure(into: call) {
      await commandExecutor.audioInjectionAppLaunchEnvironment(unprepared)
    }
    environment = commandExecutor.videoInjectionAppLaunchEnvironment(environment)
    let config = ApplicationLaunchConfiguration(
      bundleID: start.bundleID,
      bundleName: nil,
      arguments: start.appArgs,
      environment: environment,
      waitForDebugger: start.waitForDebugger,
      stdOut: stdOut,
      stdErr: stdErr,
      launchMode: launchMode)
    let launchedApp = try await Self.launch(cancellation: context.cancellation) {
      try await self.launch(config, telemetry: call)
    }
    let response = Idb_LaunchResponse.with {
      $0.debugger.pid = UInt64(launchedApp.processIdentifier)
    }
    try await responseStream.send(response)

    guard start.waitFor else { return }

    try await Self.waitForCompletion(
      application: launchedApp,
      requestStream: requestStream,
      consumers: consumers,
      cancellation: context.cancellation)
  }

  /// Runs `launch` so that the RPC's cancellation cancels it. A client that disconnects before the
  /// app has started would otherwise leave the launch running, such as a `devicectl` launch
  /// against a device CoreDevice cannot reach.
  static func launch(
    cancellation: ServerContext.RPCCancellationHandle,
    _ launch: @escaping @Sendable () async throws -> any LaunchedApplication
  ) async throws -> any LaunchedApplication {
    try await withRPCCancellation(cancellation, operation: launch)
  }

  static func waitForCompletion(
    application: any LaunchedApplication,
    requestStream: RequestStreamReader<Idb_LaunchRequest>,
    consumers: [any DataConsumerLifecycle],
    cancellation: ServerContext.RPCCancellationHandle
  ) async throws {
    try await withRPCCancellation(cancellation) {
      let completion = try await withThrowingTaskGroup(of: Completion.self) { group in
        group.addTask {
          let request = try await requestStream.requiredNext()
          guard case .stop = request.control else {
            throw RPCError(code: .failedPrecondition, message: "Application has already started")
          }
          return .stopped
        }
        group.addTask {
          do {
            try await application.waitForTermination()
            return .exited
          } catch DeviceApplicationError.awaitingTerminationUnsupported {
            return .observerUnsupported
          } catch is CancellationError {
            // Only this handler calls `application.terminate()`, after this group finishes, so
            // while the loop below waits, this is RPC cancellation; a `terminate()` during the wait
            // would also land here and leave the handler waiting for Stop. RPC cancellation can
            // arrive together with a Stop the client already sent, so the request stream decides
            // whether the app must be stopped.
            return .observerCancelled
          }
        }
        defer { group.cancelAll() }
        while let completion = try await group.next() {
          switch completion {
          case .stopped, .exited:
            return completion
          case .observerUnsupported, .observerCancelled:
            continue
          }
        }
        throw RPCError(code: .internalError, message: "Application launch ended without Stop or exit")
      }
      // Terminate the app on Stop before honouring cancellation, since a client can disconnect
      // right after sending Stop. The termination runs outside the RPC's cancellation, so a
      // disconnect cannot interrupt a stop that was accepted, and it is joined before returning.
      if case .stopped = completion {
        try await Task { try await application.terminate() }.value
      }
      try Task.checkCancellation()

      try await withThrowingTaskGroup(of: Void.self) { group in
        for consumer in consumers {
          group.addTask {
            try await consumer.awaitFinishedConsuming()
          }
        }
        try await group.waitForAll()
      }
      try Task.checkCancellation()
    }
  }

  /// Launches with the storage and target path placeholders in the environment replaced by their values.
  private func launch(_ configuration: ApplicationLaunchConfiguration, telemetry call: CallTelemetry?) async throws -> any LaunchedApplication {
    let environment = await LaunchStage.environmentReplacement.measure(into: call) {
      var replacements: [String: String] = [:]
      replacements.merge(commandExecutor.storageManager.replacementMapping) { _, new in new }
      replacements.merge(target.replacementMapping()) { _, new in new }
      return applyEnvironmentReplacements(configuration.environment, replacements: replacements)
    }

    let derived = ApplicationLaunchConfiguration(
      bundleID: configuration.bundleID,
      bundleName: configuration.bundleName,
      arguments: configuration.arguments,
      environment: environment,
      waitForDebugger: configuration.waitForDebugger,
      stdOut: configuration.stdOut,
      stdErr: configuration.stdErr,
      launchMode: configuration.launchMode
    )
    return try await LaunchStage.launch.measure(into: call) {
      try await target.application.launch(derived)
    }
  }

  private func applyEnvironmentReplacements(_ environment: [String: String], replacements: [String: String]) -> [String: String] {
    let logger = commandExecutor.logger
    logger.log("Original environment: \(environment)")
    logger.log("Existing replacement mapping: \(replacements)")
    var interpolatedEnvironment: [String: String] = [:]
    for (name, var value) in environment {
      for (interpolationName, interpolationValue) in replacements {
        value = value.replacingOccurrences(of: interpolationName, with: interpolationValue)
      }
      interpolatedEnvironment[name] = value
    }
    logger.log("Interpolated environment: \(interpolatedEnvironment)")
    return interpolatedEnvironment
  }

  static func pipeOutput(interface: Idb_ProcessOutput.Interface, send: @escaping @Sendable (Idb_LaunchResponse) throws -> Void) -> ResponseForwardingConsumer {
    return ResponseForwardingConsumer { data in
      let response = Idb_LaunchResponse.with {
        $0.output.data = data
        $0.output.interface = interface
      }
      try send(response)
    }
  }

  private enum Completion: Sendable {
    case stopped
    case exited
    case observerUnsupported
    case observerCancelled
  }
}
