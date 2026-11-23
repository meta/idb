/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

enum ListTestError: Error {
  case testListJSONParseFailed
  case unexpectedTestName(value: String)
  case listingFailed(exitCode: Int32, exitDescription: String, stdErr: String)
}

extension ListTestError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .testListJSONParseFailed:
      return "Failed to parse test list JSON"
    case let .unexpectedTestName(value):
      return "Received unexpected test name from shim: \(value)"
    case let .listingFailed(exitCode, exitDescription, stdErr):
      return "Listing of tests failed due to xctest binary exiting with non-zero exit code \(exitCode) [\(exitDescription)]: \(stdErr)"
    }
  }
}

public final class ListTestRunner {

  let target: any LogicTestTarget
  private let configuration: ListTestConfiguration
  private let logger: any ControlCoreLogger

  public init(target: any LogicTestTarget, configuration: ListTestConfiguration, logger: any ControlCoreLogger) {
    self.target = target
    self.configuration = configuration
    self.logger = logger
  }

  public func listTests() async throws -> [String] {
    let shimPath = try await target.xctest.extendedTestShim()
    let shimBuffer = ConsumableBuffer()
    let shimOutput = try FileBackedOutput.fifo(draining: shimBuffer)
    let stdErrBuffer = ConsumableBuffer()
    let stdErrConsumer: any DataConsumer = CompositeDataConsumer(consumers: [
      stdErrBuffer,
      LoggingDataConsumer(logger: logger),
    ])

    let exitCode: Int32
    do {
      exitCode = try await TemporaryDirectory(logger: logger).withTemporaryDirectory { temporaryDirectory in
        let libraries = try await OToolDynamicLibs.findFullPath(forSanitiserDyldInBundle: configuration.testBundlePath)
        let environment = ListTestRunner.setupEnvironment(withDylibs: libraries, shimPath: shimPath, shimOutputFilePath: shimOutput.path, bundlePath: configuration.testBundlePath, target: target)
        let subprocess = try await listTestSubprocess(environment: environment, temporaryDirectory: temporaryDirectory)
        let process = try await subprocess.launch(on: target.subprocessLauncher, output: .consumer(LoggingDataConsumer(logger: logger)), error: .consumer(stdErrConsumer), logger: logger)
        return try await XCTestProcess.awaitExitCode(of: process, processName: (subprocess.executable as NSString).lastPathComponent, completesWithin: configuration.testTimeout, crashLogCommands: nil, logger: logger)
      }
    } catch {
      await shimOutput.finish()
      throw error
    }
    await shimOutput.finish()

    if let description = XCTestProcess.describeFailingExitCode(exitCode) {
      let stdErrReversed = stdErrBuffer.lines().reversed().joined(separator: "\n")
      throw ListTestError.listingFailed(exitCode: exitCode, exitDescription: description, stdErr: stdErrReversed)
    }
    try await shimBuffer.awaitFinishedConsuming()
    return try ListTestRunner.testNames(fromShimOutput: shimBuffer.data())
  }

  // MARK: - Private

  private func listTestSubprocess(environment: [String: String], temporaryDirectory: URL) async throws -> Subprocess {
    guard let runnerAppPath = configuration.runnerAppPath, BundleDescriptor.isApplication(atPath: runnerAppPath) else {
      let thinned = try await ArchitectureProcessAdapter.thinExecutable(atPath: target.xctest.path, toAnyArchitectureIn: Set(configuration.architectures.map { Architecture(rawValue: $0) }), temporaryDirectory: temporaryDirectory)
      return Subprocess(
        executable: thinned.path,
        environment: .exact(
          XCTestShimConfiguration.unarmedAudioInjectionEnvironment(
            environment.merging(thinned.environment) { _, thinnedValue in thinnedValue })))
    }
    let developerLibraryPath = (XcodeConfiguration.developerDirectory as NSString).appendingPathComponent("Platforms/iPhoneSimulator.platform/Developer/Library")
    let testFrameworkPaths = [
      (developerLibraryPath as NSString).appendingPathComponent("Frameworks"),
      (developerLibraryPath as NSString).appendingPathComponent("PrivateFrameworks"),
    ].joined(separator: ":")
    var environment = environment
    environment["DYLD_FALLBACK_FRAMEWORK_PATH"] = testFrameworkPaths
    environment["DYLD_FALLBACK_LIBRARY_PATH"] = testFrameworkPaths
    let appBundle = try BundleDescriptor(path: runnerAppPath)
    return Subprocess(
      executable: appBundle.binary?.path ?? target.xctest.path,
      environment: .exact(XCTestShimConfiguration.unarmedAudioInjectionEnvironment(environment)))
  }

  private static func setupEnvironment(withDylibs libraries: [String], shimPath: String, shimOutputFilePath: String, bundlePath: String, target: any Target) -> [String: String] {
    var librariesWithShim = [shimPath]
    librariesWithShim.append(contentsOf: libraries)

    var environment: [String: String] = [
      "DYLD_INSERT_LIBRARIES": librariesWithShim.joined(separator: ":"),
      "TEST_SHIM_OUTPUT_PATH": shimOutputFilePath,
      "TEST_SHIM_BUNDLE_PATH": bundlePath,
    ]

    for (key, value) in target.environmentAdditions() {
      environment[key] = value
    }

    return environment
  }

  private static func testNames(fromShimOutput data: Data) throws -> [String] {
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      NSLog("Shimulator buffer data (should contain test information): %@", String(data: data, encoding: .utf8) ?? "")
      throw error
    }
    guard let tests = parsed as? [[String: String]] else {
      NSLog("Shimulator buffer data (should contain test information): %@", String(data: data, encoding: .utf8) ?? "")
      throw ListTestError.testListJSONParseFailed
    }
    return try tests.map { test in
      guard let testName = test["legacyTestName"] else {
        throw ListTestError.unexpectedTestName(value: String(describing: test["legacyTestName"]))
      }
      return testName
    }
  }
}
