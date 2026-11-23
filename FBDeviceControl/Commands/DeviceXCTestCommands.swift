/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import FBControlCore
import FBXCTestCore
import Foundation
import MobileDeviceAPI

public enum DeviceXCTestError: Error {
  case testManagerAlreadyRunning(configurationDescription: String)
  case unexpectedReporter(reporterDescription: String)
  case xctestrunCreationFailed(underlying: any Error)
  case xcodebuildNotFound(underlying: any Error)
  case deviceIdentifierUnavailable(deviceDescription: String)
}

extension DeviceXCTestError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .testManagerAlreadyRunning(configurationDescription):
      return "Cannot Start Test Manager with Configuration \(configurationDescription) as it is already running"
    case let .unexpectedReporter(reporterDescription):
      return "\(reporterDescription) is not an XCTestReporter"
    case let .xctestrunCreationFailed(underlying):
      return "Failed to create xctestrun file: \(underlying)"
    case let .xcodebuildNotFound(underlying):
      return "Failed to find xcodebuild: \(underlying)"
    case let .deviceIdentifierUnavailable(deviceDescription):
      return "No device identifier could be copied from \(deviceDescription)"
    }
  }
}

public final class DeviceXCTestCommands: XCTestCommands {
  private(set) weak var device: Device?
  private(set) var workingDirectory: String
  private(set) var processFetcher: ProcessFetcher
  var runningXcodeBuildOperation = false

  public init(device: Device, workingDirectory: String = NSTemporaryDirectory()) {
    self.device = device
    self.workingDirectory = workingDirectory
    self.processFetcher = ProcessFetcher()
  }

  // MARK: - Async

  public func runTest(
    launchConfiguration testLaunchConfiguration: TestLaunchConfiguration,
    reporter: AnyObject,
    logger: any ControlCoreLogger
  ) async throws {
    if runningXcodeBuildOperation {
      throw DeviceXCTestError.testManagerAlreadyRunning(configurationDescription: String(describing: testLaunchConfiguration))
    }
    guard let device else {
      throw DeviceNilError.deviceNil
    }
    guard let reporter = reporter as? any XCTestReporter else {
      throw DeviceXCTestError.unexpectedReporter(reporterDescription: String(describing: reporter))
    }
    runningXcodeBuildOperation = true
    defer { runningXcodeBuildOperation = false }

    _ = try await XcodeBuildOperation.terminateAbandonedXcodebuildProcesses(forUDID: device.udid, processFetcher: processFetcher, queue: device.workQueue, logger: logger)
    let task = try await startTestWithLaunchConfiguration(configuration: testLaunchConfiguration, logger: logger)
    try await XcodeBuildOperation.confirmExit(ofXcodebuildOperation: task, configuration: testLaunchConfiguration, reporter: reporter, logger: logger)
  }

  private func startTestWithLaunchConfiguration(configuration: TestLaunchConfiguration, logger: any ControlCoreLogger) async throws -> RunningSubprocess {
    let filePath: String
    do {
      filePath = try XcodeBuildOperation.createXCTestRunFile(at: workingDirectory, fromConfiguration: configuration)
    } catch {
      throw DeviceXCTestError.xctestrunCreationFailed(underlying: error)
    }
    let xcodeBuildPath: String
    do {
      xcodeBuildPath = try XcodeBuildOperation.xcodeBuildPath()
    } catch {
      throw DeviceXCTestError.xcodebuildNotFound(underlying: error)
    }
    // This is to work around a bug in xcodebuild. The UDID inside xcodebuild does not match
    // UDID reported by device properties (the difference is missing hyphen in xcodebuild).
    // This results in xcodebuild returning an error, since it cannot find a device with requested
    // id (e.g. we query for 00008101-001D296A2EE8001E, while xcodebuild have
    // 00008101001D296A2EE8001E).
    guard let device else {
      throw DeviceNilError.deviceNil
    }
    guard let identifier = device.calls.CopyDeviceIdentifier(device.amDeviceRef) else {
      throw DeviceXCTestError.deviceIdentifierUnavailable(deviceDescription: String(describing: device))
    }
    let udid = identifier.takeRetainedValue() as String

    return try await XcodeBuildOperation.operation(withUDID: udid, configuration: configuration, xcodeBuildPath: xcodeBuildPath, testRunFilePath: filePath, simDeviceSet: nil, macOSTestShimPath: nil, logger: logger.withName("xcodebuild"))
  }
}

// MARK: - Device+XCTestTarget

extension Device: XCTestTarget {}
