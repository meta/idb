/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// An `XCTTestIdentifier`, messaged through its selectors.
@objc private protocol XCTTestIdentifierReading {
  @objc(firstComponent) func firstComponent() -> String
  @objc(lastComponent) func lastComponent() -> String
  // The `identifierString` property accessor crashes; this is what it reads.
  @objc(_identifierString) func identifierString() -> String
}

/// A `DTXRemoteInvocationReceipt`: the answer to a call that arrives later.
@objc protocol DTXRemoteInvocationReceiptMessaging {
  @objc(invokeCompletionWithReturnValue:error:) func invokeCompletion(returnValue: AnyObject?, error: (any Error)?)
}

/// A receipt carried into the completion that answers it, with the token a terminate request names.
/// DTX answers it once, from whichever queue the completion runs on.
final class PendingReceipt: @unchecked Sendable {
  let receipt: any DTXRemoteInvocationReceiptMessaging
  let token: AnyObject?

  init(_ receipt: any DTXRemoteInvocationReceiptMessaging, token: AnyObject? = nil) {
    self.receipt = receipt
    self.token = token
  }
}

/// A new `DTXRemoteInvocationReceipt`, or nil when DTXConnectionServices is not loaded.
func makeRemoteInvocationReceipt() -> (any DTXRemoteInvocationReceiptMessaging)? {
  RuntimeClassAllocation.new("DTXRemoteInvocationReceipt").map { unsafe unsafeBitCast($0, to: (any DTXRemoteInvocationReceiptMessaging).self) }
}

/// The private XCTest `XCTestManager_IDEInterface` / `XCTMessagingChannel_RunnerToIDE` callbacks the
/// test runner and testmanagerd make over DTX. Progress goes to the reporter; process launch and
/// termination requests go to the mediator. Each method is exported under the selector DTX sends.
@objc(FBTestManagerAPIMediatorIDEInterface)
final class TestManagerAPIMediatorIDEInterface: NSObject {

  private weak var mediator: TestManagerAPIMediator?
  private let context: TestManagerContext
  private let reporter: any TestManagerReportSink
  private let logger: (any TestManagerLogSink)?

  init(mediator: TestManagerAPIMediator, context: TestManagerContext, reporter: any TestManagerReportSink, logger: (any TestManagerLogSink)?) {
    self.mediator = mediator
    self.context = context
    self.reporter = reporter
    self.logger = logger
    super.init()
  }

  private static func identifier(_ identifier: NSObject) -> any XCTTestIdentifierReading {
    unsafe unsafeBitCast(identifier, to: (any XCTTestIdentifierReading).self)
  }
}

// MARK: - Process Launch Delegation (UI Tests)

extension TestManagerAPIMediatorIDEInterface {

  /// Called when a UI test calls `-[XCUIApplication launch]`. Answers with a token that identifies
  /// the process in later requests.
  @objc(_XCT_launchProcessWithPath:bundleID:arguments:environmentVariables:)
  func launchProcess(path: String?, bundleID: String, arguments: [String], environmentVariables: [String: String]) -> Any? {
    guard let receipt = makeRemoteInvocationReceipt() else {
      return nil
    }
    let token = NSNumber(value: (receipt as AnyObject).hash)
    let pending = PendingReceipt(receipt)
    mediator?.launchProcessForUITest(withToken: token, path: path, bundleID: bundleID, arguments: arguments, environment: environmentVariables) { error in
      pending.receipt.invokeCompletion(returnValue: error == nil ? token : nil, error: error)
    }
    return receipt
  }

  /// Polled after a launch until it reports 1. The launch is only answered once the process is
  /// running, so this always reports 1.
  @objc(_XCT_getProgressForLaunch:)
  func progress(forLaunch token: AnyObject?) -> Any? {
    logger?.log("Test process requested launch process status with token \(String(describing: token))")
    let receipt = makeRemoteInvocationReceipt()
    receipt?.invokeCompletion(returnValue: NSNumber(value: 1), error: nil)
    return receipt
  }

  /// Called when the target process needs to be killed, such as before `-[XCUIApplication launch]`
  /// launches it for the next test. `token` is the one the launch answered with.
  @objc(_XCT_terminateProcess:)
  func terminateProcess(_ token: AnyObject?) -> Any? {
    guard let receipt = makeRemoteInvocationReceipt() else {
      return nil
    }
    let pending = PendingReceipt(receipt, token: token)
    mediator?.terminateProcess(forToken: token as? NSNumber) { error in
      pending.receipt.invokeCompletion(returnValue: error == nil ? pending.token : nil, error: error)
    }
    return receipt
  }

  @objc(_XCT_didBeginInitializingForUITesting)
  func didBeginInitializingForUITesting() -> Any? {
    logger?.log("Started initializing for UI testing.")
    return nil
  }

  @objc(_XCT_initializationForUITestingDidFailWithError:)
  func initializationForUITestingDidFail(error: NSError?) -> Any? {
    nil
  }

  @objc(_XCT_handleCrashReportData:fromFileWithName:)
  func handleCrashReportData(_ data: NSData?, fromFileWithName name: NSString?) -> Any? {
    nil
  }
}

// MARK: - Test Suite Progress

extension TestManagerAPIMediatorIDEInterface {

  @objc(_XCT_testSuite:didStartAt:)
  func testSuite(_ testSuite: String, didStartAt time: String) -> Any? {
    logger?.log("Test Suite \(testSuite) started")
    if testSuite.isEmpty {
      let error = NSError(domain: "IDETestOperationsObserverErrorDomain", code: 0x9, userInfo: [NSLocalizedDescriptionKey: "Test reported a suite with nil or empty identifier. This is unsupported."])
      logger?.log("\(error)")
    }
    reporter.testSuite(testSuite, didStartAt: time)
    return nil
  }

  @objc(_XCT_testSuiteWithIdentifier:didStartAt:)
  func testSuite(identifier: NSObject, didStartAt time: String) -> Any? {
    _ = testSuite(Self.identifier(identifier).identifierString(), didStartAt: time)
    return nil
  }

  @objc(_XCT_didBeginExecutingTestPlan)
  func didBeginExecutingTestPlan() -> Any? {
    logger?.log("Test Plan Started")
    reporter.didBeginExecutingTestPlan()
    return nil
  }

  @objc(_XCT_didFinishExecutingTestPlan)
  func didFinishExecutingTestPlan() -> Any? {
    logger?.log("Test Plan Ended")
    reporter.didFinishExecutingTestPlan()
    return nil
  }

  @objc(_XCT_testBundleReadyWithProtocolVersion:minimumVersion:)
  func testBundleReady(protocolVersion: NSNumber, minimumVersion: NSNumber) -> Any? {
    nil
  }

  @objc(_XCT_testCaseDidStartForTestClass:method:)
  func testCaseDidStart(testClass: String, method: String) -> Any? {
    logger?.log("Test Case \(testClass)/\(method) did start")
    reporter.testCaseDidStart(forTestClass: testClass, method: method)
    return nil
  }

  @objc(_XCT_testCaseDidStartWithIdentifier:testCaseRunConfiguration:)
  func testCaseDidStart(identifier: NSObject, testCaseRunConfiguration: AnyObject?) -> Any? {
    let identifier = Self.identifier(identifier)
    return testCaseDidStart(testClass: identifier.firstComponent(), method: identifier.lastComponent())
  }

  @objc(_XCT_testCaseWithIdentifier:didRecordIssue:)
  func testCase(identifier: NSObject, didRecordIssue issue: NSObject) -> Any? {
    let reading = Self.identifier(identifier)
    let compactDescription = issue.value(forKey: "compactDescription") as? String ?? ""
    let detailedDescription = issue.value(forKey: "detailedDescription") as? String
    logger?.log("Test Case \(reading.firstComponent())/\(reading.lastComponent()) did fail: \(detailedDescription ?? compactDescription)")
    let file = (issue.value(forKeyPath: "sourceCodeContext.location.fileURL") as? URL)?.absoluteString
    let line = issue.value(forKeyPath: "sourceCodeContext.location.lineNumber") as? NSNumber ?? 0
    reportFailure(testClass: reading.firstComponent(), method: reading.lastComponent(), message: compactDescription, file: file, line: line)
    return nil
  }

  @objc(_XCT_testCaseDidFailForTestClass:method:withMessage:file:line:)
  func testCaseDidFail(testClass: String, method: String, message: String, file: String?, line: NSNumber) -> Any? {
    logger?.log("Test Case \(testClass)/\(method) did fail: \(message)")
    reportFailure(testClass: testClass, method: method, message: message, file: file, line: line)
    return nil
  }

  @objc(_XCT_logDebugMessage:)
  func logDebugMessage(_ message: String) -> Any? {
    logger?.log(message.trimmingCharacters(in: .whitespacesAndNewlines))
    return nil
  }

  @objc(_XCT_logMessage:)
  func logMessage(_ message: String) -> Any? {
    logger?.log("_XCT_logMessage: \(message)")
    return nil
  }

  @objc(_XCT_testCaseDidFinishForTestClass:method:withStatus:duration:)
  func testCaseDidFinish(testClass: String, method: String, status: String, duration: NSNumber) -> Any? {
    logger?.log("Test Case \(testClass)/\(method) did finish (\(status))")
    reporter.testCaseDidFinish(forTestClass: testClass, method: method, with: TestManagerResultSummary.status(forStatusString: status), duration: duration.doubleValue, logs: [])
    return nil
  }

  @objc(_XCT_testCaseWithIdentifier:didFinishWithStatus:duration:)
  func testCase(identifier: NSObject, didFinishWithStatus status: String, duration: NSNumber) -> Any? {
    let identifier = Self.identifier(identifier)
    return testCaseDidFinish(testClass: identifier.firstComponent(), method: identifier.lastComponent(), status: status, duration: duration)
  }

  @objc(_XCT_testSuite:didFinishAt:runCount:withFailures:unexpected:testDuration:totalDuration:)
  func testSuite(_ testSuite: String, didFinishAt time: String, runCount: NSNumber, failures: NSNumber, unexpected: NSNumber, testDuration: NSNumber, totalDuration: NSNumber) -> Any? {
    logger?.log("Test Suite Did Finish \(testSuite)")
    reporter.finished(with: TestManagerResultSummary(testSuite: testSuite, finishingAt: time, runCount: runCount, failures: failures, unexpected: unexpected, testDuration: testDuration, totalDuration: totalDuration))
    return nil
  }

  /// The counts here are the ones the legacy suite callback already reported, which is what the
  /// reporter reads.
  @objc(_XCT_testSuiteWithIdentifier:didFinishAt:runCount:skipCount:failureCount:expectedFailureCount:uncaughtExceptionCount:testDuration:totalDuration:)
  func testSuite(identifier: NSObject, didFinishAt time: String, runCount: NSNumber, skipCount: NSNumber, failureCount: NSNumber, expectedFailureCount: NSNumber, uncaughtExceptionCount: NSNumber, testDuration: NSNumber, totalDuration: NSNumber) -> Any? {
    nil
  }

  @objc(_XCT_testCase:method:didFinishActivity:)
  func testCase(_ testClass: String, method: String, didFinishActivity activity: NSObject) -> Any? {
    reporter.testCase(testClass, method: method, didFinishActivity: ActivityRecord(activity))
    return nil
  }

  @objc(_XCT_testCase:method:willStartActivity:)
  func testCase(_ testClass: String, method: String, willStartActivity activity: NSObject) -> Any? {
    reporter.testCase(testClass, method: method, willStartActivity: ActivityRecord(activity))
    return nil
  }

  @objc(_XCT_testCaseWithIdentifier:didFinishActivity:)
  func testCase(identifier: NSObject, didFinishActivity activity: NSObject) -> Any? {
    let identifier = Self.identifier(identifier)
    return testCase(identifier.firstComponent(), method: identifier.lastComponent(), didFinishActivity: activity)
  }

  @objc(_XCT_testCaseWithIdentifier:willStartActivity:)
  func testCase(identifier: NSObject, willStartActivity activity: NSObject) -> Any? {
    let identifier = Self.identifier(identifier)
    return testCase(identifier.firstComponent(), method: identifier.lastComponent(), willStartActivity: activity)
  }

  private func reportFailure(testClass: String, method: String, message: String, file: String?, line: NSNumber) {
    reporter.testCaseDidFail(forTestClass: testClass, method: method, exceptions: [TestExceptionInfo(message: message, file: file, line: line.uintValue)])
  }
}

// MARK: - Unimplemented

/// Callbacks idb does not act on. Each is logged, with the advice to look at Xcode's own handling.
extension TestManagerAPIMediatorIDEInterface {

  private func unimplemented(_ selector: Selector) -> Any? {
    logger?.log("Received call for unhandled method (\(NSStringFromSelector(selector))). Probably you should have a look at _IDETestManagerAPIMediator in IDEFoundation.framework and implement it. Good luck!")
    return nil
  }

  @objc(_XCT_nativeFocusItemDidChangeAtTime:parameterSnapshot:applicationSnapshot:)
  func unhandledNativeFocusItemDidChangeAtTime(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledNativeFocusItemDidChangeAtTime(_:_:_:)))
  }

  @objc(_XCT_recordedEventNames:timestamp:duration:startLocation:startElementSnapshot:startApplicationSnapshot:endLocation:endElementSnapshot:endApplicationSnapshot:)
  func unhandledRecordedEventNamesTimestamp9(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?, _ a3: AnyObject?, _ a4: AnyObject?, _ a5: AnyObject?, _ a6: AnyObject?, _ a7: AnyObject?, _ a8: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledRecordedEventNamesTimestamp9(_:_:_:_:_:_:_:_:_:)))
  }

  @objc(_XCT_recordedOrientationChange:)
  func unhandledRecordedOrientationChange(_ a0: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledRecordedOrientationChange(_:)))
  }

  @objc(_XCT_recordedFirstResponderChangedWithApplicationSnapshot:)
  func unhandledRecordedFirstResponderChangedWithApplicationSnapshot(_ a0: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledRecordedFirstResponderChangedWithApplicationSnapshot(_:)))
  }

  @objc(_XCT_exchangeCurrentProtocolVersion:minimumVersion:)
  func unhandledExchangeCurrentProtocolVersion(_ a0: AnyObject?, _ a1: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledExchangeCurrentProtocolVersion(_:_:)))
  }

  @objc(_XCT_recordedKeyEventsWithApplicationSnapshot:characters:charactersIgnoringModifiers:modifierFlags:)
  func unhandledRecordedKeyEventsWithApplicationSnapshot(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?, _ a3: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledRecordedKeyEventsWithApplicationSnapshot(_:_:_:_:)))
  }

  @objc(_XCT_recordedEventNames:duration:startLocation:startElementSnapshot:startApplicationSnapshot:endLocation:endElementSnapshot:endApplicationSnapshot:)
  func unhandledRecordedEventNamesDuration8(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?, _ a3: AnyObject?, _ a4: AnyObject?, _ a5: AnyObject?, _ a6: AnyObject?, _ a7: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledRecordedEventNamesDuration8(_:_:_:_:_:_:_:_:)))
  }

  @objc(_XCT_recordedKeyEventsWithCharacters:charactersIgnoringModifiers:modifierFlags:)
  func unhandledRecordedKeyEventsWithCharacters(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledRecordedKeyEventsWithCharacters(_:_:_:)))
  }

  @objc(_XCT_recordedEventNames:duration:startElement:startApplicationSnapshot:endElement:endApplicationSnapshot:)
  func unhandledRecordedEventNamesDuration6(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?, _ a3: AnyObject?, _ a4: AnyObject?, _ a5: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledRecordedEventNamesDuration6(_:_:_:_:_:_:)))
  }

  @objc(_XCT_recordedEvent:targetElementID:applicationSnapshot:)
  func unhandledRecordedEventTargetElementID3(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledRecordedEventTargetElementID3(_:_:_:)))
  }

  @objc(_XCT_recordedEvent:forElement:)
  func unhandledRecordedEventForElement2(_ a0: AnyObject?, _ a1: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledRecordedEventForElement2(_:_:)))
  }

  @objc(_XCT_testMethod:ofClass:didMeasureMetric:file:line:)
  func unhandledTestMethodOfClass5(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?, _ a3: AnyObject?, _ a4: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestMethodOfClass5(_:_:_:_:_:)))
  }

  @objc(_XCT_testCase:method:didStallOnMainThreadInFile:line:)
  func unhandledTestCase(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?, _ a3: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestCase(_:_:_:_:)))
  }

  @objc(_XCT_testCaseWasSkippedForTestClass:method:withMessage:file:line:)
  func unhandledTestCaseWasSkippedForTestClass(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?, _ a3: AnyObject?, _ a4: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestCaseWasSkippedForTestClass(_:_:_:_:_:)))
  }

  @objc(_XCT_testSuite:didFinishAt:runCount:skipCount:failureCount:expectedFailureCount:uncaughtExceptionCount:testDuration:totalDuration:)
  func unhandledTestSuiteDidFinishAt9(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?, _ a3: AnyObject?, _ a4: AnyObject?, _ a5: AnyObject?, _ a6: AnyObject?, _ a7: AnyObject?, _ a8: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestSuiteDidFinishAt9(_:_:_:_:_:_:_:_:_:)))
  }

  @objc(_XCT_testSuite:didFinishAt:runCount:skipCount:failureCount:unexpectedFailureCount:testDuration:totalDuration:)
  func unhandledTestSuiteDidFinishAt8(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?, _ a3: AnyObject?, _ a4: AnyObject?, _ a5: AnyObject?, _ a6: AnyObject?, _ a7: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestSuiteDidFinishAt8(_:_:_:_:_:_:_:_:)))
  }

  @objc(_XCT_testMethod:ofClass:didMeasureValues:forPerformanceMetricID:name:withUnits:baselineName:baselineAverage:maxPercentRegression:maxPercentRelativeStandardDeviation:file:line:)
  func unhandledTestMethodOfClass12(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?, _ a3: AnyObject?, _ a4: AnyObject?, _ a5: AnyObject?, _ a6: AnyObject?, _ a7: AnyObject?, _ a8: AnyObject?, _ a9: AnyObject?, _ a10: AnyObject?, _ a11: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestMethodOfClass12(_:_:_:_:_:_:_:_:_:_:_:_:)))
  }

  @objc(_XCT_testBundleReady)
  func unhandledTestBundleReady() -> Any? {
    unimplemented(#selector(unhandledTestBundleReady))
  }

  @objc(_XCT_testRunnerReadyWithCapabilities:)
  func unhandledTestRunnerReadyWithCapabilities(_ a0: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestRunnerReadyWithCapabilities(_:)))
  }

  @objc(_XCT_didFailToBootstrapWithError:)
  func unhandledDidFailToBootstrapWithError(_ a0: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledDidFailToBootstrapWithError(_:)))
  }

  @objc(_XCT_reportTestWithIdentifier:didExceedExecutionTimeAllowance:)
  func unhandledReportTestWithIdentifier(_ a0: AnyObject?, _ a1: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledReportTestWithIdentifier(_:_:)))
  }

  @objc(_XCT_testCaseDidStartWithIdentifier:)
  func unhandledTestCaseDidStartWithIdentifier1(_ a0: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestCaseDidStartWithIdentifier1(_:)))
  }

  @objc(_XCT_testCaseDidStartWithIdentifier:iteration:)
  func unhandledTestCaseDidStartWithIdentifierIteration2(_ a0: AnyObject?, _ a1: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestCaseDidStartWithIdentifierIteration2(_:_:)))
  }

  @objc(_XCT_testCaseWithIdentifier:didRecordExpectedFailure:)
  func unhandledTestCaseWithIdentifierDidRecordExpectedFailure2(_ a0: AnyObject?, _ a1: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestCaseWithIdentifierDidRecordExpectedFailure2(_:_:)))
  }

  @objc(_XCT_testCaseWithIdentifier:didStallOnMainThreadInFile:line:)
  func unhandledTestCaseWithIdentifierDidStallOnMainThreadInFile3(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestCaseWithIdentifierDidStallOnMainThreadInFile3(_:_:_:)))
  }

  @objc(_XCT_testCaseWithIdentifier:wasSkippedWithMessage:sourceCodeContext:)
  func unhandledTestCaseWithIdentifierWasSkippedWithMessage3(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestCaseWithIdentifierWasSkippedWithMessage3(_:_:_:)))
  }

  @objc(_XCT_testSuiteWithIdentifier:didRecordIssue:)
  func unhandledTestSuiteWithIdentifier(_ a0: AnyObject?, _ a1: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestSuiteWithIdentifier(_:_:)))
  }

  @objc(_XCT_reportSelfDiagnosisIssue:description:)
  func unhandledReportSelfDiagnosisIssue(_ a0: AnyObject?, _ a1: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledReportSelfDiagnosisIssue(_:_:)))
  }

  @objc(_XCT_testCaseWithIdentifier:didMeasureMetric:file:line:)
  func unhandledTestCaseWithIdentifierDidMeasureMetric4(_ a0: AnyObject?, _ a1: AnyObject?, _ a2: AnyObject?, _ a3: AnyObject?) -> Any? {
    unimplemented(#selector(unhandledTestCaseWithIdentifierDidMeasureMetric4(_:_:_:_:)))
  }
}
