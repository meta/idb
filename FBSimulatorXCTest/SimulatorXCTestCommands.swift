/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
@preconcurrency import FBSimulatorControl
@preconcurrency import FBXCTestCore
import Foundation

private let testmanagerdSimSockTimeout: TimeInterval = 5
private let simSockEnvKey = "TESTMANAGERD_SIM_SOCK"

public enum SimulatorXCTestError: Error {
  case socketCreationFailed
  case socketFileMissing(path: String)
  case socketPathTooLong(path: String)
  case socketConnectionFailed
  case unexpectedReporter(reporterDescription: String)
  case testManagerAlreadyRunning(configurationDescription: String)
  case environmentVariableUnavailable(key: String, underlying: (any Error)?)
}

extension SimulatorXCTestError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .socketCreationFailed:
      return "Unable to create a unix domain socket"
    case let .socketFileMissing(path):
      return "Simulator indicated unix domain socket for testmanagerd at path \(path), but no file was found at that path."
    case let .socketPathTooLong(path):
      return "Unix domain socket path for simulator testmanagerd service '\(path)' is too big to fit in sockaddr_un.sun_path"
    case .socketConnectionFailed:
      return "Failed to connect to testmangerd socket"
    case let .unexpectedReporter(reporterDescription):
      return "\(reporterDescription) is not an XCTestReporter"
    case let .testManagerAlreadyRunning(configurationDescription):
      return "Cannot Start Test Manager with Configuration \(configurationDescription) as it is already running"
    case let .environmentVariableUnavailable(key, _):
      return "Failed to get \(key) from simulator environment"
    }
  }
}

public final class SimulatorXCTestCommands: XCTestExtendedCommands {

  // MARK: - Properties

  private weak var simulator: Simulator?
  private var isRunningXcodeBuildOperation: Bool = false

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - testmanagerd transport

  /// Resolves the testmanagerd unix-domain socket, connects to it, and hands the socket fd to
  /// `body` for the duration of the call, closing it on exit.
  public func withTransportForTestManagerService<R>(body: (Int32) async throws -> R) async throws -> R {
    guard self.simulator != nil else {
      throw WeakTargetError.simulator
    }
    let socketPath = try await testManagerDaemonSocketPath()
    let socketFD = try Self.connectedTestManagerSocket(atPath: socketPath)
    defer { close(socketFD) }
    return try await body(socketFD)
  }

  private static func connectedTestManagerSocket(atPath testManagerSocketString: String) throws -> Int32 {
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    if socketFD == -1 {
      throw SimulatorXCTestError.socketCreationFailed
    }
    if !FileManager.default.fileExists(atPath: testManagerSocketString) {
      close(socketFD)
      throw SimulatorXCTestError.socketFileMissing(path: testManagerSocketString)
    }
    let testManagerSocketCStr = testManagerSocketString.utf8CString
    if testManagerSocketCStr.count - 1 >= 0x68 {
      close(socketFD)
      throw SimulatorXCTestError.socketPathTooLong(path: testManagerSocketString)
    }
    var remote = sockaddr_un()
    remote.sun_family = sa_family_t(AF_UNIX)
    testManagerSocketCStr.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else {
        return
      }
      withUnsafeMutablePointer(to: &remote.sun_path) { sunPathPtr in
        sunPathPtr.withMemoryRebound(to: CChar.self, capacity: Int(buffer.count)) { dest in
          _ = memcpy(dest, baseAddress, buffer.count)
        }
      }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout.size(ofValue: remote.sun_len) + strlen(testManagerSocketString))
    let connectResult = withUnsafePointer(to: &remote) { remotePtr in
      remotePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        connect(socketFD, sockaddrPtr, length)
      }
    }
    if connectResult == -1 {
      close(socketFD)
      throw SimulatorXCTestError.socketConnectionFailed
    }
    return socketFD
  }

  public var path: String {
    (XcodeConfiguration.developerDirectory as NSString)
      .appendingPathComponent("Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest")
  }

  // MARK: - Async

  public func runTest(launchConfiguration: TestLaunchConfiguration, reporter: AnyObject, logger: any ControlCoreLogger) async throws {
    guard let simulator = self.simulator else {
      throw WeakTargetError.simulator
    }
    // `XCTestCommands` lives in FBControlCore, which cannot see `XCTestReporter` in FBXCTestCore,
    // so the reporter arrives type-erased and has to be recovered here.
    guard let typedReporter = reporter as? any XCTestReporter else {
      throw SimulatorXCTestError.unexpectedReporter(reporterDescription: String(describing: reporter))
    }

    if !launchConfiguration.shouldUseXcodebuild {
      try await runTest(with: launchConfiguration, reporter: typedReporter, logger: logger, workingDirectory: simulator.auxillaryDirectory)
      return
    }

    if isRunningXcodeBuildOperation {
      throw SimulatorXCTestError.testManagerAlreadyRunning(configurationDescription: String(describing: launchConfiguration))
    }

    _ = try await XcodeBuildOperation.terminateAbandonedXcodebuildProcesses(
      forUDID: simulator.udid,
      processFetcher: ProcessFetcher(),
      queue: simulator.workQueue,
      logger: logger)

    isRunningXcodeBuildOperation = true
    defer { isRunningXcodeBuildOperation = false }

    let subprocess = try await startTest(with: launchConfiguration, logger: logger)
    try await XcodeBuildOperation.confirmExit(ofXcodebuildOperation: subprocess, configuration: launchConfiguration, reporter: typedReporter, logger: logger)
  }

  public func listTests(forBundleAtPath bundlePath: String, timeout: TimeInterval, withAppAtPath appPath: String?) async throws -> [String] {
    guard let simulator = self.simulator else {
      throw WeakTargetError.simulator
    }

    let bundleDescriptor = try BundleDescriptor(path: bundlePath, fallbackIdentifier: true)
    let architectures = Set((bundleDescriptor.binary?.architectures ?? []).map(\.rawValue))
    let configuration = ListTestConfiguration(
      environment: [:],
      workingDirectory: simulator.auxillaryDirectory,
      testBundlePath: bundlePath,
      runnerAppPath: appPath,
      waitForDebugger: false,
      timeout: timeout,
      architectures: architectures)

    return try await ListTestRunner(target: simulator, configuration: configuration, logger: simulator.logger).listTests()
  }

  public func extendedTestShim() async throws -> String {
    let shimConfig = try await XCTestShimConfiguration.sharedShimConfiguration()
    return shimConfig.iOSSimulatorTestShimPath
  }

  // MARK: - Private

  private func runTest(with testLaunchConfiguration: TestLaunchConfiguration, reporter: any XCTestReporter, logger: any ControlCoreLogger, workingDirectory: String?) async throws {
    guard let simulator = self.simulator else {
      throw WeakTargetError.simulator
    }

    if simulator.state != .booted {
      throw SimulatorStateError.notBooted(operation: "run tests", state: simulator.stateString.rawValue)
    }

    try await ManagedTestRunner.runToCompletion(
      withTarget: simulator,
      configuration: testLaunchConfiguration,
      codesign: ControlCoreGlobalConfiguration.confirmCodesignaturesAreValid
        ? CodesignProvider(identityName: "-", logger: simulator.logger)
        : nil,
      workingDirectory: simulator.auxillaryDirectory,
      reporter: reporter,
      logger: logger)
  }

  func testManagerDaemonSocketPath() async throws -> String {
    guard let simulator = self.simulator else {
      throw WeakTargetError.simulator
    }
    let deadline = Date().addingTimeInterval(testmanagerdSimSockTimeout)
    var lastError: (any Error)?
    while true {
      do {
        let socketPath = try simulator.device.getenv(simSockEnvKey)
        if !socketPath.isEmpty {
          return socketPath
        }
      } catch {
        lastError = error
      }
      if Date() >= deadline {
        throw SimulatorXCTestError.environmentVariableUnavailable(key: simSockEnvKey, underlying: lastError)
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  private func startTest(with configuration: TestLaunchConfiguration, logger: any ControlCoreLogger) async throws -> RunningSubprocess {
    guard let simulator = self.simulator else {
      throw WeakTargetError.simulator
    }

    let filePath = try XcodeBuildOperation.createXCTestRunFile(at: simulator.auxillaryDirectory, fromConfiguration: configuration)
    let xcodeBuildPath = try XcodeBuildOperation.xcodeBuildPath()

    let shimConfig = try await XCTestShimConfiguration.sharedShimConfiguration()
    return try await XcodeBuildOperation.operation(
      withUDID: simulator.udid,
      configuration: configuration,
      xcodeBuildPath: xcodeBuildPath,
      testRunFilePath: filePath,
      simDeviceSet: simulator.customDeviceSetPath,
      macOSTestShimPath: shimConfig.macOSTestShimPath,
      logger: logger.withName("xcodebuild"))
  }
}
