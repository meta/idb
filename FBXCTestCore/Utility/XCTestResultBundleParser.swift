/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

private let XCTestOperationTimeoutSecs: TimeInterval = 120

// MARK: - Helper functions

/// A decoded plist or JSON object, read through accessors that fail with the field they expected.
struct ResultRecord {
  let fields: [String: Any]

  init(_ fields: [String: Any]) {
    self.fields = fields
  }

  /// Reads a property list file, or returns nil when there is none to read.
  init?(contentsOfPropertyList path: String) {
    guard let data = FileManager.default.contents(atPath: path),
      let fields = unsafe (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    else {
      return nil
    }
    self.init(fields)
  }

  func value<T>(_ key: String, as type: T.Type) throws -> T {
    guard let value = fields[key] else {
      throw XCTestResultBundleError.missingKey(key)
    }
    guard let typed = value as? T else {
      throw XCTestResultBundleError.unexpectedType(key: key, expected: String(describing: type))
    }
    return typed
  }

  func string(_ key: String) throws -> String {
    try value(key, as: String.self)
  }

  func double(_ key: String) throws -> Double {
    try value(key, as: Double.self)
  }

  func records(_ key: String) throws -> [ResultRecord] {
    try value(key, as: [[String: Any]].self).map(ResultRecord.init)
  }

  /// The records under `key`, or nil when the key is absent or holds something else.
  func optionalRecords(_ key: String) -> [ResultRecord]? {
    (fields[key] as? [[String: Any]])?.map(ResultRecord.init)
  }

  func record(_ key: String) throws -> ResultRecord {
    ResultRecord(try value(key, as: [String: Any].self))
  }

  func optionalRecord(_ key: String) -> ResultRecord? {
    (fields[key] as? [String: Any]).map(ResultRecord.init)
  }

  // MARK: - xcresulttool's wrapped values

  /// The scalar xcresulttool wraps as `{"_value": …}` under `key`, logging why when there is none.
  func unwrappedValue(_ key: String, logger: any ControlCoreLogger) -> Any? {
    guard let wrapped = fields[key] as? [String: Any] else {
      logger.log("\(key) does not exist inside \(CollectionInformation.oneLineDescription(from: Array(fields.keys)))")
      return nil
    }
    let unwrapped = wrapped["_value"]
    if unwrapped == nil {
      logger.log("Failed to unwrap value for \(key) from \(CollectionInformation.oneLineDescription(from: Array(wrapped.keys)))")
    }
    return unwrapped
  }

  func unwrappedString(_ key: String, logger: any ControlCoreLogger) -> String? {
    unwrappedValue(key, logger: logger) as? String
  }

  /// The array xcresulttool wraps as `{"_values": […]}` under `key`, logging why when there is none.
  func unwrappedArray(_ key: String, logger: any ControlCoreLogger) -> [Any]? {
    guard let wrapped = fields[key] as? [String: Any] else {
      logger.log("\(key) does not exist inside \(CollectionInformation.oneLineDescription(from: Array(fields.keys)))")
      return nil
    }
    let unwrapped = wrapped["_values"] as? [Any]
    if unwrapped == nil {
      logger.log("Failed to unwrap values for \(key) from \(CollectionInformation.oneLineDescription(from: Array(wrapped.keys)))")
    }
    return unwrapped
  }

  /// The wrapped array under `key` when every element is a record.
  func unwrappedRecords(_ key: String, logger: any ControlCoreLogger) -> [ResultRecord]? {
    (unwrappedArray(key, logger: logger) as? [[String: Any]])?.map(ResultRecord.init)
  }

  /// As `unwrappedRecords`, without logging when there are none.
  func silentlyUnwrappedRecords(_ key: String) -> [ResultRecord]? {
    (optionalRecord(key)?.fields["_values"] as? [[String: Any]])?.map(ResultRecord.init)
  }
}

/// The elements of a wrapped array, or none unless every element is a record.
private func records(_ array: [Any]) -> [ResultRecord] {
  (array as? [[String: Any]])?.map(ResultRecord.init) ?? []
}

/// xcresulttool writes numbers as strings; accept either.
private func number(from value: Any?) -> Double? {
  if let number = value as? NSNumber {
    return number.doubleValue
  }
  return (value as? String).flatMap(Double.init)
}

private let resultBundleDateFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
  return formatter
}()

private func dateFromString(_ date: String) -> Date? {
  return resultBundleDateFormatter.date(from: date)
}

enum XCTestResultBundleError: Error {
  case noActions
  case notADirectory(path: String)
  case missingKey(String)
  case unexpectedType(key: String, expected: String)
}

extension XCTestResultBundleError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .noActions:
      return "Test result bundle root record does not contain any actions"
    case let .notADirectory(path):
      return "\(path) is not a directory"
    case let .missingKey(key):
      return "Test result bundle has no \(key)"
    case let .unexpectedType(key, expected):
      return "Test result bundle's \(key) is not a \(expected)"
    }
  }
}

/// Reads an xcresult bundle's records and exports its attachments.
protocol XCResultReading {
  func record(forId bundleObjectId: String?, timeout: TimeInterval?) async throws -> ResultRecord
  func exportJPEG(to destination: String, forId bundleObjectId: String, type encodeType: String, timeout: TimeInterval?) async throws
}

/// Reads a bundle through `xcresulttool`.
struct XCResultTool: XCResultReading {
  let path: String
  let logger: any ControlCoreLogger

  func record(forId bundleObjectId: String?, timeout: TimeInterval?) async throws -> ResultRecord {
    ResultRecord(try await XCTestResultToolOperation.json(from: path, forId: bundleObjectId, logger: logger, timeout: timeout))
  }

  func exportJPEG(to destination: String, forId bundleObjectId: String, type encodeType: String, timeout: TimeInterval?) async throws {
    try await XCTestResultToolOperation.exportJPEG(from: path, to: destination, forId: bundleObjectId, type: encodeType, logger: logger, timeout: timeout)
  }
}

enum XCTestResultBundleParser {

  // MARK: - Public

  public static func parse(_ resultBundlePath: String, reporter: any XCTestReporter, logger: any ControlCoreLogger, extractScreenshots: Bool, tool: (any XCResultReading)? = nil) async throws {
    let tool = tool ?? XCResultTool(path: resultBundlePath, logger: logger)
    logger.log("Parsing the result bundle \(resultBundlePath)")

    let testSummariesPath = (resultBundlePath as NSString).appendingPathComponent("TestSummaries.plist")
    let results = ResultRecord(contentsOfPropertyList: testSummariesPath)
    let resultBundleInfoPath = (resultBundlePath as NSString).appendingPathComponent("Info.plist")
    let bundleInfo = ResultRecord(contentsOfPropertyList: resultBundleInfoPath)

    if let results {
      try reportResultsLegacy(results, reporter: reporter)
      logger.log("ResultBundlePath: \(resultBundlePath)")
      return
    }
    guard let bundleFormatVersion = bundleInfo?.optionalRecord("version") else {
      reporter.testPlanDidFail(withMessage: "No test results were produced")
      return
    }
    let majorVersion = try bundleFormatVersion.value("major", as: Int.self)
    let minorVersion = try bundleFormatVersion.value("minor", as: Int.self)
    logger.log("Test result bundle format version: \(majorVersion).\(minorVersion)")

    let record = try await tool.record(forId: nil, timeout: nil)
    guard let actions = record.optionalRecord("actions") else {
      throw XCTestResultBundleError.noActions
    }
    for bundleObjectId in try parseActions(actions, logger: logger) {
      let xcresults = try await tool.record(forId: bundleObjectId, timeout: nil)
      logger.log("Parsing summaries for id \(bundleObjectId)")
      for summary in xcresults.unwrappedRecords("summaries", logger: logger) ?? [] {
        await reportResults(summary, reporter: reporter, resultBundlePath: resultBundlePath, tool: tool, logger: logger, extractScreenshots: extractScreenshots)
      }
      logger.log("Done parsing summaries for id \(bundleObjectId)")
    }
  }

  /// The word a test's closing log line uses for how it ended.
  private static func logOutcome(_ testStatus: String, _ status: TestReportStatus) -> String {
    if status == .passed {
      return "passed"
    }
    if testStatus == "Skipped" {
      return "skipped"
    }
    return "failed"
  }

  // MARK: - Private: Legacy XCTest Result Parsing

  private static func reportResultsLegacy(_ results: ResultRecord, reporter: any XCTestReporter) throws {
    for targetTest in results.optionalRecords("TestableSummaries") ?? [] {
      let testBundleName = try targetTest.string("TestName")
      for selectedTest in targetTest.optionalRecords("Tests") ?? [] {
        for testTargetXctest in selectedTest.optionalRecords("Subtests") ?? [] {
          for testClass in testTargetXctest.optionalRecords("Subtests") ?? [] {
            let testClassName = try testClass.string("TestIdentifier")
            for testMethod in testClass.optionalRecords("Subtests") ?? [] {
              try reportTestMethodLegacy(testMethod, testBundleName: testBundleName, testClassName: testClassName, reporter: reporter)
            }
          }
        }
      }
    }
  }

  private static func reportTestMethodLegacy(_ testMethod: ResultRecord, testBundleName: String, testClassName: String, reporter: any XCTestReporter) throws {
    let testStatus = try testMethod.string("TestStatus")
    let testMethodName = try testMethod.string("TestIdentifier")
    let duration = try testMethod.double("Duration")

    var status = TestReportStatus.unknown
    if testStatus == "Success" {
      status = .passed
    }
    if testStatus == "Failure" {
      status = .failed
    }

    let activitySummaries = try testMethod.records("ActivitySummaries")
    let logs = try buildTestLogLegacy(activitySummaries, testBundleName: testBundleName, testClassName: testClassName, testMethodName: testMethodName, outcome: logOutcome(testStatus, status), duration: duration)

    reporter.testCaseDidStart(forTestClass: testClassName, method: testMethodName)
    if status == .failed {
      let failureMessages = try testMethod.records("FailureSummaries").map { try $0.string("Message") }
      reporter.testCaseDidFail(
        forTestClass: testClassName, method: testMethodName,
        exceptions: [
          TestExceptionInfo(message: failureMessages.joined(separator: "\n"))
        ])
    }
    reporter.testCaseDidFinish(forTestClass: testClassName, method: testMethodName, with: status, duration: duration, logs: logs)
  }

  private static func buildTestLogLegacy(_ activitySummaries: [ResultRecord], testBundleName: String, testClassName: String, testMethodName: String, outcome: String, duration: Double) throws -> [String] {
    var logs: [String] = []
    let testCaseFullName = "-[\(testBundleName).\(testClassName) \(testMethodName)]"
    logs.append("Test Case '\(testCaseFullName)' started.")

    var testStartTimeInterval: Double?
    for activitySummary in activitySummaries {
      let startTimeInterval = try testStartTimeInterval ?? activitySummary.double("StartTimeInterval")
      testStartTimeInterval = startTimeInterval
      if try activitySummary.string("ActivityType") == "com.apple.dt.xctest.activity-type.internal" {
        try addTestLogsFromLegacyActivitySummary(activitySummary, logs: &logs, testStartTimeInterval: startTimeInterval, indent: 0)
      }
    }

    logs.append(unsafe "Test Case '\(testCaseFullName)' \(outcome) in \(String(format: "%.3f", duration)) seconds")
    return logs
  }

  private static func addTestLogsFromLegacyActivitySummary(_ activitySummary: ResultRecord, logs: inout [String], testStartTimeInterval: Double, indent: UInt) throws {
    let message = try activitySummary.string("Title")
    let elapsed = try activitySummary.double("StartTimeInterval") - testStartTimeInterval
    let indentString = "".padding(toLength: 1 + Int(indent) * 4, withPad: " ", startingAt: 0)
    unsafe logs.append(String(format: "    t = %8.2fs%@%@", elapsed, indentString, message))

    for subActivity in activitySummary.optionalRecords("SubActivities") ?? [] {
      try addTestLogsFromLegacyActivitySummary(subActivity, logs: &logs, testStartTimeInterval: testStartTimeInterval, indent: indent + 1)
    }
  }

  // MARK: - Private: Xcode 11+ XCTest Result Parsing

  private static func parseActions(_ actions: ResultRecord, logger: any ControlCoreLogger) throws -> [String] {
    guard let actionValues = actions.fields["_values"] as? [[String: Any]] else {
      throw XCTestResultBundleError.unexpectedType(key: "actions", expected: "array of actions")
    }
    return try actionValues.map { action in
      let testsRef = try ResultRecord(action).record("actionResult").record("testsRef")
      guard let id = testsRef.unwrappedString("id", logger: logger) else {
        throw XCTestResultBundleError.unexpectedType(key: "testsRef.id", expected: String(describing: String.self))
      }
      return id
    }
  }

  private static func reportResults(_ results: ResultRecord, reporter: any XCTestReporter, resultBundlePath: String, tool: any XCResultReading, logger: any ControlCoreLogger, extractScreenshots: Bool) async {
    for targetTest in results.unwrappedRecords("testableSummaries", logger: logger) ?? [] {
      await reportTargetTest(targetTest, reporter: reporter, resultBundlePath: resultBundlePath, tool: tool, logger: logger, extractScreenshots: extractScreenshots)
    }
  }

  private static func reportTargetTest(_ targetTest: ResultRecord, reporter: any XCTestReporter, resultBundlePath: String, tool: any XCResultReading, logger: any ControlCoreLogger, extractScreenshots: Bool) async {
    let testBundleName = targetTest.unwrappedString("targetName", logger: logger) ?? ""
    guard let selectedTests = targetTest.unwrappedArray("tests", logger: logger) else {
      logger.log("Test failed and no test results found in the bundle")
      let failureSummaries = targetTest.unwrappedArray("failureSummaries", logger: logger)
      reporter.testCaseDidFail(
        forTestClass: "", method: "",
        exceptions: [
          TestExceptionInfo(message: buildErrorMessage(failureSummaries, logger: logger))
        ])
      return
    }
    for selectedTest in records(selectedTests) {
      guard let testTargetXctests = selectedTest.unwrappedArray("subtests", logger: logger) else {
        logger.log("Test failed and no target test results found in the bundle")
        reportMissingResults("No test results were found in \(testBundleName)", testClass: "", to: reporter)
        continue
      }
      for testTargetXctest in records(testTargetXctests) {
        guard let testClasses = testTargetXctest.unwrappedArray("subtests", logger: logger) else {
          logger.log("Test failed and no test class results found in the bundle")
          reportMissingResults("No test classes were found in \(testBundleName)", testClass: "", to: reporter)
          continue
        }
        for testClass in records(testClasses) {
          let testClassName = testClass.unwrappedString("identifier", logger: logger) ?? ""
          guard let testMethods = testClass.unwrappedArray("subtests", logger: logger) else {
            logger.log("Test failed for \(testClassName) and no test method results found")
            reportMissingResults("No test methods were found in \(testClassName)", testClass: testClassName, to: reporter)
            continue
          }
          for testMethod in records(testMethods) {
            await reportTestMethod(testMethod, testBundleName: testBundleName, testClassName: testClassName, reporter: reporter, resultBundlePath: resultBundlePath, tool: tool, logger: logger, extractScreenshots: extractScreenshots)
          }
        }
      }
    }
  }

  private static func reportMissingResults(_ message: String, testClass: String, to reporter: any XCTestReporter) {
    reporter.testCaseDidFail(forTestClass: testClass, method: "", exceptions: [TestExceptionInfo(message: message)])
  }

  private static func reportTestMethod(_ testMethod: ResultRecord, testBundleName: String, testClassName: String, reporter: any XCTestReporter, resultBundlePath: String, tool: any XCResultReading, logger: any ControlCoreLogger, extractScreenshots: Bool) async {
    let testStatus = testMethod.unwrappedString("testStatus", logger: logger) ?? ""
    let testMethodIdentifier = testMethod.unwrappedString("identifier", logger: logger) ?? ""
    let duration = number(from: testMethod.unwrappedValue("duration", logger: logger)) ?? 0

    var status = TestReportStatus.unknown
    if testStatus == "Success" {
      status = .passed
    }
    if testStatus == "Failure" {
      status = .failed
    }

    reporter.testCaseDidStart(forTestClass: testClassName, method: testMethodIdentifier)

    // Without a readable summary there are no failure messages or activities, but the method
    // still finishes with the status and duration its own record gives.
    guard let summaryRefId = testMethod.optionalRecord("summaryRef")?.unwrappedString("id", logger: logger),
      let actionTestSummary = try? await tool.record(forId: summaryRefId, timeout: XCTestOperationTimeoutSecs)
    else {
      let logs = buildTestLog(nil, testBundleName: testBundleName, testClassName: testClassName, testMethodName: testMethodIdentifier, outcome: logOutcome(testStatus, status), duration: duration, logger: logger)
      reporter.testCaseDidFinish(forTestClass: testClassName, method: testMethodIdentifier, with: status, duration: duration, logs: logs)
      return
    }
    if status == .failed {
      let failureSummaries = actionTestSummary.unwrappedArray("failureSummaries", logger: logger)
      reporter.testCaseDidFail(
        forTestClass: testClassName, method: testMethodIdentifier,
        exceptions: [
          TestExceptionInfo(message: buildErrorMessage(failureSummaries, logger: logger))
        ])
    }

    if let performanceMetrics = actionTestSummary.unwrappedRecords("performanceMetrics", logger: logger) {
      var testMethodName = testMethod.unwrappedString("name", logger: logger) ?? ""
      let suffix = "()"
      if testMethodName.hasSuffix(suffix) {
        testMethodName = String(testMethodName.dropLast(suffix.count))
      }
      savePerformanceMetrics(performanceMetrics, toTestResultBundle: resultBundlePath, forTestTarget: testBundleName, testClass: testClassName, testMethod: testMethodName, logger: logger)
    }

    if extractScreenshots, let activitySummaries = actionTestSummary.unwrappedRecords("activitySummaries", logger: logger) {
      await extractScreenshotsFromActivities(activitySummaries, resultBundlePath: resultBundlePath, tool: tool, logger: logger)
    }

    let logs = buildTestLog(actionTestSummary.unwrappedRecords("activitySummaries", logger: logger), testBundleName: testBundleName, testClassName: testClassName, testMethodName: testMethodIdentifier, outcome: logOutcome(testStatus, status), duration: duration, logger: logger)
    reporter.testCaseDidFinish(forTestClass: testClassName, method: testMethodIdentifier, with: status, duration: duration, logs: logs)
  }

  private static func buildTestLog(_ activitySummaries: [ResultRecord]?, testBundleName: String, testClassName: String, testMethodName: String, outcome: String, duration: Double, logger: any ControlCoreLogger) -> [String] {
    var logs: [String] = []
    let testCaseFullName = "-[\(testBundleName).\(testClassName) \(testMethodName)]"
    logs.append("Test Case '\(testCaseFullName)' started.")

    var testStartTimeInterval: Double?
    for activitySummary in activitySummaries ?? [] {
      if testStartTimeInterval == nil, let start = activitySummary.unwrappedString("start", logger: logger).flatMap(dateFromString) {
        testStartTimeInterval = start.timeIntervalSince1970
      }
      if activitySummary.unwrappedString("activityType", logger: logger) == "com.apple.dt.xctest.activity-type.internal" {
        addTestLogsFromActivitySummary(activitySummary, logs: &logs, testStartTimeInterval: testStartTimeInterval ?? 0, indent: 0, logger: logger)
      }
    }

    logs.append(unsafe "Test Case '\(testCaseFullName)' \(outcome) in \(String(format: "%.3f", duration)) seconds")
    return logs
  }

  private static func addTestLogsFromActivitySummary(_ activitySummary: ResultRecord, logs: inout [String], testStartTimeInterval: Double, indent: UInt, logger: any ControlCoreLogger) {
    let message = activitySummary.unwrappedString("title", logger: logger) ?? ""
    let startTimeInterval = dateFromString(activitySummary.unwrappedString("start", logger: logger) ?? "")?.timeIntervalSince1970 ?? 0
    let elapsed = startTimeInterval - testStartTimeInterval
    let indentString = "".padding(toLength: 1 + Int(indent) * 4, withPad: " ", startingAt: 0)
    unsafe logs.append(String(format: "    t = %8.2fs%@%@", elapsed, indentString, message))

    for subActivity in activitySummary.silentlyUnwrappedRecords("subactivities") ?? [] {
      addTestLogsFromActivitySummary(subActivity, logs: &logs, testStartTimeInterval: testStartTimeInterval, indent: indent + 1, logger: logger)
    }
  }

  private static func extractScreenshotsFromActivities(_ activities: [ResultRecord], resultBundlePath: String, tool: any XCResultReading, logger: any ControlCoreLogger) async {
    let screenshotsPath: String
    do {
      screenshotsPath = try ensureSubdirectory("Attachments", insideResultBundle: resultBundlePath)
    } catch {
      logger.log("Failed to ensure attachments directory \(error)")
      return
    }
    for activity in activities {
      if activity.fields["attachments"] != nil, let attachments = activity.unwrappedRecords("attachments", logger: logger) {
        await extractScreenshotsFromAttachments(attachments, to: screenshotsPath, tool: tool, logger: logger)
      }
      if activity.fields["subactivities"] != nil, let subactivities = activity.unwrappedRecords("subactivities", logger: logger) {
        await extractScreenshotsFromActivities(subactivities, resultBundlePath: resultBundlePath, tool: tool, logger: logger)
      }
    }
  }

  private static func ensureSubdirectory(_ subdirectory: String, insideResultBundle resultBundlePath: String) throws -> String {
    let fileManager = FileManager.default
    let subdirectoryFullPath = (resultBundlePath as NSString).appendingPathComponent(subdirectory)
    var isDirectory: ObjCBool = false
    if unsafe fileManager.fileExists(atPath: subdirectoryFullPath, isDirectory: &isDirectory) {
      if !isDirectory.boolValue {
        throw XCTestResultBundleError.notADirectory(path: subdirectoryFullPath)
      }
    } else {
      try fileManager.createDirectory(atPath: subdirectoryFullPath, withIntermediateDirectories: false, attributes: nil)
    }
    return subdirectoryFullPath
  }

  private static func extractScreenshotsFromAttachments(_ attachments: [ResultRecord], to destination: String, tool: any XCResultReading, logger: any ControlCoreLogger) async {
    for attachment in attachments {
      guard let filename = attachment.unwrappedString("filename", logger: logger) else { continue }
      guard filename.hasPrefix("Screenshot_"),
        let screenshotId = attachment.optionalRecord("payloadRef")?.unwrappedString("id", logger: logger),
        let screenshotType = attachment.unwrappedString("uniformTypeIdentifier", logger: logger)
      else { continue }
      let timestamp = attachment.unwrappedString("timestamp", logger: logger) ?? ""
      let jpgFilename = (filename as NSString).deletingPathExtension.appending(".jpg")
      let exportPath = (destination as NSString).appendingPathComponent("\(timestamp)_\(jpgFilename)")
      _ = try? await tool.exportJPEG(to: exportPath, forId: screenshotId, type: screenshotType, timeout: XCTestOperationTimeoutSecs)
    }
  }

  private static func savePerformanceMetrics(_ performanceMetrics: [ResultRecord], toTestResultBundle resultBundlePath: String, forTestTarget testTarget: String, testClass: String, testMethod: String, logger: any ControlCoreLogger) {
    let metrics: [[String: Any]] = performanceMetrics.map { performanceMetric in
      [
        "name": performanceMetric.unwrappedString("displayName", logger: logger) ?? "",
        "unit": performanceMetric.unwrappedString("unitOfMeasurement", logger: logger) ?? "",
        "identifier": performanceMetric.unwrappedString("identifier", logger: logger) ?? "",
        "measurements": (performanceMetric.unwrappedRecords("measurements", logger: logger) ?? []).compactMap { number(from: $0.fields["_value"]) },
      ]
    }

    if !JSONSerialization.isValidJSONObject(metrics) {
      logger.log("Not saving performance metrics as they're not valid json")
      return
    }
    guard let json = try? JSONSerialization.data(withJSONObject: metrics, options: .prettyPrinted) else {
      logger.log("Failed to serialize performance metrics")
      return
    }
    do {
      let performanceMetricsDirectory = try ensureSubdirectory("Metrics", insideResultBundle: resultBundlePath)
      let metricFilePath = (performanceMetricsDirectory as NSString).appendingPathComponent("\(testTarget)_\(testClass)_\(testMethod).json")
      try json.write(to: URL(fileURLWithPath: metricFilePath))
    } catch {
      logger.log("Failed to ensure performance metrics directory \(error)")
    }
  }

  private static func buildErrorMessage(_ failureSummaries: [Any]?, logger: any ControlCoreLogger) -> String {
    guard let failureSummaries = failureSummaries as? [[String: Any]] else { return "" }
    return failureSummaries.compactMap { ResultRecord($0).unwrappedString("message", logger: logger) }.joined(separator: "\n")
  }
}
