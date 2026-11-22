/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBArtifactStaging
import FBControlCore
import FBSimulatorControl
import FBXCTestCore
import Foundation
import GRPCCore
import IDBConcurrency
import IDBGRPCSwift
import SwiftProtobuf

extension IDBXCTestReporter {

  struct Configuration {

    let resultBundlePath: String

    let coverageConfiguration: CodeCoverageConfiguration?

    let logDirectoryPath: String?

    let binariesPath: [String]

    let reportAttachments: Bool

    let reportResultBundle: Bool

    init(legacy: XCTestReporterConfiguration) {
      self.resultBundlePath = legacy.resultBundlePath ?? ""
      self.coverageConfiguration = legacy.coverageConfiguration
      self.logDirectoryPath = legacy.logDirectoryPath
      self.binariesPath = legacy.binariesPaths
      self.reportAttachments = legacy.reportAttachments
      self.reportResultBundle = legacy.reportResultBundle
    }
  }

  struct CurrentTestInfo {
    var bundleName = ""
    var testClass = ""
    var testMethod = ""
    var activityRecords: [ActivityRecord] = []
    var failureInfo: Idb_XctestRunResponse.TestRunInfo.TestRunFailureInfo?
    var otherFailures: [Idb_XctestRunResponse.TestRunInfo.TestRunFailureInfo] = []
  }
}

enum IDBXCTestReporterError: Error {
  case coverageExportFailed(exitCode: Int32, stderr: String)
}

extension IDBXCTestReporterError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case let .coverageExportFailed(exitCode, stderr):
      return "xcrun failed to export code coverage data \(exitCode) \(stderr)"
    }
  }
}

final class IDBXCTestReporter: XCTestReporter, DataConsumer, @unchecked Sendable {

  private let reportingTerminated = AsyncEvent<Int>()

  /// Set once the test operation has started, which is the earliest point the configuration is known.
  var configuration: Configuration?

  @Atomic private var responseStream: RPCWriter<Idb_XctestRunResponse>?

  private let logger: ControlCoreLogger

  private let processUnderTestExited = AsyncEvent<Void>()

  @Atomic private var currentInfo = CurrentTestInfo()

  init(responseStream: RPCWriter<Idb_XctestRunResponse>, logger: ControlCoreLogger) {
    self._responseStream = .init(wrappedValue: responseStream)
    self.logger = logger
  }

  /// Waits until reporting has terminated. Returns the status raw value reported.
  func awaitReportingTerminated() async throws -> Int {
    try await reportingTerminated.wait()
  }

  // MARK: - DataConsumer implementation

  func consumeData(_ data: Data) {
    let logOutput = String(data: data, encoding: .utf8) ?? ""
    let response = createResponse(logOutput: logOutput)
    write(response: response)
  }

  func consumeEndOfFile() {
    // Implementation not required
  }

  // MARK: - XCTestReporter implementation

  func processWaitingForDebugger(processIdentifier pid: pid_t) {
    logger.info().log("Tests waiting for debugger. To debug run: lldb -p \(pid)")
    let response = Idb_XctestRunResponse.with {
      $0.status = .running
      $0.debugger = .with {
        $0.pid = UInt64(pid)
      }
    }

    write(response: response)
  }

  func didBeginExecutingTestPlan() {
    // Implementation not required
  }

  func didFinishExecutingTestPlan() {
    let response = Idb_XctestRunResponse.with {
      $0.status = .terminatedNormally
    }
    write(response: response)
  }

  func processUnderTestDidExit() {
    processUnderTestExited.happen()
  }

  func testSuite(_ testSuite: String, didStartAt startTime: String) {
    _currentInfo.sync { $0.bundleName = testSuite }
  }

  func testCaseDidFinish(forTestClass testClass: String, method: String, with status: TestReportStatus, duration: TimeInterval, logs: [String]?) {
    do {
      let info = try createRunInfo(testClass: testClass, method: method, status: status, duration: duration, logs: logs ?? [])
      write(testRunInfo: info)
    } catch {
      _responseStream.sync { $0 = nil }
      reportingTerminated.fail(error)
    }
  }

  func testCaseDidFail(forTestClass testClass: String, method: String, exceptions: [TestExceptionInfo]) {
    let currentInfo = self.currentInfo
    if testClass == currentInfo.testClass && method != currentInfo.testMethod {
      logger.log("Got failure info for \(testClass)/\(method) but the current known executing test is \(currentInfo.testClass)\(currentInfo.testMethod). Ignoring it")
      return
    }
    self._currentInfo.sync {
      if let firstExceptionInfo = exceptions.first {
        $0.failureInfo = createFailureInfo(exceptionInfo: firstExceptionInfo)
        $0.otherFailures = exceptions.dropFirst().map { createFailureInfo(exceptionInfo: $0) }
      } else {
        logger.log("No exceptions were returned in the failure. This shouldn't happen.")
      }
    }
  }

  func testCaseDidStart(forTestClass testClass: String, method: String) {
    _currentInfo.sync {
      $0.testClass = testClass
      $0.testMethod = method
    }
  }

  func testPlanDidFail(withMessage message: String) {
    let response = responseFor(crashMessage: message)
    write(response: response)
  }

  func testCase(_ testClass: String, method: String, didFinishActivity activity: ActivityRecord) {
    _currentInfo.sync {
      $0.activityRecords.append(activity)
    }
  }

  func finished(with summary: TestManagerResultSummary) {
    // Implementation not required
  }

  func testHadOutput(_ output: String) {
    let response = createResponseExtractingFailureInfo(from: output)
    write(response: response)
  }

  func handleExternalEvent(_ event: String) {
    let response = createResponseExtractingFailureInfo(from: event)
    write(response: response)
  }

  func printReport() throws {
    // Warning! This method is bridged to swift incorrectly and loses bool return type. Adapt and use with extra care
  }

  func didCrashDuringTest(_ error: Error) {
    let response = responseFor(crashMessage: error.localizedDescription)
    write(response: response)
  }

  // MARK: - Privates

  private func createRunInfo(testClass: String, method: String, status: TestReportStatus, duration: TimeInterval, logs: [String]) throws -> Idb_XctestRunResponse.TestRunInfo {

    defer { resetCurrentTestState() }

    return try _currentInfo.sync { currentInfo in

      var stackedActivities: [ActivityRecord] = []
      currentInfo.activityRecords.sort(by: { $0.start < $1.start })

      while let activity = currentInfo.activityRecords.first {
        currentInfo.activityRecords.remove(at: 0)
        populateSubactivities(root: activity, remaining: &currentInfo.activityRecords)
        stackedActivities.append(activity)
      }

      return try Idb_XctestRunResponse.TestRunInfo.with {
        $0.bundleName = currentInfo.bundleName
        $0.className = testClass
        $0.methodName = method
        $0.status = status == .failed ? .failed : .passed
        $0.duration = duration
        if let failureInfo = currentInfo.failureInfo {
          $0.failureInfo = failureInfo
        }
        $0.logs = logs
        $0.activityLogs = try stackedActivities.map(translate(activity:))
        $0.otherFailures = currentInfo.otherFailures
      }
    }
  }

  private func translate(activity: ActivityRecord) throws -> Idb_XctestRunResponse.TestRunInfo.TestActivity {
    let subactivities = activity.subactivities
    let reportAttachments = configuration?.reportAttachments ?? false
    return try Idb_XctestRunResponse.TestRunInfo.TestActivity.with {
      $0.title = activity.title
      $0.duration = activity.duration
      $0.uuid = activity.uuid.uuidString
      $0.activityType = activity.activityType
      $0.start = activity.start.timeIntervalSince1970
      $0.finish = activity.finish.timeIntervalSince1970
      $0.name = activity.name
      if reportAttachments {
        $0.attachments = try activity.attachments.map { attachment in
          try .with {
            $0.payload = attachment.payload ?? Data()
            $0.name = attachment.name
            $0.timestamp = attachment.timestamp?.timeIntervalSince1970 ?? 0
            $0.uniformTypeIdentifier = attachment.uniformTypeIdentifier
            if let userInfo = attachment.userInfo {
              $0.userInfoJson = try translate(attachmentUserInfo: userInfo)
            }
          }
        }
      }
      $0.subActivities = try subactivities.map(translate(activity:))
    }
  }

  private func translate(attachmentUserInfo userInfo: [AnyHashable: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: userInfo, options: [])
  }

  private func resetCurrentTestState() {
    _currentInfo.sync {
      $0.activityRecords.removeAll()
      $0.failureInfo = nil
      $0.testClass = ""
      $0.testMethod = ""
      $0.otherFailures.removeAll()
    }
  }

  private func populateSubactivities(root: ActivityRecord, remaining: inout [ActivityRecord]) {
    while let firstRemaining = remaining.first, root.start <= firstRemaining.start && firstRemaining.finish <= root.finish {
      remaining.remove(at: 0)
      populateSubactivities(root: firstRemaining, remaining: &remaining)
      root.subactivities.append(firstRemaining)
    }
  }

  private func write(testRunInfo: Idb_XctestRunResponse.TestRunInfo) {
    let response = Idb_XctestRunResponse.with {
      $0.status = .running
      $0.results = [testRunInfo]
    }
    write(response: response)
  }

  private func write(response: Idb_XctestRunResponse) {
    Task {
      do {
        switch response.status {
        case .terminatedNormally, .terminatedAbnormally:
          try await insertFinalDataThenWriteResponse(response: response)

        default:
          try await writeResponseFinal(response: response)
        }
      } catch {
        logger.log("Failed to write xctest run response \(error.localizedDescription)")
      }
    }
  }

  /// One of the independent, heavyweight artifacts assembled at the end of a test run.
  private enum FinalArtifact {
    case resultBundle(Data)
    case coverage(Data)
    case logDirectory(Data)
  }

  private func insertFinalDataThenWriteResponse(response: Idb_XctestRunResponse) async throws {
    var response = response

    guard let configuration else {
      logger.error().log("Finalizing a test run that was never configured, no artifacts will be attached")
      try await writeResponseFinal(response: response)
      return
    }

    let artifacts: [FinalArtifact] = try await withThrowingTaskGroup(of: FinalArtifact?.self) { group in
      let resultBundlePath = configuration.resultBundlePath
      let binariesPath = configuration.binariesPath

      if !resultBundlePath.isEmpty && configuration.reportResultBundle {
        group.addTask {
          do {
            return .resultBundle(try await self.gzipFolder(at: resultBundlePath))
          } catch {
            self.logger.info().log("Failed to create result bundle \(error.localizedDescription)")
            return nil
          }
        }
      }

      // Read back through `self` rather than the local binding: `CodeCoverageConfiguration` is a
      // non-Sendable ObjC class, so a value derived from the local would stay in this function's
      // isolation region and could not be captured by the child task.
      if let coverageConfig = self.configuration?.coverageConfiguration, !coverageConfig.coverageDirectory.isEmpty {
        group.addTask {
          do {
            return .coverage(try await self.getCoverageResponseData(config: coverageConfig, binariesPath: binariesPath))
          } catch {
            self.logger.info().log("Failed to get coverage data: \(error.localizedDescription)")
            return nil
          }
        }
      }

      if let logDirectoryPath = configuration.logDirectoryPath {
        group.addTask {
          .logDirectory(try await self.gzipFolder(at: logDirectoryPath))
        }
      }

      var collected: [FinalArtifact] = []
      for try await artifact in group {
        if let artifact {
          collected.append(artifact)
        }
      }
      return collected
    }

    for artifact in artifacts {
      switch artifact {
      case let .resultBundle(data):
        response.resultBundle = .with { $0.data = data }
      case let .coverage(data):
        response.codeCoverageData = .with { $0.data = data }
      case let .logDirectory(data):
        response.logDirectory = .with { $0.data = data }
      }
    }

    try await writeResponseFinal(response: response)
  }

  private func writeResponseFinal(response: Idb_XctestRunResponse) async throws {
    let shouldCloseStream = isLastMessage(responseStatus: response.status)

    let stream: RPCWriter<Idb_XctestRunResponse>? = _responseStream.sync { storedStream in
      guard let responseStream = storedStream else { return nil }
      if shouldCloseStream {
        storedStream = nil
      }
      return responseStream
    }

    guard let responseStream = stream else {
      logger.error().log("writeResponse called, but the last response has already been written!")
      return
    }

    try await responseStream.send(response)

    if shouldCloseStream {
      logger.log("Test Reporting has finished with status \(response.status)")
      reportingTerminated.happen(response.status.rawValue)
    }
  }

  private func isLastMessage(responseStatus: Idb_XctestRunResponse.Status) -> Bool {
    return responseStatus == .terminatedNormally || responseStatus == .terminatedAbnormally
  }

  private func gzipFolder(at path: String) async throws -> Data {
    return try await ArchiveOperations.createGzippedTarData(forPath: path, logger: logger)
  }

  private func getCoverageResponseData(config: CodeCoverageConfiguration, binariesPath: [String]) async throws -> Data {
    try await processUnderTestExited.wait()
    switch config.format {
    case .exported:
      let data = try await getCoverageDataExported(config: config, binariesPath: binariesPath)
      return data as Data

    case .raw:
      return try await gzipFolder(at: config.coverageDirectory)
    }
  }

  private func getCoverageDataExported(config: CodeCoverageConfiguration, binariesPath: [String]) async throws -> Data {
    let coverageDirectory = URL(fileURLWithPath: config.coverageDirectory)
    let profdataPath = coverageDirectory.appendingPathComponent("coverage.profdata")

    try await mergeRawCoverage(coverageDirectory: coverageDirectory, profdataPath: profdataPath)
    return try await exportCoverage(profdataPath: profdataPath, binariesPath: binariesPath)
  }

  func mergeRawCoverage(coverageDirectory: URL, profdataPath: URL) async throws {
    let profraws = try FileManager.default
      .contentsOfDirectory(at: coverageDirectory, includingPropertiesForKeys: nil, options: [])
      .filter { $0.pathExtension == "profraw" }

    let mergeArgs: [String] =
      ["llvm-profdata", "merge", "-o", profdataPath.path, "--num-threads", "2"]
      + profraws.map(\.path)

    let merge = try await Subprocess(executable: "/usr/bin/xcrun", arguments: mergeArgs)
      .run(output: .nullDevice, error: .string, exitPolicy: .any, logger: logger)
    try merge.checkExitedCleanly { IDBXCTestReporterError.coverageExportFailed(exitCode: $0, stderr: merge.standardError) }
  }

  func exportCoverage(profdataPath: URL, binariesPath: [String]) async throws -> Data {
    let exportArgs: [String] =
      ["llvm-cov", "export", "--num-threads", "2", "-instr-profile", profdataPath.path]
      + binariesPath.reduce(into: []) {
        $0 += ["-object", $1]
      }
    let exportPath = profdataPath.deletingLastPathComponent().appendingPathComponent("coverage.json")
    // `.file` does not truncate, so a stale export would leave a tail behind a shorter one.
    try? FileManager.default.removeItem(at: exportPath)
    let export = try await Subprocess(executable: "/usr/bin/xcrun", arguments: exportArgs)
      .run(output: .file(exportPath), error: .string, exitPolicy: .any, logger: logger)
    try export.checkExitedCleanly { IDBXCTestReporterError.coverageExportFailed(exitCode: $0, stderr: export.standardError) }

    return try await ArchiveOperations.createGzipData(forPath: exportPath.path, logger: logger)
  }

  private func createFailureInfo(exceptionInfo: TestExceptionInfo) -> Idb_XctestRunResponse.TestRunInfo.TestRunFailureInfo {
    return Idb_XctestRunResponse.TestRunInfo.TestRunFailureInfo.with {
      $0.failureMessage = exceptionInfo.message
      $0.file = exceptionInfo.file ?? ""
      $0.line = UInt64(exceptionInfo.line)
    }
  }

  private func responseFor(crashMessage: String) -> Idb_XctestRunResponse {
    defer { resetCurrentTestState() }

    let currentInfo = self.currentInfo
    let info = Idb_XctestRunResponse.TestRunInfo.with {
      $0.bundleName = currentInfo.bundleName
      $0.className = currentInfo.testClass
      $0.methodName = currentInfo.testMethod
      $0.failureInfo = currentInfo.failureInfo ?? .init()
      $0.failureInfo.failureMessage = crashMessage
      $0.status = .crashed
      $0.otherFailures = currentInfo.otherFailures
    }

    return Idb_XctestRunResponse.with {
      $0.status = .terminatedAbnormally
      $0.results = [info]
    }
  }

  private func createResponseExtractingFailureInfo(from logOutput: String) -> Idb_XctestRunResponse {
    extractFailureInfo(from: logOutput)
    return createResponse(logOutput: logOutput)
  }

  private let assertionFailureRegex = /Assertion failed: (.*), function (.*), file (.*), line (\d+)./.ignoresCase()

  private func extractFailureInfo(from logOutput: String) {
    guard let result = logOutput.firstMatch(of: assertionFailureRegex) else {
      return
    }
    _currentInfo.sync {
      $0.failureInfo = failureInfoWith(
        message: String(result.1),
        file: String(result.3),
        line: UInt(result.4) ?? 0)
    }
  }

  private func createResponse(logOutput: String) -> Idb_XctestRunResponse {
    return Idb_XctestRunResponse.with {
      $0.status = .running
      $0.logOutput = [logOutput]
    }
  }

  private func failureInfoWith(message: String, file: String, line: UInt) -> Idb_XctestRunResponse.TestRunInfo.TestRunFailureInfo {
    return .with {
      $0.failureMessage = message
      $0.file = file
      $0.line = UInt64(line)
    }
  }
}
