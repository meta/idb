/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// What the IDE interface reports a test run's progress to.
protocol TestManagerReportSink: AnyObject {
  func testSuite(_ testSuite: String, didStartAt startTime: String)

  func didBeginExecutingTestPlan()

  func didFinishExecutingTestPlan()

  func testCaseDidStart(forTestClass testClass: String, method: String)

  func testCaseDidFail(forTestClass testClass: String, method: String, exceptions: [TestExceptionInfo])

  func testCaseDidFinish(forTestClass testClass: String, method: String, with status: TestReportStatus, duration: TimeInterval, logs: [String]?)

  func finished(with summary: TestManagerResultSummary)

  func testCase(_ testClass: String, method: String, willStartActivity activity: ActivityRecord)

  func testCase(_ testClass: String, method: String, didFinishActivity activity: ActivityRecord)
}

final class XCTestReporterSink: TestManagerReportSink {
  private let reporter: any XCTestReporter

  init(_ reporter: any XCTestReporter) {
    self.reporter = reporter
  }

  func testSuite(_ testSuite: String, didStartAt startTime: String) {
    reporter.testSuite(testSuite, didStartAt: startTime)
  }

  func didBeginExecutingTestPlan() {
    reporter.didBeginExecutingTestPlan()
  }

  func didFinishExecutingTestPlan() {
    reporter.didFinishExecutingTestPlan()
  }

  func testCaseDidStart(forTestClass testClass: String, method: String) {
    reporter.testCaseDidStart(forTestClass: testClass, method: method)
  }

  func testCaseDidFail(forTestClass testClass: String, method: String, exceptions: [TestExceptionInfo]) {
    reporter.testCaseDidFail(forTestClass: testClass, method: method, exceptions: exceptions)
  }

  func testCaseDidFinish(forTestClass testClass: String, method: String, with status: TestReportStatus, duration: TimeInterval, logs: [String]?) {
    reporter.testCaseDidFinish(forTestClass: testClass, method: method, with: status, duration: duration, logs: logs)
  }

  func finished(with summary: TestManagerResultSummary) {
    reporter.finished(with: summary)
  }

  func testCase(_ testClass: String, method: String, willStartActivity activity: ActivityRecord) {
    reporter.testCase(testClass, method: method, willStartActivity: activity)
  }

  func testCase(_ testClass: String, method: String, didFinishActivity activity: ActivityRecord) {
    reporter.testCase(testClass, method: method, didFinishActivity: activity)
  }
}
