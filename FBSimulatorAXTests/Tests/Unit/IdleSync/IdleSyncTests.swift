/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
@testable import FBSimulatorAX
import Foundation
import ShimulatorIdleSyncCore
import ShimulatorProtocol
import Testing
import os

@Suite("Idle sync quiescence tracker")
struct IdleSyncQuiescenceTrackerTests {
  @Test("Busy carries the signals the process named, skipping reasons this host does not know")
  func busy() {
    var tracker = IdleSyncQuiescenceTracker(pid: 7, quietWindowMs: 0, openedAt: 0)
    let received = tracker.receive(IdleSyncState(idleSince: nil, reasons: ["animation", "network"]), now: 1)
    #expect(received.events == [.state(.busy([.animationsInactive]), pid: 7)])
    #expect(received.settleAt == nil)
  }

  @Test("Scrolling is a signal of its own, so a host can tell it from work running now")
  func scroll() {
    var tracker = IdleSyncQuiescenceTracker(pid: 7, quietWindowMs: 0, openedAt: 0)
    #expect(
      tracker.receive(IdleSyncState(idleSince: nil, reasons: ["scroll", "main"]), now: 1).events
        == [.state(.busy([.scrollIdle, .runLoopIdle]), pid: 7)])
  }

  @Test("With no quiet window, idle is quiet at once, and a repeated state is not reported again")
  func idleIsQuiet() {
    var tracker = IdleSyncQuiescenceTracker(pid: 7, quietWindowMs: 0, openedAt: 0)
    #expect(tracker.receive(IdleSyncState(idleSince: 1, reasons: []), now: 1).events == [.state(.quiet, pid: 7)])
    #expect(tracker.receive(IdleSyncState(idleSince: 1, reasons: []), now: 2).events == [])
  }

  @Test("Each new input the process reports handling is touchesCompleted, before the state it came with")
  func inputHandled() {
    var tracker = IdleSyncQuiescenceTracker(pid: 7, quietWindowMs: 0, openedAt: 0)
    #expect(tracker.receive(IdleSyncState(idleSince: 1, reasons: []), now: 1).events == [.state(.quiet, pid: 7)])
    #expect(
      tracker.receive(IdleSyncState(idleSince: nil, reasons: ["main"], lastInputAt: 5), now: 6).events
        == [.touchesCompleted(pid: 7), .state(.busy([.runLoopIdle]), pid: 7)])
    #expect(tracker.receive(IdleSyncState(idleSince: 9, reasons: [], lastInputAt: 5), now: 9).events == [.state(.quiet, pid: 7)])
    #expect(
      tracker.receive(IdleSyncState(idleSince: 9, reasons: [], lastInputAt: 12), now: 12).events == [.touchesCompleted(pid: 7)])
  }

  @Test("An input handled before the stream opened is not reported, even in the stream's first report")
  func inputBeforeOpening() {
    var tracker = IdleSyncQuiescenceTracker(pid: 7, quietWindowMs: 0, openedAt: 100)
    #expect(tracker.receive(IdleSyncState(idleSince: 90, reasons: [], lastInputAt: 80), now: 100).events == [.state(.quiet, pid: 7)])
    #expect(
      tracker.receive(IdleSyncState(idleSince: 120, reasons: [], lastInputAt: 110), now: 120).events == [.touchesCompleted(pid: 7)])
  }

  @Test("A quiet window counts from the start of the idle period: settling, then quiet once it has passed")
  func quietWindow() {
    var tracker = IdleSyncQuiescenceTracker(pid: 7, quietWindowMs: 300, openedAt: 0)
    let received = tracker.receive(IdleSyncState(idleSince: 1000, reasons: []), now: 1010)
    #expect(received.events == [.state(.settling, pid: 7)])
    #expect(received.settleAt == 1300)
    #expect(tracker.settle(now: 1299) == [])
    #expect(tracker.settle(now: 1300) == [.state(.quiet, pid: 7)])
  }

  @Test("An idle period that began longer ago than the window is quiet at once")
  func longIdle() {
    var tracker = IdleSyncQuiescenceTracker(pid: 7, quietWindowMs: 300, openedAt: 0)
    #expect(tracker.receive(IdleSyncState(idleSince: 100, reasons: []), now: 1000).events == [.state(.quiet, pid: 7)])
  }

  @Test("Going busy while settling cancels the pending quiet")
  func busyWhileSettling() {
    var tracker = IdleSyncQuiescenceTracker(pid: 7, quietWindowMs: 300, openedAt: 0)
    _ = tracker.receive(IdleSyncState(idleSince: 1000, reasons: []), now: 1000)
    #expect(
      tracker.receive(IdleSyncState(idleSince: nil, reasons: ["main"]), now: 1100).events == [.state(.busy([.runLoopIdle]), pid: 7)])
    #expect(tracker.settle(now: 1300) == [])
  }

  @Test("An idle period reported at the end of time stays settling rather than trapping")
  func overflow() {
    var tracker = IdleSyncQuiescenceTracker(pid: 7, quietWindowMs: 300, openedAt: 0)
    let received = tracker.receive(IdleSyncState(idleSince: .max, reasons: []), now: 1)
    #expect(received.events == [.state(.settling, pid: 7)])
    #expect(received.settleAt == .max)
    #expect(tracker.settle(now: 2) == [])
  }
}

/// A process whose shim reports a payload this host cannot decode, as one of another version might.
private final class GarbledIdleProcess: ShimulatorMethodHandler, Sendable {
  private let running = OSAllocatedUnfairLock(initialState: true)

  init(path: String, pid: pid_t) {
    Thread.detachNewThread { [self] in
      let client = ShimulatorClient(
        socketPath: path, handler: self, processIdentifier: pid, processName: "fixture", pollIntervalMilliseconds: 5, log: { _ in })
      while running.withLock({ $0 }) {
        if !client.serveOnce() {
          usleep(5_000)
        }
      }
    }
  }

  func exit() {
    running.withLock { $0 = false }
  }

  func start(_ parameters: IdleSyncParameters) throws -> Int { 0 }

  func stop(_ admission: Int) {}

  func poll(_ admission: Int) -> ShimulatorMethodUpdate? {
    ShimulatorMethodUpdate(.accepted, payload: Data("not a state".utf8))
  }
}

/// A stand-in for an armed process: the shim's own client and controller, over a probe the test sets.
private final class FakeIdleProcess: IdleSyncProbe, Sendable {
  private struct State {
    var reasons: [IdleSyncReason] = [.main]
    var idleSince: UInt64 = 0
    var thresholds: [UInt32?] = []
    var running = true
  }

  let pid: pid_t
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(path: String, pid: pid_t) {
    self.pid = pid
    Thread.detachNewThread { [self] in
      let client = ShimulatorClient(
        socketPath: path, handler: IdleSyncController(probe: self), processIdentifier: pid, processName: "fixture",
        pollIntervalMilliseconds: 5, log: { _ in })
      while state.withLock({ $0.running }) {
        if !client.serveOnce() {
          usleep(5_000)
        }
      }
    }
  }

  var thresholds: [UInt32?] { state.withLock { $0.thresholds } }

  /// Going idle starts an idle period, as the shim's trackers record it.
  func set(_ reasons: [IdleSyncReason]) {
    state.withLock { state in
      if reasons.isEmpty, !state.reasons.isEmpty {
        state.idleSince = Self.now()
      }
      state.reasons = reasons
    }
  }

  /// Stops reconnecting once the current connection ends.
  func exit() {
    state.withLock { $0.running = false }
  }

  func sample() -> IdleSyncSample {
    let (reasons, idleSince) = state.withLock { ($0.reasons, $0.idleSince) }
    return IdleSyncSample(reasons: reasons, idleSince: idleSince, at: Self.now())
  }

  private static func now() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1000)
  }

  func setBusyThreshold(milliseconds: UInt32?) {
    state.withLock { $0.thresholds.append(milliseconds) }
  }
}

@Suite("Idle sync stream")
struct IdleSyncStreamTests {
  private static func now() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1000)
  }

  /// Runs a stream following pid 42 over the updates `script` sends, until it ends.
  private static func run(
    quietWindowMs: UInt64,
    isRunning: @escaping @Sendable (pid_t) -> Bool = { _ in true },
    script: @escaping @Sendable (AsyncStream<IdleSyncHost.Update>.Continuation) async -> Void
  ) async -> (events: [QuiescenceEvent], error: Error?) {
    let (updates, input) = AsyncStream<IdleSyncHost.Update>.makeStream()
    let driver = Task {
      await script(input)
      input.finish()
    }
    defer { driver.cancel() }
    var stream = IdleSyncStream(
      requested: 42, path: "/tmp/idle.sock", quietWindowMs: quietWindowMs, connectionTimeout: 30, isRunning: isRunning)
    var events: [QuiescenceEvent] = []
    do {
      try await stream.run(current: [:], updates: updates) { events.append($0) }
      return (events, nil)
    } catch {
      return (events, error)
    }
  }

  @Test("An idle period an app dates far ahead, up to the end of time, stays settling rather than trapping", arguments: [UInt64.max, UInt64.max / 2])
  func farAhead(idleSince: UInt64) async {
    let result = await Self.run(quietWindowMs: 300) { input in
      input.yield(.state(pid: 42, IdleSyncState(idleSince: idleSince, reasons: [])))
      try? await Task.sleep(for: .milliseconds(50))
      input.yield(.state(pid: 42, IdleSyncState(idleSince: nil, reasons: ["main"])))
    }
    #expect(result.events == [.state(.settling, pid: 42), .state(.busy([.runLoopIdle]), pid: 42)])
    #expect(result.error as? QuiescenceError == .streamEnded)
  }

  @Test("A quiet window that ends while the app is disconnected is not quiet; the state it reconnects with decides")
  func noQuietWhileDisconnected() async {
    let result = await Self.run(quietWindowMs: 100) { input in
      input.yield(.state(pid: 42, IdleSyncState(idleSince: Self.now(), reasons: [])))
      input.yield(.disconnected(pid: 42))
      try? await Task.sleep(for: .milliseconds(300))
      input.yield(.state(pid: 42, IdleSyncState(idleSince: nil, reasons: ["main"])))
      input.yield(.state(pid: 42, IdleSyncState(idleSince: Self.now(), reasons: [])))
      try? await Task.sleep(for: .milliseconds(300))
    }
    #expect(
      result.events == [
        .state(.settling, pid: 42), .state(.busy([.runLoopIdle]), pid: 42), .state(.settling, pid: 42), .state(.quiet, pid: 42),
      ])
  }

  @Test("A report from the followed app that cannot be read fails the stream with why; one from another app is ignored")
  func unreadable() async {
    let result = await Self.run(quietWindowMs: 0) { input in
      input.yield(.unreadable(pid: 43, reason: "other"))
      input.yield(.state(pid: 42, IdleSyncState(idleSince: nil, reasons: ["main"])))
      input.yield(.unreadable(pid: 42, reason: "dataCorrupted"))
      try? await Task.sleep(for: .seconds(30))
    }
    #expect(result.events == [.state(.busy([.runLoopIdle]), pid: 42)])
    #expect(result.error as? IdleSyncError == .unreadableState(pid: 42, reason: "dataCorrupted"))
  }

  @Test("A closed connection whose process has gone ends the stream")
  func processExits() async {
    let result = await Self.run(quietWindowMs: 0, isRunning: { _ in false }) { input in
      input.yield(.state(pid: 42, IdleSyncState(idleSince: Self.now(), reasons: [])))
      input.yield(.disconnected(pid: 42))
      try? await Task.sleep(for: .seconds(30))
    }
    #expect(result.events == [.state(.quiet, pid: 42), .targetExited(pid: 42)])
    #expect(result.error == nil)
  }
}

@Suite("Idle sync host")
struct IdleSyncHostTests {
  private static func socketPath() -> String {
    "/tmp/idb-idle-\(UUID().uuidString.prefix(8))/T.idle.sock"
  }

  private static func quiescence(
    of pid: pid_t?, on host: IdleSyncHost, busyThresholdMs: UInt32? = nil, connectionTimeout: TimeInterval = 30
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, Error>.AsyncIterator {
    try await SimulatorIdleSyncCommands.quiescence(
      of: pid, on: host, parameters: IdleSyncParameters(busyThresholdMs: busyThresholdMs), quietWindowMs: 0,
      connectionTimeout: connectionTimeout
    ).makeAsyncIterator()
  }

  private static func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<250 where !condition() {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition())
  }

  @Test("A process that connects after the request is followed from its first state")
  func processConnectsLater() async throws {
    let host = IdleSyncHost(path: Self.socketPath())
    var events = try await Self.quiescence(of: 42, on: host)
    let process = FakeIdleProcess(path: host.path, pid: 42)
    defer { process.exit() }
    #expect(try await events.next() == .state(.busy([.runLoopIdle]), pid: 42))
    process.set([])
    #expect(try await events.next() == .state(.quiet, pid: 42))
  }

  @Test("A process already connected is answered from its latest state")
  func processAlreadyConnected() async throws {
    let host = IdleSyncHost(path: Self.socketPath())
    let process = FakeIdleProcess(path: host.path, pid: 42)
    defer { process.exit() }
    process.set([.animation])
    var first = try await Self.quiescence(of: 42, on: host)
    #expect(try await first.next() == .state(.busy([.animationsInactive]), pid: 42))

    process.set([])
    var events = try await Self.quiescence(of: 42, on: host)
    // The first state it sees may still be the busy one, if the change has not reached the host yet.
    var event = try await events.next()
    if event == .state(.busy([.animationsInactive]), pid: 42) {
      event = try await events.next()
    }
    #expect(event == .state(.quiet, pid: 42))
    withExtendedLifetime(first) {}
  }

  @Test("No target follows the one armed process, and refuses to guess between several")
  func noTarget() async throws {
    let host = IdleSyncHost(path: Self.socketPath())
    var events = try await Self.quiescence(of: nil, on: host)
    let first = FakeIdleProcess(path: host.path, pid: 42)
    defer { first.exit() }
    first.set([])
    #expect(try await events.next() == .state(.quiet, pid: 42))

    let (_, updates) = try await host.open(IdleSyncParameters())
    let second = FakeIdleProcess(path: host.path, pid: 43)
    defer { second.exit() }
    for await update in updates {
      if case .state(43, _) = update { break }
    }
    await #expect(throws: IdleSyncError.severalApplications(pids: [42, 43])) {
      var ambiguous = try await Self.quiescence(of: nil, on: host)
      _ = try await ambiguous.next()
    }
    withExtendedLifetime(events) {}
  }

  @Test("Requests share the busy threshold: none takes the one in use, another is refused while a request is open, and served once none is")
  func busyThreshold() async throws {
    let host = IdleSyncHost(path: Self.socketPath(), idleTimeout: .seconds(30))
    let process = FakeIdleProcess(path: host.path, pid: 42)
    defer { process.exit() }
    var first: AsyncThrowingStream<QuiescenceEvent, Error>.AsyncIterator? = try await Self.quiescence(of: 42, on: host, busyThresholdMs: 32)
    _ = try await first?.next()
    #expect(process.thresholds == [32])

    var second: AsyncThrowingStream<QuiescenceEvent, Error>.AsyncIterator? = try await Self.quiescence(of: 42, on: host)
    _ = try await second?.next()
    await #expect(throws: IdleSyncError.busyThresholdInUse(path: host.path, current: 32, requested: 16)) {
      _ = try await Self.quiescence(of: 42, on: host, busyThresholdMs: 16)
    }
    #expect(process.thresholds == [32], "the process was not reconnected")

    first = nil
    second = nil
    var third: AsyncThrowingStream<QuiescenceEvent, Error>.AsyncIterator?
    for _ in 0..<250 where third == nil {
      do {
        third = try await Self.quiescence(of: 42, on: host, busyThresholdMs: 16)
      } catch IdleSyncError.busyThresholdInUse(_, _, _) {
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    _ = try await third?.next()
    #expect(process.thresholds == [32, nil, 16], "the first connection ended, and the second was sent the new one")
  }

  @Test("Once the last request has ended, a request with no busy threshold is served the shim's own, not the previous one")
  func noThresholdAfterLastRequest() async throws {
    let host = IdleSyncHost(path: Self.socketPath(), idleTimeout: .seconds(30))
    let process = FakeIdleProcess(path: host.path, pid: 42)
    defer { process.exit() }
    let (_, firstUpdates) = try await host.open(IdleSyncParameters(busyThresholdMs: 32))
    try await Self.eventually { process.thresholds == [32] }
    // Cancelling the consumer ends its updates, which closes the stream before `value` returns.
    let first = Task { for await _ in firstUpdates {} }
    first.cancel()
    await first.value

    let (_, secondUpdates) = try await host.open(IdleSyncParameters())
    try await Self.eventually { process.thresholds == [32, nil, nil] }
    withExtendedLifetime(secondUpdates) {}
  }

  @Test("The socket is kept between back-to-back requests, released once the idle timeout passes, and bound again by a later request")
  func releasedWhenIdle() async throws {
    let host = IdleSyncHost(path: Self.socketPath(), idleTimeout: .milliseconds(300))
    let process = FakeIdleProcess(path: host.path, pid: 42)
    defer { process.exit() }
    process.set([])
    var first: AsyncThrowingStream<QuiescenceEvent, Error>.AsyncIterator? = try await Self.quiescence(of: 42, on: host)
    #expect(try await first?.next() == .state(.quiet, pid: 42))
    first = nil
    try await Task.sleep(for: .milliseconds(100))
    #expect(FileManager.default.fileExists(atPath: host.path), "still within the idle timeout")

    try await Self.eventually { !FileManager.default.fileExists(atPath: host.path) }
    var other = try ShimulatorServer(path: host.path, parameters: IdleSyncParameters())
    #expect(other != nil, "nothing holds the socket")
    other = nil

    var again = try await Self.quiescence(of: 42, on: host)
    #expect(try await again.next() == .state(.quiet, pid: 42))
  }

  @Test("A process whose report cannot be read fails the request with why, rather than as not connected")
  func unreadable() async throws {
    let host = IdleSyncHost(path: Self.socketPath())
    let process = GarbledIdleProcess(path: host.path, pid: 42)
    defer { process.exit() }
    var events = try await Self.quiescence(of: 42, on: host)
    do {
      _ = try await events.next()
      Issue.record("an unreadable report was not thrown")
    } catch let IdleSyncError.unreadableState(pid, reason) {
      #expect(pid == 42)
      #expect(!reason.isEmpty)
    }
  }

  @Test("A process that never connects fails the request with what to do about it")
  func neverConnects() async throws {
    let host = IdleSyncHost(path: Self.socketPath())
    await #expect(throws: IdleSyncError.notConnected(pid: 42, path: host.path, waited: 0.05)) {
      var events = try await Self.quiescence(of: 42, on: host, connectionTimeout: 0.05)
      _ = try await events.next()
    }
  }

  @Test("A request is refused while another process holds the socket")
  func socketInUse() async throws {
    let path = Self.socketPath()
    let other = try #require(try ShimulatorServer(path: path, parameters: IdleSyncParameters()))
    await #expect(throws: IdleSyncError.socketInUse(path: path)) {
      _ = try await Self.quiescence(of: 42, on: IdleSyncHost(path: path))
    }
    withExtendedLifetime(other) {}
  }
}
