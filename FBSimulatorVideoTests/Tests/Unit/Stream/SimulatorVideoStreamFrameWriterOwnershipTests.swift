/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorControl
@testable import FBSimulatorVideo
import FBVideoCore
import XCTest

/// Who owns the transport frame writer across the frame pushers a stream creates — one per mounted
/// surface — since the writer carries per-stream state (MPEG-TS continuity counters, the fMP4 init
/// segment and sequence numbers) that must not restart when the surface is swapped.
final class SimulatorVideoStreamFrameWriterOwnershipTests: XCTestCase {

  private let configuration = VideoStreamConfiguration(
    format: .compressedVideo(withCodec: .h264, transport: .mpegts),
    framesPerSecond: nil,
    rateControl: nil,
    scaleFactor: nil,
    keyFrameRate: nil)

  private func makePusher(frameWriters: VideoStreamFrameWriters?) throws -> VideoToolboxFramePusher {
    let pusher = try SimulatorVideoStream.framePusher(
      configuration: configuration,
      cadence: .lazy,
      consumer: AccumulatingBuffer(),
      encodedSampleConsumerOverride: nil,
      frameWriters: frameWriters,
      logger: CapturingLogger())
    return try XCTUnwrap(pusher as? VideoToolboxFramePusher)
  }

  func testFramePushersShareTheStreamsTransportWriter() throws {
    // The MPEG-TS writer is a class, so `===` compares the writer itself, not a boxed copy.
    let shared = VideoStreamTransport.mpegts.frameWriters(for: .h264)
    let first = try XCTUnwrap((makePusher(frameWriters: shared).encodedSampleConsumer as? DataConsumerEncodedSampleConsumer)?.frameWriter as? MPEGTSFrameWriter)
    let second = try XCTUnwrap((makePusher(frameWriters: shared).encodedSampleConsumer as? DataConsumerEncodedSampleConsumer)?.frameWriter as? MPEGTSFrameWriter)
    XCTAssertTrue(first === second)
    XCTAssertTrue(first === shared.frameWriter as AnyObject?)
  }

  func testStreamKeepsItsTransportWriterAcrossSurfaceSwaps() async throws {
    try VideoEncodingHostSupport.skipUnlessHardwareH264Encoding()
    let surface = FakeFramebufferSurface()
    surface.immediateSurface = makeTestIOSurface(width: 128, height: 128)
    let framebuffer = Framebuffer(surface: surface, logger: CapturingLogger())
    let stream = SimulatorVideoStream(framebuffer: framebuffer, configuration: configuration, logger: CapturingLogger())
    try await stream.startStreaming(AccumulatingBuffer())
    try await Self.assertKeepsTransportWriter(of: stream, acrossSwapOf: surface)
    try await stream.stopStreaming()
  }

  /// Runs on the stream's executor, because the writers and pixel buffers it compares do not leave
  /// it; the stream mounts the swapped surface while this is suspended.
  private static func assertKeepsTransportWriter(
    of stream: isolated SimulatorVideoStream,
    acrossSwapOf surface: FakeFramebufferSurface
  ) async throws {
    let first = try XCTUnwrap(stream.frameWriters?.timedMetadataWriter as AnyObject?)

    surface.ioSurfaceChanged?(makeTestIOSurface(width: 256, height: 256))
    for _ in 0..<500 {
      try await Task.sleep(nanoseconds: 10_000_000)
      if stream.pixelBuffer.map(CVPixelBufferGetWidth) == 256 { break }
    }
    XCTAssertEqual(stream.pixelBuffer.map(CVPixelBufferGetWidth), 256, "precondition: the swapped surface must have mounted")

    let second = try XCTUnwrap(stream.frameWriters?.timedMetadataWriter as AnyObject?)
    XCTAssertTrue(first === second)
  }
}
