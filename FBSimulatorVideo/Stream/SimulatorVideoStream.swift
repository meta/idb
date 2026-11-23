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
import IOSurface
import VideoToolbox
import os

enum SimulatorVideoStreamError: Error {
  case startWhenStopped
  case startAlreadyStarted
  case stopWithoutConsumer
  case failedToTearDownFramePusher(errorDescription: String)
  case failedToCreatePixelBufferFromSurface(status: CVReturn)
  case failedToCreatePixelBufferFromSurfaceNil
  case mountSurfaceWithoutConsumer
  case noPixelBufferForScreenshot
}

extension SimulatorVideoStreamError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .startWhenStopped:
      return "Cannot start streaming, since streaming is stopped"
    case .startAlreadyStarted:
      return "Cannot start streaming, since streaming has already has started"
    case .stopWithoutConsumer:
      return "Cannot stop streaming, no consumer attached"
    case .failedToTearDownFramePusher(let errorDescription):
      return "Failed to tear down frame pusher: \(errorDescription)"
    case .failedToCreatePixelBufferFromSurface(let status):
      return "Failed to create Pixel Buffer from Surface with errorCode \(status)"
    case .failedToCreatePixelBufferFromSurfaceNil:
      return "Failed to create Pixel Buffer from Surface (nil)"
    case .mountSurfaceWithoutConsumer:
      return "Cannot mount surface when there is no consumer"
    case .noPixelBufferForScreenshot:
      return "No pixel buffer available for screenshot"
    }
  }
}

// MARK: - Value Types

/// Edge insets that extend the output frame dimensions beyond the source framebuffer.
/// Each edge adds opaque pixels for overlay content (label bars, diagnostic stats, etc.).
public struct VideoStreamEdgeInsets: Sendable {
  public var top: UInt
  public var bottom: UInt
  public var left: UInt
  public var right: UInt

  public init(top: UInt, bottom: UInt, left: UInt, right: UInt) {
    self.top = top
    self.bottom = bottom
    self.left = left
    self.right = right
  }
}

/// Frame cadence strategy for the video stream.
///
/// - `.lazy`: variable-frame-rate — a frame is pushed only when the framebuffer signals that a new
///   frame was rendered (a `.frameRendered` event).
/// - `.eager(framesPerSecond:)`: constant-frame-rate — a cadence `Task` pushes frames at the fixed
///   rate, and frame-rendered events are ignored (the cadence task drives pushes).
enum VideoStreamCadence {
  case lazy
  case eager(framesPerSecond: UInt)
}

private extension VideoStreamCodec {
  var videoToolboxCodec: CMVideoCodecType {
    switch self {
    case .h264:
      return kCMVideoCodecType_H264
    case .hevc:
      return kCMVideoCodecType_HEVC
    }
  }
}

private func bitmapStreamPixelBufferAttributes(from pixelBuffer: CVPixelBuffer) -> [String: Any] {
  let width = CVPixelBufferGetWidth(pixelBuffer)
  let height = CVPixelBufferGetHeight(pixelBuffer)
  let frameSize = CVPixelBufferGetDataSize(pixelBuffer)
  let rowSize = CVPixelBufferGetBytesPerRow(pixelBuffer)
  let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
  let pixelFormatString = pixelFormat.fourCharCodeString

  var columnLeft = 0
  var columnRight = 0
  var rowsTop = 0
  var rowsBottom = 0
  CVPixelBufferGetExtendedPixels(pixelBuffer, &columnLeft, &columnRight, &rowsTop, &rowsBottom)

  return [
    "width": width,
    "height": height,
    "row_size": rowSize,
    "frame_size": frameSize,
    "padding_column_left": columnLeft,
    "padding_column_right": columnRight,
    "padding_row_top": rowsTop,
    "padding_row_bottom": rowsBottom,
    "format": pixelFormatString,
  ]
}

/// A real-time video stream of a Simulator's framebuffer, written to a `DataConsumer`.
///
/// Concurrency model: the actor serializes start/stop, framebuffer event handling, and every frame
/// push. Framebuffer events arrive on the attachment's ordered `AsyncStream`, consumed by an
/// actor-isolated task, rather than queue-delivered callbacks. The cadence is selected by the
/// `cadence` strategy: `.lazy` pushes a frame when a frame-rendered event pokes the trigger stream
/// (variable frame rate), while `.eager` runs a cadence `Task` on the actor that pushes at a fixed frame rate.
/// The clocks a stream reads: the monotonic one every frame is timed against, and the wall clock a
/// recording's start is reported on. Injected so a test can move either without waiting or setting
/// the machine's clock.
protocol VideoStreamClock: Sendable {
  var uptime: TimeInterval { get }
  var wallClock: TimeInterval { get }
  /// `mach_absolute_time`, which other media of the same moment, such as the simulator's audio,
  /// are stamped with.
  var hostTime: UInt64 { get }
}

/// The machine's clocks.
struct SystemVideoStreamClock: VideoStreamClock {
  var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
  var wallClock: TimeInterval { Date().timeIntervalSince1970 }
  var hostTime: UInt64 { mach_absolute_time() }
}

public actor SimulatorVideoStream: VideoStreamOperation {

  // MARK: - Properties

  let framebuffer: Framebuffer
  let configuration: VideoStreamConfiguration
  let edgeInsets: VideoStreamEdgeInsets
  let cadence: VideoStreamCadence
  /// When set (recording), encoded `.compressed` frames are routed to this file instead of being byte-framed to
  /// `consumer`. nil for streaming.
  let encodedSampleConsumerOverride: (any RecordingFileWriter)?
  let logger: any ControlCoreLogger
  let clock: any VideoStreamClock

  // MARK: - Lifecycle

  /// What a started stream holds: the consumer, the framebuffer attachment (whose `cancel()`
  /// detaches this stream), and the task consuming the attachment's ordered event stream onto the
  /// actor (surface changes mount, frame-rendered events poke the `.lazy` trigger; it ends when the
  /// attachment cancels, finishing the stream).
  /// Sendable so the nonisolated `deinit` backstop can reach the attachment and event task.
  private struct Session: Sendable {
    let consumer: any DataConsumer
    let attachment: FramebufferAttachment
    let eventTask: Task<Void, Never>
  }

  /// One-way: `.idle` → `.starting` → `.streaming` → `.stopped`. A stop is legal from `.starting`; a
  /// failed initial mount unwinds `.starting` back to `.idle`.
  private enum Lifecycle: Sendable {
    /// Never started; a `startStreaming` may begin.
    case idle
    /// Attached, awaiting the first surface mount; the awaiters are suspended `startStreaming` callers.
    case starting(Session, startAwaiters: [CheckedContinuation<Void, any Error>])
    /// The first surface mounted; frames flow.
    case streaming(Session)
    /// Terminal; the stream cannot be restarted.
    case stopped
  }

  private var lifecycle: Lifecycle = .idle

  /// Completion awaiters, keyed per await so a cancelled `awaitCompletion` can resume its own
  /// continuation even when the stream cannot be stopped. Kept outside `Lifecycle` because
  /// completion can be awaited in any phase, including before a start.
  private var stopAwaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  /// The push-loop task that drives frame pushes (nil before `mountSurface` starts it). It iterates a
  /// stimulus `AsyncSequence` of `FrameTrigger`s: `FrameCadence` (the fixed-rate clock) in `.eager`
  /// mode, or `LazyFrameTriggers` (poked by the framebuffer callbacks) in `.lazy` mode.
  /// Started in `mountSurface`, cancelled in `cadenceTeardown`/`deinit`.
  private var framePusherTask: Task<Void, Never>?

  /// In `.lazy` (VFR) mode, the trigger source that the framebuffer event loop (`.frameRendered`)
  /// and `updateOverlayBuffer` poke to drive a push through the shared loop. Created in `mountSurface`,
  /// finished in `cadenceTeardown`. Nil in `.eager` mode (the cadence clock drives pushes there).
  private var lazyTriggers: LazyFrameTriggers?
  /// In `.lazy` mode, the mounted surface's modification seed as of its mount or the latest rendered frame: the screen
  /// the Simulator last presented. A seed that has moved on since means the Simulator wrote into the surface without
  /// reporting a frame.
  private var presentedSurfaceSeed: UInt32?
  /// Whether the next triggered push must force the keyframe of an overlay swap whose own push was held back
  private var keyFrameHeldBack = false

  var pixelBuffer: CVPixelBuffer?
  /// The mounted surface as the interface shows it.
  var mountedSource: VideoFrameSource?
  /// The surface the framebuffer last reported: the one the stream should show, whether or not it mounted.
  private var latestSurface: IOSurface?

  /// What the encoder's frames are sized to. A live stream follows the mounted surface, and so does a recording into a
  /// file that can change frame size. Any other file's players show every frame at the first one's size, so a recording
  /// into it keeps the canvas of its first mount and letterboxes any later surface into it.
  private enum CanvasPolicy {
    case followsSurface
    case fixedAtFirstMount
    case fixed(VideoFrameSource)
  }

  private var canvasPolicy: CanvasPolicy

  /// The frames the mounted pusher is set up for: the mounted source, or the canvas a recording keeps.
  var canvas: VideoFrameSource? {
    switch canvasPolicy {
    case .followsSurface, .fixedAtFirstMount:
      return mountedSource
    case let .fixed(canvas):
      return canvas
    }
  }
  var timeAtFirstFrame: TimeInterval = 0
  var wallClockAtFirstFrame: TimeInterval = 0
  var hostTimeAtFirstFrame: UInt64 = 0
  var timeAtLastPush: TimeInterval = 0
  var frameNumber: UInt = 0
  var pixelBufferAttributes: [String: Any]?
  /// The session's consumer while started, nil otherwise — the mount and push paths read this.
  var consumer: (any DataConsumer)? {
    switch lifecycle {
    case .idle, .stopped:
      return nil
    case .starting(let session, _), .streaming(let session):
      return session.consumer
    }
  }
  var framePusher: (any FramePusher)?
  /// What lays the overlay out for the canvas, set from outside the actor and read at every mount.
  private nonisolated let overlayLayout = OSAllocatedUnfairLock<OverlayRenderer?>(initialState: nil)
  /// The size of the overlay laid out for the current canvas; a buffer of any other size is from an earlier one.
  private var overlaySize: (width: Int, height: Int)?
  /// Set up for the other displays a stream switches between, once a configuration has several surface sizes.
  /// A displaced pusher is kept here rather than torn down while `preparesForDisplaySwitches`. A spare is set up
  /// as a mount would set it up: the configuration and edge insets are fixed for the stream's life, so its source
  /// is the only input that varies, and it is taken only for a surface of that source.
  var spareFramePushers = FramePusherPool()
  var preparesForDisplaySwitches = false
  /// The newest display configuration, so pushers are prepared at the first mount if it arrived before.
  var displayConfiguration: SimulatorDisplayConfiguration?
  /// The transport writers for compressed video, created on the first mount and shared by every
  /// pusher the stream creates: they carry per-stream state (MPEG-TS continuity counters, the fMP4
  /// init segment and sequence numbers) that must survive a surface swap. nil for other formats.
  var frameWriters: VideoStreamFrameWriters?
  /// The timed-metadata (chapter) sink: the streaming transport writer, or (recording) the file
  /// writer's chapter track. Resolved in `mountSurface`, cleared in `stopStreaming`.
  var timedMetadataConsumer: (any TimedMetadataConsumer)?

  /// Overlay and edge-inset compositing; configured for the source at every mount.
  let compositor: OverlayCompositor

  // MARK: - Initializers

  /// Makes a stream whose output frame is extended by `edgeInsets` (reserved for overlay content), none by default.
  /// Cadence is derived from `configuration.framesPerSecond`.
  public init(framebuffer: Framebuffer, configuration: VideoStreamConfiguration, edgeInsets: VideoStreamEdgeInsets = VideoStreamEdgeInsets(top: 0, bottom: 0, left: 0, right: 0), logger: any ControlCoreLogger) {
    self.init(
      framebuffer: framebuffer,
      configuration: configuration,
      edgeInsets: edgeInsets,
      cadence: Self.cadence(for: configuration),
      logger: logger)
  }

  /// Makes a recording stream: encoded `.compressed` frames are muxed into a file via `fileWriter`
  /// rather than byte-framed to a `DataConsumer`. `edgeInsets` (default zero) reserves overlay bar
  /// regions exactly as on the streaming path. Cadence is derived from `configuration.framesPerSecond`.
  init(framebuffer: Framebuffer, configuration: VideoStreamConfiguration, edgeInsets: VideoStreamEdgeInsets = VideoStreamEdgeInsets(top: 0, bottom: 0, left: 0, right: 0), fileWriter: any RecordingFileWriter, logger: any ControlCoreLogger) {
    self.init(
      framebuffer: framebuffer,
      configuration: configuration,
      edgeInsets: edgeInsets,
      cadence: Self.cadence(for: configuration),
      logger: logger,
      encodedSampleConsumerOverride: fileWriter)
  }

  /// Makes and starts a stream to `consumer`.
  public static func start(framebuffer: Framebuffer, configuration: VideoStreamConfiguration, edgeInsets: VideoStreamEdgeInsets = VideoStreamEdgeInsets(top: 0, bottom: 0, left: 0, right: 0), to consumer: any DataConsumer, logger: any ControlCoreLogger) async throws -> SimulatorVideoStream {
    let stream = SimulatorVideoStream(framebuffer: framebuffer, configuration: configuration, edgeInsets: edgeInsets, logger: logger)
    try await stream.startStreaming(consumer)
    return stream
  }

  /// Eager (constant-frame-rate) when a positive `framesPerSecond` is set, else lazy (variable-rate,
  /// driven by damage events).
  private static func cadence(for configuration: VideoStreamConfiguration) -> VideoStreamCadence {
    guard let framesPerSecond = configuration.framesPerSecond, framesPerSecond > 0 else {
      return .lazy
    }
    return .eager(framesPerSecond: UInt(framesPerSecond))
  }

  init(framebuffer: Framebuffer, configuration: VideoStreamConfiguration, edgeInsets: VideoStreamEdgeInsets, cadence: VideoStreamCadence, logger: any ControlCoreLogger, encodedSampleConsumerOverride: (any RecordingFileWriter)? = nil, clock: any VideoStreamClock = SystemVideoStreamClock()) {
    self.framebuffer = framebuffer
    self.configuration = configuration
    self.edgeInsets = edgeInsets
    self.cadence = cadence
    self.encodedSampleConsumerOverride = encodedSampleConsumerOverride
    self.canvasPolicy = encodedSampleConsumerOverride?.carriesFrameSizeChanges == false ? .fixedAtFirstMount : .followsSurface
    self.logger = logger
    self.clock = clock
    self.compositor = OverlayCompositor(edgeInsets: edgeInsets)
  }

  deinit {
    // Backstop teardown if the stream is dropped without a clean stopStreaming: cancel the
    // attachment (finishing the event stream, which ends the event task) and both tasks.
    // Reachable while the push loop runs because it holds the stream weakly; that loop also exits
    // on its own at the next trigger once the stream is gone. A `.starting` phase with pending
    // awaiters cannot reach deinit — a suspended caller keeps the actor alive.
    switch lifecycle {
    case .starting(let session, _), .streaming(let session):
      session.attachment.cancel()
      session.eventTask.cancel()
    case .idle, .stopped:
      break
    }
    framePusherTask?.cancel()
  }

  // MARK: - Public

  public nonisolated func startStreaming(_ consumer: any DataConsumer) async throws {
    try await isolatedStartStreaming(consumer)
  }

  private func isolatedStartStreaming(_ consumer: any DataConsumer) async throws {
    switch lifecycle {
    case .starting, .streaming:
      throw SimulatorVideoStreamError.startAlreadyStarted
    case .stopped:
      throw SimulatorVideoStreamError.startWhenStopped
    case .idle:
      break
    }
    let attachment = try framebuffer.attach()
    // Consume the attachment's ordered event stream onto the actor. `[weak self]` so the task
    // never keeps the stream alive; the strong `attachment` capture ends when the stream
    // finishes (attachment cancel), completing the loop.
    let eventTask = Task { [weak self] in
      for await event in attachment.events {
        await self?.handle(event)
      }
    }
    lifecycle = .starting(Session(consumer: consumer, attachment: attachment, eventTask: eventTask), startAwaiters: [])
    // When a surface is already available this mounts it synchronously (transitioning to
    // `.streaming`), otherwise the first surface event does.
    // So the first mount is in the interface's orientation, which a recording's canvas is fixed by.
    displayConfiguration = attachment.initialConfiguration
    if let surface = attachment.initialSurface {
      latestSurface = surface
      do {
        try mountSurface(surface)
      } catch {
        // No awaiters exist yet, so this only tears the session down; the error is thrown to the caller.
        failPendingStart(with: error)
        throw error
      }
      pushFrame(forceKeyFrame: false)
    }
    guard case .starting = lifecycle else {
      return // mounted synchronously — already streaming
    }
    // A start still waiting for a surface ends when its task is cancelled, so a caller that went
    // away does not hold the framebuffer, or a recording's place, until a surface arrives.
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          failPendingStart(with: CancellationError())
          continuation.resume(throwing: CancellationError())
          return
        }
        guard case .starting(let session, var awaiters) = lifecycle else {
          continuation.resume()
          return
        }
        awaiters.append(continuation)
        lifecycle = .starting(session, startAwaiters: awaiters)
      }
    } onCancel: { [attachment] in
      Task { await self.failPendingStart(of: attachment, with: CancellationError()) }
    }
  }

  public func stopStreaming() async throws {
    let session: Session
    let pendingStartAwaiters: [CheckedContinuation<Void, any Error>]
    switch lifecycle {
    case .stopped:
      return
    case .idle:
      throw SimulatorVideoStreamError.stopWithoutConsumer
    case .starting(let active, let awaiters):
      session = active
      pendingStartAwaiters = awaiters
    case .streaming(let active):
      session = active
      pendingStartAwaiters = []
    }
    // Transition first so a failing pusher teardown still leaves the stream `.stopped` with awaiters resumed.
    lifecycle = .stopped
    session.attachment.cancel()
    session.eventTask.cancel()
    session.consumer.consumeEndOfFile()
    var tearDownError: (any Error)?
    spareFramePushers.removeAll().forEach { tearDown($0, after: "the stream stopped") }
    preparesForDisplaySwitches = false
    displayConfiguration = nil
    mountedSource = nil
    latestSurface = nil
    if let framePusher {
      do {
        try framePusher.tearDown()
      } catch {
        tearDownError = error
      }
    }
    timedMetadataConsumer = nil
    frameWriters = nil
    compositor.reset()
    cadenceTeardown()
    resumeStopAwaiters()
    for awaiter in pendingStartAwaiters {
      awaiter.resume(throwing: SimulatorVideoStreamError.startWhenStopped)
    }
    if let tearDownError {
      throw SimulatorVideoStreamError.failedToTearDownFramePusher(errorDescription: "\(tearDownError)")
    }
  }

  /// Resume everyone awaiting completion.
  private func resumeStopAwaiters() {
    let awaiters = stopAwaiters
    stopAwaiters = [:]
    for awaiter in awaiters.values {
      awaiter.resume()
    }
  }

  /// Unwind a start still awaiting its first mount because that mount failed: the awaiters are
  /// failed and the session is torn down (back to `.idle`), so a stream that reported a failed
  /// start can never quietly self-start on a later surface. A no-op once `.streaming` — a failed
  /// mid-stream surface swap keeps streaming the previous surface.
  /// Fails the start that attached `attachment`, if it is still waiting for a surface, and not a later one.
  private func failPendingStart(of attachment: FramebufferAttachment, with error: any Error) {
    guard case .starting(let session, _) = lifecycle, session.attachment === attachment else {
      return
    }
    failPendingStart(with: error)
  }

  private func failPendingStart(with error: any Error) {
    guard case .starting(let session, let awaiters) = lifecycle else {
      return
    }
    lifecycle = .idle
    session.eventTask.cancel()
    session.attachment.cancel()
    for awaiter in awaiters {
      awaiter.resume(throwing: error)
    }
  }

  /// Finishes the `.lazy` trigger stream and cancels the push-loop task (cancellation also wakes an
  /// `.eager` loop suspended in `Task.sleep`).
  func cadenceTeardown() {
    lazyTriggers?.finish()
    lazyTriggers = nil
    framePusherTask?.cancel()
    framePusherTask = nil
  }

  // MARK: - Framebuffer Events

  /// Apply a single framebuffer event. Per-event work is O(1) and non-suspending, honoring the
  /// unbounded event stream's drain invariant: a surface change (always a genuinely different surface,
  /// `Framebuffer` drops re-reports) mounts once; a rendered frame pokes
  /// the `.lazy` trigger, whose `bufferingNewest(1)` coalescing keeps real-time frame dropping where
  /// it belongs. In `.eager` mode the cadence clock drives pushes, so frame-rendered events are ignored.
  private func handle(_ event: FramebufferEvent) {
    switch event {
    case let .surfaceChanged(surface):
      guard let surface else { return }
      latestSurface = surface
      reconcileMount()
      // After the push, so preparing for a configuration that arrived before the first mount does not delay it.
      prepareSpareFramePushers()
    case .frameRendered:
      switch cadence {
      case .lazy:
        presentedSurfaceSeed = mountedSurfaceSeed
        lazyTriggers?.signalFrameRendered()
      case .eager:
        break
      }
    case let .configurationChanged(displayConfiguration):
      self.displayConfiguration = displayConfiguration
      reconcileMount()
      prepareSpareFramePushers()
    case let .ended(error):
      logger.log("Framebuffer ended: \(error)")
      failPendingStart(with: error)
    }
  }

  // MARK: - Private (Surface)

  func mountSurface(_ surface: IOSurface) throws {
    // CVPixelBufferCreateWithIOSurface returns +1 via an Unmanaged out-param; takeRetainedValue() adopts it.
    var unmanagedBuffer: Unmanaged<CVPixelBuffer>?
    let status = CVPixelBufferCreateWithIOSurface(nil, surface, nil, &unmanagedBuffer)
    if status != kCVReturnSuccess {
      throw SimulatorVideoStreamError.failedToCreatePixelBufferFromSurface(status: status)
    }
    guard let buffer = unmanagedBuffer?.takeRetainedValue() else {
      throw SimulatorVideoStreamError.failedToCreatePixelBufferFromSurfaceNil
    }

    guard let consumer else {
      throw SimulatorVideoStreamError.mountSurfaceWithoutConsumer
    }

    let attributes = bitmapStreamPixelBufferAttributes(from: buffer)
    logger.log("Mounting Surface \(IOSurfaceGetID(surface)) with Attributes: \(CollectionInformation.oneLineDescription(from: attributes))")
    try mount(buffer, attributes: attributes, consumer: consumer)
  }

  /// Mounts the surface the framebuffer last reported, as the interface shows it, unless that is what is mounted.
  /// A new surface and a rotation of the interface both differ from what is mounted, and so does a mount that
  /// failed: the stream keeps its working pipeline, and the next display event tries again. A first mount that
  /// fails fails the start instead.
  func reconcileMount() {
    guard let latestSurface else {
      return
    }
    if let pixelBuffer, let mountedSource, let mountedSurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue(),
      IOSurfaceGetID(mountedSurface) == IOSurfaceGetID(latestSurface),
      compositor.rotation == interfaceRotation(of: pixelBuffer),
      VideoFrameSource(pixelBuffer).rotated(interfaceRotation(of: pixelBuffer)) == mountedSource
    {
      return
    }
    do {
      try mountSurface(latestSurface)
    } catch {
      logger.log("Failed to mount surface \(IOSurfaceGetID(latestSurface)), keeping the mounted one until the next display event: \(error)")
      failPendingStart(with: error)
      return
    }
    // A pusher taken from the spares has encoded before, so its next frame would reference one the consumer
    // never received.
    pushFrame(forceKeyFrame: true)
  }

  /// The interface rotation of the display whose surface is `buffer`: a transition's incoming display, then the
  /// active one, then any other. Upright when no display's surface is the buffer's size.
  private func interfaceRotation(of buffer: CVPixelBuffer) -> SimulatorDisplayRotation {
    guard let displayConfiguration else {
      return .upright
    }
    var candidates: [SimulatorDisplayGeometry] = []
    if case let .transitioning(incoming?) = displayConfiguration.phase {
      candidates.append(incoming.geometry)
    }
    switch displayConfiguration.active {
    case let .identified(display):
      candidates.append(display.geometry)
    case let .unidentified(geometry):
      candidates.append(geometry)
    case .unresolved, .unknown:
      break
    }
    candidates += displayConfiguration.displays.map(\.geometry)
    let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    return candidates.first { $0.surfacePixelSize == size }?.rotation ?? .upright
  }

  private func mount(_ buffer: CVPixelBuffer, attributes: [String: Any], consumer: any DataConsumer) throws {
    if frameWriters == nil {
      frameWriters = configuration.format.frameWriters()
    }
    let rotation = interfaceRotation(of: buffer)
    let source = VideoFrameSource(buffer).rotated(rotation)
    let canvas: VideoFrameSource
    let framePusher: any FramePusher
    if case let .fixed(fixed) = canvasPolicy, let mounted = self.framePusher {
      canvas = fixed
      framePusher = mounted
    } else if let spare = spareFramePushers.take(source) {
      canvas = source
      framePusher = spare
      logger.log("Mounting with the frame pusher prepared for a \(source) surface")
    } else {
      canvas = source
      framePusher = try newFramePusher(consumer: consumer)
      try framePusher.setup(source: canvas, edgeInsets: edgeInsets)
    }

    // Published only once every throwing step is past, so a mount is all-or-nothing: a failed one
    // leaves the previous surface installed rather than a new `pixelBuffer` behind a pusher never
    // set up for it.
    let previousFramePusher = self.framePusher
    let previousSource = mountedSource
    self.pixelBuffer = buffer
    self.pixelBufferAttributes = attributes
    presentedSurfaceSeed = mountedSurfaceSeed
    self.framePusher = framePusher
    self.mountedSource = source
    if case .fixedAtFirstMount = canvasPolicy {
      canvasPolicy = .fixed(canvas)
    }
    // Torn down or kept after the new pusher is published so a swap never leaves the stream without
    // a working pusher, and a teardown failure cannot fail an otherwise good mount.
    if let previousFramePusher, previousFramePusher !== framePusher {
      if preparesForDisplaySwitches, let previousSource, previousSource != source {
        previousFramePusher.completeFrames()
        if let displaced = spareFramePushers.keep(previousFramePusher, for: previousSource) {
          tearDown(displaced, after: "being replaced by the previous one")
        }
      } else {
        tearDown(previousFramePusher, after: "a surface swap")
      }
    }
    // Resolve the timed-metadata (chapter) sink. A recording file writer that supports chapters
    // supplies its own consumer; otherwise the streaming transport writer (fMP4 emsg / MPEG-TS ID3)
    // handles markers, dropping them on transports with no metadata channel.
    if let recordingMetadata = encodedSampleConsumerOverride {
      self.timedMetadataConsumer = recordingMetadata
    } else if case .compressedVideo = configuration.format {
      self.timedMetadataConsumer = TransportTimedMetadataConsumer(consumer: consumer, timedMetadataWriter: frameWriters?.timedMetadataWriter)
    }

    compositor.configure(
      sourceWidth: CVPixelBufferGetWidth(buffer), sourceHeight: CVPixelBufferGetHeight(buffer), rotation: rotation, canvas: canvas,
      scaleFactor: configuration.scaleFactor)
    layOutOverlay()
    let insets = edgeInsets
    if insets.top + insets.bottom + insets.left + insets.right > 0 {
      logger.info().log("Composited pool includes edge insets (t=\(insets.top) b=\(insets.bottom) l=\(insets.left) r=\(insets.right)): w=\(compositor.outputWidth)/h=\(compositor.outputHeight)")
    }

    // The first mount transitions `.starting` → `.streaming`, resuming anyone awaiting it. A
    // re-mount (surface swap) is already `.streaming` and transitions nothing.
    if case .starting(let session, let awaiters) = lifecycle {
      lifecycle = .streaming(session)
      for awaiter in awaiters {
        awaiter.resume()
      }
    }

    // Started once; a surface re-mount just swaps `pixelBuffer` for the running loop. The task holds the
    // stream weakly: a strong capture would make task and actor keep each other alive, so a stream dropped
    // without `stopStreaming` would push forever and `deinit` could never run.
    guard framePusherTask == nil else { return }
    switch cadence {
    case let .eager(framesPerSecond):
      framePusherTask = Task { [weak self, logger] in
        let stats = CadenceStats(frameIntervalNanos: NSEC_PER_SEC / UInt64(framesPerSecond), logger: logger)
        await Self.runFramePushLoop(stimulus: FrameCadence(framesPerSecond: framesPerSecond), stats: stats) { self }
      }
    case .lazy:
      let triggers = LazyFrameTriggers()
      lazyTriggers = triggers
      framePusherTask = Task { [weak self] in
        await Self.runFramePushLoop(stimulus: triggers, stats: nil) { self }
      }
    }
  }

  func pushFrame(forceKeyFrame: Bool) {
    guard let pixelBuffer, let consumer, let framePusher else {
      return
    }
    if !consumer.hasCapacityForFrame(logger: logger) {
      return
    }

    // Uptime is monotonic; the wall clock steps under NTP and can hand the encoder (and a file
    // writer) a timestamp earlier than the previous frame's.
    let now = clock.uptime
    let frameNumber = self.frameNumber
    if frameNumber == 0 {
      timeAtFirstFrame = now
      // Read here, beside the monotonic one, because this is the only moment at which the wall
      // clock says when this frame was captured. A reading taken later has had time to be set.
      wallClockAtFirstFrame = clock.wallClock
      hostTimeAtFirstFrame = clock.hostTime
    }
    let timeAtFirstFrame = self.timeAtFirstFrame
    let frameDuration = timeAtLastPush > 0 ? (now - timeAtLastPush) : 0
    timeAtLastPush = now

    // The simulator's render server writes into the mounted surface; the lock is advisory, so the
    // seed is compared across the read to count frames it wrote into anyway. Every read of the
    // source happens inside this window — the overlay composite and the pusher's colour conversion —
    // and nothing after it touches the source.
    let sourceSurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
    let seedBefore = sourceSurface.map { IOSurfaceGetSeed($0) }
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)

    do {
      try framePusher.writeEncodedFrame(
        compositor.composite(pixelBuffer),
        frameNumber: frameNumber,
        timeAtFirstFrame: timeAtFirstFrame,
        frameDuration: frameDuration,
        forceKeyFrame: forceKeyFrame)
    } catch {
      logger.log("Failed to submit frame \(frameNumber) for encoding: \(error)")
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    if let sourceSurface, let seedBefore, IOSurfaceGetSeed(sourceSurface) != seedBefore {
      framePusher.recordTornFrame()
    }

    self.frameNumber = frameNumber + 1
  }

  /// Lays overlays out on the current canvas from now on, as it changes with rotations and switches between
  /// displays of different sizes.
  public nonisolated func setOverlayLayout(_ layout: OverlayRenderer) {
    overlayLayout.withLock { $0 = layout }
    Task { await self.layOutOverlay() }
  }

  private func layOutOverlay() {
    guard let layout = overlayLayout.withLock({ $0 }), let mountedSource, let canvas else {
      return
    }
    let buffer = layout.layOut(
      screenPixelWidth: mountedSource.width, screenPixelHeight: mountedSource.height, canvasPixelWidth: canvas.width,
      canvasPixelHeight: canvas.height)
    overlaySize = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
    updateOverlayBuffer(buffer)
  }

  // MARK: - Frame Pusher

  private func newFramePusher(consumer: any DataConsumer) throws -> any FramePusher {
    return try Self.framePusher(
      configuration: configuration,
      cadence: cadence,
      consumer: consumer,
      encodedSampleConsumerOverride: encodedSampleConsumerOverride,
      frameWriters: frameWriters,
      logger: logger)
  }

  /// The displaced pusher's VideoToolbox sessions are only released deterministically by `tearDown`; releasing
  /// the reference alone can leave them alive with encodes in flight into the same consumer.
  private func tearDown(_ framePusher: any FramePusher, after reason: String) {
    do {
      try framePusher.tearDown()
      logger.log("Tore down a frame pusher after \(reason)")
    } catch {
      logger.log("Failed to tear down a frame pusher after \(reason): \(error)")
    }
  }

  /// Sets up and warms a pusher for each surface size of the integrated displays a stream may switch to, so a
  /// switch does not start an encoder. Only once a configuration has several sizes, and once a surface is mounted,
  /// as a pusher needs the consumer. Warming waits for one encode per size. A recording keeps its one pusher.
  private func prepareSpareFramePushers() {
    guard case .followsSurface = canvasPolicy, let displayConfiguration, let consumer, let mounted = mountedSource else {
      return
    }
    var displays = displayConfiguration.displays.filter(\.isIntegrated)
    if case let .transitioning(incoming?) = displayConfiguration.phase {
      displays.append(incoming)
    }
    // A simulator's framebuffer surfaces are BGRA; a surface in another format is not a spare's source, so its
    // mount sets up a pusher of its own.
    let sources = Set(displays.compactMap { VideoFrameSource($0.geometry.surfacePixelSize, pixelFormat: kCVPixelFormatType_32BGRA)?.rotated($0.rotation) })
    guard sources.count > 1 else {
      return
    }
    preparesForDisplaySwitches = true
    for source in sources where source != mounted && !spareFramePushers.contains(source) {
      do {
        let framePusher = try newFramePusher(consumer: consumer)
        try framePusher.setup(source: source, edgeInsets: edgeInsets)
        try framePusher.warm(with: try Self.blankPixelBuffer(source))
        if let displaced = spareFramePushers.keep(framePusher, for: source) {
          tearDown(displaced, after: "being replaced by a prepared one")
        }
        logger.log("Prepared a frame pusher for a \(source) surface")
      } catch {
        logger.log("Failed to prepare a frame pusher for a \(source) surface: \(error)")
      }
    }
  }

  private static func blankPixelBuffer(_ source: VideoFrameSource) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    let status = CVPixelBufferCreate(nil, source.width, source.height, source.pixelFormat, attributes as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else {
      throw SimulatorVideoStreamError.failedToCreatePixelBufferFromSurface(status: status)
    }
    return buffer
  }

  static func framePusher(
    configuration: VideoStreamConfiguration,
    cadence: VideoStreamCadence,
    consumer: any DataConsumer,
    encodedSampleConsumerOverride: (any EncodedSampleConsumer)?,
    frameWriters: VideoStreamFrameWriters?,
    logger: any ControlCoreLogger
  ) throws -> any FramePusher {
    let videoCodec: CMVideoCodecType
    switch configuration.format {
    case let .compressedVideo(codec, _):
      videoCodec = codec.videoToolboxCodec
    case .mjpeg, .minicap:
      videoCodec = kCMVideoCodecType_JPEG
    case .bgra:
      return BitmapFramePusher(consumer: consumer, scaleFactor: configuration.scaleFactor)
    }
    let frameWriter = (frameWriters ?? configuration.format.frameWriters()).frameWriter
    return VideoToolboxFramePusher(
      settings: VideoToolboxEncoderSettings(
        configuration: configuration, cadence: cadence, sink: encodedSampleConsumerOverride == nil ? .live : .file),
      scaleFactor: configuration.scaleFactor,
      videoCodec: videoCodec,
      encodedSampleConsumer: encodedSampleConsumerOverride ?? DataConsumerEncodedSampleConsumer(consumer: consumer, frameWriter: frameWriter),
      logger: logger)
  }

  /// Write a timed metadata marker (chapter) at the current stream position. Routed to the
  /// `TimedMetadataConsumer` resolved in `mountSurface` — the streaming transport writer
  /// (MPEG-TS ID3 / fMP4 emsg) or, when recording, the file writer's chapter track. A no-op before the
  /// surface is mounted, after the stream stops, or for formats without a metadata channel.
  public func writeTimedMetadata(_ text: String) {
    timedMetadataConsumer?.writeTimedMetadata(text, logger: logger)
  }

  // MARK: - Overlay

  /// Update the overlay buffer and push a frame to encode the change.
  /// Pass nil to clear the overlay.
  ///
  /// In lazy/VFR mode: signals the push loop so the change is encoded promptly. Swapping the buffer
  /// in or out forces a keyframe so consumers that need one to start rendering (e.g. ffplay) see the
  /// change whole; an in-place content update pushes a plain frame — those arrive at the overlay
  /// effect timer's animation cadence (~30fps), and forcing an IDR for each turns the entire stream
  /// into keyframes, starving the motion budget.
  /// In eager/CFR mode: no extra push — the next cadence tick picks up the change without disrupting frame timing.
  public func updateOverlayBuffer(_ overlayBuffer: CVPixelBuffer?) {
    if let overlayBuffer, let overlaySize, CVPixelBufferGetWidth(overlayBuffer) != overlaySize.width || CVPixelBufferGetHeight(overlayBuffer) != overlaySize.height {
      logger.log("Ignoring an overlay laid out for an earlier canvas")
      return
    }
    let sameReference = (overlayBuffer === compositor.overlayBuffer)
    if !sameReference {
      compositor.overlayBuffer = overlayBuffer
    }

    let stateDescription = overlayBuffer != nil ? (sameReference ? "contents updated" : "buffer swapped") : "cleared"
    logger.log("Overlay \(stateDescription) (frame=\(frameNumber))")

    switch cadence {
    case .lazy:
      if sameReference {
        lazyTriggers?.signalOverlayChanged()
      } else {
        lazyTriggers?.signalKeyFrame()
      }
    case .eager:
      break
    }
  }

  /// Request that the next encoded frame be a keyframe (IDR).
  /// Schedules an extra push on the actor with the VideoToolbox
  /// `kVTEncodeFrameOptionKey_ForceKeyFrame` flag set, so a downstream consumer
  /// that has lost frames (e.g. a WebRTC viewer that has sent a PLI/FIR) can
  /// resync immediately instead of waiting for the next periodic IDR.
  ///
  /// `nonisolated` fire-and-forget: safe to call from any thread. A burst of calls produces a burst
  /// of keyframes — callers are expected to throttle if needed.
  public nonisolated func requestKeyFrame() {
    Task { [weak self] in
      await self?.pushFrame(forceKeyFrame: true)
    }
  }

  // MARK: - Screenshot

  /// Capture a PNG screenshot of the current frame with overlay composited. While a recording letterboxes its screen,
  /// the screenshot is the screen at its own size and orientation, with the overlay laid out for it.
  public func captureCompositedScreenshot() throws -> Data {
    guard let sourceBuffer = pixelBuffer else {
      throw SimulatorVideoStreamError.noPixelBufferForScreenshot
    }
    var screenOverlay: CVPixelBuffer?
    if compositor.letterboxes, compositor.overlayBuffer != nil, let layout = overlayLayout.withLock({ $0 }), let mountedSource {
      screenOverlay = layout.snapshot(screenPixelWidth: mountedSource.width, screenPixelHeight: mountedSource.height)
    }
    return try compositor.screenshotPNG(of: sourceBuffer, screenOverlay: screenOverlay)
  }

  // MARK: - Stats

  /// Returns a snapshot of the current video encoder stats.
  /// Returns a zeroed struct if the stream uses a non-encoded format (e.g. bitmap/BGRA).
  public func currentEncoderStats() -> VideoEncoderStats {
    if let pusher = framePusher, let stats = pusher.currentStats() {
      return stats
    }
    return VideoEncoderStats()
  }

  /// Returns a snapshot of the current framebuffer stats (from the underlying Framebuffer).
  /// `nonisolated`: reads only the immutable `framebuffer` reference, whose stats are lock-guarded.
  public nonisolated func currentFramebufferStats() -> FramebufferStats {
    framebuffer.currentStats()
  }

  /// The Unix timestamp of media time zero, for a file anchored `anchor` seconds after the first
  /// pushed frame, or nil before a frame was pushed. Worked out from the wall clock as it read when
  /// that frame was pushed, so the answer is unchanged by how long the recording ran and by the
  /// clock being set since.
  func mediaOrigin(anchor: TimeInterval) -> TimeInterval? {
    guard timeAtFirstFrame > 0 else {
      return nil
    }
    return MediaOrigin(wallClockAtFirstFrame: wallClockAtFirstFrame).startedAt(anchor: anchor)
  }

  /// Media time zero on the host clock, in `mach_absolute_time` ticks, for a file anchored `anchor`
  /// seconds after the first pushed frame, or nil before a frame was pushed.
  func mediaOriginHostTime(anchor: TimeInterval) -> UInt64? {
    guard timeAtFirstFrame > 0 else {
      return nil
    }
    return MediaOrigin(wallClockAtFirstFrame: wallClockAtFirstFrame, hostTimeAtFirstFrame: hostTimeAtFirstFrame)
      .startHostTime(anchor: anchor)
  }

  /// Wall-clock time when the first framebuffer callback was received, or 0 if not yet started.
  /// `nonisolated`: reads only the immutable `framebuffer` reference.
  public nonisolated var framebufferStatsStartTime: ContinuousClock.Instant? { framebuffer.statsStartTime }

  // MARK: - VideoStreamOperation

  public func awaitCompletion() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        if case .stopped = lifecycle {
          continuation.resume()
          return
        }
        stopAwaiters[id] = continuation
      }
    } onCancel: {
      // Cancelling a completion await stops the stream (mirrors a cancellable completion signal).
      Task { [weak self] in await self?.completionAwaitCancelled(id) }
    }
  }

  /// Stop on behalf of a cancelled completion await, then resume that await regardless of whether
  /// the stop could proceed — a never-started stream has nothing to stop, but the cancelled awaiter
  /// must still return. A successful stop resumes every awaiter, so the removal here finds nothing.
  private func completionAwaitCancelled(_ id: UUID) async {
    try? await stopStreaming()
    if let continuation = stopAwaiters.removeValue(forKey: id) {
      continuation.resume()
    }
  }

  // MARK: - Cadence Loop

  /// The frame push loop shared by both cadences: for each trigger, push a frame and record it.
  ///
  /// Runs on the actor, so each push (and the state it mutates) is serialized with every other isolated
  /// method; the `for await` suspension between triggers lets events, accessors and stop interleave.
  /// Ends on task cancellation or when the stimulus finishes.
  // Concrete overloads rather than one generic loop: iterating a generic `AsyncSequence` from
  // actor-isolated code cannot prove the conformance nonisolated (SE-0470). Static and weakly-held so the
  // loop does not recreate the task↔stream retain cycle.
  private static func runFramePushLoop(stimulus: LazyFrameTriggers, stats: CadenceStats?, stream: () -> SimulatorVideoStream?) async {
    var stats = stats
    for await trigger in stimulus {
      guard !Task.isCancelled else { break }
      guard let stream = stream() else { break }
      if let pushDurationMach = await stream.pushTriggered(trigger) {
        stats?.record(pushDurationMach: pushDurationMach, overran: trigger.overran)
      }
    }
  }

  private static func runFramePushLoop(stimulus: FrameCadence, stats: CadenceStats?, stream: () -> SimulatorVideoStream?) async {
    var stats = stats
    for await trigger in stimulus {
      guard !Task.isCancelled else { break }
      guard let stream = stream() else { break }
      if let pushDurationMach = await stream.pushTriggered(trigger) {
        stats?.record(pushDurationMach: pushDurationMach, overran: trigger.overran)
      }
    }
  }

  /// One trigger's worth of work, shared by both cadence loops: push a frame, returning the push
  /// duration in Mach ticks for the caller's cadence statistics, or nil when an overlay-only push is
  /// held back until the Simulator presents the frame it drew
  func pushTriggered(_ trigger: FrameTrigger) -> UInt64? {
    // The Simulator has drawn into the surface without presenting the frame yet. That frame's rendered event pushes it
    // with the overlay change included.
    if trigger.overlayOnly, mountedSurfaceSeed != presentedSurfaceSeed {
      keyFrameHeldBack = keyFrameHeldBack || trigger.forceKeyFrame
      return nil
    }
    let beforePush = mach_absolute_time()
    pushFrame(forceKeyFrame: trigger.forceKeyFrame || keyFrameHeldBack)
    keyFrameHeldBack = false
    return mach_absolute_time() - beforePush
  }

  /// The mounted surface's modification seed, which moves on whenever anything writes into the surface
  private var mountedSurfaceSeed: UInt32? {
    pixelBuffer.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }.map(IOSurfaceGetSeed)
  }
}
