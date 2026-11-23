/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import Foundation

enum TestManagerError: Error {
  case hostProcessStalled(timeout: TimeInterval, processIdentifier: pid_t, stackshot: String)
  case appUnderTestNotInstallable(configurationDescription: String)
}

extension TestManagerError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .hostProcessStalled(timeout, processIdentifier, stackshot):
      return "Waited \(timeout) seconds for process \(processIdentifier) to terminate, but the host application process stalled: \(stackshot)"
    case let .appUnderTestNotInstallable(configurationDescription):
      return "Could not install App-Under-Test \(configurationDescription) as it is not installed and no path was provided"
    }
  }
}

private enum RunOutcome {
  case completed
  case timedOut
}

/// A simplified re-implementation of Apple's `_IDETestManagerAPIMediator`: takes over once the test host process has started, mediating between the host, `testmanagerd` and the test runner.
@objc
public final class TestManagerAPIMediator: NSObject, @unchecked Sendable {

  private static let defaultTestTimeout: TimeInterval = 60 * 60

  // MARK: - Properties

  private let context: TestManagerContext
  private let target: any XCTestExtendedTarget
  private let reporter: any XCTestReporter
  private let logger: any ControlCoreLogger
  private let requestQueue: DispatchQueue

  private let tokenLock = NSLock()
  private var tokenToLaunchedApp: [NSNumber: any LaunchedApplication] = [:]

  private lazy var ideInterface = TestManagerAPIMediatorIDEInterface(mediator: self, context: context, reporter: XCTestReporterSink(reporter), logger: ControlCoreLoggerSink(logger))

  // MARK: - Initializers

  /// Runs the whole test session to completion. Test failures are reported, not thrown; only execution errors throw.
  public static func connectAndRunUntilCompletion(
    with context: TestManagerContext,
    target: any XCTestExtendedTarget,
    reporter: any XCTestReporter,
    logger: any ControlCoreLogger
  ) async throws {
    let mediator = TestManagerAPIMediator(context: context, target: target, reporter: reporter, logger: logger)
    try await mediator.connectAndRunUntilCompletion()
  }

  private init(
    context: TestManagerContext,
    target: any XCTestExtendedTarget,
    reporter: any XCTestReporter,
    logger: any ControlCoreLogger
  ) {
    self.context = context
    self.target = target
    self.reporter = reporter
    self.logger = logger
    self.requestQueue = DispatchQueue(label: "com.facebook.xctestboostrap.mediator")
    super.init()
  }

  // MARK: - Orchestration

  private func connectAndRunUntilCompletion() async throws {
    let timeout = context.timeout <= 0 ? Self.defaultTestTimeout : context.timeout
    let result: Result<Void, any Error>
    do {
      let launchedApplication = try await target.application.launch(context.testHostLaunchConfiguration)
      do {
        if context.testHostLaunchConfiguration.waitForDebugger {
          reporter.processWaitingForDebugger(processIdentifier: launchedApplication.processIdentifier)
          try await ProcessFetcher.waitForDebuggerToAttachAndContinue(for: launchedApplication.processIdentifier)
        }
        try await runUntilCompletion(launchedApplication: launchedApplication, timeout: timeout)
        result = .success(())
      } catch {
        result = .failure(error)
      }
      _ = try? await launchedApplication.terminate()
    } catch {
      result = .failure(error)
    }

    reporter.processUnderTestDidExit()
    if case let .failure(error) = result {
      logger.log("Test Execution finished in error \(error)")
      reporter.didCrashDuringTest(error)
    }
    try result.get()
  }

  private func runUntilCompletion(launchedApplication: any LaunchedApplication, timeout: TimeInterval) async throws {
    // The timeout is applied to the lifecycle of the entire application.
    let outcome = try await withThrowingTaskGroup(of: RunOutcome.self) { group in
      group.addTask {
        // The transport socket is closed when this scope ends, so the whole connection must run inside it.
        try await self.target.xctest.withTransportForTestManagerService { socket in
          let connection = TestBundleConnection(
            context: self.context,
            target: self.target,
            socket: socket,
            interface: self.ideInterface,
            testHostApplication: launchedApplication,
            requestQueue: self.requestQueue,
            logger: self.logger
          )
          try await connection.connectAndRun()
        }
        try await self.terminateSpawnedProcesses()
        _ = try? await launchedApplication.terminate()
        return .completed
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return .timedOut
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else { preconditionFailure("The task group has two children; next() cannot be empty") }
      return first
    }
    switch outcome {
    case .completed:
      return
    case .timedOut:
      logger.log("Timed out after \(timeout), attempting stack sample")
      let stackshot = (try? await sampleStack(forProcessIdentifier: launchedApplication.processIdentifier)) ?? "<no stackshot>"
      try? await terminateSpawnedProcesses()
      throw TestManagerError.hostProcessStalled(timeout: timeout, processIdentifier: launchedApplication.processIdentifier, stackshot: stackshot)
    }
  }

  private func sampleStack(forProcessIdentifier processIdentifier: pid_t) async throws -> String {
    try await ProcessFetcher.sampleStackshot(processIdentifier: processIdentifier)
  }

  // MARK: - Spawned process token map (synchronous, lock-guarded)

  private func storeToken(_ token: NSNumber, launchedApplication: any LaunchedApplication) {
    tokenLock.lock()
    defer { tokenLock.unlock() }
    tokenToLaunchedApp[token] = launchedApplication
  }

  private func launchedApplication(forToken token: NSNumber) -> (any LaunchedApplication)? {
    tokenLock.lock()
    defer { tokenLock.unlock() }
    return tokenToLaunchedApp[token]
  }

  private func drainSpawnedApplications() -> [any LaunchedApplication] {
    tokenLock.lock()
    defer { tokenLock.unlock() }
    let apps = Array(tokenToLaunchedApp.values)
    tokenToLaunchedApp.removeAll()
    return apps
  }

  private func terminateSpawnedProcesses() async throws {
    let appsToKill = drainSpawnedApplications()
    if appsToKill.isEmpty {
      return
    }
    logger.log("Terminating processes spawned due to test bundle requests: \(appsToKill.map(\.bundleID))")
    for app in appsToKill {
      try await target.application.kill(bundleID: app.bundleID)
    }
  }

  // MARK: - Application lifecycle (invoked by the IDE interface delegate)

  @objc(launchProcessForUITestWithToken:path:bundleID:arguments:environment:completion:)
  public func launchProcessForUITest(
    withToken token: NSNumber,
    path: String?,
    bundleID: String,
    arguments: [String],
    environment: [String: String],
    completion: @escaping @Sendable ((any Error)?) -> Void
  ) {
    logger.log("Test process requested process launch with bundleID \(bundleID)")
    Task {
      do {
        let launchedApplication = try await self.launchUITestProcess(path: path, bundleID: bundleID, arguments: arguments, environment: environment)
        self.storeToken(token, launchedApplication: launchedApplication)
        completion(nil)
      } catch {
        completion(error)
      }
    }
  }

  @objc(terminateProcessForToken:completion:)
  public func terminateProcess(forToken token: NSNumber?, completion: @escaping @Sendable ((any Error)?) -> Void) {
    logger.log("Test process requested process termination with token \(String(describing: token))")
    guard let token else {
      completion(NSError(domain: "XCTestIDEInterfaceErrorDomain", code: 0x1, userInfo: [NSLocalizedDescriptionKey: "API violation: token was nil."]))
      return
    }
    guard let app = launchedApplication(forToken: token) else {
      completion(NSError(domain: "XCTestIDEInterfaceErrorDomain", code: 0x2, userInfo: [NSLocalizedDescriptionKey: "Invalid or expired token: no matching operation was found."]))
      return
    }
    let bundleID = app.bundleID
    Task {
      do {
        try await self.target.application.kill(bundleID: bundleID)
        completion(nil)
      } catch {
        completion(error)
      }
    }
  }

  private func launchUITestProcess(path: String?, bundleID: String, arguments: [String], environment: [String: String]) async throws -> any LaunchedApplication {
    var targetEnvironment = context.testedApplicationAdditionalEnvironment
    for (key, value) in environment {
      targetEnvironment[key] = value
    }
    let launch = ApplicationLaunchConfiguration(
      bundleID: bundleID,
      bundleName: bundleID,
      arguments: arguments,
      environment: targetEnvironment,
      waitForDebugger: false,
      stdOut: .consumer(LoggingDataConsumer(logger: logger)),
      stdErr: .consumer(LoggingDataConsumer(logger: logger)),
      launchMode: .failIfRunning
    )
    return try await launchApplication(launch, atPath: path)
  }

  private func launchApplication(_ configuration: ApplicationLaunchConfiguration, atPath path: String?) async throws -> any LaunchedApplication {
    if let installed = try? await target.application.installed(bundleID: configuration.bundleID), installed.bundle.path == path {
      return try await target.application.launch(configuration)
    }
    return try await installAndLaunchApplication(configuration, atPath: path)
  }

  private func installAndLaunchApplication(_ configuration: ApplicationLaunchConfiguration, atPath path: String?) async throws -> any LaunchedApplication {
    guard let path else {
      throw TestManagerError.appUnderTestNotInstallable(configurationDescription: String(describing: configuration))
    }
    if await isApplicationInstalled(bundleID: configuration.bundleID) {
      try await target.application.uninstall(bundleID: configuration.bundleID)
    }
    _ = try await target.application.install(atPath: path)
    return try await target.application.launch(configuration)
  }

  private func isApplicationInstalled(bundleID: String) async -> Bool {
    do {
      _ = try await target.application.installed(bundleID: bundleID)
      return true
    } catch {
      return false
    }
  }
}
