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
import Foundation
import IOSurface
import Testing
import os

/// One display surface that several framebuffers register with, as every `connect` of a simulator's
/// display does: each registration is kept under its own token, and a frame reaches every registration.
// SAFETY: the registrations are guarded by the lock.
// patternlint-disable-next-line unchecked-sendable
private final class SharedDisplaySurface: FramebufferSurface, @unchecked Sendable {
  private let lock = NSLock()
  private var frameCallbacks: [UUID: () -> Void] = [:]
  let surface = makeTestIOSurface()

  var registeredTokens: Set<UUID> {
    lock.withLock { Set(frameCallbacks.keys) }
  }

  func immediatelyAvailableSurface() -> IOSurface? {
    surface
  }

  func registerCallbacks(
    token: UUID,
    ioSurfaceChanged: @escaping (IOSurface?) -> Void,
    frameRendered: @escaping () -> Void,
    configurationChanged: @escaping (SimulatorDisplayConfiguration) -> Void
  ) throws {
    lock.withLock { frameCallbacks[token] = frameRendered }
  }

  func unregisterCallbacks(token: UUID) {
    _ = lock.withLock { frameCallbacks.removeValue(forKey: token) }
  }

  func renderFrame() {
    for callback in lock.withLock({ Array(frameCallbacks.values) }) {
      callback()
    }
  }
}

/// A stream of the shared display into a buffer of its own.
private struct Capture {
  let stream: SimulatorVideoStream
  let output: AccumulatingBuffer

  static func start(on display: SharedDisplaySurface) async throws -> Capture {
    let stream = SimulatorVideoStream(
      framebuffer: Framebuffer(surface: display, logger: CapturingLogger()),
      configuration: VideoStreamConfiguration(format: .bgra, framesPerSecond: nil, rateControl: nil, scaleFactor: nil, keyFrameRate: nil),
      edgeInsets: VideoStreamEdgeInsets(top: 0, bottom: 0, left: 0, right: 0),
      cadence: .lazy,
      logger: CapturingLogger(),
      clock: SystemVideoStreamClock())
    let output = AccumulatingBuffer()
    try await stream.startStreaming(output)
    return Capture(stream: stream, output: output)
  }

  var bytes: Int { output.data().count }
}

/// Renders frames until `capture` has written more than `bytes`, or fails after five seconds.
private func renderUntil(_ capture: Capture, writesMoreThan bytes: Int, on display: SharedDisplaySurface) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while capture.bytes <= bytes {
    guard ContinuousClock.now < deadline else {
      Issue.record("no frame reached the stream within five seconds")
      return
    }
    display.renderFrame()
    try await Task.sleep(for: .milliseconds(10))
  }
}

@Suite("Concurrent streams of one display are isolated")
struct SimulatorVideoStreamIsolationTests {

  /// Stops one of two streams of the same display, then renders more frames: the stopped one writes
  /// nothing more and is no longer registered, and the other keeps writing frames.
  private func stopOneAndRenderMore(stoppingTheFirst: Bool) async throws {
    let display = SharedDisplaySurface()
    let first = try await Capture.start(on: display)
    let second = try await Capture.start(on: display)
    #expect(display.registeredTokens.count == 2)
    try await renderUntil(first, writesMoreThan: 0, on: display)
    try await renderUntil(second, writesMoreThan: 0, on: display)

    let (stopped, running) = stoppingTheFirst ? (first, second) : (second, first)
    try await stopped.stream.stopStreaming()
    let stoppedBytes = stopped.bytes
    let runningBytes = running.bytes
    #expect(display.registeredTokens.count == 1)

    try await renderUntil(running, writesMoreThan: runningBytes, on: display)

    #expect(running.bytes > runningBytes, "the stream still running stopped receiving frames")
    #expect(stopped.bytes == stoppedBytes, "the stopped stream kept writing")
    try await running.stream.stopStreaming()
    #expect(display.registeredTokens.isEmpty)
  }

  @Test("Stopping the first stream leaves the second receiving frames")
  func stoppingTheFirstLeavesTheSecond() async throws {
    try await stopOneAndRenderMore(stoppingTheFirst: true)
  }

  @Test("Stopping the second stream leaves the first receiving frames")
  func stoppingTheSecondLeavesTheFirst() async throws {
    try await stopOneAndRenderMore(stoppingTheFirst: false)
  }

  @Test("Cancelling one attachment leaves the other's registration and events")
  func cancellingOneAttachmentLeavesTheOther() async throws {
    let display = SharedDisplaySurface()
    let first = try Framebuffer(surface: display, logger: CapturingLogger()).attach()
    let second = try Framebuffer(surface: display, logger: CapturingLogger()).attach()
    let frames = OSAllocatedUnfairLock(initialState: 0)
    let reader = Task {
      for await event in second.events {
        if case .frameRendered = event { frames.withLock { $0 += 1 } }
      }
    }

    first.cancel()
    first.cancel()
    #expect(display.registeredTokens.count == 1)

    let deadline = ContinuousClock.now + .seconds(5)
    while frames.withLock({ $0 }) == 0 && ContinuousClock.now < deadline {
      display.renderFrame()
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(frames.withLock { $0 } > 0, "the remaining attachment received no frame")
    second.cancel()
    await reader.value
    #expect(display.registeredTokens.isEmpty)
  }

  @Test("A start waiting for a surface ends when its task is cancelled")
  func aStartWaitingForASurfaceEndsWhenCancelled() async throws {
    let surface = FakeFramebufferSurface()
    let stream = SimulatorVideoStream(
      framebuffer: Framebuffer(surface: surface, logger: CapturingLogger()),
      configuration: VideoStreamConfiguration(format: .bgra, framesPerSecond: nil, rateControl: nil, scaleFactor: nil, keyFrameRate: nil),
      edgeInsets: VideoStreamEdgeInsets(top: 0, bottom: 0, left: 0, right: 0),
      cadence: .lazy,
      logger: CapturingLogger(),
      clock: SystemVideoStreamClock())
    let outcome = OSAllocatedUnfairLock<Result<Void, any Error>?>(initialState: nil)
    let start = Task {
      do {
        try await stream.startStreaming(AccumulatingBuffer())
        outcome.withLock { $0 = .success(()) }
      } catch {
        outcome.withLock { $0 = .failure(error) }
      }
    }
    // Cancelled once it has registered and suspended waiting for a surface, so the cancellation
    // handler, not the check before suspending, ends it.
    let deadline = ContinuousClock.now + .seconds(5)
    while surface.registeredTokens.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(surface.registeredTokens.count == 1, "the start never registered")
    #expect(outcome.withLock { $0 } == nil, "the start ended before it was cancelled")

    start.cancel()
    while outcome.withLock({ $0 }) == nil && ContinuousClock.now < deadline + .seconds(5) {
      try await Task.sleep(for: .milliseconds(10))
    }

    guard case .failure(let error)? = outcome.withLock({ $0 }) else {
      Issue.record("the cancelled start did not end with an error: \(String(describing: outcome.withLock { $0 }))")
      return
    }
    #expect(error is CancellationError)
    #expect(surface.unregisteredTokens == surface.registeredTokens, "the cancelled start kept its registration")
  }
}
