/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreFoundation
import Darwin
import FBSimulatorBridgeProtocol
import Foundation

#if canImport(SimulatorFrameworkBridgeRuntime)
internal import SimulatorFrameworkBridgeRuntime
#endif

private typealias Wire = BridgeAXWire.Quiescence

/// Decides an application's quiescence from when each signal was requested and when it was answered.
///
/// An application holds a request until the condition it asks about is true, so a request that stays
/// unanswered past the busy threshold means the application is busy. Time is passed in rather than read,
/// so every decision is a function of its inputs.
public struct QuiescenceTracker: Sendable {
  public enum State: Equatable, Sendable {
    case busy(Set<BridgeAXWire.Quiescence.Signal>)
    case settling
    case quiet
  }

  private struct SignalTimes {
    var requestedAt: TimeInterval?
    /// Since when the signal has not been busy; nil until it is first answered.
    var calmSince: TimeInterval?
  }

  public let busyThreshold: TimeInterval
  public let quietWindow: TimeInterval
  private var signals: [BridgeAXWire.Quiescence.Signal: SignalTimes] = [:]

  public init(busyThreshold: TimeInterval, quietWindow: TimeInterval) {
    self.busyThreshold = busyThreshold
    self.quietWindow = quietWindow
    reset()
  }

  public mutating func reset() {
    signals = Dictionary(uniqueKeysWithValues: BridgeAXWire.Quiescence.Signal.allCases.map { ($0, SignalTimes()) })
  }

  public mutating func requested(_ signal: BridgeAXWire.Quiescence.Signal, at time: TimeInterval) {
    signals[signal]?.requestedAt = time
  }

  /// An answer to a request this tracker did not see made is ignored, and false: another client asked for it.
  @discardableResult
  public mutating func answered(_ signal: BridgeAXWire.Quiescence.Signal, at time: TimeInterval) -> Bool {
    guard var times = signals[signal], let requestedAt = times.requestedAt else { return false }
    if times.calmSince == nil || time - requestedAt >= busyThreshold {
      times.calmSince = time
    }
    times.requestedAt = nil
    signals[signal] = times
    return true
  }

  /// The signals asked for at or before `time` and not yet answered.
  public func unanswered(since time: TimeInterval) -> [BridgeAXWire.Quiescence.Signal] {
    BridgeAXWire.Quiescence.Signal.allCases.filter { signals[$0]?.requestedAt.map { $0 <= time } ?? false }
  }

  /// Nil until every signal has either been answered or gone unanswered long enough to count as busy.
  public func state(at now: TimeInterval) -> State? {
    let busy = Set(signals.filter { isBusy($0.value, at: now) }.keys)
    if !busy.isEmpty {
      return .busy(busy)
    }
    let calm = signals.values.compactMap(\.calmSince)
    guard calm.count == signals.count, let since = calm.max() else { return nil }
    return now - since >= quietWindow ? .quiet : .settling
  }

  /// The earliest time the state can change with no further request or answer.
  public func nextDeadline(after now: TimeInterval) -> TimeInterval? {
    var deadlines = signals.values.compactMap { times -> TimeInterval? in
      guard let requestedAt = times.requestedAt, !isBusy(times, at: now) else { return nil }
      return requestedAt + busyThreshold
    }
    if state(at: now) == .settling, let since = signals.values.compactMap(\.calmSince).max() {
      deadlines.append(since + quietWindow)
    }
    return deadlines.min()
  }

  private func isBusy(_ times: SignalTimes, at now: TimeInterval) -> Bool {
    guard let requestedAt = times.requestedAt else { return false }
    return now - requestedAt >= busyThreshold
  }
}

/// Streams one application's quiescence, following the frontmost application when no pid was named.
///
/// Everything after `run` starts happens on the serving thread's run loop, which is also where the
/// monitor delivers, so no state here is shared between threads except the cancellation flag.
final class QuiescenceStream: AccessibilityAnswerStream {
  enum Target {
    case pid(pid_t)
    case frontmost
  }

  /// How long after an answer the signal is asked for again. Keeps an idle application from being asked
  /// in a tight loop, at the cost of noticing it become busy up to this much later.
  private static let rearmDelay: TimeInterval = 0.05
  /// How often a named application is checked for having exited, and the frontmost one re-resolved in
  /// case a state change went unreported.
  private static let heartbeatInterval: TimeInterval = 1

  /// Adds a timer to the current run loop. Its handler runs on this thread, so unlike `Timer`'s it
  /// need not be `@Sendable`.
  private static func scheduledTimer(after interval: TimeInterval, repeating: Bool, handler: @escaping () -> Void) -> CFRunLoopTimer {
    let timer: CFRunLoopTimer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + interval, repeating ? interval : 0, 0, 0) { _ in handler() }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
    return timer
  }

  private let target: Target
  private let resolveFrontmost: (FBAXClient) throws -> FBAXFrontmostOutcome
  private var tracker: QuiescenceTracker

  private let lock = NSLock()
  private var cancelled = false
  private var runLoop: CFRunLoop?

  private var emit: ((BridgeAXAnswer) -> Bool)?
  private var client: FBAXClient?
  private var monitor: FBAXQuiescenceMonitorClient?
  private var pid: pid_t = 0
  private var application: FBAXElement?
  /// Bumped on every retarget, so a re-arm scheduled for the previous application is dropped.
  private var generation = 0
  private var lastState: QuiescenceTracker.State?
  private var deadlineTimer: CFRunLoopTimer?
  private var heartbeat: CFRunLoopTimer?
  private(set) var failed = false

  init(target: Target, busyThreshold: TimeInterval, quietWindow: TimeInterval, resolveFrontmost: @escaping (FBAXClient) throws -> FBAXFrontmostOutcome) {
    self.target = target
    self.resolveFrontmost = resolveFrontmost
    tracker = QuiescenceTracker(busyThreshold: busyThreshold, quietWindow: quietWindow)
  }

  func run(emit: @escaping (BridgeAXAnswer) -> Bool) {
    lock.lock()
    runLoop = CFRunLoopGetCurrent()
    lock.unlock()
    self.emit = emit
    do {
      try start()
    } catch {
      fail(error.localizedDescription, kind: .readerUnavailable)
    }
    // A stop can land before the loop runs, so the loop also wakes periodically to check.
    while !isCancelled {
      CFRunLoopRunInMode(.defaultMode, Self.heartbeatInterval, false)
    }
    if let deadlineTimer {
      CFRunLoopTimerInvalidate(deadlineTimer)
    }
    if let heartbeat {
      CFRunLoopTimerInvalidate(heartbeat)
    }
    monitor?.invalidate()
    // The one-shot CLI lends `emit` only for the duration of `run`.
    self.emit = nil
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let runLoop = runLoop
    lock.unlock()
    if let runLoop {
      CFRunLoopStop(runLoop)
    }
  }

  private var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  private func start() throws {
    let client = try FBAXClientProvider.client()
    self.client = client
    // Applications only answer the monitoring actions in automation mode.
    if try !client.automationModeEnabled().boolValue, try !client.setAutomationModeEnabled(true).boolValue {
      return fail("accessibility automation mode could not be enabled, so no application answers quiescence requests", kind: .readerUnavailable)
    }
    monitor = try client.quiescenceMonitor { [weak self] report, pid in
      self?.enqueue(report, pid: pid)
    }
    heartbeat = Self.scheduledTimer(after: Self.heartbeatInterval, repeating: true) { [weak self] in self?.beat() }
    switch target {
    case let .pid(pid):
      try arm(pid)
    case .frontmost:
      let outcome = try resolveFrontmost(client)
      guard outcome.status == .resolved else {
        return fail(outcome.failureReason ?? "could not resolve the frontmost application", kind: Self.errorKind(for: outcome.status))
      }
      try arm(outcome.processIdentifier)
    }
  }

  private func arm(_ pid: pid_t) throws {
    guard let client else { return }
    self.pid = pid
    // An application that was running before automation mode came on loads its accessibility server a
    // moment later, so until then it has no element and is retried on the heartbeat.
    guard let application = try client.applicationElement(forProcessIdentifier: pid).value else {
      return targetUnavailable()
    }
    self.application = application
    for signal in Wire.Signal.allCases {
      try request(signal)
    }
  }

  /// A resend asks again for a signal already asked for, keeping how long it has gone unanswered.
  private func request(_ signal: Wire.Signal, resend: Bool = false) throws {
    guard let monitor, let application, !isCancelled else { return }
    let outcome = try monitor.request(signal == .runLoopIdle ? .runLoopIdle : .animationsInactive, fromApplication: application)
    switch outcome.status {
    case .written, .applicationNotResponding:
      guard !resend else { return }
      // An application too busy to take the request is busy, which is what the request would have shown.
      tracker.requested(signal, at: Self.now)
      evaluate()
    case .applicationUnavailable:
      targetUnavailable()
    case .empty, .assertionFailed, .failed:
      fallthrough
    @unknown default:
      fail(outcome.failureReason ?? "the application refused the quiescence request", kind: .applicationNotResponding)
    }
  }

  // The live monitor already delivers on this run loop; hopping regardless keeps every delivery on it.
  private func enqueue(_ report: FBAXQuiescenceReport, pid: pid_t) {
    guard let runLoop else { return }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
      self?.guarded { try self?.handle(report, pid: pid) }
    }
    CFRunLoopWakeUp(runLoop)
  }

  private func handle(_ report: FBAXQuiescenceReport, pid: pid_t) throws {
    guard !isCancelled else { return }
    switch report {
    case .applicationStateChanged:
      if case .frontmost = target {
        try retarget()
      }
    case .touchesCompleted:
      if pid == self.pid {
        write(.quiescence(.touchesCompleted(pid: pid)))
      }
    case .runLoopIdle, .animationsInactive:
      guard pid == self.pid else { return }
      let signal: Wire.Signal = report == .runLoopIdle ? .runLoopIdle : .animationsInactive
      // Every client's monitor hears every answer, so re-arming on another's would multiply the requests.
      guard tracker.answered(signal, at: Self.now) else { return }
      evaluate()
      let generation = generation
      _ = Self.scheduledTimer(after: Self.rearmDelay, repeating: false) { [weak self] in
        guard let self, self.generation == generation else { return }
        self.guarded { try self.request(signal) }
      }
    @unknown default:
      break
    }
  }

  private func beat() {
    guarded {
      switch target {
      case .pid:
        guard Self.isAlive(pid) else { return targetUnavailable() }
      case .frontmost:
        try retarget()
      }
      try recoverDroppedRequests()
      if application == nil {
        try arm(pid)
      }
    }
  }

  /// Automation mode goes off for the whole simulator when another accessibility client exits, and
  /// applications drop the requests they are sent while it is off. Any client may turn it back on first,
  /// so a request left unanswered for a heartbeat is asked again whether or not this stream saw it off.
  private func recoverDroppedRequests() throws {
    guard let client else { return }
    var askedBefore = Self.now - Self.heartbeatInterval
    if try !client.automationModeEnabled().boolValue {
      guard try client.setAutomationModeEnabled(true).boolValue else {
        return fail("accessibility automation mode went off and could not be enabled again, so no application answers quiescence requests", kind: .readerUnavailable)
      }
      askedBefore = Self.now
    }
    for signal in tracker.unanswered(since: askedBefore) {
      try request(signal, resend: true)
    }
  }

  // A resolution that fails keeps the current target: the frontmost application is briefly unknowable
  // during transitions.
  private func retarget() throws {
    guard let client else { return }
    let outcome = try resolveFrontmost(client)
    guard outcome.status == .resolved, outcome.processIdentifier != pid else { return }
    generation += 1
    tracker.reset()
    lastState = nil
    write(.quiescence(.targetChanged(pid: outcome.processIdentifier)))
    try arm(outcome.processIdentifier)
  }

  /// Only a named application that has exited ends the stream. Otherwise the element is dropped and the
  /// heartbeat re-arms it, or whichever application is frontmost by then.
  private func targetUnavailable() {
    application = nil
    tracker.reset()
    guard case .pid = target, !Self.isAlive(pid) else { return }
    write(.quiescence(.targetExited(pid: pid)))
    finish()
  }

  // The applications a stream follows run as this user, so `EPERM` means the pid now names another process.
  private static func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
  }

  private func evaluate() {
    let now = Self.now
    if let state = tracker.state(at: now), state != lastState {
      lastState = state
      write(.quiescence(Self.event(for: state, pid: pid)))
    }
    if let deadlineTimer {
      CFRunLoopTimerInvalidate(deadlineTimer)
    }
    deadlineTimer = nil
    guard let deadline = tracker.nextDeadline(after: now) else { return }
    deadlineTimer = Self.scheduledTimer(after: max(0, deadline - now), repeating: false) { [weak self] in self?.evaluate() }
  }

  private static func event(for state: QuiescenceTracker.State, pid: pid_t) -> BridgeAXQuiescenceEvent {
    switch state {
    case let .busy(signals): .state(.busy, busySignals: signals.sorted { $0.rawValue < $1.rawValue }, pid: pid)
    case .settling: .state(.settling, busySignals: [], pid: pid)
    case .quiet: .state(.quiet, busySignals: [], pid: pid)
    }
  }

  private static func errorKind(for status: FBAXFrontmostStatus) -> BridgeAXWire.ErrorKind {
    switch status {
    case .applicationUnavailable: .applicationUnavailable
    case .applicationNotResponding: .applicationNotResponding
    default: .frontmostUnresolved
    }
  }

  private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  private func guarded(_ body: () throws -> Void) {
    do {
      try body()
    } catch {
      fail("the reader raised while streaming: \(error.localizedDescription)", kind: .readerUnavailable)
    }
  }

  private func fail(_ message: String, kind: BridgeAXWire.ErrorKind) {
    failed = true
    write(.failure(BridgeAXFailure(message: message, kind: kind)))
    finish()
  }

  private func write(_ answer: BridgeAXAnswer) {
    guard !isCancelled, let emit else { return }
    if !emit(answer) {
      finish()
    }
  }

  private func finish() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}
