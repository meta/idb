/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreVideo
import FBControlCore
@testable import FBSimulatorControl
@testable import FBSimulatorVideo
import FBVideoCore
import IOSurface
import ImageIO
import XCTest

/// How a recording session's overlays and bars are laid out when the stream's canvas changes.
@MainActor
final class VideoSessionOverlayLayoutTests: XCTestCase {

  private struct Session {
    let stream: SimulatorVideoStream
    let surface: FakeFramebufferSurface
    let renderer: OverlayRenderer
    let handler: StdinCommandHandler
  }

  private func startSession(recording: Bool = false) async throws -> Session {
    let surface = FakeFramebufferSurface()
    surface.immediateSurface = makeTestIOSurface(width: 20, height: 30)
    if recording {
      let upright = display(width: 20, height: 30, rotation: .upright)
      surface.configurationAtRegistration = SimulatorDisplayConfiguration(
        generation: 1, displays: [upright], active: .identified(upright), phase: .settled)
    }
    let stream = SimulatorVideoStream(
      framebuffer: Framebuffer(surface: surface, logger: CapturingLogger()),
      configuration: VideoStreamConfiguration(format: .bgra, framesPerSecond: nil, rateControl: nil, scaleFactor: nil, keyFrameRate: nil),
      edgeInsets: VideoStreamEdgeInsets(top: 4, bottom: 4, left: 0, right: 0),
      cadence: .lazy,
      logger: CapturingLogger(),
      encodedSampleConsumerOverride: recording ? DiscardingEncodedSampleConsumer() : nil)
    try await stream.startStreaming(AccumulatingBuffer())
    let renderer = OverlayRenderer(
      transform: OverlayCoordinateTransform(
        screenPixelWidth: 20, screenPixelHeight: 30, retinaScale: 1, videoScale: 1, borderTop: 4, scaledBorderTop: 4, borderBottom: 4,
        scaledBorderBottom: 4))
    let (handler, _) = VideoSession.makeHandler(
      videoStream: stream, renderer: renderer, screenshotDir: nil, parsedBars: [(position: "top", height: 4, mode: .pad)], barStats: [],
      logger: CapturingLogger())
    renderer.setBarContent(.text("bar"), position: "top")
    await stream.updateOverlayBuffer(renderer.buffer)
    return Session(stream: stream, surface: surface, renderer: renderer, handler: handler)
  }

  private func display(width: Int, height: Int, rotation: SimulatorDisplayRotation) -> SimulatorDisplay {
    SimulatorDisplay(
      uniqueID: "panel", name: "panel", activity: .active, isPrimary: true, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: width, height: height), scale: 1, rotation: rotation)
  }

  private func waitUntil(_ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date(timeIntervalSinceNow: 5)
    while await !condition() {
      guard deadline.timeIntervalSinceNow > 0 else { return XCTFail("condition never held", file: file, line: line) }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  /// The screenshot's size, and whether its pixel at `point` (from the top left) is opaque red.
  private func screenshot(_ data: Data, isRedAt point: CGPoint) throws -> (size: CGSize, isRed: Bool) {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: -point.x, y: point.y - CGFloat(image.height) + 1, width: CGFloat(image.width), height: CGFloat(image.height)))
    return (CGSize(width: image.width, height: image.height), pixel[0] > 200 && pixel[1] < 50 && pixel[2] < 50)
  }

  private func size(_ buffer: CVPixelBuffer?) -> CGSize? {
    buffer.map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
  }

  /// The size of the overlay `stream` composites. Read on the stream's executor, because the
  /// compositor does not leave it.
  private static func overlaySize(of stream: isolated SimulatorVideoStream) -> CGSize? {
    stream.compositor.overlayBuffer.map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
  }

  func testTheOverlayAfterASwitchToALargerSurface() async throws {
    let session = try await startSession()
    session.surface.ioSurfaceChanged?(makeTestIOSurface(width: 40, height: 60))
    try await waitUntil { await session.stream.mountedSource?.width == 40 }

    let composited = await Self.overlaySize(of: session.stream)
    XCTAssertEqual(size(session.renderer.buffer), CGSize(width: 40, height: 68))
    XCTAssertEqual(composited, CGSize(width: 40, height: 68))
    try await session.stream.stopStreaming()
  }

  func testTheOverlayAfterARotation() async throws {
    let session = try await startSession()
    let turned = display(width: 20, height: 30, rotation: .clockwise)
    session.surface.configurationChanged?(SimulatorDisplayConfiguration(generation: 1, displays: [turned], active: .identified(turned), phase: .settled))
    try await waitUntil { await session.stream.mountedSource?.width == 30 }

    let composited = await Self.overlaySize(of: session.stream)
    XCTAssertEqual(size(session.renderer.buffer), CGSize(width: 30, height: 28))
    XCTAssertEqual(composited, CGSize(width: 30, height: 28))
    try await session.stream.stopStreaming()
  }

  func testARecordingsOverlayAfterARotation() async throws {
    let session = try await startSession(recording: true)
    let turned = display(width: 20, height: 30, rotation: .clockwise)
    session.surface.configurationChanged?(SimulatorDisplayConfiguration(generation: 2, displays: [turned], active: .identified(turned), phase: .settled))
    try await waitUntil { await session.stream.mountedSource?.width == 30 }

    let composited = await Self.overlaySize(of: session.stream)
    let screenOrigin = session.renderer.transform.bufferPoint(x: 0, y: 4)
    XCTAssertEqual(size(session.renderer.buffer), CGSize(width: 20, height: 38))
    XCTAssertEqual(composited, CGSize(width: 20, height: 38))
    XCTAssertEqual(screenOrigin.x, 0, accuracy: 0.001)
    XCTAssertEqual(screenOrigin.y, 4 + (30 - 20 * 2.0 / 3) / 2, accuracy: 0.001)
    try await session.stream.stopStreaming()
  }

  func testARecordingsScreenshotAfterARotation() async throws {
    let session = try await startSession(recording: true)
    let turned = display(width: 20, height: 30, rotation: .clockwise)
    session.surface.configurationChanged?(SimulatorDisplayConfiguration(generation: 2, displays: [turned], active: .identified(turned), phase: .settled))
    try await waitUntil { await session.stream.mountedSource?.width == 30 }
    // The session's bar is taller than its border, so it would cover the shape.
    session.renderer.setBarContent(.hidden, position: "top")
    session.renderer.render(overlays: [.rectangle(OverlayShape.Rectangle(x: 0, y: 4, width: 6, height: 6, rgba: [255, 0, 0, 1], effect: nil))])
    await session.stream.updateOverlayBuffer(session.renderer.buffer)

    let shot = try screenshot(try await session.stream.captureCompositedScreenshot(), isRedAt: CGPoint(x: 2, y: 6))
    XCTAssertEqual(shot.size, CGSize(width: 30, height: 28))
    XCTAssertTrue(shot.isRed)
    try await session.stream.stopStreaming()
  }
}
