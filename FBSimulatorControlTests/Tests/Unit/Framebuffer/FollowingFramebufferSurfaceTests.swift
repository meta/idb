/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import Foundation
import IOSurface
import XCTest

final class FollowingFramebufferSurfaceTests: XCTestCase {

  private struct LocateFailure: Error {}

  private func display(_ id: String) -> SimulatorDisplay {
    SimulatorDisplay(
      uniqueID: id, name: id, activity: .active, isPrimary: false, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: .upright)
  }

  private func configuration(active: String, phase: SimulatorDisplayConfiguration.Phase = .settled) -> SimulatorDisplayConfiguration {
    SimulatorDisplayConfiguration(generation: 1, displays: [display(active)], active: .identified(display(active)), phase: phase)
  }

  private func surface(
    _ screens: [String: FakeFramebufferSurface], configurations: AsyncStream<SimulatorDisplayConfiguration>, movement: FollowingFramebufferSurface.Movement = .followsActiveDisplay,
    failing: Set<String> = []
  ) -> FollowingFramebufferSurface {
    let locations = LockedCount()
    let located = FramebufferScreensDouble(screens: screens)
    return FollowingFramebufferSurface(
      displayUniqueID: "cover", surface: screens["cover"]!, movement: movement,
      configurations: { configurations },
      locate: { uniqueID in
        locations.increment()
        guard !failing.contains(uniqueID) || locations.value > 1, let screen = located.screens[uniqueID] else { throw LocateFailure() }
        return screen
      },
      logger: CapturingLogger())
  }

  private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date(timeIntervalSinceNow: 5)
    while !condition() {
      guard deadline.timeIntervalSinceNow > 0 else { return XCTFail("condition never held", file: file, line: line) }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  func testMovingToAnotherDisplayReRegistersOnItsScreenAndReportsItsSurface() async throws {
    let cover = FakeFramebufferSurface()
    let inner = FakeFramebufferSurface()
    inner.immediateSurface = makeTestIOSurface(width: 20, height: 30)
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let following = surface(["cover": cover, "inner": inner], configurations: configurations)
    let token = UUID()
    var reported: [IOSurface?] = []
    try following.registerCallbacks(token: token, ioSurfaceChanged: { reported.append($0) }, frameRendered: {}, configurationChanged: { _ in })

    continuation.yield(configuration(active: "inner"))
    try await waitUntil { !inner.registeredTokens.isEmpty }

    XCTAssertEqual(inner.registeredTokens, [token])
    XCTAssertEqual(cover.unregisteredTokens, [token])
    XCTAssertEqual(reported.map { $0.map(IOSurfaceGetID) }, [inner.immediateSurface.map(IOSurfaceGetID)])
    XCTAssertTrue(following.immediatelyAvailableSurface() === inner.immediateSurface)
  }

  func testIdentifyingTheScreenAlreadyFollowedKeepsItsFramesFlowing() async throws {
    let main = KeyedFramebufferSurface()
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let following = FollowingFramebufferSurface(
      displayUniqueID: nil, surface: main, movement: .followsActiveDisplay,
      configurations: { configurations }, locate: { _ in main }, logger: CapturingLogger())
    let frames = LockedCount()
    let moves = LockedCount()
    try following.registerCallbacks(token: UUID(), ioSurfaceChanged: { _ in moves.increment() }, frameRendered: { frames.increment() }, configurationChanged: { _ in })

    continuation.yield(configuration(active: "main"))
    try await waitUntil { moves.value == 1 }
    main.renderFrame()

    XCTAssertEqual(frames.value, 1)
  }

  func testAMoveThatCannotRegisterKeepsTheCurrentScreenDelivering() async throws {
    let cover = FakeFramebufferSurface()
    cover.immediateSurface = makeTestIOSurface()
    let inner = FakeFramebufferSurface()
    inner.registerError = LocateFailure()
    let logger = CapturingLogger()
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let screens = FramebufferScreensDouble(screens: ["inner": inner])
    let following = FollowingFramebufferSurface(
      displayUniqueID: "cover", surface: cover, movement: .followsActiveDisplay,
      configurations: { configurations }, locate: { _ in try await screens.screen(uniqueID: "inner") }, logger: logger)
    let frames = LockedCount()
    try following.registerCallbacks(token: UUID(), ioSurfaceChanged: { _ in }, frameRendered: { frames.increment() }, configurationChanged: { _ in })

    continuation.yield(configuration(active: "inner"))
    try await waitUntil { ((logger.messages.copy() as? [String]) ?? []).contains { $0.hasPrefix("Framebuffer: staying on display cover") } }
    cover.frameRendered?()

    XCTAssertEqual(frames.value, 1)
    XCTAssertTrue(following.immediatelyAvailableSurface() === cover.immediateSurface)
  }

  func testAMoveThatCannotRestoreTheCurrentScreenReportsItLost() async throws {
    let cover = FakeFramebufferSurface()
    let inner = FakeFramebufferSurface()
    inner.registerError = LocateFailure()
    let logger = CapturingLogger()
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let screens = FramebufferScreensDouble(screens: ["inner": inner])
    let following = FollowingFramebufferSurface(
      displayUniqueID: "cover", surface: cover, movement: .followsActiveDisplay,
      configurations: { configurations }, locate: { _ in try await screens.screen(uniqueID: "inner") }, logger: logger)
    try following.registerCallbacks(token: UUID(), ioSurfaceChanged: { _ in }, frameRendered: {}, configurationChanged: { _ in })
    cover.registerError = LocateFailure()
    let messages = { (logger.messages.copy() as? [String]) ?? [] }

    continuation.yield(configuration(active: "inner"))
    try await waitUntil { !messages().isEmpty }

    XCTAssertEqual(messages().count, 1)
    XCTAssertTrue(messages()[0].hasPrefix("Framebuffer: lost display cover"), messages()[0])
  }

  func testAConsumerCanUseTheSurfaceWhenToldOfAMove() async throws {
    let cover = FakeFramebufferSurface()
    let inner = FakeFramebufferSurface()
    inner.immediateSurface = makeTestIOSurface(width: 20, height: 30)
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let following = surface(["cover": cover, "inner": inner], configurations: configurations)
    let token = UUID()
    let seen = LockedCount()
    try following.registerCallbacks(
      token: token,
      ioSurfaceChanged: { _ in
        _ = following.immediatelyAvailableSurface()
        following.unregisterCallbacks(token: token)
        seen.increment()
      },
      frameRendered: {}, configurationChanged: { _ in })

    continuation.yield(configuration(active: "inner"))
    try await waitUntil { seen.value == 1 }

    XCTAssertEqual(inner.unregisteredTokens, [token])
  }

  func testTheLeftScreenNoLongerReachesConsumers() async throws {
    let cover = FakeFramebufferSurface()
    let inner = FakeFramebufferSurface()
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let following = surface(["cover": cover, "inner": inner], configurations: configurations)
    var frames = 0
    var surfaces = 0
    try following.registerCallbacks(token: UUID(), ioSurfaceChanged: { _ in surfaces += 1 }, frameRendered: { frames += 1 }, configurationChanged: { _ in })
    let coverFrame = try XCTUnwrap(cover.frameRendered)
    let coverSurface = try XCTUnwrap(cover.ioSurfaceChanged)

    continuation.yield(configuration(active: "inner"))
    try await waitUntil { !inner.registeredTokens.isEmpty }
    coverFrame()
    coverSurface(makeTestIOSurface())
    inner.frameRendered?()

    XCTAssertEqual(frames, 1)
    XCTAssertEqual(surfaces, 1)
  }

  func testTheFollowedDisplayReportedAgainKeepsItsScreen() async throws {
    let cover = FakeFramebufferSurface()
    let inner = FakeFramebufferSurface()
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let following = surface(["cover": cover, "inner": inner], configurations: configurations)
    try following.registerCallbacks(token: UUID(), ioSurfaceChanged: { _ in }, frameRendered: {}, configurationChanged: { _ in })

    continuation.yield(configuration(active: "cover"))
    continuation.yield(configuration(active: "inner"))
    try await waitUntil { !inner.registeredTokens.isEmpty }

    XCTAssertEqual(cover.registeredTokens.count, 1)
    XCTAssertEqual(cover.unregisteredTokens.count, 1)
  }

  func testADisplayThatCannotBeCapturedLeavesTheCurrentOneUntilALaterUpdate() async throws {
    let cover = FakeFramebufferSurface()
    let inner = FakeFramebufferSurface()
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let following = surface(["cover": cover, "inner": inner], configurations: configurations, failing: ["inner"])
    try following.registerCallbacks(token: UUID(), ioSurfaceChanged: { _ in }, frameRendered: {}, configurationChanged: { _ in })

    continuation.yield(configuration(active: "inner"))
    continuation.yield(configuration(active: "inner"))
    try await waitUntil { !inner.registeredTokens.isEmpty }

    XCTAssertEqual(inner.registeredTokens.count, 1)
    XCTAssertEqual(cover.unregisteredTokens.count, 1)
  }

  func testAConsumerRegisteringLateIsToldTheCurrentConfiguration() async throws {
    let cover = FakeFramebufferSurface()
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let following = surface(["cover": cover], configurations: configurations)
    var first: [SimulatorDisplayConfiguration] = []
    try following.registerCallbacks(
      token: UUID(), ioSurfaceChanged: { _ in }, frameRendered: {}, configurationChanged: { first.append($0) })
    continuation.yield(configuration(active: "cover"))
    try await waitUntil { !first.isEmpty }

    var late: [SimulatorDisplayConfiguration] = []
    try following.registerCallbacks(token: UUID(), ioSurfaceChanged: { _ in }, frameRendered: {}, configurationChanged: { late.append($0) })

    XCTAssertEqual(late, [configuration(active: "cover")])
  }

  func testATransitionIsAnnouncedWithoutMovingUntilItSettles() async throws {
    let cover = FakeFramebufferSurface()
    let inner = FakeFramebufferSurface()
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let following = surface(["cover": cover, "inner": inner], configurations: configurations)
    let token = UUID()
    var phases: [SimulatorDisplayConfiguration.Phase] = []
    var registeredDuringTransition: Int?
    try following.registerCallbacks(
      token: token, ioSurfaceChanged: { _ in }, frameRendered: {},
      configurationChanged: {
        phases.append($0.phase)
        if $0.phase == .settled { registeredDuringTransition = inner.registeredTokens.count }
      })

    continuation.yield(configuration(active: "inner", phase: .transitioning(incoming: nil)))
    continuation.yield(configuration(active: "inner"))
    try await waitUntil { !inner.registeredTokens.isEmpty }

    XCTAssertEqual(phases, [.transitioning(incoming: nil), .settled])
    XCTAssertEqual(registeredDuringTransition, 0)
  }

  func testAFollowingSurfaceDuringATransitionNamingItsIncomingDisplay() async throws {
    let cover = FakeFramebufferSurface()
    let inner = FakeFramebufferSurface()
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let following = surface(["cover": cover, "inner": inner], configurations: configurations)
    var registeredWhenSettled: Int?
    try following.registerCallbacks(
      token: UUID(), ioSurfaceChanged: { _ in }, frameRendered: {},
      configurationChanged: { if $0.phase == .settled { registeredWhenSettled = inner.registeredTokens.count } })

    continuation.yield(configuration(active: "cover", phase: .transitioning(incoming: display("inner"))))
    continuation.yield(configuration(active: "inner"))
    // The surface registers on the named incoming display while the transition is still under way, so that
    // registration can land before the settled configuration is announced: wait for the announcement instead.
    try await waitUntil { registeredWhenSettled != nil }

    XCTAssertEqual(registeredWhenSettled, 1)
    XCTAssertEqual(inner.registeredTokens.count, 1)
  }

  func testASurfaceFixedToItsDisplayAnnouncesConfigurationsButNeverMoves() async throws {
    let cover = FakeFramebufferSurface()
    let inner = FakeFramebufferSurface()
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let following = surface(["cover": cover, "inner": inner], configurations: configurations, movement: .fixed)
    let token = UUID()
    let announced = LockedCount()
    try following.registerCallbacks(
      token: token, ioSurfaceChanged: { _ in }, frameRendered: {}, configurationChanged: { _ in announced.increment() })

    continuation.yield(configuration(active: "inner"))
    try await waitUntil { announced.value == 1 }

    XCTAssertEqual(inner.registeredTokens, [])
    XCTAssertEqual(cover.unregisteredTokens, [])
  }

  func testAnUnregisteredConsumerIsNoLongerToldOfConfigurations() async throws {
    let cover = FakeFramebufferSurface()
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let following = surface(["cover": cover], configurations: configurations)
    let leaving = UUID()
    let staying = UUID()
    var left: [SimulatorDisplayConfiguration] = []
    var stayed: [SimulatorDisplayConfiguration] = []
    try following.registerCallbacks(
      token: leaving, ioSurfaceChanged: { _ in }, frameRendered: {}, configurationChanged: { left.append($0) })
    try following.registerCallbacks(
      token: staying, ioSurfaceChanged: { _ in }, frameRendered: {}, configurationChanged: { stayed.append($0) })

    following.unregisterCallbacks(token: leaving)
    continuation.yield(configuration(active: "cover"))
    try await waitUntil { !stayed.isEmpty }

    XCTAssertEqual(left, [])
  }

  func testRemovingTheLastConsumerStopsFollowing() async throws {
    let cover = FakeFramebufferSurface()
    let (configurations, continuation) = AsyncStream.makeStream(of: SimulatorDisplayConfiguration.self)
    let stopped = LockedCount()
    continuation.onTermination = { _ in stopped.increment() }
    let following = surface(["cover": cover], configurations: configurations)
    let first = UUID()
    let second = UUID()
    try following.registerCallbacks(token: first, ioSurfaceChanged: { _ in }, frameRendered: {}, configurationChanged: { _ in })
    try following.registerCallbacks(token: second, ioSurfaceChanged: { _ in }, frameRendered: {}, configurationChanged: { _ in })

    following.unregisterCallbacks(token: first)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(stopped.value, 0)

    following.unregisterCallbacks(token: second)
    try await waitUntil { stopped.value == 1 }
    XCTAssertEqual(cover.unregisteredTokens, [first, second])
  }
}

/// A display surface that keeps one callback per token, as CoreSimulator's screens do: unregistering a token
/// removes whatever is registered under it.
private final class KeyedFramebufferSurface: FramebufferSurface, @unchecked Sendable {
  private let lock = NSLock()
  private var frameCallbacks: [UUID: () -> Void] = [:]
  func immediatelyAvailableSurface() -> IOSurface? { nil }

  func registerCallbacks(
    token: UUID,
    ioSurfaceChanged: @escaping (IOSurface?) -> Void,
    frameRendered: @escaping () -> Void,
    configurationChanged: @escaping (SimulatorDisplayConfiguration) -> Void
  ) throws {
    lock.withLock {
      frameCallbacks[token] = frameRendered
    }
  }

  func unregisterCallbacks(token: UUID) {
    lock.withLock { frameCallbacks[token] = nil }
  }

  func renderFrame() {
    lock.withLock { Array(frameCallbacks.values) }.forEach { $0() }
  }
}

private final class LockedCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int { lock.withLock { count } }

  func increment() { lock.withLock { count += 1 } }
}
