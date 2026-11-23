/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import FBControlCore
import Foundation

private enum VideoFileWriterError: Error {
  case cannotAddFileOutput(filePath: String)
  case failedToRemoveExistingVideo(filePath: String, cause: any Error)
  case failedToCreateAuxiliaryDirectory(filePath: String, cause: any Error)
}

extension VideoFileWriterError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .cannotAddFileOutput(let filePath):
      return "Cannot add File Output to session for \(filePath)"
    case .failedToRemoveExistingVideo(let filePath, _):
      return "Failed to remove existing device video at \(filePath)"
    case .failedToCreateAuxiliaryDirectory(let filePath, _):
      return "Failed to create auxiliary directory for device video at \(filePath)"
    }
  }

  var failureReason: String? {
    switch self {
    case .cannotAddFileOutput:
      return nil
    case .failedToRemoveExistingVideo(_, let cause), .failedToCreateAuxiliaryDirectory(_, let cause):
      return cause.localizedDescription
    }
  }
}

public final class VideoFileWriter: NSObject, AVCaptureFileOutputRecordingDelegate {

  private let session: AVCaptureSession
  private let output: AVCaptureMovieFileOutput
  private let logger: any ControlCoreLogger
  private let outputURL: URL
  private let started = AsyncEvent<Void>()
  private let finished = AsyncEvent<Void>()

  /// Adds a movie file output to `session` that will write to `filePath`.
  public convenience init(session: AVCaptureSession, filePath: String, logger: any ControlCoreLogger) throws {
    let output = AVCaptureMovieFileOutput()
    if !session.canAddOutput(output) {
      throw VideoFileWriterError.cannotAddFileOutput(filePath: filePath)
    }
    session.addOutput(output)
    self.init(session: session, output: output, filePath: filePath, logger: logger)
  }

  init(session: AVCaptureSession, output: AVCaptureMovieFileOutput, filePath: String, logger: any ControlCoreLogger) {
    self.session = session
    self.output = output
    self.outputURL = URL(fileURLWithPath: filePath)
    self.logger = logger
    super.init()
  }

  public func start() async throws {
    try await startWriting()
  }

  public func stop() async throws -> URL {
    try await stopWriting()
    return outputURL
  }

  private var filePath: String {
    outputURL.path
  }

  private func startWriting() async throws {
    if FileManager.default.fileExists(atPath: filePath) {
      logger.log("File already exists at \(filePath), deleting")
      do {
        try FileManager.default.removeItem(atPath: filePath)
      } catch {
        throw VideoFileWriterError.failedToRemoveExistingVideo(filePath: filePath, cause: error)
      }
      logger.log("Removed video file at \(filePath)")
    }
    do {
      try FileManager.default.createDirectory(atPath: (filePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: nil)
    } catch {
      throw VideoFileWriterError.failedToCreateAuxiliaryDirectory(filePath: filePath, cause: error)
    }
    session.startRunning()
    output.startRecording(to: outputURL, recordingDelegate: self)
    logger.log("Started Video Session for Device Video at file \(filePath)")
    try await started.waitIgnoringCancellation()
  }

  private func stopWriting() async throws {
    output.stopRecording()
    session.stopRunning()
    try await finished.waitIgnoringCancellation()
  }

  // MARK: - AVCaptureFileOutputRecordingDelegate

  public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
    logger.log("Did Start Recording at \(filePath)")
    started.happen()
  }

  public func fileOutput(_ output: AVCaptureFileOutput, didPauseRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
    logger.log("Did Pause Recording at \(filePath)")
  }

  public func fileOutput(_ output: AVCaptureFileOutput, willFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
    logger.log("Will Finish Recording at \(filePath)")
  }

  public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
    logger.log("Did Finish Recording at \(filePath)")
    finished.happen()
  }

  public func fileOutput(_ output: AVCaptureFileOutput, didResumeRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
    logger.log("Did Resume Recording at \(filePath)")
  }
}
