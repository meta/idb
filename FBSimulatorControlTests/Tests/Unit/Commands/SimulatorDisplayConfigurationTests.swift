/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorControl
import Foundation
import XCTest

final class SimulatorDisplayConfigurationTests: XCTestCase {
  private func display(
    _ id: String, _ activity: SimulatorDisplayActivity = .active, name: String? = nil, rotation: SimulatorDisplayRotation = .upright
  ) -> SimulatorDisplay {
    SimulatorDisplay(
      uniqueID: id, name: name ?? id, activity: activity, isPrimary: false, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: rotation)
  }

  private var cover: SimulatorDisplayReport { .displays([display("cover"), display("inner", .inactive)]) }
  private var inner: SimulatorDisplayReport { .displays([display("cover", .inactive), display("inner")]) }

  // MARK: - Generations

  func testRepeatedReportKeepsItsGeneration() throws {
    let tracker = DisplayConfigurationTracker()
    let first = try tracker.observe(cover)
    let second = try tracker.observe(cover)
    XCTAssertEqual(first, SimulatorDisplayConfiguration(generation: 1, displays: [display("cover"), display("inner", .inactive)], active: .identified(display("cover")), phase: .settled))
    XCTAssertEqual(second, first)
  }

  func testFoldTransitionsWithinTheOutgoingGenerationThenSettlesOnTheNext() throws {
    let tracker = DisplayConfigurationTracker()
    let before = try tracker.observe(cover)
    let transitioning = try tracker.observe(.transitioning(incoming: display("inner")))
    let after = try tracker.observe(inner)
    XCTAssertEqual(
      transitioning,
      SimulatorDisplayConfiguration(generation: 1, displays: before.displays, active: before.active, phase: .transitioning(incoming: display("inner"))))
    XCTAssertEqual(after.generation, 2)
    XCTAssertEqual(after.active, .identified(display("inner")))
    XCTAssertEqual(after.phase, .settled)
  }

  func testTransitionThatSettlesWhereItStartedKeepsItsGeneration() throws {
    let tracker = DisplayConfigurationTracker()
    _ = try tracker.observe(cover)
    _ = try tracker.observe(.transitioning(incoming: nil))
    XCTAssertEqual(try tracker.observe(cover).generation, 1)
  }

  func testInterfaceRotationAdvancesTheGeneration() throws {
    let tracker = DisplayConfigurationTracker()
    _ = try tracker.observe(.displays([display("lcd")]))
    let rotated = try tracker.observe(.displays([display("lcd", rotation: .clockwise)]))
    XCTAssertEqual(rotated.generation, 2)
    XCTAssertEqual(rotated.active, .identified(display("lcd", rotation: .clockwise)))
  }

  func testRenamedDisplayKeepsItsGeneration() throws {
    let tracker = DisplayConfigurationTracker()
    _ = try tracker.observe(.displays([display("lcd")]))
    let renamed = try tracker.observe(.displays([display("lcd", name: "LCD")]))
    XCTAssertEqual(renamed.generation, 1)
    XCTAssertEqual(renamed.displays, [display("lcd", name: "LCD")])
  }

  func testLegacyGeometryChangeAdvancesTheGeneration() throws {
    let tracker = DisplayConfigurationTracker()
    let upright = try tracker.observe(.legacy(integrated: [display("lcd").geometry]))
    let rotated = try tracker.observe(.legacy(integrated: [display("lcd", rotation: .clockwise).geometry]))
    XCTAssertEqual(upright, SimulatorDisplayConfiguration(generation: 1, displays: [], active: .unidentified(display("lcd").geometry), phase: .settled))
    XCTAssertEqual(rotated.generation, 2)
  }

  func testUnresolvableActiveDisplayIsSettledWithoutOne() throws {
    let tracker = DisplayConfigurationTracker()
    let configuration = try tracker.observe(.displays([display("cover", .inactive), display("inner", .inactive)]))
    XCTAssertEqual(configuration.active, .unresolved)
    XCTAssertEqual(configuration.displays.count, 2)
  }

  func testActiveDisplayIsTheIdentifiedOne() throws {
    let configuration = try DisplayConfigurationTracker().observe(cover)
    XCTAssertEqual(try configuration.activeDisplay(), display("cover"))
    XCTAssertEqual(try configuration.activeGeometry(), display("cover").geometry)
  }

  func testLegacyDisplayHasGeometryButNoIdentity() throws {
    let configuration = try DisplayConfigurationTracker().observe(.legacy(integrated: [display("lcd").geometry]))
    XCTAssertEqual(try configuration.activeGeometry(), display("lcd").geometry)
    XCTAssertThrowsError(try configuration.activeDisplay()) { error in
      guard case SimulatorDisplayInteractionError.unsupportedCapability = error else { return XCTFail("unexpected error: \(error)") }
    }
  }

  func testSeveralLegacyDisplaysAreUnknown() throws {
    let geometry = display("lcd").geometry
    let configuration = try DisplayConfigurationTracker().observe(.legacy(integrated: [geometry, geometry]))
    XCTAssertEqual(configuration.active, .unknown)
    XCTAssertThrowsError(try configuration.activeGeometry()) { error in
      guard case SimulatorDisplayInteractionError.unsupportedCapability = error else { return XCTFail("unexpected error: \(error)") }
    }
  }

  func testNoActiveDisplayIsCurrentState() throws {
    let configuration = try DisplayConfigurationTracker().observe(.displays([display("cover", .inactive), display("inner", .inactive)]))
    XCTAssertThrowsError(try configuration.activeGeometry()) { error in
      guard case SimulatorDisplayError.noActiveIntegratedDisplay = error else { return XCTFail("unexpected error: \(error)") }
    }
  }

  func testSeveralActiveDisplaysAreCurrentState() throws {
    let configuration = try DisplayConfigurationTracker().observe(.displays([display("cover"), display("inner")]))
    XCTAssertThrowsError(try configuration.activeDisplay()) { error in
      guard case let SimulatorDisplayError.ambiguousActiveDisplays(identities) = error else { return XCTFail("unexpected error: \(error)") }
      XCTAssertEqual(identities, ["cover", "inner"])
    }
  }

  func testSeveralActiveTVOutputsAreCurrentStateOnAnAppleTV() throws {
    func tvOutput(_ id: String) -> SimulatorDisplay {
      SimulatorDisplay(
        uniqueID: id, name: id, activity: .active, isPrimary: false, isIntegrated: false,
        bounds: CGRect(x: 0, y: 0, width: 3840, height: 2160), scale: 2, rotation: .upright)
    }
    let configuration = try DisplayConfigurationTracker { .external }.observe(
      .displays([display("lcd"), tvOutput("first"), tvOutput("second")]))
    XCTAssertEqual(configuration.active, .unresolved)
    XCTAssertThrowsError(try configuration.activeDisplay()) { error in
      guard case let SimulatorDisplayError.ambiguousActiveDisplays(identities) = error else { return XCTFail("unexpected error: \(error)") }
      XCTAssertEqual(identities, ["first", "second"])
    }
  }

  func testTransitioningConfigurationHasNoActiveDisplayYet() throws {
    let tracker = DisplayConfigurationTracker()
    _ = try tracker.observe(cover)
    let configuration = try tracker.observe(.transitioning(incoming: nil))
    XCTAssertThrowsError(try configuration.activeDisplay()) { error in
      guard case SimulatorDisplayError.transitioning = error else { return XCTFail("unexpected error: \(error)") }
    }
  }

  func testFailedReadThrowsAndLeavesTheGenerationAlone() throws {
    let tracker = DisplayConfigurationTracker()
    _ = try tracker.observe(cover)
    XCTAssertThrowsError(try tracker.observe(.failed(.timedOut))) { error in
      XCTAssertEqual(error as? SimulatorCoreDeviceError, .timedOut)
    }
    XCTAssertEqual(try tracker.observe(cover).generation, 1)
  }

  // MARK: - Settled reads

  func testSettledConfigurationWaitsOutATransition() async throws {
    let displays = DisplayCommandsDouble([.success(.transitioning(incoming: nil)), .success(.transitioning(incoming: nil)), .success(inner)])
    let configuration = try await displays.settledConfiguration(within: .seconds(1))
    XCTAssertEqual(configuration.phase, .settled)
    XCTAssertEqual(configuration.active, .identified(display("inner")))
    XCTAssertEqual(displays.reads, 3)
  }

  func testSettledConfigurationReportsATransitionThatOutlastsTheTimeout() async throws {
    let displays = DisplayCommandsDouble([.success(cover), .success(.transitioning(incoming: nil))])
    _ = try await displays.settledConfiguration(within: .zero)
    let configuration = try await displays.settledConfiguration(within: .milliseconds(20))
    XCTAssertEqual(configuration.phase, .transitioning(incoming: nil))
    XCTAssertEqual(configuration.active, .identified(display("cover")))
  }

  func testSettledConfigurationThrowsAFailedRead() async {
    let displays = DisplayCommandsDouble([.success(.failed(.timedOut))])
    do {
      _ = try await displays.settledConfiguration(within: .seconds(1))
      XCTFail("Expected the read's failure")
    } catch {
      XCTAssertEqual(error as? SimulatorCoreDeviceError, .timedOut)
    }
  }

  func testRoutedReadsShareGenerations() async throws {
    let displays = DisplayCommandsDouble([.success(cover), .success(inner), .success(inner)])
    _ = try await displays.currentDisplay()
    _ = try await displays.currentDisplay()
    let configuration = try await displays.settledConfiguration(within: .zero)
    XCTAssertEqual(configuration.generation, 2)
  }

  func testAReadThatBeganFirstButFinishedLastDoesNotReplaceANewerOne() async throws {
    let displays = GatedDisplayCommands(first: cover, later: inner)
    _ = try displays.configurationTracker.observe(cover)
    let stale = Task { try await displays.settledConfiguration(within: .zero) }
    await displays.firstReadStarted()
    let fresh = try await displays.settledConfiguration(within: .zero)
    displays.releaseFirstRead()
    let late = try await stale.value
    XCTAssertEqual(fresh.generation, 2)
    XCTAssertEqual(late, fresh)
    XCTAssertEqual(displays.configurationTracker.latest, fresh)
  }

  // MARK: - Stream

  func testStreamReplaysTheCurrentConfigurationThenFollowsChangedPushes() async {
    let (pushes, push) = AsyncThrowingStream<SimulatorDisplayReport, Error>.makeStream()
    push.yield(cover)
    push.yield(.transitioning(incoming: nil))
    push.yield(inner)
    push.yield(inner)
    push.finish()
    let displays = DisplayCommandsDouble([.success(cover), .success(inner)], pushes: pushes)
    let configurations = await collect(displays.followConfigurations(), count: 3)
    XCTAssertEqual(configurations.map(\.generation), [1, 1, 2])
    XCTAssertEqual(configurations.map(\.phase), [.settled, .transitioning(incoming: nil), .settled])
  }

  func testStreamPollsWhenPushesAreUnavailable() async {
    let displays = DisplayCommandsDouble([.success(cover), .success(inner)])
    let configurations = await collect(displays.followConfigurations(polling: .milliseconds(1)), count: 2)
    XCTAssertEqual(configurations.map(\.generation), [1, 2])
  }

  func testStreamSkipsAFailedFirstRead() async {
    let (pushes, push) = AsyncThrowingStream<SimulatorDisplayReport, Error>.makeStream()
    push.yield(cover)
    push.finish()
    let displays = DisplayCommandsDouble([.success(.failed(.timedOut)), .success(cover)], pushes: pushes)
    let configurations = await collect(displays.followConfigurations(), count: 1)
    XCTAssertEqual(configurations.map(\.active), [.identified(display("cover"))])
  }

  func testConcurrentStreamsShareOneFollowing() async {
    let (pushes, push) = AsyncThrowingStream<SimulatorDisplayReport, Error>.makeStream()
    let displays = DisplayCommandsDouble([.success(cover)], pushes: pushes)
    var first = displays.followConfigurations().makeAsyncIterator()
    var second = displays.followConfigurations().makeAsyncIterator()
    let initial = await (first.next(), second.next())
    push.yield(inner)
    let changed = await (first.next(), second.next())
    XCTAssertEqual([initial.0, initial.1].map { $0?.generation }, [1, 1])
    XCTAssertEqual([changed.0, changed.1].map { $0?.active }, [.identified(display("inner")), .identified(display("inner"))])
    XCTAssertEqual(displays.reads, 1)
  }

  func testLateStreamStartsFromTheCurrentConfiguration() async {
    let (pushes, push) = AsyncThrowingStream<SimulatorDisplayReport, Error>.makeStream()
    let displays = DisplayCommandsDouble([.success(cover)], pushes: pushes)
    var early = displays.followConfigurations().makeAsyncIterator()
    _ = await early.next()
    push.yield(inner)
    _ = await early.next()
    let late = await collect(displays.followConfigurations(), count: 1)
    XCTAssertEqual(late.map(\.active), [.identified(display("inner"))])
    XCTAssertEqual(displays.reads, 1)
  }

  func testStreamAfterEveryStreamEndsFollowsAgain() async {
    let displays = DisplayCommandsDouble([.success(cover), .success(inner)])
    // The first read, then an immediate poll, after which the following sleeps for the rest of the test.
    _ = await collect(displays.followConfigurations(polling: .seconds(60)), count: 2)
    let configurations = await collect(displays.followConfigurations(polling: .seconds(60)), count: 1)
    XCTAssertEqual(configurations.map(\.generation), [2])
    XCTAssertGreaterThan(displays.reads, 2, "A restarted following reads afresh rather than replaying")
  }

  func testStreamCarriesAConfigurationAnotherReaderObserved() async throws {
    // Pushes that stay open keep the following waiting on them. Without pushes it would poll at once, and a poll that
    // begins after `inner` was numbered, but is observed first, would rightly make `inner` stale.
    let (pushes, push) = AsyncThrowingStream<SimulatorDisplayReport, Error>.makeStream()
    let displays = DisplayCommandsDouble([.success(cover)], pushes: pushes)
    var stream = displays.followConfigurations(polling: .seconds(60)).makeAsyncIterator()
    _ = await stream.next()
    _ = try displays.configurationTracker.observe(inner)
    let next = await stream.next()
    XCTAssertEqual(next?.active, .identified(display("inner")))
    withExtendedLifetime(push) {}
  }

  func testAFollowingStoppedMidReadDoesNotReachTheNextStream() async {
    let logger = AnnouncingLogger()
    let displays = GatedDisplayCommands(first: cover, later: inner, logger: logger)
    let abandoned = Task { for await _ in displays.followConfigurations(polling: .seconds(60)) {} }
    await displays.firstReadStarted()
    abandoned.cancel()
    await abandoned.value
    var stream = displays.followConfigurations(polling: .seconds(60)).makeAsyncIterator()
    let current = await stream.next()
    displays.releaseFirstRead()
    // Each following logs that pushes are unavailable once its first read is observed.
    await logger.wait(forMessages: 2)
    XCTAssertEqual(displays.configurationTracker.latest, current)
  }

  func testFollowingPollsAtTheShortestIntervalOfItsStreams() async {
    let follower = DisplayConfigurationFollower()
    let slow = follower.subscribe(polling: .seconds(1)) { Task {} }
    let fast = follower.subscribe(polling: .milliseconds(50)) { Task {} }
    XCTAssertEqual(follower.interval, .milliseconds(50))
    let consumer = Task { for await _ in fast {} }
    consumer.cancel()
    await consumer.value
    XCTAssertEqual(follower.interval, .seconds(1))
    withExtendedLifetime(slow) {}
  }

  /// The first `count` configurations; the stream polls forever, so the test hangs if fewer arrive.
  private func collect(_ stream: AsyncStream<SimulatorDisplayConfiguration>, count: Int) async -> [SimulatorDisplayConfiguration] {
    var collected: [SimulatorDisplayConfiguration] = []
    for await configuration in stream {
      collected.append(configuration)
      if collected.count == count { break }
    }
    return collected
  }
}

/// Holds its first read until released, ignoring cancellation as a read already sent to the simulator would.
// SAFETY: Every access to the continuations holds the lock.
// patternlint-disable-next-line unchecked-sendable
private final class GatedDisplayCommands: DisplayCommands, @unchecked Sendable {
  let identities = DisplayIdentityCache()
  let configurationTracker = DisplayConfigurationTracker()
  let logger: (any ControlCoreLogger)?
  private let first: SimulatorDisplayReport
  private let later: SimulatorDisplayReport
  private let started = AsyncStream<Void>.makeStream()
  private let lock = NSLock()
  private var reads = 0
  private var release: CheckedContinuation<Void, Never>?

  init(first: SimulatorDisplayReport, later: SimulatorDisplayReport, logger: (any ControlCoreLogger)? = nil) {
    self.first = first
    self.later = later
    self.logger = logger
  }

  func report() async throws -> SimulatorDisplayReport {
    let read = lock.withLock {
      reads += 1
      return reads
    }
    guard read == 1 else { return later }
    await withCheckedContinuation { continuation in
      lock.withLock { release = continuation }
      started.continuation.yield()
    }
    return first
  }

  func touchscreens() async throws -> [SimulatorTouchscreen] { [] }

  func firstReadStarted() async {
    var iterator = started.stream.makeAsyncIterator()
    await iterator.next()
  }

  func releaseFirstRead() {
    lock.withLock { release }?.resume()
  }
}

/// Lets a test wait for a number of messages to be logged.
// SAFETY: The continuation is safe to yield from any thread, and only one test consumes the stream.
// patternlint-disable-next-line unchecked-sendable
private final class AnnouncingLogger: ControlCoreLogger, @unchecked Sendable {
  private let messages = AsyncStream<String>.makeStream()

  func wait(forMessages count: Int) async {
    var remaining = count
    for await _ in messages.stream {
      remaining -= 1
      if remaining == 0 { return }
    }
  }

  @discardableResult
  func log(_ message: String) -> ControlCoreLogger {
    messages.continuation.yield(message)
    return self
  }

  func info() -> ControlCoreLogger { self }
  func debug() -> ControlCoreLogger { self }
  func error() -> ControlCoreLogger { self }
  func withName(_ prefix: String) -> ControlCoreLogger { self }
  func withDateFormatEnabled(_ enabled: Bool) -> ControlCoreLogger { self }
  var name: String? { nil }
  var level: ControlCoreLogLevel { .multiple }
}
