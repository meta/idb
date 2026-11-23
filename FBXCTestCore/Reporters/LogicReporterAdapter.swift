/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

public final class LogicReporterAdapter: LogicXCTestReporter {

  private let reporter: any XCTestReporter
  private let logger: (any ControlCoreLogger)?

  public init(reporter: any XCTestReporter, logger: (any ControlCoreLogger)?) {
    self.reporter = reporter
    self.logger = logger?.withName("LogicReporterAdapter") as (any ControlCoreLogger)?
  }

  // MARK: - LogicXCTestReporter

  public func didBeginExecutingTestPlan() {
    reporter.didBeginExecutingTestPlan()
  }

  public func didFinishExecutingTestPlan() {
    reporter.didFinishExecutingTestPlan()
    reporter.processUnderTestDidExit()
  }

  public func processWaitingForDebugger(processIdentifier pid: pid_t) {
    reporter.processWaitingForDebugger(processIdentifier: pid)
  }

  public func testHadOutput(_ output: String) {
    reporter.testHadOutput(output)
  }

  public func handleEventJSONData(_ data: Data) {
    if data.isEmpty {
      logger?.log("Received zero-length JSON data")
      return
    }
    guard let jsonEvent = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
      logger?.log("Received invalid JSON: '\(String(data: data, encoding: .utf8) ?? "")'")
      return
    }

    let eventName = jsonEvent["event"] as? String
    if eventName == "begin-test-suite" {
      let suiteName = jsonEvent["suite"] as? String ?? ""
      let startTime = jsonEvent["timestamp"]
      if let startTime = startTime as? NSNumber {
        reporter.testSuite(suiteName, didStartAt: startTime.stringValue)
      } else if let startTime = startTime as? String {
        reporter.testSuite(suiteName, didStartAt: startTime)
      } else {
        assertionFailure("Unknown type of obj. This will likely cause crash in runtime because of swift signature mismatch")
      }
    } else if eventName == "begin-test" {
      let className = jsonEvent["className"] as? String ?? ""
      let methodName = jsonEvent["methodName"] as? String ?? ""
      reporter.testCaseDidStart(forTestClass: className, method: methodName)
    } else if eventName == "end-test" {
      handleEndTest(jsonEvent, data: data)
    } else if eventName == "end-test-suite" {
      let finishDate = Date(timeIntervalSince1970: (jsonEvent["timestamp"] as? NSNumber)?.doubleValue ?? 0)
      let unexpected = (jsonEvent["unexpectedExceptionCount"] as? NSNumber)?.intValue ?? 0
      let summary = TestManagerResultSummary(
        testSuite: jsonEvent["suite"] as? String ?? "",
        finishTime: finishDate,
        runCount: (jsonEvent["testCaseCount"] as? NSNumber)?.intValue ?? 0,
        failureCount: (jsonEvent["totalFailureCount"] as? NSNumber)?.intValue ?? 0,
        unexpected: unexpected,
        testDuration: (jsonEvent["testDuration"] as? NSNumber)?.doubleValue ?? 0,
        totalDuration: (jsonEvent["totalDuration"] as? NSNumber)?.doubleValue ?? 0
      )
      reporter.finished(with: summary)
    } else {
      logger?.log("[\(String(describing: type(of: self)))] Unhandled event JSON: \(jsonEvent)")
      // We don't know how to handle it, but an upstream reporter might.
      let stringEvent = String(data: data, encoding: .utf8) ?? ""
      reporter.handleExternalEvent(stringEvent)
    }
  }

  public func didCrashDuringTest(_ error: any Error) {
    reporter.didCrashDuringTest(error)
    reporter.processUnderTestDidExit()
  }

  private func handleEndTest(_ jsonEvent: [String: Any], data: Data) {
    let testClass = jsonEvent["className"] as? String ?? ""
    let testName = jsonEvent["methodName"] as? String ?? ""
    let result = jsonEvent["result"] as? String ?? ""
    let duration = (jsonEvent["totalDuration"] as? NSNumber)?.doubleValue ?? 0

    if result == "success" {
      reporter.testCaseDidFinish(forTestClass: testClass, method: testName, with: .passed, duration: duration, logs: nil)
    } else if result == "failure" || result == "error" {
      reportTestFailure(forTestClass: testClass, testName: testName, endTestEvent: jsonEvent)
      reporter.testCaseDidFinish(forTestClass: testClass, method: testName, with: .failed, duration: duration, logs: nil)
    } else {
      // We don't know how to handle it, but an upstream reporter might.
      let stringEvent = String(data: data, encoding: .utf8) ?? ""
      reporter.handleExternalEvent(stringEvent)
    }
  }

  private func reportTestFailure(forTestClass testClass: String, testName: String, endTestEvent jsonEvent: [String: Any]) {
    let exceptionDicts = jsonEvent["exceptions"] as? [[String: Any]]
    var parsedExceptions: [TestExceptionInfo] = []

    if let exceptionDicts {
      for exceptionDict in exceptionDicts {
        let message = exceptionDict["reason"] as? String ?? ""
        let file = exceptionDict["filePathInProject"] as? String
        let line = (exceptionDict["lineNumber"] as? NSNumber)?.uintValue ?? 0
        let exception = TestExceptionInfo(message: message, file: file, line: line)
        parsedExceptions.append(exception)
      }
    }

    reporter.testCaseDidFail(forTestClass: testClass, method: testName, exceptions: parsedExceptions)
  }
}
