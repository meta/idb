/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import ArgumentParser
import CoreMedia
import CoreVideo
import FBControlCore
import FBSimulatorControl
import FBSimulatorVideo
import FBVideoCore
import Foundation
import VideoToolbox
import os

struct Record: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Record a playable file with overlay and chapter control")
  @OptionGroup var target: SimulatorOptions
  @OptionGroup var video: VideoOptions
  @Option(help: "h264 (default), hevc, mjpeg, or auto (HEVC then JPEG)") var encoding: RecordingEncoding = .h264
  @Option(help: "Stop after this many seconds (disables stdin controls); otherwise wait for stdin shutdown or a signal") var duration: Double?
  @Argument(help: "Output .mp4, .mov or .webm path; mjpeg and auto require .mov. A .webm recording follows the screen's size and plays in Chrome, not QuickTime") var output: String

  func validate() throws {
    if let duration, !duration.isFinite || duration <= 0 {
      throw ValidationError("--duration must be positive")
    }
    guard let container = Self.container(of: output) else {
      throw ValidationError("Output must end in .mp4, .mov or .webm")
    }
    if encoding == .mjpeg || encoding == .auto {
      guard case .mov = container else {
        throw ValidationError("mjpeg and auto recordings require a .mov output")
      }
    }
    guard !FileManager.default.fileExists(atPath: output),
      !FileManager.default.fileExists(atPath: output + ".json")
    else {
      throw ValidationError("Output already exists: \(output)")
    }
  }

  /// The container the output path names; `validate` has refused any other.
  private var container: SimulatorVideoContainer {
    Self.container(of: output) ?? .mp4
  }

  private static func container(of path: String) -> SimulatorVideoContainer? {
    SimulatorVideoContainer(pathExtension: (path as NSString).pathExtension)
  }

  @MainActor
  mutating func run() async throws {
    let logger = ControlCoreGlobalConfiguration.systemLogger(writingToStderr: true, debugLogging: false)
    let simulator = try target.simulator(logger: logger)
    let (insets, renderer, bars) = try video.composition(simulator: simulator, logger: logger)
    let framebuffer = try await simulator.framebuffer.connect(display: .active)
    let stdinDriven = duration == nil && isatty(FileHandle.standardInput.fileDescriptor) == 0
    let (recording, selected) = try await startRecording(framebuffer: framebuffer, insets: insets, chapters: stdinDriven, logger: logger)
    let (handler, timers) = VideoSession.makeHandler(videoStream: recording.stream, renderer: renderer, screenshotDir: video.screenshotDir, parsedBars: bars, barStats: video.barStats, logger: logger)
    defer { timers.forEach { $0.cancel() } }
    FileHandle.standardError.write(Data("Going into PLAYING state.\n".utf8))
    if stdinDriven {
      await handler.driveUntilStoppedOrSignal(waitForSignal: waitForStopSignal)
    } else {
      let duration = duration
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await waitForStopSignal() }
        if let duration { group.addTask { try? await Task.sleep(for: .seconds(duration)) } }
        await group.next()
        group.cancelAll()
      }
    }
    let url = try await recording.stop()
    let startedAt = await recording.startedAt()
    let report = try await RecordingReport.read(url: url, container: container, encoding: selected.rawValue, startedAt: startedAt)
    try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: output + ".json"), options: .atomic)
    logger.info().log("Recorded \(report.duration) seconds to \(output) (\(selected.rawValue))")
  }

  @MainActor
  private func startRecording(framebuffer: Framebuffer, insets: VideoStreamEdgeInsets, chapters: Bool, logger: any ControlCoreLogger) async throws -> (SimulatorVideo, RecordingEncoding) {
    let candidates: [RecordingEncoding] = encoding == .auto ? [.hevc, .mjpeg] : [encoding]
    for candidate in candidates {
      let configuration = video.configuration(format: candidate.format)
      let recording = SimulatorVideo(framebuffer: framebuffer, configuration: configuration, filePath: output, container: container, edgeInsets: insets, chaptersEnabled: chapters, logger: logger)
      do {
        try await recording.startRecording()
        let deadline = ContinuousClock.now + .seconds(10)
        while await recording.stream.currentEncoderStats().writeCount == 0 {
          try Task.checkCancellation()
          guard ContinuousClock.now < deadline else {
            throw RecordingError.noFrames(candidate.rawValue)
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        return (recording, candidate)
      } catch let recordingError {
        _ = try? await recording.stop()
        logger.error().log("Recording with \(candidate.rawValue) failed: \(recordingError)")
        if recordingError is CancellationError || candidate == candidates.last { throw recordingError }
        if FileManager.default.fileExists(atPath: output) {
          do {
            try FileManager.default.removeItem(atPath: output)
          } catch {
            logger.error().log("Could not remove incomplete recording at \(output): \(error)")
            throw recordingError
          }
        }
      }
    }
    throw RecordingError.noFrames(encoding.rawValue)
  }
}

enum RecordingEncoding: String, ExpressibleByArgument {
  case h264, hevc, mjpeg, auto
  var format: VideoStreamFormat {
    switch self {
    case .h264: return .compressedVideo(withCodec: .h264, transport: .annexB)
    case .hevc, .auto: return .compressedVideo(withCodec: .hevc, transport: .annexB)
    // A recording tolerates a slower encoder; see `MJPEGEncoderSelection`.
    case .mjpeg: return .mjpeg(encoder: .allowSoftware)
    }
  }
}

enum RecordingError: Error, LocalizedError {
  case noFrames(String)
  case unreadable
  var errorDescription: String? {
    switch self {
    case let .noFrames(encoding): return "No video frames written with \(encoding)"
    case .unreadable: return "Recording contains no decodable video frame"
    }
  }
}

struct RecordingReport: Encodable {
  let encoding: String
  let width: Int
  let height: Int
  let duration: Double
  /// The Unix timestamp the first frame was captured at, so a caller timestamping its own events can
  /// place them on the recording's timeline. Absent when the recorder could not establish it.
  let startedAt: Double?

  static func read(url: URL, container: SimulatorVideoContainer, encoding: String, startedAt: Double?) async throws -> Self {
    switch container {
    case .mp4, .mov:
      return try await readMovie(url: url, encoding: encoding, startedAt: startedAt)
    case .webm:
      // AVFoundation cannot open WebM, so the first keyframe is decoded with VideoToolbox directly.
      let summary = try WebMFileReader.read(url)
      guard summary.duration.isFinite, summary.duration > 0 else { throw RecordingError.unreadable }
      let (width, height) = try decodedSize(of: summary.firstKeyFrame)
      return Self(encoding: encoding, width: width, height: height, duration: summary.duration, startedAt: startedAt)
    @unknown default:
      return try await readMovie(url: url, encoding: encoding, startedAt: startedAt)
    }
  }

  private static func decodedSize(of sample: CMSampleBuffer) throws -> (Int, Int) {
    guard let format = CMSampleBufferGetFormatDescription(sample) else { throw RecordingError.unreadable }
    var session: VTDecompressionSession?
    guard unsafe VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr, let session else {
      throw RecordingError.unreadable
    }
    defer { VTDecompressionSessionInvalidate(session) }
    let size = OSAllocatedUnfairLock<(Int, Int)?>(initialState: nil)
    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
      guard status == noErr, let imageBuffer else { return }
      let decoded = (CVPixelBufferGetWidth(imageBuffer), CVPixelBufferGetHeight(imageBuffer))
      size.withLock { $0 = decoded }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    guard status == noErr, let decoded = size.withLock({ $0 }) else { throw RecordingError.unreadable }
    return decoded
  }

  private static func readMovie(url: URL, encoding: String, startedAt: Double?) async throws -> Self {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecordingError.unreadable }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    guard reader.startReading(), let sample = output.copyNextSampleBuffer(), let image = CMSampleBufferGetImageBuffer(sample) else { throw RecordingError.unreadable }
    reader.cancelReading()
    let duration = try await asset.load(.duration).seconds
    guard duration.isFinite, duration > 0 else { throw RecordingError.unreadable }
    return Self(encoding: encoding, width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image), duration: duration, startedAt: startedAt)
  }
}
