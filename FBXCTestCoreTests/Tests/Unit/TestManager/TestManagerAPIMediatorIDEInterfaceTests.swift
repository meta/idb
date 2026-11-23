/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBXCTestCore
import Foundation
import Testing

/// Records what the IDE interface reports, one line per call.
private final class RecordingReportSink: NSObject, TestManagerReportSink {
  private(set) var events: [String] = []
  private(set) var exceptions: [TestExceptionInfo] = []
  private(set) var summaries: [TestManagerResultSummary] = []
  private(set) var activities: [ActivityRecord] = []

  func testSuite(_ testSuite: String, didStartAt startTime: String) {
    events.append("suiteStart:\(testSuite):\(startTime)")
  }

  func didBeginExecutingTestPlan() {
    events.append("planStart")
  }

  func didFinishExecutingTestPlan() {
    events.append("planFinish")
  }

  func testCaseDidStart(forTestClass testClass: String, method: String) {
    events.append("caseStart:\(testClass)/\(method)")
  }

  func testCaseDidFail(forTestClass testClass: String, method: String, exceptions: [TestExceptionInfo]) {
    events.append("caseFail:\(testClass)/\(method)")
    self.exceptions.append(contentsOf: exceptions)
  }

  func testCaseDidFinish(forTestClass testClass: String, method: String, with status: TestReportStatus, duration: TimeInterval, logs: [String]?) {
    events.append("caseFinish:\(testClass)/\(method):\(status.rawValue):\(duration):\(logs ?? ["nil"])")
  }

  func finished(with summary: TestManagerResultSummary) {
    events.append("summary")
    summaries.append(summary)
  }

  func testCase(_ testClass: String, method: String, willStartActivity activity: ActivityRecord) {
    events.append("activityStart:\(testClass)/\(method):\(activity.title)")
    activities.append(activity)
  }

  func testCase(_ testClass: String, method: String, didFinishActivity activity: ActivityRecord) {
    events.append("activityFinish:\(testClass)/\(method):\(activity.title)")
    activities.append(activity)
  }
}

private final class RecordingLogSink: NSObject, TestManagerLogSink {
  private(set) var messages: [String] = []

  func log(_ message: String) {
    messages.append(message)
  }
}

/// The fields of XCTest's `XCActivityRecord` that are read from an activity, through KVC.
private final class ActivityRecordDouble: NSObject {
  @objc let title = "Tap button"
  @objc let activityType = "com.apple.dt.xctest.activity-type.userCreated"
  @objc let uuid = UUID(uuidString: "6F0F3D2A-7C55-4F4B-9A39-6E3A9E2B6C11")!
  @objc let start = Date(timeIntervalSince1970: 100)
  @objc let finish = Date(timeIntervalSince1970: 102)
  @objc let duration = 2.0
  @objc let name = "Tap button"
  @objc let attachments: [NSObject] = []
}

/// The fields of XCTest's `XCTIssue` that are read from a recorded issue.
private final class IssueDouble: NSObject {
  final class SourceCodeLocation: NSObject {
    @objc let fileURL: URL?
    @objc let lineNumber: Int

    init(fileURL: URL?, lineNumber: Int) {
      self.fileURL = fileURL
      self.lineNumber = lineNumber
    }
  }

  final class SourceCodeContext: NSObject {
    @objc let location: SourceCodeLocation

    init(location: SourceCodeLocation) {
      self.location = location
    }
  }

  @objc let compactDescription: String
  @objc let detailedDescription: String?
  @objc let sourceCodeContext: SourceCodeContext

  init(compactDescription: String, detailedDescription: String?, file: String, line: Int) {
    self.compactDescription = compactDescription
    self.detailedDescription = detailedDescription
    self.sourceCodeContext = SourceCodeContext(location: SourceCodeLocation(fileURL: URL(fileURLWithPath: file), lineNumber: line))
  }
}

/// The callbacks the test runner and testmanagerd make over DTX, and what each reports. The callbacks
/// are invoked by selector, as DTX invokes them.
@Suite
struct TestManagerAPIMediatorIDEInterfaceTests {

  private let reporter = RecordingReportSink()
  private let logger = RecordingLogSink()
  // Reporting never reaches the mediator, which launches and terminates processes, so these tests give
  // the interface an object that stands in for it.
  private let mediatorPlaceholder = NSObject()

  private func makeInterface() throws -> NSObject {
    let sessionIdentifier = UUID()
    let testConfiguration = try TestConfiguration(
      byWritingToFileWithSessionIdentifier: sessionIdentifier,
      moduleName: "ModuleName",
      testBundlePath: NSTemporaryDirectory(),
      uiTesting: false,
      testsToRun: nil,
      testsToSkip: nil,
      targetApplicationPath: nil,
      targetApplicationBundleID: nil,
      testApplicationDependencies: nil,
      automationFrameworkPath: nil,
      reportActivities: false)
    let context = TestManagerContext(
      sessionIdentifier: sessionIdentifier,
      timeout: 60,
      testHostLaunchConfiguration: ApplicationLaunchConfiguration(
        bundleID: "com.example.host",
        bundleName: "Host",
        arguments: [],
        environment: [:],
        waitForDebugger: false,
        launchMode: .failIfRunning),
      testedApplicationAdditionalEnvironment: [:],
      testConfiguration: testConfiguration)
    return TestManagerAPIMediatorIDEInterface(
      mediator: Unmanaged<TestManagerAPIMediator>.fromOpaque(Unmanaged.passUnretained(mediatorPlaceholder).toOpaque()).takeUnretainedValue(),
      context: context,
      reporter: reporter,
      logger: logger)
  }

  private func testIdentifier(_ testClass: String, _ method: String) -> NSObject {
    makeIdentifier("initWithClassName:methodName:", testClass as NSString, method as NSString)
  }

  private func suiteIdentifier(_ suite: String) -> NSObject {
    makeIdentifier("initWithClassName:", suite as NSString, nil)
  }

  /// `alloc` returns a reference `init` consumes, so it is not retained here; `init` returns the one
  /// the test keeps.
  private func makeIdentifier(_ initializer: String, _ first: NSString, _ second: NSString?) -> NSObject {
    let identifierClass: AnyObject = NSClassFromString("XCTTestIdentifier")!
    let allocated = identifierClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
    let selector = NSSelectorFromString(initializer)
    let initialized = second.map { allocated.perform(selector, with: first, with: $0) } ?? allocated.perform(selector, with: first)
    return initialized!.takeRetainedValue() as! NSObject
  }

  @discardableResult
  private func send(_ target: NSObject, _ selector: String, _ arguments: AnyObject?...) -> AnyObject? {
    let sel = NSSelectorFromString(selector)
    #expect(target.responds(to: sel), "\(selector) is not implemented")
    let imp = target.method(for: sel)!
    switch arguments.count {
    case 0:
      typealias F = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
      return unsafeBitCast(imp, to: F.self)(target, sel)?.takeUnretainedValue()
    case 1:
      typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<AnyObject>?
      return unsafeBitCast(imp, to: F.self)(target, sel, arguments[0])?.takeUnretainedValue()
    case 2:
      typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
      return unsafeBitCast(imp, to: F.self)(target, sel, arguments[0], arguments[1])?.takeUnretainedValue()
    case 3:
      typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
      return unsafeBitCast(imp, to: F.self)(target, sel, arguments[0], arguments[1], arguments[2])?.takeUnretainedValue()
    case 4:
      typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
      return unsafeBitCast(imp, to: F.self)(target, sel, arguments[0], arguments[1], arguments[2], arguments[3])?.takeUnretainedValue()
    case 5:
      typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
      return unsafeBitCast(imp, to: F.self)(target, sel, arguments[0], arguments[1], arguments[2], arguments[3], arguments[4])?.takeUnretainedValue()
    case 7:
      typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
      return unsafeBitCast(imp, to: F.self)(target, sel, arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5], arguments[6])?.takeUnretainedValue()
    case 9:
      typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
      return unsafeBitCast(imp, to: F.self)(target, sel, arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5], arguments[6], arguments[7], arguments[8])?.takeUnretainedValue()
    default:
      Issue.record("no invoker for \(arguments.count) arguments")
      return nil
    }
  }

  @Test
  func aTestPlanIsReportedFromStartToFinish() throws {
    let interface = try makeInterface()

    #expect(send(interface, "_XCT_didBeginExecutingTestPlan") == nil)
    #expect(send(interface, "_XCT_testSuite:didStartAt:", "Suite" as NSString, "12:00" as NSString) == nil)
    #expect(send(interface, "_XCT_testCaseDidStartForTestClass:method:", "Class" as NSString, "testMethod" as NSString) == nil)
    #expect(send(interface, "_XCT_testCaseDidFinishForTestClass:method:withStatus:duration:", "Class" as NSString, "testMethod" as NSString, "passed" as NSString, 1.5 as NSNumber) == nil)
    #expect(send(interface, "_XCT_didFinishExecutingTestPlan") == nil)

    #expect(
      reporter.events == [
        "planStart",
        "suiteStart:Suite:12:00",
        "caseStart:Class/testMethod",
        "caseFinish:Class/testMethod:\(TestReportStatus.passed.rawValue):1.5:[]",
        "planFinish",
      ])
  }

  @Test
  func aTestSuiteIdentifierIsReportedByItsIdentifierString() throws {
    let interface = try makeInterface()

    send(interface, "_XCT_testSuiteWithIdentifier:didStartAt:", suiteIdentifier("Suite"), "12:00" as NSString)

    #expect(reporter.events == ["suiteStart:Suite:12:00"])
  }

  @Test
  func anEmptySuiteNameIsLoggedAndStillReported() throws {
    let interface = try makeInterface()

    send(interface, "_XCT_testSuite:didStartAt:", "" as NSString, "12:00" as NSString)

    #expect(reporter.events == ["suiteStart::12:00"])
    #expect(logger.messages.contains { $0.contains("nil or empty identifier") }, "\(logger.messages)")
  }

  @Test
  func aTestCaseIdentifierIsReportedByItsClassAndMethod() throws {
    let interface = try makeInterface()
    let identifier = testIdentifier("Class", "testMethod")

    send(interface, "_XCT_testCaseDidStartWithIdentifier:testCaseRunConfiguration:", identifier, nil)
    send(interface, "_XCT_testCaseWithIdentifier:didFinishWithStatus:duration:", identifier, "failed" as NSString, 0.25 as NSNumber)

    #expect(
      reporter.events == [
        "caseStart:Class/testMethod",
        "caseFinish:Class/testMethod:\(TestReportStatus.failed.rawValue):0.25:[]",
      ])
  }

  @Test
  func aLegacyFailureIsReportedWithItsLocation() throws {
    let interface = try makeInterface()

    send(interface, "_XCT_testCaseDidFailForTestClass:method:withMessage:file:line:", "Class" as NSString, "testMethod" as NSString, "XCTAssertTrue failed" as NSString, "/tmp/Test.swift" as NSString, 42 as NSNumber)

    #expect(reporter.events == ["caseFail:Class/testMethod"])
    #expect(reporter.exceptions.map(\.message) == ["XCTAssertTrue failed"])
    #expect(reporter.exceptions.map(\.file) == ["/tmp/Test.swift"])
    #expect(reporter.exceptions.map(\.line) == [42])
  }

  @Test
  func aRecordedIssueIsReportedWithItsCompactDescriptionAndLocation() throws {
    let interface = try makeInterface()
    let issue = IssueDouble(
      compactDescription: "XCTAssertEqual failed",
      detailedDescription: "XCTAssertEqual failed: (\"1\") is not equal to (\"2\")",
      file: "/tmp/Test.swift",
      line: 7)

    #expect(send(interface, "_XCT_testCaseWithIdentifier:didRecordIssue:", testIdentifier("Class", "testMethod"), issue) == nil)

    #expect(reporter.events == ["caseFail:Class/testMethod"])
    #expect(reporter.exceptions.map(\.message) == ["XCTAssertEqual failed"])
    #expect(reporter.exceptions.map(\.file) == [URL(fileURLWithPath: "/tmp/Test.swift").absoluteString])
    #expect(reporter.exceptions.map(\.line) == [7])
    #expect(logger.messages.contains { $0.contains("is not equal to") }, "the detailed description is logged: \(logger.messages)")
  }

  @Test
  func aLegacySuiteFinishIsReportedAsASummary() throws {
    let interface = try makeInterface()

    send(interface, "_XCT_testSuite:didFinishAt:runCount:withFailures:unexpected:testDuration:totalDuration:", "Suite" as NSString, "12:01" as NSString, 3 as NSNumber, 1 as NSNumber, 0 as NSNumber, 2.0 as NSNumber, 2.5 as NSNumber)

    #expect(reporter.events == ["summary"])
    let summary = try #require(reporter.summaries.first)
    #expect(summary.testSuite == "Suite")
    #expect(summary.runCount == 3)
    #expect(summary.failureCount == 1)
    #expect(summary.unexpected == 0)
  }

  @Test
  func anIdentifiedSuiteFinishIsNotReported() throws {
    let interface = try makeInterface()

    #expect(send(interface, "_XCT_testSuiteWithIdentifier:didFinishAt:runCount:skipCount:failureCount:expectedFailureCount:uncaughtExceptionCount:testDuration:totalDuration:", suiteIdentifier("Suite"), "12:01" as NSString, 3 as NSNumber, 0 as NSNumber, 1 as NSNumber, 0 as NSNumber, 0 as NSNumber, 2.0 as NSNumber, 2.5 as NSNumber) == nil)

    #expect(reporter.events == [])
  }

  @Test
  func activitiesAreReportedByClassAndMethodOrIdentifier() throws {
    let interface = try makeInterface()
    let activity = ActivityRecordDouble()

    send(interface, "_XCT_testCase:method:willStartActivity:", "Class" as NSString, "testMethod" as NSString, activity)
    send(interface, "_XCT_testCase:method:didFinishActivity:", "Class" as NSString, "testMethod" as NSString, activity)
    send(interface, "_XCT_testCaseWithIdentifier:willStartActivity:", testIdentifier("Class", "testOther"), activity)
    send(interface, "_XCT_testCaseWithIdentifier:didFinishActivity:", testIdentifier("Class", "testOther"), activity)

    #expect(
      reporter.events == [
        "activityStart:Class/testMethod:Tap button",
        "activityFinish:Class/testMethod:Tap button",
        "activityStart:Class/testOther:Tap button",
        "activityFinish:Class/testOther:Tap button",
      ])
    #expect(reporter.activities.first?.duration == 2.0)
    #expect(reporter.activities.first?.uuid == activity.uuid)
  }

  @Test
  func messagesAreLogged() throws {
    let interface = try makeInterface()

    send(interface, "_XCT_logDebugMessage:", "  debug line \n" as NSString)
    send(interface, "_XCT_logMessage:", "message" as NSString)

    #expect(logger.messages.contains("debug line"), "\(logger.messages)")
    #expect(logger.messages.contains("_XCT_logMessage: message"), "\(logger.messages)")
    #expect(reporter.events == [])
  }

  @Test
  func launchProgressIsAlwaysComplete() throws {
    let interface = try makeInterface()

    let receipt = try #require(send(interface, "_XCT_getProgressForLaunch:", 1 as NSNumber) as? NSObject)

    #expect(receipt.isKind(of: NSClassFromString("DTXRemoteInvocationReceipt")!), "\(receipt)")
  }

  @Test
  func callbacksThatNeedNoAnswerReturnNothing() throws {
    let interface = try makeInterface()

    #expect(send(interface, "_XCT_didBeginInitializingForUITesting") == nil)
    #expect(send(interface, "_XCT_initializationForUITestingDidFailWithError:", NSError(domain: "Test", code: 1)) == nil)
    #expect(send(interface, "_XCT_handleCrashReportData:fromFileWithName:", Data() as NSData, "crash" as NSString) == nil)
    #expect(send(interface, "_XCT_testBundleReadyWithProtocolVersion:minimumVersion:", 36 as NSNumber, 8 as NSNumber) == nil)
    #expect(reporter.events == [])
  }
}
