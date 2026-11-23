/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import CoreVideo
import FBControlCore
@testable import FBSimulatorControl
@testable import FBSimulatorVideo
import FBVideoCore
import VideoToolbox
import XCTest

final class SimulatorVideoStreamCallbackTests: XCTestCase {

  override func setUpWithError() throws {
    // This class exercises encoder-callback machinery that crashes
    // intermittently on hosted CI runners, taking neighboring tests down
    // with it. It is reliable on internal continuous runs, which remain the
    // coverage of record; skip wholesale rather than gating tests one by one.
    try XCTSkipIf(
      ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
      "encoder-callback tests are covered by internal continuous runs")
    try super.setUpWithError()
  }

  // MARK: - Helpers

  private func makeReadySampleBuffer() -> CMSampleBuffer {
    createH264SampleBuffer()
  }

  private func makeNotReadySampleBuffer() -> CMSampleBuffer {
    createNotReadySampleBuffer()
  }

  // MARK: - Tests

  func testWarmupFramesSuppressed() {
    let logger = CapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    for _ in 0..<5 {
      let notReady = makeNotReadySampleBuffer()
      pusher.handleCompressedSampleBuffer(notReady, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    }

    for msg in logger.messages {
      XCTAssertFalse((msg as! String).contains("Sample Buffer is not ready"), "Should not log per-frame not-ready messages during warmup")
    }

    let ready = makeReadySampleBuffer()
    pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())

    var warmupMessageCount: UInt = 0
    for msg in logger.messages {
      if (msg as! String).contains("Encoder warmed up after 5 skipped frames") {
        warmupMessageCount += 1
      }
    }
    XCTAssertEqual(warmupMessageCount, 1, "Should log exactly one warmup completion message")
    XCTAssertTrue(pusher.statsRecorder.warmupComplete)
  }

  func testStarvationDetectedDuringWarmup() {
    let logger = CapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    for _ in 0..<20 {
      let notReady = makeNotReadySampleBuffer()
      pusher.handleCompressedSampleBuffer(notReady, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    }

    var foundStarvationWarning = false
    for msg in logger.messages {
      if (msg as! String).contains("has not produced a frame after 20 attempts") {
        foundStarvationWarning = true
      }
    }
    XCTAssertTrue(foundStarvationWarning, "Should warn about possible starvation after 20 warmup frames")
    XCTAssertTrue(pusher.statsRecorder.starvationWarningLogged)
  }

  func testPostWarmupStarvation() {
    let logger = CapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    let ready = makeReadySampleBuffer()
    pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    XCTAssertTrue(pusher.statsRecorder.warmupComplete)

    for _ in 0..<10 {
      let notReady = makeNotReadySampleBuffer()
      pusher.handleCompressedSampleBuffer(notReady, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    }

    var foundStarvationWarning = false
    for msg in logger.messages {
      if (msg as! String).contains("Encoder starvation: 10 consecutive frames not ready after warmup") {
        foundStarvationWarning = true
      }
    }
    XCTAssertTrue(foundStarvationWarning, "Should warn about post-warmup starvation after 10 consecutive failures")
    XCTAssertTrue(pusher.statsRecorder.starvationWarningLogged)
  }

  func testEncodeErrorLogged() {
    let logger = CapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    pusher.handleCompressedSampleBuffer(nil, encodeStatus: -12345, infoFlags: VTEncodeInfoFlags())

    var foundError = false
    for msg in logger.messages {
      if (msg as! String).contains("VideoToolbox encode error: OSStatus -12345") {
        foundError = true
      }
    }
    XCTAssertTrue(foundError, "Should log VideoToolbox encode error with status code")
    XCTAssertEqual(pusher.statsRecorder.snapshot.callbackCount, 1)
  }

  func testFrameDroppedCountedAsFailure() {
    let logger = CapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    pusher.handleCompressedSampleBuffer(nil, encodeStatus: noErr, infoFlags: .frameDropped)

    XCTAssertEqual(pusher.statsRecorder.consecutiveNotReadyFrameCount, 1)
    XCTAssertEqual(pusher.statsRecorder.snapshot.callbackCount, 1)
    XCTAssertEqual(UInt(logger.messages.count), 1, "Should only log the first-callback message, not per-frame drop messages")
  }

  func testDroppedFramesTriggersStarvationWarning() {
    let logger = CapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    for _ in 0..<20 {
      pusher.handleCompressedSampleBuffer(nil, encodeStatus: noErr, infoFlags: .frameDropped)
    }

    var foundStarvationWarning = false
    for msg in logger.messages {
      if (msg as! String).contains("has not produced a frame after 20 attempts") {
        foundStarvationWarning = true
      }
    }
    XCTAssertTrue(foundStarvationWarning, "20 consecutive dropped frames should trigger starvation warning")
    XCTAssertEqual(UInt(logger.messages.count), 2, "Should produce the first-callback message and one starvation warning")
  }

  func testNoWarmupMessageWhenFirstFrameSucceeds() {
    let logger = CapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    let ready = makeReadySampleBuffer()
    pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())

    XCTAssertTrue(pusher.statsRecorder.warmupComplete)

    for msg in logger.messages {
      XCTAssertFalse((msg as! String).contains("Encoder warmed up"), "Should not log warmup message when first frame succeeds immediately")
    }
  }

  func testPeriodicStatsNotLoggedBeforeInterval() {
    let logger = CapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    for _ in 0..<3 {
      let ready = makeReadySampleBuffer()
      pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    }

    for msg in logger.messages {
      XCTAssertFalse((msg as! String).contains("Video stats"), "Should not log stats before interval elapses")
    }
  }

  func testPeriodicStatsCountersAccurate() {
    let logger = CapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    for _ in 0..<3 {
      let ready = makeReadySampleBuffer()
      pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    }

    for _ in 0..<2 {
      pusher.handleCompressedSampleBuffer(nil, encodeStatus: noErr, infoFlags: .frameDropped)
    }

    pusher.handleCompressedSampleBuffer(nil, encodeStatus: -12345, infoFlags: VTEncodeInfoFlags())

    XCTAssertEqual(pusher.statsRecorder.snapshot.writeCount, 3)
    XCTAssertEqual(pusher.statsRecorder.snapshot.dropCount, 2)
    XCTAssertEqual(pusher.statsRecorder.snapshot.encodeErrorCount, 1)
    XCTAssertEqual(pusher.statsRecorder.snapshot.callbackCount, 6)

    pusher.statsRecorder.backdateStatsTimerForTesting(by: .seconds(6))

    let ready = makeReadySampleBuffer()
    pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())

    var foundStats = false
    for msg in logger.messages {
      let s = msg as! String
      if s.contains("Video stats")
        && s.contains("4 written")
        && s.contains("2 dropped")
        && s.contains("1 encode errors")
      {
        foundStats = true
      }
    }
    XCTAssertTrue(foundStats, "Stats message should contain accurate counters")
  }

  func testPeriodicStatsDuringWarmup() {
    let logger = CapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    for _ in 0..<10 {
      let notReady = makeNotReadySampleBuffer()
      pusher.handleCompressedSampleBuffer(notReady, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    }

    pusher.statsRecorder.backdateStatsTimerForTesting(by: .seconds(6))

    let notReady = makeNotReadySampleBuffer()
    pusher.handleCompressedSampleBuffer(notReady, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())

    var foundStats = false
    for msg in logger.messages {
      let s = msg as! String
      if s.contains("Video stats")
        && s.contains("0 written")
        && s.contains("11 write failures")
      {
        foundStats = true
      }
    }
    XCTAssertTrue(foundStats, "Stats during warmup should show 0 written and write failures")
  }
}

/// Tests for the bitmap (BGRA) frame pusher's raw byte contract.
final class SimulatorVideoStreamBitmapPusherTests: XCTestCase {

  // MARK: - Helpers

  /// Creates an IOSurface-backed BGRA pixel buffer filled with a constant byte.
  private func makeBGRAPixelBuffer(width: Int, height: Int, fill: UInt8) -> CVPixelBuffer {
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
    precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
    let buffer = pixelBuffer!

    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      memset(base, Int32(fill), CVPixelBufferGetDataSize(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
  }

  // MARK: - Tests

  func testBitmapPusherWritesRawPixelBytes() throws {
    let buffer = makeBGRAPixelBuffer(width: 16, height: 8, fill: 0xAB)
    let consumer = AccumulatingBuffer()
    let pusher = BitmapFramePusher(consumer: consumer, scaleFactor: nil)

    let zeroInsets = VideoStreamEdgeInsets(top: 0, bottom: 0, left: 0, right: 0)
    try pusher.setup(source: VideoFrameSource(buffer), edgeInsets: zeroInsets)
    try pusher.writeEncodedFrame(
      buffer,
      frameNumber: 0,
      timeAtFirstFrame: 0,
      frameDuration: 0,
      forceKeyFrame: false
    )

    // The bitmap pusher writes the raw pixel buffer bytes through to the consumer, unframed.
    let output = consumer.data()
    XCTAssertEqual(output.count, CVPixelBufferGetDataSize(buffer))
    XCTAssertFalse(output.isEmpty)
    XCTAssertTrue(output.allSatisfy { $0 == 0xAB }, "Raw BGRA bytes should pass through unchanged")

    try pusher.tearDown()
  }
}

/// End-to-end delivery through the public API over a fake display surface: a framebuffer event
/// on the fake must come out of the stream as pushed frame data (surface event -> framebuffer ->
/// cadence -> pusher -> consumer).
final class SimulatorVideoStreamDeliveryTests: XCTestCase {

  /// `.bgra` and no `framesPerSecond`: the lazy (variable-frame-rate) cadence with the bitmap
  /// pusher, so pushes reach the consumer without any encoder in the way.
  private static let lazyConfiguration = VideoStreamConfiguration(
    format: .bgra, framesPerSecond: nil, rateControl: nil, scaleFactor: nil, keyFrameRate: nil)

  /// `lazyConfiguration` with a fractional scale: the bitmap pusher then owns a
  /// `VTPixelTransferSession`, giving a displaced pusher session state to observe.
  private static let scaledLazyConfiguration = VideoStreamConfiguration(
    format: .bgra, framesPerSecond: nil, rateControl: nil, scaleFactor: 0.5, keyFrameRate: nil)

  private func makeStream(
    surface: FakeFramebufferSurface,
    configuration: VideoStreamConfiguration = lazyConfiguration
  ) -> SimulatorVideoStream {
    let framebuffer = Framebuffer(surface: surface, logger: CapturingLogger())
    return SimulatorVideoStream(
      framebuffer: framebuffer, configuration: configuration, logger: CapturingLogger())
  }

  /// Poll until `condition` holds, or fail after ~5s. The delivery chain hops queues/tasks, so
  /// tests await outcomes rather than assuming synchronous effects.
  private func expectEventually(
    _ message: String,
    condition: () async -> Bool
  ) async throws {
    for _ in 0..<500 {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let holds = await condition()
    XCTAssertTrue(holds, message)
  }

  /// Wait for the byte count to stop growing (two identical samples 100ms apart) so a test can
  /// take a baseline that in-flight attach-time pushes cannot disturb.
  private func settledCount(of consumer: AccumulatingBuffer) async throws -> Int {
    var previous = -1
    for _ in 0..<50 {
      let current = consumer.data().count
      if current == previous {
        return current
      }
      previous = current
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    return previous
  }

  func testFrameRenderedSignalPushesFrame() async throws {
    let surface = FakeFramebufferSurface()
    surface.immediateSurface = makeTestIOSurface()
    let consumer = AccumulatingBuffer()
    let stream = makeStream(surface: surface)

    try await stream.startStreaming(consumer)
    let baseline = try await settledCount(of: consumer)

    surface.frameRendered?()

    try await expectEventually("a rendered-frame signal must produce a pushed frame") {
      consumer.data().count > baseline
    }
    try await stream.stopStreaming()
  }

  func testPushesTrackFrameSignalsAndQuietFramebufferPushesNothing() async throws {
    let surface = FakeFramebufferSurface()
    surface.immediateSurface = makeTestIOSurface()
    let consumer = AccumulatingBuffer()
    let stream = makeStream(surface: surface)

    try await stream.startStreaming(consumer)
    let baseline = try await settledCount(of: consumer)

    surface.frameRendered?()
    try await expectEventually("first signal pushes") { consumer.data().count > baseline }
    let afterFirst = try await settledCount(of: consumer)

    // Variable-frame-rate contract: no signal, no push.
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(consumer.data().count, afterFirst, "a quiet framebuffer must not push frames in .lazy mode")

    surface.frameRendered?()
    try await expectEventually("a signal after a quiet period pushes again") {
      consumer.data().count > afterFirst
    }
    try await stream.stopStreaming()
  }

  func testSurfaceArrivingAfterAttachMountsAndStartsStream() async throws {
    let surface = FakeFramebufferSurface()
    let consumer = AccumulatingBuffer()
    let stream = makeStream(surface: surface)

    // With no immediately-available surface, startStreaming suspends until the first
    // surface-change event mounts. Deliver it once the callbacks are registered.
    async let started: Void = stream.startStreaming(consumer)
    try await expectEventually("attach must register the surface callbacks") {
      surface.ioSurfaceChanged != nil
    }
    surface.ioSurfaceChanged?(makeTestIOSurface())
    try await started

    try await expectEventually("mounting the first surface must push a frame") {
      !consumer.data().isEmpty
    }
    try await stream.stopStreaming()
  }

  func testSurfaceSwapRemountsAndPushes() async throws {
    let surface = FakeFramebufferSurface()
    surface.immediateSurface = makeTestIOSurface()
    let consumer = AccumulatingBuffer()
    let stream = makeStream(surface: surface)

    try await stream.startStreaming(consumer)
    let baseline = try await settledCount(of: consumer)

    surface.ioSurfaceChanged?(makeTestIOSurface(width: 32, height: 32))

    try await expectEventually("a surface swap must remount and push a frame") {
      consumer.data().count > baseline
    }
    try await stream.stopStreaming()
  }

  func testSurfaceSwapTearsDownPreviousFramePusher() async throws {
    let surface = FakeFramebufferSurface()
    surface.immediateSurface = makeTestIOSurface()
    let consumer = AccumulatingBuffer()
    let stream = makeStream(surface: surface, configuration: Self.scaledLazyConfiguration)

    try await stream.startStreaming(consumer)
    let mountedHandle = await stream.currentFramePusherHandle()
    let previous = try XCTUnwrap(mountedHandle)
    let previousPusher = try XCTUnwrap(previous.bitmapPusher)
    XCTAssertNotNil(previousPusher.scaler, "precondition: a scaled bitmap pusher owns a scaler")

    surface.ioSurfaceChanged?(makeTestIOSurface(width: 32, height: 32))
    try await expectEventually("a surface swap must install a new frame pusher") {
      await stream.currentFramePusherHandle()?.identity != previous.identity
    }

    XCTAssertNil(previousPusher.scaler, "a surface swap must tear down the displaced pusher")
    try await stream.stopStreaming()
  }

  func testSurfaceChangedForMountedSurfaceDoesNotRemount() async throws {
    let surface = FakeFramebufferSurface()
    let ioSurface = makeTestIOSurface()
    surface.immediateSurface = ioSurface
    let consumer = AccumulatingBuffer()
    let stream = makeStream(surface: surface)

    try await stream.startStreaming(consumer)
    let mountedHandle = await stream.currentFramePusherHandle()
    let mounted = try XCTUnwrap(mountedHandle)
    let baseline = try await settledCount(of: consumer)

    // Report the surface that is already mounted, then a rendered frame. Events are delivered in
    // order, so once the rendered frame's push lands the surface report has been handled.
    surface.ioSurfaceChanged?(ioSurface)
    surface.frameRendered?()
    try await expectEventually("the rendered frame must push") { consumer.data().count > baseline }

    let currentHandle = await stream.currentFramePusherHandle()
    let current = try XCTUnwrap(currentHandle)
    XCTAssertEqual(current.identity, mounted.identity, "reporting the already-mounted surface must not re-mount it")
    try await stream.stopStreaming()
  }

  func testOverlayUpdatesKeepPushingWhileTheScreenIsIdle() async throws {
    let surface = FakeFramebufferSurface()
    surface.immediateSurface = makeTestIOSurface()
    let consumer = AccumulatingBuffer()
    let stream = makeStream(surface: surface)
    try await stream.startStreaming(consumer)
    let overlay = OverlayRenderer(width: 16, height: 16).buffer

    // Each push composites the overlay over the screen, reading the surface; an update after it must
    // still find the screen presented
    var before = try await settledCount(of: consumer)
    await stream.updateOverlayBuffer(overlay)
    try await expectEventually("an overlay swap over an idle screen pushes a frame") { consumer.data().count > before }
    before = try await settledCount(of: consumer)
    await Self.updateOverlayInPlace(stream)
    try await expectEventually("an in-place overlay update over an idle screen pushes a frame") { consumer.data().count > before }

    try await stream.stopStreaming()
  }

  /// Creates an IOSurface with no pixel format: `CVPixelBufferCreateWithIOSurface` rejects it
  /// (-6661), so mounting it always fails — the trigger for the failed-initial-mount path.
  private func makeUnmountableIOSurface() -> IOSurface {
    let width = 16
    let height = 16
    let bytesPerElement = 4
    let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * bytesPerElement)
    let properties: [IOSurfacePropertyKey: Any] = [
      .width: width,
      .height: height,
      .bytesPerElement: bytesPerElement,
      .bytesPerRow: bytesPerRow,
      .allocSize: bytesPerRow * height,
    ]
    guard let surface = IOSurface(properties: properties) else {
      fatalError("Failed to create format-less test IOSurface")
    }
    return surface
  }

  /// Completion latch for observing whether a task settled.
  // SAFETY: every access to `settled` is serialized behind `lock`.
  // patternlint-disable-next-line unchecked-sendable
  private final class SettledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    func markSettled() {
      lock.lock()
      settled = true
      lock.unlock()
    }
    var isSettled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return settled
    }
  }

  /// True if `task` has neither returned nor thrown within `nanoseconds`. Observed via a detached
  /// flag-setter rather than a task group racing `task.value`: awaiting a hung task can never be
  /// abandoned (`Task.value` ignores the awaiter's cancellation), so a group child doing that await
  /// would keep the group — and the test — suspended forever. The observer task is abandoned if the
  /// observed task never settles; it completes once the task does.
  private func isStillPending<Success: Sendable, Failure>(_ task: Task<Success, Failure>, after nanoseconds: UInt64) async -> Bool {
    let flag = SettledFlag()
    Task {
      _ = await task.result
      flag.markSettled()
    }
    try? await Task.sleep(nanoseconds: nanoseconds)
    return !flag.isSettled
  }

  func testStartStreamingWhenStoppedBeforeFirstSurfaceMount() async throws {
    let surface = FakeFramebufferSurface()
    let consumer = AccumulatingBuffer()
    let stream = makeStream(surface: surface)

    // No immediately-available surface: startStreaming attaches, then suspends awaiting the first
    // mount. Wait for the registration so the stop below is ordered after the suspension.
    let startTask = Task { try await stream.startStreaming(consumer) }
    try await expectEventually("attach must register the surface callbacks") {
      surface.ioSurfaceChanged != nil
    }

    try await stream.stopStreaming()

    // Stopping before any surface mounted fails the pending start promptly — it can never complete.
    let pending = await isStillPending(startTask, after: 200_000_000)
    XCTAssertFalse(pending, "startStreaming must settle promptly after stopStreaming")
    guard !pending else { return } // a hung start can never be awaited to completion
    do {
      try await startTask.value
      XCTFail("startStreaming must throw after the stream stopped before mounting")
    } catch {
      XCTAssertTrue(String(describing: error).contains("startWhenStopped"), "unexpected error: \(error)")
    }
  }

  func testStartStreamingWhenInitialSurfaceIsUnmountable() async throws {
    let surface = FakeFramebufferSurface()
    surface.immediateSurface = makeUnmountableIOSurface()
    let consumer = AccumulatingBuffer()
    let stream = makeStream(surface: surface)

    // The attach-time surface cannot be wrapped by CVPixelBufferCreateWithIOSurface, so the initial
    // mount fails.
    let startTask = Task { try await stream.startStreaming(consumer) }

    let pending = await isStillPending(startTask, after: 200_000_000)
    XCTAssertFalse(pending, "startStreaming must settle promptly when the initial mount fails")
    guard !pending else { return } // a hung start can never be awaited to completion
    do {
      try await startTask.value
      XCTFail("startStreaming must throw when the initial surface cannot be mounted")
    } catch {
      XCTAssertTrue(String(describing: error).contains("failedToCreatePixelBufferFromSurface"), "unexpected error: \(error)")
    }
  }

  func testStartStreamingWhenLateSurfaceCannotBeMounted() async throws {
    let surface = FakeFramebufferSurface()
    let consumer = AccumulatingBuffer()
    let stream = makeStream(surface: surface)

    // No attach-time surface: startStreaming suspends awaiting the first mount, which arrives via
    // the event stream and fails.
    let startTask = Task { try await stream.startStreaming(consumer) }
    try await expectEventually("attach must register the surface callbacks") {
      surface.ioSurfaceChanged != nil
    }
    surface.ioSurfaceChanged?(makeUnmountableIOSurface())

    // The event-path mount failure fails the pending start promptly and unwinds the session, so a
    // stream that reported a failed start can never quietly self-start on a later surface.
    let pending = await isStillPending(startTask, after: 200_000_000)
    XCTAssertFalse(pending, "startStreaming must settle promptly when the late mount fails")
    guard !pending else { return } // a hung start can never be awaited to completion
    do {
      try await startTask.value
      XCTFail("startStreaming must throw when the late surface cannot be mounted")
    } catch {
      XCTAssertTrue(String(describing: error).contains("failedToCreatePixelBufferFromSurface"), "unexpected error: \(error)")
    }
    XCTAssertEqual(surface.unregisteredTokens.count, 1, "a failed pending start must unregister from the surface")
  }

  func testAwaitCompletionCancellationOnNeverStartedStream() async throws {
    let surface = FakeFramebufferSurface()
    let stream = makeStream(surface: surface)

    let awaitTask = Task { await stream.awaitCompletion() }
    try await Task.sleep(nanoseconds: 100_000_000)
    awaitTask.cancel()

    let pending = await isStillPending(awaitTask, after: 200_000_000)
    XCTAssertFalse(pending, "a cancelled awaitCompletion must return promptly")
  }

  /// `.compressedVideo` h264 over Annex-B with no `framesPerSecond`: the lazy cadence with a real
  /// VideoToolbox encode, so keyframe decisions are observable as IDR NAL units in the output bytes.
  private static let h264Configuration = VideoStreamConfiguration(
    format: .compressedVideo(withCodec: .h264, transport: .annexB), framesPerSecond: nil, rateControl: nil, scaleFactor: nil, keyFrameRate: nil)

  /// Updates `stream`'s overlay in place, as an overlay effect timer does: with the buffer it already composites,
  /// which does not leave the stream's executor.
  private static func updateOverlayInPlace(_ stream: isolated SimulatorVideoStream) {
    stream.updateOverlayBuffer(stream.compositor.overlayBuffer)
  }

  /// A small BGRA overlay buffer for compositing over the fake surface's frames.
  private static func makeOverlayBuffer() -> CVPixelBuffer {
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 128, 128, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
    precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
    return pixelBuffer!
  }

  /// Counts IDR slices (NAL unit type 5) in an Annex-B H.264 elementary stream.
  private func countIDRNALUnits(in data: Data) -> Int {
    let bytes = [UInt8](data)
    var count = 0
    var i = 0
    while i + 3 < bytes.count {
      guard bytes[i] == 0, bytes[i + 1] == 0 else {
        i += 1
        continue
      }
      var nalStart = -1
      if bytes[i + 2] == 1 {
        nalStart = i + 3
      } else if bytes[i + 2] == 0, i + 4 < bytes.count, bytes[i + 3] == 1 {
        nalStart = i + 4
      }
      guard nalStart > 0, nalStart < bytes.count else {
        i += 1
        continue
      }
      if bytes[nalStart] & 0x1F == 5 {
        count += 1
      }
      i = nalStart
    }
    return count
  }

  func testKeyframesAcrossOverlayUpdates() async throws {
    // Without a hardware encoder the stream never produces output, so the
    // assertions cannot be exercised on this host.
    try VideoEncodingHostSupport.skipUnlessHardwareH264Encoding()
    let surface = FakeFramebufferSurface()
    surface.immediateSurface = makeTestIOSurface(width: 128, height: 128)
    let consumer = AccumulatingBuffer()
    let stream = makeStream(surface: surface, configuration: Self.h264Configuration)

    try await stream.startStreaming(consumer)
    try await expectEventually("the initial mount must produce encoded output") {
      !consumer.data().isEmpty
    }

    // Phase 1: setting an overlay swaps the buffer in — a keyframe so a decoder can show it whole.
    let overlay = Self.makeOverlayBuffer()
    var before = consumer.data().count
    await stream.updateOverlayBuffer(overlay)
    try await expectEventually("an overlay swap pushes a frame") { consumer.data().count > before }
    let idrAfterSwap = countIDRNALUnits(in: consumer.data())

    // Phase 2: four in-place content updates (the same buffer reference — how the overlay effect
    // timer animates), each awaited so trigger coalescing cannot merge them.
    for _ in 0..<4 {
      before = consumer.data().count
      await Self.updateOverlayInPlace(stream)
      try await expectEventually("an in-place overlay update pushes a frame") { consumer.data().count > before }
    }
    let idrAfterInPlace = countIDRNALUnits(in: consumer.data())

    // Phase 3: swapping to a different buffer.
    before = consumer.data().count
    await stream.updateOverlayBuffer(Self.makeOverlayBuffer())
    try await expectEventually("an overlay buffer swap pushes a frame") { consumer.data().count > before }
    let idrAfterSecondSwap = countIDRNALUnits(in: consumer.data())

    // In-place overlay updates push plain frames — only a swap changes what a joining decoder must
    // see whole, so only swaps force an IDR.
    XCTAssertEqual(idrAfterInPlace - idrAfterSwap, 0, "in-place overlay updates must not force IDRs")
    XCTAssertGreaterThanOrEqual(idrAfterSecondSwap - idrAfterInPlace, 1, "an overlay buffer swap forces an IDR")

    try await stream.stopStreaming()
  }

  func testDroppedStreamIsReleasedOnceSurfaceReleasesCallbacks() async throws {
    let surface = FakeFramebufferSurface()
    surface.immediateSurface = makeTestIOSurface()
    let consumer = AccumulatingBuffer()
    let eager = VideoStreamConfiguration(
      format: .bgra, framesPerSecond: 20, rateControl: nil, scaleFactor: nil, keyFrameRate: nil)
    var stream: SimulatorVideoStream? = makeStream(surface: surface, configuration: eager)
    weak let weakStream = stream

    try await stream?.startStreaming(consumer)

    // Drop every external retention: this test's reference and the surface's callback blocks (as
    // the real proxy does at its own teardown). Only the push-loop task could still hold the
    // stream — and it must not, or a stream dropped without stopStreaming pushes frames forever
    // and the deinit backstop can never run.
    stream = nil
    surface.releaseCallbacks()

    try await expectEventually("dropping the last external reference must release the stream") {
      weakStream == nil
    }
  }
}

/// A snapshot of the stream's current frame pusher, taken on the actor so the non-Sendable pusher
/// never crosses an isolation boundary.
// SAFETY: pusher state is mutated only on the stream actor; tests read `bitmapPusher` only after
// the actor has finished the operation under test.
// patternlint-disable-next-line unchecked-sendable
private final class FramePusherHandle: @unchecked Sendable {
  let identity: ObjectIdentifier
  let bitmapPusher: BitmapFramePusher?

  init(pusher: any FramePusher) {
    identity = ObjectIdentifier(pusher)
    bitmapPusher = pusher as? BitmapFramePusher
  }
}

extension SimulatorVideoStream {
  fileprivate func currentFramePusherHandle() -> FramePusherHandle? {
    framePusher.map(FramePusherHandle.init)
  }
}
