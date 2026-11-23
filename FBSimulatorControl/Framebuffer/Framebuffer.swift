/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import Foundation
@preconcurrency import IOSurface

/// Counters for framebuffer surface-change and frame-rendered callbacks, sampled for periodic
/// logging. There is no rect geometry: the underlying CoreSimulator callback is a per-frame change
/// signal only (see `FramebufferSurface`), so a frame-rendered callback carries no dimensions.
public struct FramebufferStats: Sendable {
  public var frameRenderedCount: UInt = 0
  var ioSurfaceChangeCount: UInt = 0

  public init() {}
}

/// Errors surfaced by `Framebuffer`.
public enum FramebufferError: Error, LocalizedError {
  /// No renderable main-display surface could be located for the simulator.
  case mainScreenSurfaceNotFound(description: String)
  /// The surface-change or frame-rendered callbacks could not be registered on the display surface.
  case surfaceCallbackRegistrationFailed(underlying: (any Error)?)

  public var errorDescription: String? {
    switch self {
    case let .mainScreenSurfaceNotFound(description):
      return description
    case let .surfaceCallbackRegistrationFailed(underlying):
      if let underlying {
        return "Failed to register framebuffer surface callbacks: \(underlying)"
      }
      return "Failed to register framebuffer surface callbacks"
    }
  }
}

/// A single framebuffer occurrence, delivered in the order the display surface reported it. One
/// stream carries both kinds so that a surface swap can never be observed out of order with the
/// frame-rendered events around it.
public enum FramebufferEvent: Sendable {
  /// The display's backing IOSurface changed (nil when the display has no surface). Delivered only
  /// when the surface differs, by IOSurface ID, from the one the attachment last knew: the display
  /// re-reports its current surface right after registration, and the legacy path can report one
  /// swap through both the plural and singular callbacks. Neither reaches consumers.
  case surfaceChanged(IOSurface?)
  /// A new frame was rendered into the current surface. A bare per-frame signal — modern
  /// CoreSimulator reports no changed-region geometry (see `FramebufferSurface`).
  case frameRendered
  /// The simulator's displays are now in this configuration. Delivered first with the configuration at
  /// attachment, once it has been read, then for each change. A framebuffer following the active display
  /// delivers it ahead of the `surfaceChanged` that moves to the new display, so no frame of that display
  /// precedes it; frames of the outgoing display may arrive in between. Every framebuffer but the main
  /// screen's delivers it.
  case configurationChanged(SimulatorDisplayConfiguration)
  /// The framebuffer no longer captures what it was connected to, and delivers nothing more. A
  /// framebuffer bound to a display configuration ends with `SimulatorDisplayError.changed`, after the
  /// `configurationChanged` that replaced it.
  case ended(SimulatorDisplayError)
}

/// Tracks the surface an attachment last reported and refuses re-reports of it. Compared by
/// IOSurface ID rather than object identity because the proxy may vend a distinct wrapper object for
/// the same underlying surface.
private final class SurfaceChangeFilter: @unchecked Sendable {
  private let lock = NSLock()
  private var currentSurfaceID: IOSurfaceID?

  init(initialSurface: IOSurface?) {
    currentSurfaceID = initialSurface.map { IOSurfaceGetID($0) }
  }

  /// True if `surface` differs from the last admitted one, recording it as current when it does.
  func admit(_ surface: IOSurface?) -> Bool {
    let surfaceID = surface.map { IOSurfaceGetID($0) }
    lock.lock()
    defer { lock.unlock() }
    if surfaceID == currentSurfaceID {
      return false
    }
    currentSurfaceID = surfaceID
    return true
  }
}

/// The configuration a display surface reported most recently, read once registration returns: a surface that
/// knows its configuration reports it while registering.
private final class LatestConfiguration: @unchecked Sendable {
  private let lock = NSLock()
  private var configuration: SimulatorDisplayConfiguration?

  var value: SimulatorDisplayConfiguration? {
    lock.withLock { configuration }
  }

  func record(_ configuration: SimulatorDisplayConfiguration) {
    lock.withLock { self.configuration = configuration }
  }
}

public final class Framebuffer: @unchecked Sendable {

  private let surface: any FramebufferSurface
  private let boundGeneration: UInt64?
  private let statsRecorder: FramebufferStatsRecorder
  private let logger: any ControlCoreLogger

  public static func mainScreenSurface(for simulator: Simulator, logger: any ControlCoreLogger) throws -> Framebuffer {
    let surface = try FramebufferSurfaceLocator.mainDisplaySurface(for: simulator, logger: logger)
    return Framebuffer(surface: surface, logger: logger)
  }

  /// A framebuffer bound to `generation` ends once the display configuration moves on from it.
  init(surface: any FramebufferSurface, boundTo generation: UInt64? = nil, logger: any ControlCoreLogger) {
    self.surface = surface
    self.boundGeneration = generation
    self.statsRecorder = FramebufferStatsRecorder(logger: logger)
    self.logger = logger
  }

  /// Attach to the framebuffer, receiving events as an ordered `AsyncStream` on the returned
  /// attachment. The stream carries every event from the moment of attachment (events yielded before
  /// iteration begins are buffered, never dropped). The attachment owns the registration: `cancel()`,
  /// or releasing the handle, unregisters and finishes the stream.
  ///
  /// Consumers must keep per-event work O(1) and non-suspending — the stream is unbounded so that a
  /// surface swap can never be dropped; heavy per-frame work belongs on a decoupled cadence, not in
  /// the event loop.
  public func attach() throws -> FramebufferAttachment {
    try register()
  }

  fileprivate func detach(token: UUID) {
    surface.unregisterCallbacks(token: token)
  }

  // MARK: - Stats

  public func currentStats() -> FramebufferStats {
    statsRecorder.snapshot()
  }

  /// When the stats recorder saw its first frame, or nil before it.
  public var statsStartTime: ContinuousClock.Instant? {
    statsRecorder.startTime
  }

  /// Register with the display surface, producing an attachment whose event stream is fed directly
  /// from the surface callbacks. Events are yielded synchronously inside the callback (no thread
  /// hop) so the stream preserves the exact order the surface reported, across both event kinds.
  /// Surface re-reports are dropped here (see `FramebufferEvent.surfaceChanged`), seeded with the
  /// attach-time surface so its registration echo is the first thing filtered.
  private func register() throws -> FramebufferAttachment {
    let token = UUID()
    let immediateSurface = surface.immediatelyAvailableSurface()
    let filter = SurfaceChangeFilter(initialSurface: immediateSurface)
    let latestConfiguration = LatestConfiguration()

    let (events, continuation) = AsyncStream.makeStream(of: FramebufferEvent.self, bufferingPolicy: .unbounded)

    do {
      try register(token: token, filter: filter, latestConfiguration: latestConfiguration, continuation: continuation)
    } catch {
      surface.unregisterCallbacks(token: token)
      throw error
    }

    return FramebufferAttachment(
      framebuffer: self,
      token: token,
      initialSurface: immediateSurface,
      initialConfiguration: latestConfiguration.value,
      events: events,
      continuation: continuation)
  }

  private func register(
    token: UUID, filter: SurfaceChangeFilter, latestConfiguration: LatestConfiguration, continuation: AsyncStream<FramebufferEvent>.Continuation
  ) throws {
    try surface.registerCallbacks(
      token: token,
      ioSurfaceChanged: { [statsRecorder, logger] surface in
        statsRecorder.recordIOSurfaceChange(surface: surface)
        guard filter.admit(surface) else {
          logger.info().log("Framebuffer: ignoring surface change for the already-current surface \(surface.map { String(IOSurfaceGetID($0)) } ?? "nil")")
          return
        }
        continuation.yield(.surfaceChanged(surface))
      },
      frameRendered: { [statsRecorder] in
        statsRecorder.recordFrameRendered()
        continuation.yield(.frameRendered)
      },
      configurationChanged: { [boundGeneration] configuration in
        latestConfiguration.record(configuration)
        continuation.yield(.configurationChanged(configuration))
        guard let boundGeneration, configuration.generation != boundGeneration else { return }
        continuation.yield(.ended(.changed))
        continuation.finish()
      })
  }
}

/// The handle returned by `Framebuffer.attach`. Owns a single registration: cancelling (or
/// releasing) the handle unregisters from the display surface and finishes `events`.
public final class FramebufferAttachment: @unchecked Sendable {

  /// The surface available at attach time, if the framebuffer could vend one synchronously.
  public let initialSurface: IOSurface?

  /// The display configuration known at attach time, if the display surface reported one while registering. It is
  /// also the first `configurationChanged` in `events`.
  public let initialConfiguration: SimulatorDisplayConfiguration?

  /// Every framebuffer event since attachment, in the order the display surface reported them.
  /// Buffered without loss until iterated; finished by `cancel()`.
  public let events: AsyncStream<FramebufferEvent>

  private let token: UUID
  /// Strong on purpose: the registration outlives the `Framebuffer` that made it — the display
  /// surface holds the callbacks, not the framebuffer — so a weak reference here lets `cancel()`
  /// silently skip `detach` whenever the caller did not keep the framebuffer alive itself, leaving
  /// the surface calling into a finished stream. Nothing the framebuffer owns refers back to the
  /// attachment, so there is no cycle to break.
  private let framebuffer: Framebuffer
  private let continuation: AsyncStream<FramebufferEvent>.Continuation
  private let lock = NSLock()
  private var isCancelled = false

  init(
    framebuffer: Framebuffer,
    token: UUID,
    initialSurface: IOSurface?,
    initialConfiguration: SimulatorDisplayConfiguration?,
    events: AsyncStream<FramebufferEvent>,
    continuation: AsyncStream<FramebufferEvent>.Continuation
  ) {
    self.framebuffer = framebuffer
    self.token = token
    self.initialSurface = initialSurface
    self.initialConfiguration = initialConfiguration
    self.events = events
    self.continuation = continuation
  }

  /// Detach from the framebuffer and finish the event stream. Idempotent.
  public func cancel() {
    lock.lock()
    if isCancelled {
      lock.unlock()
      return
    }
    isCancelled = true
    lock.unlock()
    framebuffer.detach(token: token)
    continuation.finish()
  }

  deinit {
    cancel()
  }
}
