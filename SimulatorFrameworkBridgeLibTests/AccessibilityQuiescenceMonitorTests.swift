/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import SimulatorFrameworkBridgeRuntime
import Testing

@Suite
struct AccessibilityQuiescenceMonitorTests {
  private func report(_ notification: UInt32, _ info: Any?) -> FBAXQuiescenceReport? {
    var report = FBAXQuiescenceReport.runLoopIdle
    return FBAXQuiescenceReportForNotification(notification, info, &report) ? report : nil
  }

  @Test
  func userTestingEventsClassifyByEvent() {
    #expect(report(4002, ["event": "RunLoopIsIdle"]) == .runLoopIdle)
    #expect(report(4002, ["event": "AnimationsNonActive"]) == .animationsInactive)
    #expect(report(4002, ["event": "TouchEventsCompleted"]) == .touchesCompleted)
  }

  @Test
  func unrecognisedUserTestingEventsReportNothing() {
    #expect(report(4002, ["event": "ViewDidAppear"]) == nil)
    #expect(report(4002, [:] as [String: Any]) == nil)
    #expect(report(4002, nil) == nil)
    #expect(report(4002, "RunLoopIsIdle") == nil)
  }

  @Test
  func suspendedStatusChangesReportAStateChangeWhateverTheStatus() {
    #expect(report(1021, ["pid": 42, "suspended-status": "resumed"]) == .applicationStateChanged)
    #expect(report(1021, ["pid": 42, "suspended-status": "tentative-suspended"]) == .applicationStateChanged)
  }

  @Test
  func otherNotificationsReportNothing() {
    #expect(report(1001, nil) == nil)
    #expect(report(1069, ["event": "RunLoopIsIdle"]) == nil)
  }

  @Test
  func theClientUnwrapsElementsForRequestsAndForwardsReports() throws {
    let runtime = FBAXFakeRuntime()
    let application = FBAXFakeElement.readable("UIApplication")
    runtime.applicationElements[42] = application
    let client = FBAXClient(runtime: runtime)
    var heard: [(FBAXQuiescenceReport, pid_t)] = []

    let monitor = try client.quiescenceMonitor { report, pid in heard.append((report, pid)) }
    let applicationElement = try client.applicationElement(forProcessIdentifier: 42).value
    let element = try #require(applicationElement)
    let outcome = try monitor.request(.animationsInactive, fromApplication: element)

    #expect(outcome.status == .written)
    let fake = try #require(runtime.quiescenceMonitors.firstObject as? FBAXFakeQuiescenceMonitor)
    #expect(fake.requests.count == 1)
    let request = try #require(fake.requests.firstObject as? [String: Any])
    #expect(request["signal"] as? UInt == FBAXQuiescenceSignal.animationsInactive.rawValue)
    #expect(request["element"] as AnyObject === application)

    fake.deliver(.runLoopIdle, pid: 42)
    monitor.invalidate()
    fake.deliver(.animationsInactive, pid: 42)
    #expect(fake.isInvalidated)
    #expect(heard.map(\.0) == [.runLoopIdle])
    #expect(heard.map(\.1) == [42])
  }

  @Test
  func aBindFailureIsAnErrorCarryingTheRuntimesReason() {
    let runtime = FBAXFakeRuntime()
    runtime.quiescenceMonitorError = "AXObserverCreate failed (-25200)"

    let error = #expect(throws: (any Error).self) { try FBAXClient(runtime: runtime).quiescenceMonitor { _, _ in } }
    #expect((error as NSError?)?.localizedDescription == "AXObserverCreate failed (-25200)")
  }

  @Test
  func aRaiseWhileStartingIsContained() {
    let runtime = FBAXFakeRuntime()
    runtime.raiseOnOperation = "quiescenceMonitor"

    let error = #expect(throws: (any Error).self) { try FBAXClient(runtime: runtime).quiescenceMonitor { _, _ in } }
    #expect((error as NSError?)?.domain == "FBAXRuntimeException")
  }

  // Creating an observer inside an app-hosted test process traps in FrontBoardServices, so the live monitor
  // is exercised through a spawned guest instead; this pins only that its entry points are there.
  @Test
  func theQuiescenceEntryPointsResolve() {
    #expect(dlopen(FBAXPathAXRuntime, RTLD_NOW) != nil, "AXRuntime could not be opened")
    for symbol in ["AXObserverCreate", "AXObserverAddNotification", "AXObserverGetRunLoopSource", "AXUIElementPerformActionWithValue"] {
      #expect(dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) != nil, "\(symbol)")
    }
  }
}
