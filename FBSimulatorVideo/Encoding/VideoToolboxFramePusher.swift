/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import CoreVideo
import FBControlCore
import FBSimulatorControl
import FBVideoCore
import Foundation
import VideoToolbox

/// Errors from the VideoToolbox sessions a `VideoToolboxFramePusher` (and `PixelBufferConverter`) drives.
enum VideoToolboxFramePusherError: Error {
  case failedToCreatePixelTransferSession(status: OSStatus)
  case failedToStartCompressionSession(status: OSStatus)
  case compressionSessionNil
  case failedToSetCompressionSessionProperties(status: OSStatus)
  case failedToPrepareCompressionSession(status: OSStatus)
  case missingCompressionSession
  case failedToCompress(status: OSStatus)
}

extension VideoToolboxFramePusherError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .failedToCreatePixelTransferSession(let status):
      return "Failed to create VTPixelTransferSession: \(status)"
    case .failedToStartCompressionSession(let status):
      return "Failed to start Compression Session \(status)"
    case .compressionSessionNil:
      return "Failed to start Compression Session (nil)"
    case .failedToSetCompressionSessionProperties(let status):
      return "Failed to set compression session properties \(status)"
    case .failedToPrepareCompressionSession(let status):
      return "Failed to prepare compression session \(status)"
    case .missingCompressionSession:
      return "No compression session"
    case .failedToCompress(let status):
      return "Failed to compress \(status)"
    }
  }
}

/// Encodes frames via a VTCompressionSession (BGRA→NV12 via `PixelBufferConverter`) and hands each
/// encoded sample to an `EncodedSampleConsumer` — a transport writer, a JPEG framer or a file
/// writer. Outcomes are accounted for by `EncoderStatsRecorder`.
///
/// @unchecked Sendable: `VTCompressionSessionEncodeFrame`'s `@Sendable` output handler can run on a
/// VideoToolbox thread after the encode call returns, so it captures `self`. VideoToolbox invokes a
/// session's output handlers serially, in decode order, so the handler's two collaborators are never
/// entered concurrently: the encoded-sample consumer, whose state (a transport writer's continuity
/// counters, the Minicap header flag, the file writer) is touched only from the handler, and the
/// stats recorder, which additionally locks the counters the owning actor reads. The pusher's own
/// stored properties are immutable after `setup`. `tearDown` flushes every pending handler before
/// it invalidates the session.
final class VideoToolboxFramePusher: FramePusher, @unchecked Sendable {
  let settings: VideoToolboxEncoderSettings
  /// The scale factor between 0-1. nil for no scaling.
  let scaleFactor: Double?
  let videoCodec: CMVideoCodecType
  let encodedSampleConsumer: EncodedSampleConsumer
  let logger: any ControlCoreLogger

  var compressionSession: VTCompressionSession?
  /// BGRA→NV12 at the encoded output size; nil until `setup`.
  private var converter: PixelBufferConverter?
  let statsRecorder: EncoderStatsRecorder

  init(
    settings: VideoToolboxEncoderSettings,
    scaleFactor: Double?,
    videoCodec: CMVideoCodecType,
    encodedSampleConsumer: EncodedSampleConsumer,
    logger: any ControlCoreLogger
  ) {
    self.settings = settings
    self.scaleFactor = scaleFactor
    self.encodedSampleConsumer = encodedSampleConsumer
    self.logger = logger
    self.videoCodec = videoCodec
    self.statsRecorder = EncoderStatsRecorder(logger: logger)
  }

  /// The output handler: hands the sample to the encoded-sample consumer and records the outcome.
  func handleCompressedSampleBuffer(_ sampleBuffer: CMSampleBuffer?, encodeStatus: OSStatus, infoFlags: VTEncodeInfoFlags) {
    statsRecorder.record(outcome(of: sampleBuffer, encodeStatus: encodeStatus, infoFlags: infoFlags))
  }

  private func outcome(of sampleBuffer: CMSampleBuffer?, encodeStatus: OSStatus, infoFlags: VTEncodeInfoFlags) -> EncoderStatsRecorder.Outcome {
    if encodeStatus != noErr {
      return .encodeError(encodeStatus)
    }
    if infoFlags.contains(.frameDropped) {
      return .dropped
    }
    guard let sampleBuffer, encodedSampleConsumer.consume(sampleBuffer, logger: logger) else {
      return .writeFailed
    }
    let encodedBytes = CMSampleBufferGetDataBuffer(sampleBuffer).map(CMBlockBufferGetDataLength) ?? 0
    return .written(encodedBytes: encodedBytes)
  }

  func setup(source: VideoFrameSource, edgeInsets: VideoStreamEdgeInsets) throws {
    let encoderSpecification = settings.encoderSpecification

    let sourceWidth = source.width
    let sourceHeight = source.height
    // The composited frame includes the edge insets, so the NV12 pool and compression session must
    // accommodate the full output size — the same `VideoOutputDimensions` the composited pool uses.
    let dimensions = VideoOutputDimensions.calculate(
      sourceWidth: sourceWidth, sourceHeight: sourceHeight,
      scaleFactor: scaleFactor, edgeInsets: edgeInsets)
    let destinationWidth = dimensions.width
    let destinationHeight = dimensions.height
    if let scaleFactor, scaleFactor > 0, scaleFactor < 1 {
      logger.info().log("Applying \(scaleFactor) scale from w=\(sourceWidth)/h=\(sourceHeight) to output w=\(destinationWidth)/h=\(destinationHeight)")
    }

    let converter = try PixelBufferConverter(
      outputWidth: destinationWidth, outputHeight: destinationHeight, pixelFormat: PixelBufferConverter.encoderPixelFormat,
      destinationColor: settings.colorDescription)
    self.converter = converter
    logger.info().log("Created BGRA→NV12 conversion pipeline at w=\(destinationWidth)/h=\(destinationHeight) (GPU via VTPixelTransferSession)")

    // No create-time output callback: each frame is encoded with the block-based
    // `VTCompressionSessionEncodeFrame(...outputHandler:)` overload (see `writeEncodedFrame`),
    // so the session needs neither an `outputCallback` nor a `refcon`.
    var compressionSession: VTCompressionSession?
    func createCompressionSession(_ specification: [String: Any]) -> OSStatus {
      VTCompressionSessionCreate(
        allocator: nil,
        width: Int32(destinationWidth),
        height: Int32(destinationHeight),
        codecType: videoCodec,
        encoderSpecification: specification as CFDictionary,
        imageBufferAttributes: converter.outputBufferAttributes as CFDictionary,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &compressionSession
      )
    }
    var status = createCompressionSession(encoderSpecification)
    if status != noErr, let fallback = settings.fallbackEncoderSpecification {
      logger.info().log("Hardware compression session refused (\(status)); retrying with a software encoder allowed")
      status = createCompressionSession(fallback)
    }
    if status != noErr {
      throw VideoToolboxFramePusherError.failedToStartCompressionSession(status: status)
    }
    guard let compressionSession else {
      throw VideoToolboxFramePusherError.compressionSessionNil
    }

    let sessionProperties = settings.sessionProperties(outputWidth: destinationWidth, outputHeight: destinationHeight)
    if case .compressedVideo = settings.format {
      logger.info().log(
        "Rate control \(settings.rateControl) resolved to \(sessionProperties[kVTCompressionPropertyKey_AverageBitRate as String] ?? 0) bps average for w=\(destinationWidth)/h=\(destinationHeight)")
    }

    let propertiesStatus = VTSessionSetProperties(compressionSession, propertyDictionary: sessionProperties as CFDictionary)
    if propertiesStatus != noErr {
      throw VideoToolboxFramePusherError.failedToSetCompressionSessionProperties(status: propertiesStatus)
    }
    let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(compressionSession)
    if prepareStatus != noErr {
      throw VideoToolboxFramePusherError.failedToPrepareCompressionSession(status: prepareStatus)
    }
    self.compressionSession = compressionSession
  }

  func tearDown() throws {
    if let compressionSession {
      VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
      VTCompressionSessionInvalidate(compressionSession)
      self.compressionSession = nil
    }
    converter?.invalidate()
    converter = nil
  }

  func writeEncodedFrame(
    _ pixelBuffer: CVPixelBuffer,
    frameNumber: UInt,
    timeAtFirstFrame: TimeInterval,
    frameDuration: TimeInterval,
    forceKeyFrame: Bool
  ) throws {
    guard let compressionSession else {
      throw VideoToolboxFramePusherError.missingCompressionSession
    }

    var bufferToWrite = pixelBuffer

    let encodeStart = ContinuousClock.now
    statsRecorder.recordSubmissionStarting(at: encodeStart)

    // BGRA→NV12 (and scale, since the pool is destination-sized) in one pass; on failure the encoder
    // takes the BGRA frame and converts internally.
    if let converter {
      switch converter.convert(pixelBuffer) {
      case let .converted(nv12Buffer):
        bufferToWrite = nv12Buffer
      case let .transferFailed(status):
        logger.log("VTPixelTransferSession BGRA→NV12 failed: \(status) — falling back to BGRA input")
      case let .poolExhausted(status):
        logger.log("Failed to get a pixel buffer from the NV12 pool: \(status)")
      }
    }

    let time = CMTimeMakeWithSeconds(ProcessInfo.processInfo.systemUptime - timeAtFirstFrame, preferredTimescale: Int32(NSEC_PER_SEC))
    let duration = frameDuration > 0 ? CMTimeMakeWithSeconds(frameDuration, preferredTimescale: Int32(NSEC_PER_SEC)) : CMTime.invalid
    var frameProperties: [String: Any]?
    if frameNumber == 0 || forceKeyFrame {
      frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
    }

    // `[weak self]`: the session does not retain the pusher, so a strong capture would be a cycle
    // (pusher → session → handler → pusher). The handler may run on a VideoToolbox thread after this
    // call returns (see the class doc).
    let handler: VTCompressionOutputHandler = { [weak self] encodeStatus, infoFlags, sampleBuffer in
      self?.handleCompressedSampleBuffer(sampleBuffer, encodeStatus: encodeStatus, infoFlags: infoFlags)
    }

    let status = VTCompressionSessionEncodeFrame(
      compressionSession,
      imageBuffer: bufferToWrite,
      presentationTimeStamp: time,
      duration: duration,
      frameProperties: frameProperties as CFDictionary?,
      infoFlagsOut: nil,
      outputHandler: handler
    )

    statsRecorder.recordEncodeSubmission(ContinuousClock.now - encodeStart)

    if status != 0 {
      throw VideoToolboxFramePusherError.failedToCompress(status: status)
    }
  }

  /// A keyframe, so the session's next frame need not reference it; that frame is forced to a keyframe anyway.
  /// Waits for the output, which is dropped rather than handed to the consumer or counted in the stats.
  func warm(with pixelBuffer: CVPixelBuffer) throws {
    guard let compressionSession else {
      throw VideoToolboxFramePusherError.missingCompressionSession
    }
    var source = pixelBuffer
    if let converter, case let .converted(nv12Buffer) = converter.convert(pixelBuffer) {
      source = nv12Buffer
    }
    let status = VTCompressionSessionEncodeFrame(
      compressionSession,
      imageBuffer: source,
      presentationTimeStamp: .zero,
      duration: .invalid,
      frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary,
      infoFlagsOut: nil,
      outputHandler: { _, _, _ in }
    )
    if status != noErr {
      throw VideoToolboxFramePusherError.failedToCompress(status: status)
    }
    VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
  }

  func completeFrames() {
    if let compressionSession {
      VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
    }
  }

  func recordTornFrame() {
    statsRecorder.recordTornFrame()
  }

  func currentStats() -> VideoEncoderStats? {
    statsRecorder.snapshot
  }
}
