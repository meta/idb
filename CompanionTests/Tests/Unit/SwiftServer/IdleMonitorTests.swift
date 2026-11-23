/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBControlCore
import Foundation
// ast-grep-ignore: swift-testing/swift/no-new-xctest
import XCTest

/// Thread-safe ordered record of callbacks, so the monitor's timer/queue
/// callbacks can be observed from the test thread without data races.
private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []

  func add(_ event: String) {
    lock.lock()
    defer { lock.unlock() }
    events.append(event)
  }

  var all: [String] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}

final class IdleMonitorTests: XCTestCase {

  /// A short idle window keeps the timing-based tests fast; waits below use a
  /// large multiple of it to avoid flaking under load.
  private let idleTime: TimeInterval = 0.2

  private static let logger = IDBLogger(
    loggers: [ControlCoreGlobalConfiguration.systemLogger(writingToStderr: true, debugLogging: false)])

  private func makeMonitor(onShutdownStarted: (@Sendable () -> Void)? = nil) -> IdleMonitor {
    IdleMonitor(idleTime: idleTime, logger: Self.logger, onShutdownStarted: onShutdownStarted)
  }

  /// Registers an expectation that fulfills when `expired` resolves, optionally
  /// running `onResolve` first.
  private func expirationExpectation(for monitor: IdleMonitor, onResolve: (@Sendable () -> Void)? = nil) -> XCTestExpectation {
    let fulfilled = expectation(description: "monitor.expired resolves")
    Task {
      try? await monitor.waitUntilExpired()
      onResolve?()
      fulfilled.fulfill()
    }
    return fulfilled
  }

  func testFiresAfterIdlePeriodWhenStarted() {
    let log = EventLog()
    let monitor = makeMonitor(onShutdownStarted: { log.add("shutdown") })
    let fired = expirationExpectation(for: monitor)
    monitor.start()
    wait(for: [fired], timeout: idleTime * 10)
    XCTAssertEqual(log.all, ["shutdown"])
  }

  func testOnShutdownStartedRunsBeforeExpiredResolves() {
    let log = EventLog()
    let monitor = makeMonitor(onShutdownStarted: { log.add("shutdown") })
    let fired = expirationExpectation(for: monitor, onResolve: { log.add("expired") })
    monitor.start()
    wait(for: [fired], timeout: idleTime * 10)
    // The synchronous hook must run before `expired` resolves so the socket is
    // removed before any client can observe (and act on) the shutdown.
    XCTAssertEqual(log.all, ["shutdown", "expired"])
  }

  func testDoesNotFireWhileRequestInFlight() {
    let monitor = makeMonitor()
    let fired = expirationExpectation(for: monitor)
    fired.isInverted = true
    monitor.requestStarted() // never ended -> a request stays in flight
    monitor.start()
    wait(for: [fired], timeout: idleTime * 4)
  }

  func testReArmsAfterLastRequestCompletes() {
    let monitor = makeMonitor()
    // A request in flight means start() does not arm the idle timer...
    monitor.requestStarted()
    monitor.start()
    let fired = expirationExpectation(for: monitor)
    // ...and completing the last request re-arms it.
    monitor.requestEnded()
    wait(for: [fired], timeout: idleTime * 10)
  }

  func testActivityResetsCountdownThenFires() {
    let monitor = makeMonitor()
    let fired = expirationExpectation(for: monitor)
    monitor.start()
    // A request arriving and finishing partway through the window resets the
    // countdown; the monitor still fires once it is idle again.
    Thread.sleep(forTimeInterval: idleTime / 2)
    monitor.requestStarted()
    monitor.requestEnded()
    wait(for: [fired], timeout: idleTime * 10)
  }

  func testFiresOnlyOnce() {
    let log = EventLog()
    let monitor = makeMonitor(onShutdownStarted: { log.add("shutdown") })
    let fired = expirationExpectation(for: monitor)
    monitor.start()
    wait(for: [fired], timeout: idleTime * 10)
    // Give any stray/superseded timer a chance to fire a second time.
    Thread.sleep(forTimeInterval: idleTime * 3)
    XCTAssertEqual(log.all, ["shutdown"])
  }
}
