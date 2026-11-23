/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import Foundation

private let bundleReadyTimeout: TimeInterval = 60
private let ideInterfaceReadyTimeout: TimeInterval = 60
private let daemonSessionReadyTimeout: TimeInterval = 60
private let crashCheckWaitLimit: TimeInterval = 120

enum TestBundleConnectionError: Error {
  case hostRelaunchedByOS(underlying: any Error)
  case hostStalled(processIdentifier: pid_t, stackshot: String)
  case hostCrashed(crashLog: String)
  case connectionLost(message: String)
  case processStillRunning(processIdentifier: pid_t)
  case crashLogTimedOut(processIdentifier: pid_t, bundleID: String, timeout: TimeInterval)
}

extension TestBundleConnectionError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .hostRelaunchedByOS:
      return "Error while establishing connection to test bundle: Running test host application pid is different from the pid launched and set up to execute the tests. The host application is likely to have crashed during startup and been relaunched by iOS."
    case let .hostStalled(processIdentifier, stackshot):
      return "Could not connect to test bundle, but host application process \(processIdentifier) is still alive and busy/stalled: \(stackshot)"
    case let .hostCrashed(crashLog):
      return "Test Bundle/HostApp Crashed: \(crashLog)"
    case let .connectionLost(message):
      return message
    case let .processStillRunning(processIdentifier):
      return "The Process for \(processIdentifier) is not crashed as it is running"
    case let .crashLogTimedOut(processIdentifier, bundleID, timeout):
      return "Timed out after \(timeout) seconds getting crash log for process with pid \(processIdentifier), bundle ID: \(bundleID)"
    }
  }
}

/// How far the test bundle got through its test plan.
enum TestPlanOutcome {
  case unfinished
  case finished
  /// The bundle reported a failure, such as UI testing failing to initialize, before finishing.
  case failed(any Error)
}

/// What the test bundle and testmanagerd have done over the connection, as events to wait on.
final class TestBundleEvents: @unchecked Sendable {
  let proxyChannelOpened = AsyncEvent<Void>()
  let sessionStarted = AsyncEvent<Void>()
  let bundleReady = AsyncEvent<Void>()
  let disconnected = AsyncEvent<Void>()

  private let lock = NSLock()
  private var outcome = TestPlanOutcome.unfinished

  /// Read once the connection has gone away.
  var testPlanOutcome: TestPlanOutcome {
    lock.withLock { outcome }
  }

  /// The test bundle opened its proxy channel.
  func testBundleConnectionDidOpenProxyChannel() {
    proxyChannelOpened.happen()
  }

  /// testmanagerd answered the session request, with an error if it refused it.
  func testBundleConnectionDidStartSessionWithError(_ error: (any Error)?) {
    if let error {
      sessionStarted.fail(error)
    } else {
      sessionStarted.happen()
    }
  }

  /// The test bundle is ready to execute its test plan.
  func testBundleConnectionBundleDidBecomeReady() {
    bundleReady.happen()
  }

  /// The test bundle cannot run: a protocol mismatch, or UI testing failing to initialize.
  func testBundleConnectionBundleDidFailWithError(_ error: any Error) {
    bundleReady.fail(error)
    endTestPlan(.failed(error))
  }

  /// The test bundle finished executing its test plan.
  func testBundleConnectionDidFinishTestPlan() {
    endTestPlan(.finished)
  }

  /// The testmanagerd connection went away.
  func testBundleConnectionDidDisconnect() {
    disconnected.happen()
  }

  private func endTestPlan(_ ending: TestPlanOutcome) {
    lock.withLock {
      guard case .unfinished = outcome else {
        return
      }
      outcome = ending
    }
  }
}

final class TestBundleConnection {

  private let context: TestManagerContext
  private let target: any Target
  private let socket: Int32
  private let interface: NSObject
  private let testHostApplication: any LaunchedApplication
  private let requestQueue: DispatchQueue
  private let logger: any ControlCoreLogger

  init(
    context: TestManagerContext,
    target: any Target,
    socket: Int32,
    interface: NSObject,
    testHostApplication: any LaunchedApplication,
    requestQueue: DispatchQueue,
    logger: any ControlCoreLogger
  ) {
    self.context = context
    self.target = target
    self.socket = socket
    self.interface = interface
    self.testHostApplication = testHostApplication
    self.requestQueue = requestQueue
    self.logger = logger
  }

  func connectAndRun() async throws {
    logger.log("Connecting Test Bundle")
    let events = TestBundleEvents()
    let core = TestBundleDTXConnection(
      context: context,
      work: target.workQueue,
      socket: socket,
      interface: interface,
      delegate: events,
      request: requestQueue,
      logger: ControlCoreLoggerSink(logger)
    )
    try core.connect()
    defer { core.disconnect() }
    do {
      core.setupAndStartSession()
      try await Self.waitForSession(events)
      logger.log("Waiting for test bundle to be ready..")
      try await events.bundleReady.wait(timeout: bundleReadyTimeout, waitingFor: "Bundle Ready to be called")
    } catch {
      throw await self.diagnosedConnectionError(from: error)
    }
    core.startExecutingTestPlan()
    try await events.disconnected.wait()
    switch events.testPlanOutcome {
    case .finished:
      self.logger.log("Bundle disconnected, with the test plan completed. Bundle exited successfully.")
    case let .failed(error):
      self.logger.log("Bundle disconnected, after failing before the test plan completed: \(error)")
      throw error
    case .unfinished:
      self.logger.log("Bundle disconnected, but test plan has not completed. This could mean a crash has occurred")
      throw await self.crashLogOrNotFoundError(description: "Lost connection to test process, but could not find a crash log")
    }
  }

  /// Fails with whichever of the two fails first, as either holds up the session.
  private static func waitForSession(_ events: TestBundleEvents) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await events.proxyChannelOpened.wait(timeout: ideInterfaceReadyTimeout, waitingFor: "XCTestManager_IDEInterface to be ready")
      }
      group.addTask {
        try await events.sessionStarted.wait(timeout: daemonSessionReadyTimeout, waitingFor: "testmanagerd to start the test session")
      }
      try await group.waitForAll()
    }
  }

  // MARK: - Diagnosis

  private func diagnosedConnectionError(from error: any Error) async -> any Error {
    let bundleID = context.testHostLaunchConfiguration.bundleID
    let runningPid: pid_t
    do {
      runningPid = try await target.application.processID(forBundleID: bundleID)
    } catch {
      return await crashLogOrNotFoundError(description: "Error while establishing connection to test bundle: The host application is likely to have crashed during startup, but could not find a crash log.")
    }
    let expectedPid = testHostApplication.processIdentifier
    if runningPid != expectedPid {
      // iOS sometimes relaunches a host that crashed very early as a vanilla process that idb cannot
      // drive, so there is no bundle to connect to.
      return TestBundleConnectionError.hostRelaunchedByOS(underlying: error)
    }
    if let stackshot = try? await ProcessFetcher.sampleStackshot(processIdentifier: expectedPid) {
      return TestBundleConnectionError.hostStalled(processIdentifier: expectedPid, stackshot: stackshot)
    }
    return error
  }

  private func crashLogOrNotFoundError(description notFound: String) async -> any Error {
    if let crashLog = try? await findCrashedProcessLog() {
      return TestBundleConnectionError.hostCrashed(crashLog: String(describing: crashLog))
    }
    return TestBundleConnectionError.connectionLost(message: notFound)
  }

  private func findCrashedProcessLog() async throws -> CrashReport {
    let bundleID = context.testHostLaunchConfiguration.bundleID
    if let runningPid = try? await target.application.processID(forBundleID: bundleID) {
      throw TestBundleConnectionError.processStillRunning(processIdentifier: runningPid)
    }
    var crashWaitTimeout = crashCheckWaitLimit
    if let env = ProcessInfo.processInfo.environment["FBXCTEST_CRASH_WAIT_TIMEOUT"] {
      crashWaitTimeout = TimeInterval((env as NSString).floatValue)
    }
    let pid = testHostApplication.processIdentifier
    let predicate = CrashLogPredicate.processIdentifier(pid)
    let info = try await target.crashLog.notifyOfCrash(matching: predicate, within: crashWaitTimeout, orThrow: TestBundleConnectionError.crashLogTimedOut(processIdentifier: pid, bundleID: bundleID, timeout: crashWaitTimeout))
    return try info.obtainCrashLog()
  }
}
