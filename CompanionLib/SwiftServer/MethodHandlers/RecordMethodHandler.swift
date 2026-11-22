/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBArtifactStaging
import FBControlCore
import FBSimulatorCodeInjection
import FBSimulatorControl
import FBVideoCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf

struct RecordMethodHandler {

  let target: CompanionTarget
  let targetLogger: ControlCoreLogger

  /// Stops `recording`, returning the file to deliver and the failure to report once it has been.
  ///
  /// Finalizing can fail with a usable recording already on disk: every frame has been written by
  /// this point and it is the closing write that fails. Reporting that before the file is sent
  /// costs the caller a recording that exists, so the error is handed back rather than thrown and
  /// the caller delivers first. The fallback path is the file the recording was started against,
  /// which is where those frames are.
  static func finalizeForDelivery(
    _ recording: any VideoRecording,
    fallbackPath: String,
    logger: any ControlCoreLogger,
  ) async -> (outputURL: URL, finalizeError: (any Error)?) {
    do {
      return (try await recording.stop(), nil)
    } catch {
      logger.log("Recording did not finalize cleanly, sending what was written: \(error)")
      return (URL(fileURLWithPath: fallbackPath), error)
    }
  }

  /// Runs `body`, the part of a call between starting `recording` and its stop, and stops the
  /// recording if `body` fails instead: the client went away, the connection dropped or the call was
  /// cancelled. Nothing else stops it, and a recording left running keeps its encoder, its
  /// framebuffer consumer and its file for the life of the companion. `body`'s error is rethrown.
  static func stoppingOnFailure(
    _ recording: any VideoRecording,
    logger: any ControlCoreLogger,
    _ body: () async throws -> Void
  ) async throws {
    do {
      try await body()
    } catch {
      do {
        _ = try await recording.stop()
      } catch let stopError {
        logger.error().log("Recording whose call ended before its stop did not stop cleanly: \(stopError)")
      }
      throw error
    }
  }

  /// Where a recording the companion streams to its client is written first: a file of its own, so
  /// recordings that overlap never write the same one. It is deleted once the RPC ends.
  static func stagingPath(in directory: String) -> String {
    (directory as NSString).appendingPathComponent("idb_encode-\(UUID().uuidString).mp4")
  }

  func handle(requestStream: RequestStreamReader<Idb_RecordRequest>, responseStream: RPCWriter<Idb_RecordResponse>, context: ServerContext) async throws {

    let request = try await requestStream.requiredNext()
    guard case let .start(start) = request.control
    else { throw RPCError(code: .failedPrecondition, message: "Expect start as initial request frame") }

    let streamingToClient = start.filePath.isEmpty
    let filePath = streamingToClient ? Self.stagingPath(in: target.auxillaryDirectory) : start.filePath
    defer {
      if streamingToClient {
        try? FileManager.default.removeItem(atPath: filePath)
      }
    }

    let videoRecording = target.videoRecording
    let encodeOptions = try RecordRequestTranslation.encodeOptions(from: start)
    if encodeOptions != nil {
      try RecordRequestTranslation.requireHonoredConfiguration(videoRecording, describing: "\(target)")
    }
    // Started first, so the audio covers the recording's first frame.
    let capture = start.audio ? try await startAudioCapture(for: videoRecording) : nil
    let recording: any VideoRecording
    if let encodeOptions {
      recording = try await videoRecording.start(
        toFile: filePath,
        configuration: RecordRequestTranslation.configuration(for: encodeOptions))
    } else {
      recording = try await videoRecording.start(toFile: filePath)
    }
    try await Self.stoppingOnFailure(recording, logger: targetLogger) {
      if encodeOptions != nil || start.audio {
        // Ahead of any payload, so a client reading the stream in order learns what it is about to
        // receive before it receives any of it.
        try await responseStream.send(RecordRequestTranslation.appliedResponse(encodeOptions, audio: start.audio))
      }
      _ = try await requestStream.requiredNext()
    }

    let (outputURL, finalizeError) = await Self.finalizeForDelivery(
      recording,
      fallbackPath: filePath,
      logger: targetLogger)
    var audioError: (any Error)?
    if let capture, finalizeError == nil {
      let keepingAudio = !start.filePath.isEmpty
      do {
        let response = try await Self.addAudio(
          from: capture, to: recording,
          mixingTo: RecordRequestTranslation.audioPath(besideRecordingAt: outputURL.path), keepingMix: keepingAudio,
          logger: targetLogger)
        try await responseStream.send(response)
      } catch {
        // The video is whole without its audio, so it is still delivered.
        targetLogger.log("Recording is delivered without its audio: \(error)")
        audioError = error
      }
    }

    try await Self.deliverThenReport(
      outputURL: outputURL,
      streamingToClient: streamingToClient,
      localFilePath: start.filePath,
      finalizeError: finalizeError ?? audioError,
      responseStream: responseStream,
      logger: targetLogger)
  }

  /// Starts keeping what the simulator's apps play, for a request that asked for audio.
  private func startAudioCapture(for commands: any VideoRecordingCommands) async throws -> AudioCaptureSession {
    guard commands.acceptsAudio else {
      throw RPCError(code: .unimplemented, message: "\(target) records without audio")
    }
    do {
      return try await target.simulator().audioCapture.start()
    } catch let error as AudioCaptureError {
      throw RecordRequestTranslation.rpcError(for: error)
    } catch let error as IDBCommandError {
      throw RPCError(code: .failedPrecondition, message: error.localizedDescription)
    }
  }

  /// Stops `capture`, mixes it into `mixPath` and adds it to the stopped recording as a track, and
  /// returns the response describing the audio. The mix is deleted afterwards unless `keepingMix`.
  static func addAudio(
    from capture: AudioCaptureSession, to recording: any VideoRecording, mixingTo mixPath: String, keepingMix: Bool,
    logger: any ControlCoreLogger
  ) async throws -> Idb_RecordResponse {
    let captured = try await capture.stop(writingMixTo: mixPath)
    defer {
      if !keepingMix {
        try? FileManager.default.removeItem(atPath: mixPath)
      }
    }
    var placement: AudioTrackPlacement?
    if let path = captured.path {
      guard captured.startHostTime != 0 else {
        throw RPCError(code: .internalError, message: "The captured audio carries no host time to place it in the recording by")
      }
      placement = try await recording.addAudio(fromWAV: path, startingAtHostTime: captured.startHostTime)
    }
    let names = captured.processes.filter { $0.frames > 0 }.map(\.name)
    logger.log("Recorded \(placement?.frames ?? 0) frames of audio from \(names.isEmpty ? "no process" : names.joined(separator: ", "))")
    return RecordRequestTranslation.audioResponse(
      captured, placement: placement, keptAt: keepingMix ? captured.path : nil)
  }

  /// Sends the recording, and only then reports a finalize failure.
  ///
  /// The order is the whole point. Reporting first aborts the RPC with the file still sitting on
  /// this host, which is how a recording that existed was lost: the caller received no bytes at all.
  static func deliverThenReport(
    outputURL: URL,
    streamingToClient: Bool,
    localFilePath: String,
    finalizeError: (any Error)?,
    responseStream: RPCWriter<Idb_RecordResponse>,
    logger: any ControlCoreLogger,
  ) async throws {
    if streamingToClient {
      // A finalize that failed before the file was created leaves nothing to send, and gzip would
      // fail on the missing path with an error that hides the real one.
      if FileManager.default.fileExists(atPath: outputURL.path) {
        try await FileDrainWriter.performDrain(ArchiveOperations.gzipSubprocess(forPath: outputURL.path), logger: logger) { data in
          let response = Idb_RecordResponse.with { $0.payload.data = data }
          try await responseStream.send(response)
        }
      }
    } else {
      let response = Idb_RecordResponse.with {
        $0.output = .payload(.with { $0.source = .filePath(localFilePath) })
      }
      try await responseStream.send(response)
    }

    if let finalizeError {
      throw finalizeError
    }
  }
}
