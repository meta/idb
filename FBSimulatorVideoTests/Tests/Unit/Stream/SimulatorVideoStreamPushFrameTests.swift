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
import XCTest

/// What `pushFrame` hands the frame pusher and how it reports the pusher's outcome, observed
/// through a recording pusher installed in place of the real one.
final class SimulatorVideoStreamPushFrameTests: XCTestCase {

  private static let lazyConfiguration = VideoStreamConfiguration(
    format: .bgra, framesPerSecond: nil, rateControl: nil, scaleFactor: nil, keyFrameRate: nil)

  private struct Started {
    let stream: SimulatorVideoStream
    let pusher: RecordingFramePusher
    let surface: FakeFramebufferSurface
    let ioSurface: IOSurface
    let logger: CapturingLogger
  }

  private func makeStream(clock: any VideoStreamClock = SystemVideoStreamClock()) -> Started {
    let surface = FakeFramebufferSurface()
    let ioSurface = makeTestIOSurface()
    surface.immediateSurface = ioSurface
    let logger = CapturingLogger()
    let framebuffer = Framebuffer(surface: surface, logger: logger)
    let stream = SimulatorVideoStream(
      framebuffer: framebuffer,
      configuration: Self.lazyConfiguration,
      edgeInsets: VideoStreamEdgeInsets(top: 0, bottom: 0, left: 0, right: 0),
      cadence: .lazy,
      logger: logger,
      clock: clock)
    return Started(stream: stream, pusher: RecordingFramePusher(), surface: surface, ioSurface: ioSurface, logger: logger)
  }

  private func startStream(clock: any VideoStreamClock = SystemVideoStreamClock()) async throws -> Started {
    let made = makeStream(clock: clock)
    let stream = made.stream
    let surface = made.surface
    let ioSurface = made.ioSurface
    let logger = made.logger
    try await stream.startStreaming(AccumulatingBuffer())
    let pusher = RecordingFramePusher()
    await stream.installFramePusher(pusher)
    return Started(stream: stream, pusher: pusher, surface: surface, ioSurface: ioSurface, logger: logger)
  }

  func testASignalDuringAPushIsStillPushed() async throws {
    let started = try await startStream()
    defer { Task { [stream = started.stream] in try? await stream.stopStreaming() } }
    let pushInProgress = DispatchSemaphore(value: 0)
    started.pusher.onWrite = {
      pushInProgress.signal()
      usleep(2_000)
    }

    // The second signal lands while the first push is in progress; the third right after the second.
    started.surface.frameRendered?()
    XCTAssertEqual(pushInProgress.wait(timeout: .now() + 2), .success, "the first signal must start a push")
    started.surface.frameRendered?()
    started.surface.frameRendered?()

    for _ in 0..<200 where started.pusher.writes.count < 2 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    let writes = started.pusher.writes
    XCTAssertGreaterThanOrEqual(writes.count, 2, "a signal during a push must still be pushed")
    XCTAssertLessThanOrEqual(writes.count, 3, "three signals cannot produce more than three pushes")
  }

  func testFrameTimingReferenceIsTheMonotonicClock() async throws {
    let started = try await startStream()
    defer { Task { [stream = started.stream] in try? await stream.stopStreaming() } }

    await started.stream.pushFrame(forceKeyFrame: false)
    await started.stream.pushFrame(forceKeyFrame: false)

    let writes = started.pusher.writes
    XCTAssertEqual(writes.count, 2)
    let reference = try XCTUnwrap(writes.first?.timeAtFirstFrame)
    XCTAssertEqual(reference, ProcessInfo.processInfo.systemUptime, accuracy: 5, "frame timing reference must be a monotonic uptime reading")
    XCTAssertEqual(writes[1].timeAtFirstFrame, reference, "every frame shares the first frame's reference time")
    XCTAssertGreaterThanOrEqual(writes[1].frameDuration, 0)
  }

  func testEncodeSubmissionFailureIsLogged() async throws {
    let started = try await startStream()
    defer { Task { [stream = started.stream] in try? await stream.stopStreaming() } }
    started.pusher.error = VideoToolboxFramePusherError.failedToCompress(status: -12902)

    await started.stream.pushFrame(forceKeyFrame: false)

    XCTAssertEqual(started.pusher.writes.count, 1)
    let encodeFailureLogs = started.logger.messages.compactMap { $0 as? String }.filter { $0.contains("-12902") }
    XCTAssertEqual(encodeFailureLogs.count, 1, "an encode submission failure must be logged once: \(started.logger.messages)")
  }

  func testMediaOriginIsUnknownBeforeAFrameWasPushed() async throws {
    // Starting a stream pushes its first frame as the surface mounts, so the only stream that has
    // pushed nothing is one that has not started.
    let made = makeStream()

    let origin = await made.stream.mediaOrigin(anchor: 0)

    XCTAssertNil(origin)
  }

  func testMediaOriginIsTheWallClockAtTheFirstFramePlusTheFileSAnchor() async throws {
    let clock = SettableClock(uptime: 100, wallClock: 1_000_000)
    let started = try await startStream(clock: clock)
    defer { Task { [stream = started.stream] in try? await stream.stopStreaming() } }

    await started.stream.pushFrame(forceKeyFrame: false)
    // A minute of recording on both clocks, and a file anchored on a sample muxed 2 seconds after
    // the first frame was pushed.
    clock.advance(by: 60)

    let origin = await started.stream.mediaOrigin(anchor: 2)

    XCTAssertEqual(origin, 1_000_002)
  }

  func testMediaOriginWhenTheWallClockIsSetDuringTheRecording() async throws {
    let clock = SettableClock(uptime: 100, wallClock: 1_000_000)
    let started = try await startStream(clock: clock)
    defer { Task { [stream = started.stream] in try? await stream.stopStreaming() } }

    await started.stream.pushFrame(forceKeyFrame: false)
    // A minute of recording, during which the wall clock was also set forward by a minute.
    clock.advance(by: 60)
    clock.wallClock += 60

    let origin = await started.stream.mediaOrigin(anchor: 0)

    // The first frame was pushed at 1_000_000, and setting the wall clock afterwards cannot change
    // when that happened.
    XCTAssertEqual(origin, 1_000_000)
  }

  func testMediaOriginOnTheHostClockIsTheHostTimeAtTheFirstFramePlusTheFileSAnchor() async throws {
    let clock = SettableClock(uptime: 100, wallClock: 1_000_000, hostTime: 5_000_000_000)
    let started = try await startStream(clock: clock)
    defer { Task { [stream = started.stream] in try? await stream.stopStreaming() } }

    await started.stream.pushFrame(forceKeyFrame: false)
    clock.advance(by: 60)

    let origin = await started.stream.mediaOriginHostTime(anchor: 2)

    XCTAssertEqual(origin, 5_000_000_000 + SettableClock.ticks(seconds: 2))
  }

  func testSurfaceWrittenDuringPushIsCountedAsTorn() async throws {
    let started = try await startStream()
    defer { Task { [stream = started.stream] in try? await stream.stopStreaming() } }
    let ioSurface = started.ioSurface
    started.pusher.onWrite = {
      // The render server writing into the surface while the frame is being read.
      try? ioSurface.lock(options: [], seed: nil)
      ioSurface.baseAddress.assumingMemoryBound(to: UInt8.self)[0] ^= 0xFF
      try? ioSurface.unlock(options: [], seed: nil)
    }

    await started.stream.pushFrame(forceKeyFrame: false)

    XCTAssertEqual(started.pusher.writes.count, 1)
    let stats = await started.stream.currentEncoderStats()
    XCTAssertEqual(stats.tornFrameCount, 1)
  }

  func testAnOverlayOnlyPushOverThePresentedScreenIsPushed() async throws {
    let started = try await startStream()
    defer { Task { [stream = started.stream] in try? await stream.stopStreaming() } }

    let pushed = await started.stream.pushTriggered(FrameTrigger(forceKeyFrame: false, overran: false, overlayOnly: true))

    XCTAssertNotNil(pushed)
    XCTAssertEqual(started.pusher.writes.count, 1)
  }

  func testAnOverlayOnlyPushWaitsForTheFrameTheSimulatorIsDrawing() async throws {
    let started = try await startStream()
    defer { Task { [stream = started.stream] in try? await stream.stopStreaming() } }
    // The render server drawing into the surface before it reports the frame
    try started.ioSurface.lock(options: [], seed: nil)
    started.ioSurface.baseAddress.assumingMemoryBound(to: UInt8.self)[0] ^= 0xFF
    try started.ioSurface.unlock(options: [], seed: nil)

    let held = await started.stream.pushTriggered(FrameTrigger(forceKeyFrame: true, overran: false, overlayOnly: true))
    XCTAssertNil(held)
    XCTAssertTrue(started.pusher.writes.isEmpty, "an overlay-only push must not encode a frame the Simulator has not presented")

    let rendered = expectation(description: "the rendered frame is pushed")
    rendered.assertForOverFulfill = false
    started.pusher.onWrite = { rendered.fulfill() }
    started.surface.frameRendered?()
    await fulfillment(of: [rendered], timeout: 5)
    let resumed = await started.stream.pushTriggered(FrameTrigger(forceKeyFrame: false, overran: false, overlayOnly: true))

    XCTAssertNotNil(resumed)
    // The rendered frame carries the held-back swap's keyframe; once it is presented, overlay-only pushes go ahead
    XCTAssertEqual(started.pusher.writes.map(\.forceKeyFrame), [true, false])
  }
}

/// A frame pusher that records what `pushFrame` hands it and can fail or act on demand.
// SAFETY: `writes` is guarded by `lock`; `error` and `onWrite` are set before the push under test.
// patternlint-disable-next-line unchecked-sendable
private final class RecordingFramePusher: FramePusher, @unchecked Sendable {
  struct Write {
    let time: TimeInterval
    let frameNumber: UInt
    let timeAtFirstFrame: TimeInterval
    let frameDuration: TimeInterval
    let forceKeyFrame: Bool
  }

  private let lock = NSLock()
  private var recorded: [Write] = []
  private var tornFrameCount: UInt = 0
  var error: Error?
  var onWrite: (() -> Void)?

  var writes: [Write] {
    lock.withLock { recorded }
  }

  func recordTornFrame() {
    lock.withLock { tornFrameCount += 1 }
  }

  func currentStats() -> VideoEncoderStats? {
    var stats = VideoEncoderStats()
    stats.tornFrameCount = lock.withLock { tornFrameCount }
    return stats
  }

  func setup(source: VideoFrameSource, edgeInsets: VideoStreamEdgeInsets) throws {}

  func tearDown() throws {}

  func writeEncodedFrame(
    _ pixelBuffer: CVPixelBuffer,
    frameNumber: UInt,
    timeAtFirstFrame: TimeInterval,
    frameDuration: TimeInterval,
    forceKeyFrame: Bool
  ) throws {
    let time = ProcessInfo.processInfo.systemUptime
    onWrite?()
    lock.withLock {
      recorded.append(Write(time: time, frameNumber: frameNumber, timeAtFirstFrame: timeAtFirstFrame, frameDuration: frameDuration, forceKeyFrame: forceKeyFrame))
    }
    if let error {
      throw error
    }
  }
}

extension SimulatorVideoStream {
  fileprivate func installFramePusher(_ pusher: any FramePusher & Sendable) {
    framePusher = pusher
  }
}

/// The clocks a test moves by hand, in place of the machine's.
// SAFETY: every reading is guarded by `lock`.
// patternlint-disable-next-line unchecked-sendable
private final class SettableClock: VideoStreamClock, @unchecked Sendable {
  private let lock = NSLock()
  private var uptimeReading: TimeInterval
  private var wallClockReading: TimeInterval
  private var hostTimeReading: UInt64

  init(uptime: TimeInterval, wallClock: TimeInterval, hostTime: UInt64 = 1) {
    uptimeReading = uptime
    wallClockReading = wallClock
    hostTimeReading = hostTime
  }

  static func ticks(seconds: TimeInterval) -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return UInt64((seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer)).rounded())
  }

  var hostTime: UInt64 {
    lock.withLock { hostTimeReading }
  }

  var uptime: TimeInterval {
    get { lock.withLock { uptimeReading } }
    set { lock.withLock { uptimeReading = newValue } }
  }

  var wallClock: TimeInterval {
    get { lock.withLock { wallClockReading } }
    set { lock.withLock { wallClockReading = newValue } }
  }

  /// Time passing, as it does on every clock at once.
  func advance(by seconds: TimeInterval) {
    lock.withLock {
      uptimeReading += seconds
      wallClockReading += seconds
      hostTimeReading += Self.ticks(seconds: seconds)
    }
  }
}
