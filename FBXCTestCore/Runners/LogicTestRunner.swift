/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

private let EndOfFileTimeout: TimeInterval = 5

private struct LogicTestRunConsumers {
  let stdOut: any DataConsumer
  let stdErr: any DataConsumer
  let stdErrBuffer: ConsumableBuffer
  let shim: any DataConsumer & DataConsumerLifecycle
}

enum LogicTestRunError: Error {
  case xctestProcessFailed(exitCode: Int32, exitDescription: String, stdErr: String)
  case sigstopWaitFailed(processIdentifier: pid_t, underlying: any Error)
}

extension LogicTestRunError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .xctestProcessFailed(exitCode, exitDescription, stdErr):
      return "xctest process exited in failure (\(exitCode)): \(exitDescription) \(stdErr)"
    case let .sigstopWaitFailed(processIdentifier, underlying):
      return "Failed to wait test process (pid \(processIdentifier)) to receive a SIGSTOP: '\(underlying.localizedDescription)'"
    }
  }
}

public final class LogicTestRunner {

  private let target: any LogicTestTarget
  private let configuration: LogicTestConfiguration
  private let reporter: any LogicXCTestReporter
  private let logger: any ControlCoreLogger

  public init(target: any LogicTestTarget, configuration: LogicTestConfiguration, reporter: any LogicXCTestReporter, logger: any ControlCoreLogger) {
    self.target = target
    self.configuration = configuration
    self.reporter = reporter
    self.logger = logger
  }

  public func run() async throws {
    let shimPath = try await target.xctest.extendedTestShim()
    let consumers = try await buildConsumers()
    let shimOutput = try FileBackedOutput.fifo(draining: consumers.shim)

    logger.log("Starting Logic Test execution of \(configuration)")
    reporter.didBeginExecutingTestPlan()

    // A failure to launch is not reported as a crash; anything after the launch is.
    let completion: Result<Int32, any Error>
    do {
      completion = try await TemporaryDirectory(logger: logger).withTemporaryDirectory { temporaryDirectory in
        let subprocess = try await testSubprocess(shimPath: shimPath, shimOutputPath: shimOutput.path, temporaryDirectory: temporaryDirectory)
        let process = try await subprocess.launch(on: target.subprocessLauncher, output: .consumer(consumers.stdOut), error: .consumer(consumers.stdErr), logger: logger)
        do {
          return .success(try await awaitTestProcess(process, processName: (subprocess.executable as NSString).lastPathComponent))
        } catch {
          return .failure(error)
        }
      }
    } catch {
      await shimOutput.finish()
      throw error
    }
    await finishReadingShim(shimOutput, consumer: consumers.shim)

    do {
      let exitCode = try completion.get()
      logger.log("xctest process terminated, exited with \(exitCode), checking status code")
      if let descriptionOfExit = XCTestProcess.describeFailingExitCode(exitCode) {
        let stdErrReversed = consumers.stdErrBuffer.lines().reversed().joined(separator: "\n")
        throw LogicTestRunError.xctestProcessFailed(exitCode: exitCode, exitDescription: descriptionOfExit, stdErr: stdErrReversed)
      }
    } catch {
      logger.log("Abnormal exit of xctest process \(error)")
      let reporter = self.reporter
      await afterQueuedOutput { reporter.didCrashDuringTest(error as NSError) }
      throw error
    }
    logger.log("Normal exit of xctest process")
    let reporter = self.reporter
    await afterQueuedOutput { reporter.didFinishExecutingTestPlan() }
  }

  // MARK: - Private

  // The output consumers report each line asynchronously on `target.workQueue`, and finishing
  // them does not wait for those dispatches, so the end of the plan is reported from the same
  // serial queue to land behind them.
  private func afterQueuedOutput(_ report: @escaping () -> Void) async {
    // The reporter is not Sendable, but every call to it, this one included, runs on that one
    // serial queue.
    nonisolated(unsafe) let report = report
    await target.workQueue.perform {
      report()
    }
  }

  private func testSubprocess(shimPath: String, shimOutputPath: String, temporaryDirectory: URL) async throws -> Subprocess {
    let libraries = try await OToolDynamicLibs.findFullPath(forSanitiserDyldInBundle: configuration.testBundlePath)
    let environment = LogicTestRunner.setupEnvironment(withDylibs: configuration.processUnderTestEnvironment, withLibraries: libraries, injectLibraries: configuration.injectLibraries, shimOutputFilePath: shimOutputPath, shimPath: shimPath, bundlePath: configuration.testBundlePath, coverageConfiguration: configuration.coverageConfiguration, logDirectoryPath: configuration.logDirectoryPath, waitForDebugger: configuration.waitForDebugger, target: target)
    let thinned = try await ArchitectureProcessAdapter.thinExecutable(atPath: target.xctest.path, toAnyArchitectureIn: Set(configuration.architectures.map { Architecture(rawValue: $0) }), temporaryDirectory: temporaryDirectory)
    let arguments = ["-XCTest", configuration.testFilter ?? "All", configuration.testBundlePath]
    let launchEnvironment = XCTestShimConfiguration.unarmedAudioInjectionEnvironment(
      environment.merging(thinned.environment) { _, thinnedValue in thinnedValue })
    logger.log("Launching xctest process with arguments \(CollectionInformation.oneLineDescription(from: [thinned.path] + arguments)), environment \(CollectionInformation.oneLineDescription(from: launchEnvironment))")
    return Subprocess(executable: thinned.path, arguments: arguments, environment: .exact(launchEnvironment), mode: .posixSpawn)
  }

  private func awaitTestProcess(_ process: RunningSubprocess, processName: String) async throws -> Int32 {
    if configuration.waitForDebugger {
      let processIdentifier = process.processIdentifier
      do {
        try await ProcessFetcher.waitForStopSignal(process: processIdentifier)
      } catch {
        throw LogicTestRunError.sigstopWaitFailed(processIdentifier: processIdentifier, underlying: error)
      }
      reporter.processWaitingForDebugger(processIdentifier: processIdentifier)
    }
    return try await XCTestProcess.awaitExitCode(of: process, processName: processName, completesWithin: configuration.testTimeout, crashLogCommands: target.crashLog, logger: logger)
  }

  private func finishReadingShim(_ shimOutput: FileBackedOutput, consumer: any DataConsumerLifecycle) async {
    logger.log("xctest process terminated, Tearing down IO.")
    await shimOutput.finish()
    // Bounded so that a consumer that never finishes delays the result without failing the run.
    do {
      try await consumer.finishedConsuming.wait(timeout: EndOfFileTimeout, waitingFor: "an end-of-file from the shim after the xctest process exited")
    } catch {
      logger.log("\(error.localizedDescription)")
    }
  }

  private static func setupEnvironment(withDylibs environment: [String: String], withLibraries libraries: [String], injectLibraries: [String], shimOutputFilePath: String, shimPath: String, bundlePath: String, coverageConfiguration: CodeCoverageConfiguration?, logDirectoryPath: String?, waitForDebugger: Bool, target: any Target) -> [String: String] {
    var librariesWithShim = [shimPath]
    librariesWithShim.append(contentsOf: libraries)
    librariesWithShim.append(contentsOf: injectLibraries)

    var environmentAdditions: [String: String] = [
      "DYLD_INSERT_LIBRARIES": librariesWithShim.joined(separator: ":"),
      "TEST_SHIM_STDOUT_PATH": shimOutputFilePath,
      "TEST_SHIM_BUNDLE_PATH": bundlePath,
      "XCTOOL_WAIT_FOR_DEBUGGER": waitForDebugger ? "YES" : "NO",
    ]

    if let coverageConfiguration {
      let continuousCoverageCollectionMode = coverageConfiguration.shouldEnableContinuousCoverageCollection ? "%c" : ""
      let coverageFile = "coverage_\((bundlePath as NSString).lastPathComponent)\(continuousCoverageCollectionMode).profraw"
      let coveragePath = (coverageConfiguration.coverageDirectory as NSString).appendingPathComponent(coverageFile)
      environmentAdditions["LLVM_PROFILE_FILE"] = coveragePath
    }

    if let logDirectoryPath {
      environmentAdditions["LOG_DIRECTORY_PATH"] = logDirectoryPath
    }

    var updatedEnvironment = environment
    for (key, value) in environmentAdditions {
      updatedEnvironment[key] = value
    }
    for (key, value) in target.environmentAdditions() {
      updatedEnvironment[key] = value
    }

    return updatedEnvironment
  }

  private func buildConsumers() async throws -> LogicTestRunConsumers {
    let reporter = self.reporter
    let logger = self.logger
    let queue = target.workQueue
    let mirrorToLogger = (configuration.mirroring.rawValue & LogicTestMirrorLogs.logger.rawValue) != 0
    let mirrorToFiles = (configuration.mirroring.rawValue & LogicTestMirrorLogs.fileLogs.rawValue) != 0

    var shimConsumers: [any DataConsumer] = []
    var stdOutConsumers: [any DataConsumer] = []
    var stdErrConsumers: [any DataConsumer] = []

    let shimReportingConsumer = LineConsumer(
      delivery: .queue(queue),
      dataConsumer: { line in
        reporter.handleEventJSONData(line)
      })
    shimConsumers.append(shimReportingConsumer)

    let stdOutReportingConsumer = LineConsumer(
      delivery: .queue(queue),
      consumer: { line in
        reporter.testHadOutput(line + "\n")
      })
    stdOutConsumers.append(stdOutReportingConsumer)

    let stdErrReportingConsumer = LineConsumer(
      delivery: .queue(queue),
      consumer: { line in
        reporter.testHadOutput(line + "\n")
      })
    stdErrConsumers.append(stdErrReportingConsumer)
    let stdErrBuffer = ConsumableBuffer()
    stdErrConsumers.append(stdErrBuffer)

    if mirrorToLogger {
      shimConsumers.append(LoggingDataConsumer(logger: logger))
      stdErrConsumers.append(LoggingDataConsumer(logger: logger))
      stdErrConsumers.append(LoggingDataConsumer(logger: logger))
    }

    let stdOutConsumer = CompositeDataConsumer(consumers: stdOutConsumers)
    let stdErrConsumer = CompositeDataConsumer(consumers: stdErrConsumers)
    let shimConsumer = CompositeDataConsumer(consumers: shimConsumers)

    guard mirrorToFiles else {
      return LogicTestRunConsumers(stdOut: stdOutConsumer, stdErr: stdErrConsumer, stdErrBuffer: stdErrBuffer, shim: shimConsumer)
    }
    let mirrorLogger: XCTestLogger
    if let logDirectoryPath = configuration.logDirectoryPath {
      mirrorLogger = XCTestLogger(directory: logDirectoryPath)
    } else {
      mirrorLogger = XCTestLogger()
    }
    let mirroredStdOut = try await mirrorLogger.logConsumption(of: stdOutConsumer, toFileNamed: "test_process_stdout.out", logger: logger)
    let mirroredStdErr = try await mirrorLogger.logConsumption(of: stdErrConsumer, toFileNamed: "test_process_stderr.err", logger: logger)
    let mirroredShim = try await mirrorLogger.logConsumption(of: shimConsumer, toFileNamed: "shimulator_logs.shim", logger: logger)
    return LogicTestRunConsumers(stdOut: mirroredStdOut, stdErr: mirroredStdErr, stdErrBuffer: stdErrBuffer, shim: mirroredShim)
  }
}
