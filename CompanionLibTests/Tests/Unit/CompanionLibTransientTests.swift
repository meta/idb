/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency @testable import CompanionLib
@preconcurrency import FBControlCore
import FBXCTestCore
import Foundation
import Testing

@Suite
struct CompanionLibTransientTests {

  // MARK: - XCTestRunRequest Factory & Property Tests

  @Test
  func logicTestRequestProperties() {
    let coverageRequest = CodeCoverageRequest(collect: false, format: .raw, enableContinuousCoverageCollection: false)
    let request = XCTestRunRequest.logicTest(
      withTestBundleID: "com.test.bundle",
      environment: ["KEY": "VALUE"],
      arguments: ["-arg1"],
      testsToRun: Set(["TestClass/testMethod"]),
      testsToSkip: Set<String>(),
      testTimeout: 300,
      reportActivities: true,
      reportAttachments: false,
      coverageRequest: coverageRequest,
      collectLogs: true,
      waitForDebugger: false,
      collectResultBundle: false
    )
    #expect((request.bundle) == (.identifier("com.test.bundle")))
    #expect((request.mode) == (.logic))
    #expect((request.isLogicTest))
    #expect(!(request.isUITest))
    #expect((request.testBundleID) == ("com.test.bundle"))
    #expect((request.testPath) == nil)
    #expect((request.testHostAppBundleID) == nil)
    #expect((request.testTargetAppBundleID) == nil)
    #expect((request.environment) == (["KEY": "VALUE"]))
    #expect((request.arguments) == (["-arg1"]))
    #expect((request.testsToRun) == (Set(["TestClass/testMethod"])))
    #expect((request.testsToSkip.isEmpty))
    #expect((request.testTimeout) == (300))
    #expect((request.reportActivities))
    #expect(!(request.reportAttachments))
    #expect(!(request.coverageRequest.collect))
    #expect((request.collectLogs))
    #expect(!(request.waitForDebugger))
    #expect(!(request.collectResultBundle))
  }

  @Test
  func applicationTestRequestProperties() {
    let coverageRequest = CodeCoverageRequest(collect: true, format: .exported, enableContinuousCoverageCollection: true)
    let request = XCTestRunRequest.applicationTest(
      withTestBundleID: "com.test.apptest",
      testHostAppBundleID: "com.test.host",
      environment: [:],
      arguments: [],
      testsToRun: nil,
      testsToSkip: Set<String>(),
      testTimeout: 600,
      reportActivities: false,
      reportAttachments: true,
      coverageRequest: coverageRequest,
      collectLogs: false,
      waitForDebugger: true,
      collectResultBundle: true
    )
    #expect((request.bundle) == (.identifier("com.test.apptest")))
    #expect((request.mode) == (.application(testHostAppBundleID: "com.test.host")))
    #expect(!(request.isLogicTest))
    #expect(!(request.isUITest))
    #expect((request.testBundleID) == ("com.test.apptest"))
    #expect((request.testPath) == nil)
    #expect((request.testHostAppBundleID) == ("com.test.host"))
    #expect((request.testTargetAppBundleID) == nil)
    #expect((request.testsToRun) == nil)
    #expect((request.coverageRequest.collect))
    #expect((request.waitForDebugger))
    #expect((request.collectResultBundle))
  }

  @Test
  func uITestRequestProperties() {
    let coverageRequest = CodeCoverageRequest(collect: false, format: .raw, enableContinuousCoverageCollection: false)
    let request = XCTestRunRequest.uiTest(
      withTestBundleID: "com.test.uitest",
      testHostAppBundleID: "com.test.runner",
      testTargetAppBundleID: "com.test.app",
      environment: ["UI": "true"],
      arguments: ["-ui"],
      testsToRun: Set(["UITestSuite"]),
      testsToSkip: Set(["UITestSuite/testSkipped"]),
      testTimeout: 900,
      reportActivities: true,
      reportAttachments: true,
      coverageRequest: coverageRequest,
      collectLogs: true,
      collectResultBundle: false
    )
    #expect((request.bundle) == (.identifier("com.test.uitest")))
    #expect((request.mode) == (.ui(testHostAppBundleID: "com.test.runner", testTargetAppBundleID: "com.test.app")))
    #expect(!(request.isLogicTest))
    #expect((request.isUITest))
    #expect((request.testBundleID) == ("com.test.uitest"))
    #expect((request.testHostAppBundleID) == ("com.test.runner"))
    #expect((request.testTargetAppBundleID) == ("com.test.app"))
    #expect((request.environment) == (["UI": "true"]))
    #expect((request.arguments) == (["-ui"]))
    #expect((request.testsToRun) == (Set(["UITestSuite"])))
    #expect((request.testsToSkip) == (Set(["UITestSuite/testSkipped"])))
    #expect(!(request.waitForDebugger))
  }

  @Test
  func logicTestWithTestPathProperties() {
    let coverageRequest = CodeCoverageRequest(collect: false, format: .raw, enableContinuousCoverageCollection: false)
    let testURL = URL(fileURLWithPath: "/tmp/MyTest.xctest")
    let request = XCTestRunRequest.logicTest(
      withTestPath: testURL,
      environment: [:],
      arguments: [],
      testsToRun: nil,
      testsToSkip: Set<String>(),
      testTimeout: 60,
      reportActivities: false,
      reportAttachments: false,
      coverageRequest: coverageRequest,
      collectLogs: false,
      waitForDebugger: false,
      collectResultBundle: false
    )
    #expect((request.bundle) == (.path(testURL)))
    #expect((request.mode) == (.logic))
    #expect((request.isLogicTest))
    #expect(!(request.isUITest))
    #expect((request.testPath) == (testURL))
    #expect((request.testBundleID) == nil)
  }

  @Test
  func pathBundlesCombineWithHostedModes() {
    let coverageRequest = CodeCoverageRequest(collect: false, format: .raw, enableContinuousCoverageCollection: false)
    let testURL = URL(fileURLWithPath: "/tmp/MyTest.xctest")
    let applicationTest = XCTestRunRequest.applicationTest(
      withTestPath: testURL,
      testHostAppBundleID: "com.test.host",
      environment: [:],
      arguments: [],
      testsToRun: nil,
      testsToSkip: Set<String>(),
      testTimeout: nil,
      reportActivities: false,
      reportAttachments: false,
      coverageRequest: coverageRequest,
      collectLogs: false,
      waitForDebugger: false,
      collectResultBundle: false
    )
    #expect((applicationTest.bundle) == (.path(testURL)))
    #expect((applicationTest.mode) == (.application(testHostAppBundleID: "com.test.host")))
    #expect(!(applicationTest.isLogicTest))
    #expect(!(applicationTest.isUITest))
    #expect((applicationTest.testPath) == (testURL))
    #expect((applicationTest.testBundleID) == nil)
    #expect((applicationTest.testTargetAppBundleID) == nil)

    let uiTest = XCTestRunRequest.uiTest(
      withTestPath: testURL,
      testHostAppBundleID: "com.test.runner",
      testTargetAppBundleID: "com.test.app",
      environment: [:],
      arguments: [],
      testsToRun: nil,
      testsToSkip: Set<String>(),
      testTimeout: nil,
      reportActivities: false,
      reportAttachments: false,
      coverageRequest: coverageRequest,
      collectLogs: false,
      collectResultBundle: false
    )
    #expect((uiTest.bundle) == (.path(testURL)))
    #expect((uiTest.mode) == (.ui(testHostAppBundleID: "com.test.runner", testTargetAppBundleID: "com.test.app")))
    #expect(!(uiTest.isLogicTest))
    #expect((uiTest.isUITest))
    #expect((uiTest.testPath) == (testURL))
    #expect((uiTest.testBundleID) == nil)
  }

  @Test
  func requestDescriptionNamesModeAndBundle() {
    let coverageRequest = CodeCoverageRequest(collect: false, format: .raw, enableContinuousCoverageCollection: false)
    let logicTest = XCTestRunRequest.logicTest(
      withTestBundleID: "com.test.bundle",
      environment: [:],
      arguments: [],
      testsToRun: nil,
      testsToSkip: Set<String>(),
      testTimeout: nil,
      reportActivities: false,
      reportAttachments: false,
      coverageRequest: coverageRequest,
      collectLogs: false,
      waitForDebugger: false,
      collectResultBundle: false
    )
    #expect((String(describing: logicTest)) == ("logic test of bundle id com.test.bundle"))

    let applicationTest = XCTestRunRequest.applicationTest(
      withTestBundleID: "com.test.apptest",
      testHostAppBundleID: "com.test.host",
      environment: [:],
      arguments: [],
      testsToRun: nil,
      testsToSkip: Set<String>(),
      testTimeout: nil,
      reportActivities: false,
      reportAttachments: false,
      coverageRequest: coverageRequest,
      collectLogs: false,
      waitForDebugger: false,
      collectResultBundle: false
    )
    #expect((String(describing: applicationTest)) == ("application test of bundle id com.test.apptest hosted by com.test.host"))

    let uiTest = XCTestRunRequest.uiTest(
      withTestPath: URL(fileURLWithPath: "/tmp/MyTest.xctest"),
      testHostAppBundleID: "com.test.runner",
      testTargetAppBundleID: "com.test.app",
      environment: [:],
      arguments: [],
      testsToRun: nil,
      testsToSkip: Set<String>(),
      testTimeout: nil,
      reportActivities: false,
      reportAttachments: false,
      coverageRequest: coverageRequest,
      collectLogs: false,
      collectResultBundle: false
    )
    #expect((String(describing: uiTest)) == ("ui test of bundle at /tmp/MyTest.xctest hosted by com.test.runner targeting com.test.app"))
  }

  // MARK: - XCTestReporterConfiguration Tests

  @Test
  func reporterConfigurationDescription() {
    let config = XCTestReporterConfiguration(
      resultBundlePath: "/result",
      coverageConfiguration: nil,
      logDirectoryPath: "/logs",
      binariesPaths: ["/bin"],
      reportAttachments: true,
      reportResultBundle: false
    )
    let desc = config.description
    #expect((desc.contains("/result")))
    #expect((desc.contains("/logs")))
  }
}
