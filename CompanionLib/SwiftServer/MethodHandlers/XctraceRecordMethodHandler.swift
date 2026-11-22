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
import IDBConcurrency
import IDBGRPCSwift
import SwiftProtobuf

/// The parts of a running xctrace a record session drives.
protocol XCTraceRecording: Sendable {
  /// Resolves with xctrace's exit status once it exits, whether it was stopped or exited on its own.
  func exitStatus() async throws -> Int32

  /// Interrupts xctrace and returns the trace it wrote, throwing if xctrace exited with a failure.
  func stop(withTimeout timeout: TimeInterval) async throws -> URL
}

extension XCTraceRecordOperation: XCTraceRecording {
  func exitStatus() async throws -> Int32 {
    switch try await running.terminationStatus {
    case .exited(let code):
      return code
    case .signalled(let signo):
      throw ProcessTerminationError.exitedWithSignal(processIdentifier: running.processIdentifier, processName: "xctrace", signal: signo)
    }
  }
}

struct XctraceRecordMethodHandler {

  let logger: ControlCoreLogger
  let targetLogger: ControlCoreLogger
  let target: any Target

  func handle(requestStream: RequestStreamReader<Idb_XctraceRecordRequest>, responseStream: RPCWriter<Idb_XctraceRecordResponse>, context: ServerContext) async throws {
    guard case let .start(start) = try await requestStream.requiredNext().control
    else { throw RPCError(code: .failedPrecondition, message: "Expected start control") }
    let (operation, output) = try await startXCTraceOperation(request: start, responseStream: responseStream)
    defer { output.stopForwarding() }

    let stop = try await Self.recordUntilStopped(requestStream: requestStream, recording: operation)
    try await finishXCTrace(operation: operation, request: stop, responseStream: responseStream, output: output)
  }

  /// Records until the client sends Stop, then stops xctrace. Fails as soon as xctrace exits with a failure,
  /// since the client may otherwise wait forever for a session that has already ended.
  static func recordUntilStopped(requestStream: RequestStreamReader<Idb_XctraceRecordRequest>, recording: some XCTraceRecording) async throws -> Idb_XctraceRecordRequest.Stop {
    let request = try await withThrowingTaskGroup(of: Idb_XctraceRecordRequest?.self) { group in
      group.addTask {
        try await requestStream.requiredNext()
      }
      group.addTask {
        let status = try await recording.exitStatus()
        guard status == 0 else {
          throw RPCError(code: .internalError, message: "xctrace exited with status \(status) before it was stopped")
        }
        // A clean exit leaves a trace to collect, so keep waiting for Stop.
        return nil
      }
      while let next = try await group.next() {
        if let request = next {
          group.cancelAll()
          return request
        }
      }
      throw RPCError(code: .internalError, message: "Recording ended without a Stop")
    }
    guard case let .stop(stop) = request.control
    else { throw RPCError(code: .failedPrecondition, message: "Expected end control") }

    let stopTimeout = stop.timeout != 0 ? stop.timeout : DefaultXCTraceRecordStopTimeout
    _ = try await recording.stop(withTimeout: stopTimeout)
    return stop
  }

  private func startXCTraceOperation(request start: Idb_XctraceRecordRequest.Start, responseStream: RPCWriter<Idb_XctraceRecordResponse>) async throws -> (XCTraceRecordOperation, ResponseForwardingConsumer) {
    let config = xcTraceRecordConfiguration(from: start)

    let responseWriter = FIFOStreamWriter(stream: responseStream)
    let consumer = ResponseForwardingConsumer { data in
      try responseWriter.send(Idb_XctraceRecordResponse.with { $0.log = data })
    }

    let logger = CompositeLogger(
      loggers: [
        ConsumerLogger(consumer: consumer),
        targetLogger,
      ].compactMap({ $0 }))

    let operation = try await target.xctraceRecord.start(configuration: config, logger: logger)
    let response = Idb_XctraceRecordResponse.with {
      $0.state = .running
    }
    try await responseStream.send(response)

    return (operation, consumer)
  }

  private func finishXCTrace(operation: XCTraceRecordOperation, request stop: Idb_XctraceRecordRequest.Stop, responseStream: RPCWriter<Idb_XctraceRecordResponse>, output: ResponseForwardingConsumer) async throws {
    let response = Idb_XctraceRecordResponse.with {
      $0.state = .processing
    }
    try await responseStream.send(response)

    let processed = try await Self.postProcess(
      arguments: stop.args,
      traceFile: operation.traceDir,
      logger: logger)
    output.stopForwarding()

    try await Self.sendTrace(atPath: processed.path, responseStream: responseStream, logger: logger)
  }

  /// Streams the trace at `path` to the client as a single gzipped tar, in chunks.
  static func sendTrace(atPath path: String, responseStream: RPCWriter<Idb_XctraceRecordResponse>, logger: ControlCoreLogger) async throws {
    let archive = try ArchiveOperations.gzippedTarSubprocess(forPath: path, logger: logger)
    try await FileDrainWriter.performDrain(archive, logger: logger) { data in
      let response = Idb_XctraceRecordResponse.with {
        $0.payload = .with { $0.data = data }
      }
      try await responseStream.send(response)
    }
  }

  /// Runs the client's post-processing tool over the trace, returning the processed trace beside it.
  ///
  /// `arguments` is `[tool, script, output name, extra...]`; the tool runs as `tool script <trace> -o <output> extra...`.
  static func postProcess(
    arguments: [String]?,
    traceFile: URL,
    logger: (any ControlCoreLogger)?
  ) async throws -> URL {
    guard let arguments, !arguments.isEmpty else {
      return traceFile
    }
    let outputTraceFile = traceFile.deletingLastPathComponent().appendingPathComponent(arguments[2])
    var launchArguments = [arguments[1], traceFile.path, "-o", outputTraceFile.path]
    if arguments.count > 3 {
      launchArguments.append(contentsOf: arguments[3...])
    }

    logger?.log("Starting post processing | Launch path: \(arguments[0]) | Arguments: \(CollectionInformation.oneLineDescription(from: launchArguments))")
    let standardInput = InputSource()
    defer { standardInput.finish() }
    let output: Subprocess.Output<Void> = logger.map { .logger($0) } ?? .nullDevice
    _ = try await Subprocess(executable: arguments[0], arguments: launchArguments)
      .run(output: output, error: output, input: .source(standardInput), logger: logger)
    return outputTraceFile
  }

  private func xcTraceRecordConfiguration(from request: Idb_XctraceRecordRequest.Start) -> XCTraceRecordConfiguration {
    let timeLimit = request.timeLimit != 0 ? request.timeLimit : DefaultXCTraceRecordOperationTimeLimit

    return .init(
      templateName: request.templateName,
      timeLimit: timeLimit,
      package: request.package,
      allProcesses: request.target.allProcesses,
      processToAttach: request.target.processToAttach,
      processToLaunch: request.target.launchProcess.processToLaunch,
      launchArgs: request.target.launchProcess.launchArgs,
      targetStdin: request.target.launchProcess.targetStdin,
      targetStdout: request.target.launchProcess.targetStdout,
      processEnv: request.target.launchProcess.processEnv,
      shim: nil)
  }
}
