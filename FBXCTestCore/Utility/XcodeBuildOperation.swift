/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

private let XcodebuildEnvironmentTargetUDID = "XCTESTBOOTSTRAP_TARGET_UDID"
private let XcodebuildEnvironmentDeviceSetPath = "SIM_DEVICE_SET_PATH"
private let XcodebuildEnvironmentInsertDylib = "DYLD_INSERT_LIBRARIES"
private let XcodebuildDestinationTimeoutSecs = "180"

enum XcodeBuildError: Error {
  case shimMissing
  case writeFailed(path: String)
  case xcodebuildMissing(path: String)
}

extension XcodeBuildError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .shimMissing:
      return "Failed to locate the shim file for xcodebuild method swizzling"
    case let .writeFailed(path):
      return "Failed to write to file \(path)"
    case let .xcodebuildMissing(path):
      return "xcodebuild does not exist at expected path \(path)"
    }
  }
}

public enum XcodeBuildOperation {

  // MARK: - Initializers

  public static func operation(withUDID udid: String, configuration: TestLaunchConfiguration, xcodeBuildPath: String, testRunFilePath: String, simDeviceSet simDeviceSetPath: String?, macOSTestShimPath: String?, logger: (any ControlCoreLogger)?) async throws -> RunningSubprocess {
    var arguments = [
      "test-without-building",
      "-xctestrun", testRunFilePath,
      "-destination", "id=\(udid)",
      "-destination-timeout", XcodebuildDestinationTimeoutSecs,
    ]

    if let resultBundlePath = configuration.resultBundlePath {
      arguments.append(contentsOf: ["-resultBundlePath", resultBundlePath])
    }

    for test in configuration.testsToRun ?? [] {
      arguments.append("-only-testing:\(test)")
    }

    for test in configuration.testsToSkip ?? [] {
      arguments.append("-skip-testing:\(test)")
    }

    var environment = XCTestShimConfiguration.unarmedAudioInjectionEnvironment(ProcessInfo.processInfo.environment)
    environment[XcodebuildEnvironmentTargetUDID] = udid

    if let simDeviceSetPath {
      guard let macOSTestShimPath else {
        throw XcodeBuildError.shimMissing
      }
      environment[XcodebuildEnvironmentDeviceSetPath] = simDeviceSetPath
      if let existingDylib = environment[XcodebuildEnvironmentInsertDylib] {
        environment[XcodebuildEnvironmentInsertDylib] = "\(existingDylib):\(macOSTestShimPath)"
      } else {
        environment[XcodebuildEnvironmentInsertDylib] = macOSTestShimPath
      }
    }

    logger?.log("Starting test with xcodebuild | Arguments: \(arguments.joined(separator: " ")) | Environments: \(environment)")
    let subprocess = Subprocess(executable: xcodeBuildPath, arguments: arguments, environment: .exact(environment))
    let running: RunningSubprocess
    if let logger {
      running = try await subprocess.launch(output: .logger(logger), error: .logger(logger), logger: logger)
    } else {
      // The unset builder default buffered both streams into memory that
      // nothing ever read; an open null device discards them outright.
      running = try await subprocess.launch(output: .nullDevice, error: .nullDevice, logger: nil)
    }
    logger?.log("Task started pid \(running.processIdentifier) for xcodebuild \(arguments.joined(separator: " "))")
    return running
  }

  // MARK: - Public Methods

  public static func xctestRunProperties(_ testLaunch: TestLaunchConfiguration) -> [String: Any] {
    return [
      "StubBundleId": [
        "TestHostPath": testLaunch.testHostBundle?.path as Any,
        "TestBundlePath": testLaunch.testBundle.path,
        "UseUITargetAppProvidedByTests": true,
        "IsUITestBundle": true,
        "CommandLineArguments": testLaunch.applicationLaunchConfiguration.arguments,
        "EnvironmentVariables": testLaunch.applicationLaunchConfiguration.environment,
        "TestingEnvironmentVariables": [
          "DYLD_FRAMEWORK_PATH": "__TESTROOT__:__PLATFORMS__/iPhoneOS.platform/Developer/Library/Frameworks",
          "DYLD_LIBRARY_PATH": "__TESTROOT__:__PLATFORMS__/iPhoneOS.platform/Developer/Library/Frameworks",
        ],
      ] as [String: Any]
    ]
  }

  public static func createXCTestRunFile(at directory: String, fromConfiguration configuration: TestLaunchConfiguration) throws -> String {
    let fileName = ProcessInfo.processInfo.globallyUniqueString.appending(".xctestrun")
    let path = (directory as NSString).appendingPathComponent(fileName)

    let defaultTestRunProperties = XcodeBuildOperation.xctestRunProperties(configuration)

    let mergedTestRunProperties =
      configuration.xcTestRunProperties.map {
        XcodeBuildOperation.overwriteXCTestRunProperties(withBaseProperties: $0, newProperties: defaultTestRunProperties)
      } ?? defaultTestRunProperties
    let testRunProperties = unarmedAudioInjectionProperties(
      mergedTestRunProperties, applicationEnvironment: configuration.applicationLaunchConfiguration.environment)

    if !(testRunProperties as NSDictionary).write(toFile: path, atomically: false) {
      throw XcodeBuildError.writeFailed(path: path)
    }
    return path
  }

  public static func terminateAbandonedXcodebuildProcesses(forUDID udid: String, processFetcher: ProcessFetcher, queue: DispatchQueue, logger: any ControlCoreLogger) async throws -> [RunningProcessInfo] {
    let processes = XcodeBuildOperation.activeXcodebuildProcesses(forUDID: udid, processFetcher: processFetcher)
    if processes.isEmpty {
      logger.log("No processes for \(udid) to terminate")
      return []
    }
    logger.log("Terminating abandoned xcodebuild processes \(CollectionInformation.oneLineDescription(from: processes))")
    let terminator = ProcessTerminator(processFetcher: processFetcher, workQueue: queue, logger: logger)
    // Each termination waits for its process to leave the process table, so they are run
    // concurrently rather than one after another.
    try await withThrowingTaskGroup(of: Void.self) { group in
      for processIdentifier in processes.map(\.processIdentifier) {
        group.addTask {
          try await terminator.terminate(processIdentifier)
        }
      }
      try await group.waitForAll()
    }
    return processes
  }

  public static func xcodeBuildPath() throws -> String {
    let path = (XcodeConfiguration.developerDirectory as NSString).appendingPathComponent("/usr/bin/xcodebuild")
    if !FileManager.default.fileExists(atPath: path) {
      throw XcodeBuildError.xcodebuildMissing(path: path)
    }
    return path
  }

  public static func overwriteXCTestRunProperties(withBaseProperties baseProperties: [String: Any], newProperties: [String: Any]) -> [String: Any] {
    let defaultTestProperties = newProperties["StubBundleId"] as? [String: Any] ?? [:]
    let armingVariable = XCTestShimConfiguration.audioInjectionEnvironmentVariable
    let explicitArming = (defaultTestProperties["EnvironmentVariables"] as? [String: String])?[armingVariable]
    var mutableTestRunProperties: [String: Any] = [:]
    for (testId, value) in baseProperties {
      guard var mutableTestProperties = value as? [String: Any] else { continue }
      for (key, newValue) in defaultTestProperties {
        if mutableTestProperties[key] != nil {
          var replacement = newValue
          if explicitArming == nil, ["EnvironmentVariables", "TestingEnvironmentVariables"].contains(key),
            var environment = newValue as? [String: Any],
            let existing = mutableTestProperties[key] as? [String: Any]
          {
            environment[armingVariable] = environment[armingVariable] ?? existing[armingVariable]
            replacement = environment
          }
          mutableTestProperties[key] = replacement
        }
      }
      mutableTestRunProperties[testId] = mutableTestProperties
    }
    return mutableTestRunProperties
  }

  static func unarmedAudioInjectionProperties(
    _ properties: [String: Any], applicationEnvironment: [String: String]
  ) -> [String: Any] {
    let armingVariable = XCTestShimConfiguration.audioInjectionEnvironmentVariable
    var updated = properties
    for (testID, value) in properties {
      guard var target = value as? [String: Any], target["TestBundlePath"] != nil else { continue }
      var environment = target["EnvironmentVariables"] as? [String: Any] ?? [:]
      let testingEnvironment = target["TestingEnvironmentVariables"] as? [String: Any] ?? [:]
      if environment[armingVariable] == nil && testingEnvironment[armingVariable] == nil {
        environment[armingVariable] = "0"
        target["EnvironmentVariables"] = environment
      }
      if target["IsUITestBundle"] as? Bool == true || target["UITargetAppEnvironmentVariables"] != nil {
        var application = target["UITargetAppEnvironmentVariables"] as? [String: Any] ?? [:]
        if application[armingVariable] == nil {
          application[armingVariable] = applicationEnvironment[armingVariable] ?? "0"
        }
        target["UITargetAppEnvironmentVariables"] = application
      }
      updated[testID] = target
    }
    return updated
  }

  public static func confirmExit(ofXcodebuildOperation running: RunningSubprocess, configuration: TestLaunchConfiguration, reporter: any XCTestReporter, logger: any ControlCoreLogger) async throws {
    let status = try await withTaskCancellationHandler {
      try await running.terminationStatus
    } onCancel: {
      Task {
        await running.terminate(gracePeriod: 1)
      }
    }
    guard case .exited(let code) = status, code == 0 || code == 65 else {
      throw SubprocessError.unacceptableTermination(
        status: status,
        policy: .mustExit([0, 65]),
        executable: "xcodebuild",
        processIdentifier: running.processIdentifier)
    }
    logger.log("xcodebuild operation completed successfully with pid \(running.processIdentifier)")
    if let resultBundlePath = configuration.resultBundlePath {
      try await XCTestResultBundleParser.parse(resultBundlePath, reporter: reporter, logger: logger, extractScreenshots: configuration.reportResultBundle)
    } else {
      logger.log("No result bundle to parse")
    }
    logger.log("Reporting test results")
    reporter.didFinishExecutingTestPlan()
  }

  // MARK: - Private

  private static func activeXcodebuildProcesses(forUDID udid: String, processFetcher: ProcessFetcher) -> [RunningProcessInfo] {
    let xcodebuildProcesses = processFetcher.processes(withProcessName: "xcodebuild")
    var relevantProcesses: [RunningProcessInfo] = []
    for process in xcodebuildProcesses {
      guard let targetUDID = process.environment[XcodebuildEnvironmentTargetUDID], targetUDID == udid else {
        continue
      }
      relevantProcesses.append(process)
    }
    return relevantProcesses
  }
}
