/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import FBControlCore
import FBSimulatorControl
import FBVideoCore
import Foundation

/// The file format a recording is written in.
public enum SimulatorVideoContainer: Sendable {
  /// An MP4 plays everywhere but presents every frame at one size, so a recording into it keeps its first frame's
  /// canvas and letterboxes a later screen of another shape into it.
  case mp4
  /// A QuickTime movie, which behaves as an MP4.
  case mov
  /// WebM with H.264 or HEVC. A recording into it follows the screen's size through rotations and display switches,
  /// for players that handle a change of size, such as Chrome. QuickTime cannot open it.
  case webm

  /// The container a file extension names, or nil for an extension that names none.
  public init?(pathExtension: String) {
    switch pathExtension.lowercased() {
    case "mp4":
      self = .mp4
    case "mov":
      self = .mov
    case "webm":
      self = .webm
    default:
      return nil
    }
  }
}

enum SimulatorVideoError: Error, LocalizedError {
  case webMRequiresCompressedVideo
  case audioBeforeStop
  case audioRequiresMP4OrMOV
  case audioWithoutFrames

  var errorDescription: String? {
    switch self {
    case .webMRequiresCompressedVideo:
      return "A WebM recording must be encoded as H.264 or HEVC"
    case .audioBeforeStop:
      return "Audio can be added to a recording only once it has stopped"
    case .audioRequiresMP4OrMOV:
      return "Audio can be added to an MP4 or MOV recording, not a WebM"
    case .audioWithoutFrames:
      return "The recording holds no frames, so there is no timeline to place audio on"
    }
  }
}

/// Records simulator video in-process. Drives the framebuffer through the shared
/// `SimulatorVideoStream` encode pipeline with the configured cadence and muxes encoded frames
/// into MP4 or MOV via `SimulatorVideoFileWriter` (`AVAssetWriter`), or into WebM via `SimulatorVideoWebMWriter`.
/// The byte-stream consumer is unused; only the recording file is produced.
///
/// An actor: `hasStopped` guards the single stop and is set before the first suspension, so
/// concurrent `stop()` calls cannot both finalize, and each later call returns only once the file
/// the first finalizes is done.
public actor SimulatorVideo {

  /// The URL of the recording file.
  let outputURL: URL
  private let container: SimulatorVideoContainer
  private let format: VideoStreamFormat
  /// The underlying encode pipeline, exposed so callers can drive overlay/chapter/screenshot on the live
  /// recording. `nonisolated`: a constant of Sendable (actor) type, readable without a hop.
  public nonisolated let stream: SimulatorVideoStream
  private let fileWriter: any RecordingFileWriter
  private let logger: any ControlCoreLogger
  private var hasStopped = false
  private let stopped = AsyncEvent<URL>()
  private var keyFrames: Task<Void, Never>?

  /// How often the recording asks the encoder for a keyframe, at half the writer's fragment
  /// interval so that a sync sample always falls between two fragment boundaries.
  ///
  /// A fragmented movie can only begin a fragment at a sync sample, and the encoder's keyframe
  /// interval is a maximum in *source* duration: it can only be honoured on a frame, and the
  /// simulator's screen supplies frames only as it changes. A screen that sits still through a slow
  /// step stretches the gap between sync samples far past the nominal interval -- twelve seconds
  /// against a nominal four, measured on a recording of the end-to-end suite -- and a fragment
  /// boundary landing in that gap is refused, ending the recording. The request pushes a frame of
  /// its own, so the gap is bounded by this interval whatever the screen is doing.
  private static let keyFrameInterval = Duration.seconds(SimulatorVideoFileWriter.movieFragmentInterval.seconds / 2)

  public init(framebuffer: Framebuffer, configuration: VideoStreamConfiguration, filePath: String, container: SimulatorVideoContainer = .mp4, edgeInsets: VideoStreamEdgeInsets = VideoStreamEdgeInsets(top: 0, bottom: 0, left: 0, right: 0), chaptersEnabled: Bool = false, logger: any ControlCoreLogger) {
    self.outputURL = URL(fileURLWithPath: filePath)
    self.container = container
    self.format = configuration.format
    let fileWriter: any RecordingFileWriter
    switch container {
    case .mp4:
      fileWriter = SimulatorVideoFileWriter(filePath: filePath, fileType: .mp4, chaptersEnabled: chaptersEnabled, logger: logger)
    case .mov:
      fileWriter = SimulatorVideoFileWriter(filePath: filePath, fileType: .mov, chaptersEnabled: chaptersEnabled, logger: logger)
    case .webm:
      fileWriter = SimulatorVideoWebMWriter(filePath: filePath, chaptersEnabled: chaptersEnabled, logger: logger)
    }
    self.fileWriter = fileWriter
    self.logger = logger
    self.stream = SimulatorVideoStream(framebuffer: framebuffer, configuration: configuration, edgeInsets: edgeInsets, fileWriter: fileWriter, logger: logger)
  }

  // MARK: - Recording

  public func startRecording() async throws {
    if case .webm = container {
      guard case .compressedVideo = format else {
        throw SimulatorVideoError.webMRequiresCompressedVideo
      }
    }
    // Encoded frames are routed to `fileWriter` (which opens lazily on its first sample, since
    // passthrough muxing needs that sample's format); the stream's byte consumer is unused, so a
    // no-op consumer satisfies its streaming bookkeeping (and never reports back-pressure).
    try await stream.startStreaming(NullDataConsumer())
    keyFrames = Task { [stream] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.keyFrameInterval)
        guard !Task.isCancelled else { return }
        stream.requestKeyFrame()
      }
    }
  }

  /// The Unix timestamp of the recording's own media time zero, or nil before a frame was muxed.
  ///
  /// The file's timeline is anchored at the first encoded sample's presentation timestamp, which
  /// the encoder stamps relative to the first pushed frame, so media zero is that frame plus the
  /// anchor. When the frame was captured is the wall clock read as it was pushed, so the answer is
  /// unchanged by how long the recording ran, by how long finalization took, and by the clock
  /// being set in between. Callers measuring their own wall-clock events against the recording
  /// need this rather than the moment they observed the recorder come up, which trails media zero
  /// by however long readiness took to detect.
  public func startedAt() async -> Double? {
    guard let anchor = fileWriter.startPresentationTime else {
      return nil
    }
    return await stream.mediaOrigin(anchor: anchor.seconds)
  }

  /// The recording's media time zero on the host clock, in `mach_absolute_time` ticks, or nil before
  /// a frame was muxed. Read, like `startedAt()`, as the first frame was pushed.
  public func startedAtHostTime() async -> UInt64? {
    guard let anchor = fileWriter.startPresentationTime else {
      return nil
    }
    return await stream.mediaOriginHostTime(anchor: anchor.seconds)
  }

  /// Adds the audio in a WAV file to the stopped recording, as an AAC track. `hostTime` is when the
  /// WAV's first frame played, in `mach_absolute_time` ticks, and places it against the frames, which
  /// are timed on the same clock. Audio from before the first frame is cut.
  public func addAudio(fromWAV path: String, startingAtHostTime hostTime: UInt64) async throws -> AudioTrackPlacement {
    guard hasStopped else {
      throw SimulatorVideoError.audioBeforeStop
    }
    // The file is rewritten only once the stop has finished writing it.
    _ = try? await stopped.waitIgnoringCancellation()
    let fileType: AVFileType
    switch container {
    case .mp4:
      fileType = .mp4
    case .mov:
      fileType = .mov
    case .webm:
      throw SimulatorVideoError.audioRequiresMP4OrMOV
    }
    guard let origin = await startedAtHostTime() else {
      throw SimulatorVideoError.audioWithoutFrames
    }
    return try await AudioTrackMuxer.addAudio(
      fromWAV: URL(fileURLWithPath: path), offset: MediaOrigin.seconds(fromHostTime: origin, to: hostTime),
      to: outputURL, fileType: fileType, logger: logger)
  }

  public func stop() async throws -> URL {
    if hasStopped {
      // The first stop may still be finalizing the file; a later one returns once it has.
      return try await stopped.waitIgnoringCancellation()
    }
    hasStopped = true
    // A later stop returns the file, as one after a failed stop always has, but only once this one is done with it.
    defer { stopped.happen(outputURL) }
    keyFrames?.cancel()
    keyFrames = nil
    // Stop the framebuffer push and flush the encoder (tearDown's VTCompressionSessionCompleteFrames
    // drains all pending frames into `fileWriter`) before finalizing the file's moov.
    try await stream.stopStreaming()
    try await fileWriter.finish()
    return outputURL
  }

}
