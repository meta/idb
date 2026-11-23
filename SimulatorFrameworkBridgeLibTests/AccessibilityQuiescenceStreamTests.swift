/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBSimulatorBridgeProtocol
import Foundation
import SimulatorFrameworkBridgeRuntime
import SimulatorFrameworkBridgeSupport
import UIKit
import XCTest

// Drives `quiet` through a real serve socket against the fake runtime. Thresholds are either generous or
// the thing under test, so scheduling jitter cannot flip an answer.
extension BridgeServerSocketTests {
  private func useRuntime(_ runtime: FBAXFakeRuntime) {
    FBAXClientProvider.setRuntimeForTesting(runtime)
    addTeardownBlock { FBAXClientProvider.setRuntimeForTesting(nil) }
  }

  private func openQuietStream(_ runtime: FBAXFakeRuntime, _ request: [String: Any]) throws -> Int32 {
    useRuntime(runtime)
    startServerExclusive(exclusive: true)
    let client = connectClient()
    var payload = request
    payload["verb"] = "quiet"
    Self.sendData(data: try Self.frame(accessibility: payload), to: client)
    return client
  }

  /// Opens a stream with a request the flat parameters could not spell, as a host could still send one.
  private func openStream(_ runtime: FBAXFakeRuntime, _ request: BridgeAXRequest) throws -> Int32 {
    useRuntime(runtime)
    startServerExclusive(exclusive: true)
    let client = connectClient()
    Self.sendData(data: try Self.frame(command: .accessibility(request)), to: client)
    return client
  }

  /// The accessibility envelope a streamed frame carries.
  private func readEvent(fd: Int32) -> BridgeAXAnswer? {
    let answers = (Self.readResponse(fd: fd)?["result"] as? NSDictionary)?["answers"] as? [NSDictionary]
    guard let answer = (answers?.first?["accessibility"] as? NSDictionary)?["answer"], let data = try? JSONSerialization.data(withJSONObject: answer) else {
      return nil
    }
    return try? JSONDecoder().decode(BridgeAXAnswer.self, from: data)
  }

  private func snapshot(_ answer: BridgeAXAnswer?) -> BridgeAXSettingSnapshot? {
    guard case let .settingSnapshot(snapshot)? = answer else { return nil }
    return snapshot
  }

  private func failure(_ answer: BridgeAXAnswer?) -> BridgeAXFailure? {
    guard case let .failure(failure)? = answer else { return nil }
    return failure
  }

  // The exclusive server exits once the client hangs up, and must be waited for inside the test body.
  private func closeQuietStream(_ client: Int32) {
    close(client)
    finishServer()
  }

  private func eventually<T>(_ description: String, _ probe: () -> T?) throws -> T {
    let deadline = Date(timeIntervalSinceNow: 5)
    while deadline.timeIntervalSinceNow > 0 {
      if let value = probe() {
        return value
      }
      usleep(1000)
    }
    throw NSError(domain: "AccessibilityQuiescenceStreamTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(description)"])
  }

  private func monitor(of runtime: FBAXFakeRuntime, requests: Int) throws -> FBAXFakeQuiescenceMonitor {
    try eventually("\(requests) quiescence requests") {
      guard let monitor = runtime.quiescenceMonitors.lastObject as? FBAXFakeQuiescenceMonitor, monitor.requests.count >= requests else { return nil }
      return monitor
    }
  }

  private func runtimeWithApplications(_ pids: [pid_t]) -> FBAXFakeRuntime {
    let runtime = FBAXFakeRuntime()
    runtime.automationMode = true
    for pid in pids {
      runtime.applicationElements[NSNumber(value: pid)] = FBAXFakeElement.readable("UIApplication")
    }
    return runtime
  }

  // Above the kernel's highest pid, so certain not to be running.
  private static let exitedPid: pid_t = 99999

  private func state(_ state: BridgeAXQuiescenceEvent.State, pid: pid_t, signals: [BridgeAXQuiescenceEvent.Signal] = []) -> BridgeAXAnswer {
    .quiescence(.state(state, busySignals: signals, pid: pid))
  }

  func testANamedApplicationGoesQuietOnceBothSignalsAnswer() throws {
    let pid = getpid()
    let runtime = runtimeWithApplications([pid])
    let client = try openQuietStream(runtime, ["pid": pid, "busyThresholdMs": 5000, "quietWindowMs": 0])

    let monitor = try monitor(of: runtime, requests: 2)
    let requests = try XCTUnwrap(monitor.requests.copy() as? [[String: Any]])
    let application = runtime.applicationElements[NSNumber(value: pid)] as AnyObject
    XCTAssertEqual(Set(requests.compactMap { ($0["signal"] as? NSNumber)?.uintValue }), [FBAXQuiescenceSignal.runLoopIdle.rawValue, FBAXQuiescenceSignal.animationsInactive.rawValue])
    XCTAssertTrue(requests.allSatisfy { ($0["element"] as AnyObject) === application })
    monitor.deliver(.runLoopIdle, pid: pid)
    monitor.deliver(.animationsInactive, pid: pid)
    XCTAssertEqual(readEvent(fd: client), state(.quiet, pid: pid))

    _ = try self.monitor(of: runtime, requests: 4)
    monitor.deliver(.touchesCompleted, pid: pid)
    XCTAssertEqual(readEvent(fd: client), .quiescence(.touchesCompleted(pid: pid)))
    closeQuietStream(client)
    XCTAssertTrue(monitor.isInvalidated)
  }

  func testASignalUnansweredPastTheThresholdIsBusyUntilItAnswers() throws {
    let pid = getpid()
    let runtime = runtimeWithApplications([pid])
    let client = try openQuietStream(runtime, ["pid": pid, "busyThresholdMs": 20, "quietWindowMs": 0])
    defer { closeQuietStream(client) }

    let monitor = try monitor(of: runtime, requests: 2)
    monitor.deliver(.animationsInactive, pid: pid + 1)
    monitor.deliver(.runLoopIdle, pid: pid)
    XCTAssertEqual(readEvent(fd: client), state(.busy, pid: pid, signals: [.animationsInactive]), "an answer for another application is not this one's")
    monitor.deliver(.animationsInactive, pid: pid)
    XCTAssertEqual(readEvent(fd: client), state(.quiet, pid: pid))
  }

  // Every client's monitor hears every answer, so a second answer here stands in for another client's.
  func testAnAnswerToAnotherClientsRequestIsNotReArmed() throws {
    let pid = getpid()
    let runtime = runtimeWithApplications([pid])
    let client = try openQuietStream(runtime, ["pid": pid, "busyThresholdMs": 5000, "quietWindowMs": 0])
    defer { closeQuietStream(client) }

    let monitor = try monitor(of: runtime, requests: 2)
    monitor.deliver(.runLoopIdle, pid: pid)
    monitor.deliver(.runLoopIdle, pid: pid)
    _ = try self.monitor(of: runtime, requests: 3)
    usleep(200_000)
    XCTAssertEqual(monitor.requests.count, 3)
  }

  // Automation mode goes off when another accessibility client exits, and applications drop the requests
  // they are sent while it is off.
  func testAutomationModeTurnedOffMidStreamIsTurnedBackOnAndTheUnansweredSignalsAskedAgain() throws {
    let pid = getpid()
    let runtime = runtimeWithApplications([pid])
    let client = try openQuietStream(runtime, ["pid": pid, "busyThresholdMs": 5000, "quietWindowMs": 0])
    defer { closeQuietStream(client) }

    _ = try monitor(of: runtime, requests: 2)
    runtime.automationMode = false
    _ = try monitor(of: runtime, requests: 4)
    XCTAssertEqual(runtime.automationModeWrites, [true])
  }

  // Whichever client notices automation mode off turns it back on, so this stream may never see it off.
  func testASignalUnansweredForAHeartbeatIsAskedAgainThoughAutomationModeLooksOn() throws {
    let pid = getpid()
    let runtime = runtimeWithApplications([pid])
    let client = try openQuietStream(runtime, ["pid": pid, "busyThresholdMs": 5000, "quietWindowMs": 0])
    defer { closeQuietStream(client) }

    _ = try monitor(of: runtime, requests: 4)
    XCTAssertEqual(runtime.automationModeWrites, [])
  }

  func testTheDefaultWindowSettlesBeforeGoingQuiet() throws {
    let pid = getpid()
    let runtime = runtimeWithApplications([pid])
    let client = try openQuietStream(runtime, ["pid": pid, "busyThresholdMs": 5000])
    defer { closeQuietStream(client) }

    let monitor = try monitor(of: runtime, requests: 2)
    monitor.deliver(.runLoopIdle, pid: pid)
    monitor.deliver(.animationsInactive, pid: pid)
    XCTAssertEqual(readEvent(fd: client), state(.settling, pid: pid))
    XCTAssertEqual(readEvent(fd: client), state(.quiet, pid: pid))
  }

  func testFollowingTheFrontmostApplicationMovesToTheNextOne() throws {
    let (first, second) = (getpid(), getppid())
    let runtime = runtimeWithApplications([first, second])
    runtime.windowServerOutcome = .resolved(first)
    let client = try openQuietStream(runtime, ["busyThresholdMs": 5000, "quietWindowMs": 0])
    defer { closeQuietStream(client) }

    let monitor = try monitor(of: runtime, requests: 2)
    monitor.deliver(.runLoopIdle, pid: first)
    monitor.deliver(.animationsInactive, pid: first)
    XCTAssertEqual(readEvent(fd: client), state(.quiet, pid: first))

    runtime.windowServerOutcome = .resolved(second)
    let before = monitor.requests.count
    monitor.deliver(.applicationStateChanged, pid: second)
    XCTAssertEqual(readEvent(fd: client), .quiescence(.targetChanged(pid: second)))
    _ = try self.monitor(of: runtime, requests: before + 2)
    monitor.deliver(.runLoopIdle, pid: second)
    monitor.deliver(.animationsInactive, pid: second)
    XCTAssertEqual(readEvent(fd: client), state(.quiet, pid: second))
  }

  func testFollowingTheFrontmostApplicationOnANamedDisplayAsksThatDisplay() throws {
    let (first, second) = (getpid(), getppid())
    let runtime = runtimeWithApplications([first, second])
    runtime.windowServerOutcome = .resolved(first)
    let client = try openQuietStream(runtime, ["displayID": 42, "busyThresholdMs": 5000, "quietWindowMs": 0])
    defer { closeQuietStream(client) }

    let monitor = try monitor(of: runtime, requests: 2)
    XCTAssertEqual(runtime.lastFrontmostDisplayIdentifier, NSNumber(value: 42))

    runtime.windowServerOutcome = .resolved(second)
    monitor.deliver(.applicationStateChanged, pid: second)
    XCTAssertEqual(readEvent(fd: client), .quiescence(.targetChanged(pid: second)))
    XCTAssertEqual(runtime.lastFrontmostDisplayIdentifier, NSNumber(value: 42), "retargeting stays on the named display")
  }

  func testAMalformedDisplayIsRefusedWithoutStreaming() throws {
    let client = try openStream(runtimeWithApplications([]), .quiescence(pid: nil, busyThresholdMs: nil, quietWindowMs: nil, displayID: 0))
    defer { closeQuietStream(client) }
    XCTAssertEqual(readEvent(fd: client), .failure(BridgeAXFailure(message: "displayID must be a positive 32-bit integer", kind: .badRequest)))
  }

  func testANamedApplicationThatHasExitedEndsTheStream() throws {
    let pid = Self.exitedPid
    let client = try openQuietStream(runtimeWithApplications([]), ["pid": pid])
    defer { closeQuietStream(client) }
    XCTAssertEqual(readEvent(fd: client), .quiescence(.targetExited(pid: pid)))
    Self.assertEOF(fd: client)
  }

  func testARunningApplicationWithoutAnElementYetIsArmedOnceItHasOne() throws {
    let pid = getpid()
    let runtime = runtimeWithApplications([])
    let client = try openQuietStream(runtime, ["pid": pid, "busyThresholdMs": 5000, "quietWindowMs": 0])
    defer { closeQuietStream(client) }

    _ = try eventually("the monitor") { runtime.quiescenceMonitors.lastObject as? FBAXFakeQuiescenceMonitor }
    runtime.applicationElements[NSNumber(value: pid)] = FBAXFakeElement.readable("UIApplication")
    let monitor = try monitor(of: runtime, requests: 2)
    monitor.deliver(.runLoopIdle, pid: pid)
    monitor.deliver(.animationsInactive, pid: pid)
    XCTAssertEqual(readEvent(fd: client), state(.quiet, pid: pid))
  }

  func testAutomationModeIsTurnedOnAndAFailureToIsAnError() throws {
    let runtime = runtimeWithApplications([getpid()])
    runtime.automationMode = false
    runtime.automationModeWriteFails = true
    let client = try openQuietStream(runtime, ["pid": getpid()])
    defer { closeQuietStream(client) }
    XCTAssertEqual(failure(readEvent(fd: client))?.kind, .readerUnavailable)
    Self.assertEOF(fd: client)
    XCTAssertEqual(runtime.automationModeWrites, [true])
  }

  func testAMonitorThatCannotBindIsAnError() throws {
    let runtime = runtimeWithApplications([getpid()])
    runtime.quiescenceMonitorError = "AXObserverCreate failed (-25200)"
    let client = try openQuietStream(runtime, ["pid": getpid()])
    defer { closeQuietStream(client) }
    XCTAssertEqual(readEvent(fd: client), .failure(BridgeAXFailure(message: "AXObserverCreate failed (-25200)", kind: .readerUnavailable)))
    Self.assertEOF(fd: client)
  }

  func testANegativeTunableIsRefusedWithoutStreaming() throws {
    let client = try openStream(runtimeWithApplications([]), .quiescence(pid: nil, busyThresholdMs: nil, quietWindowMs: -1))
    defer { closeQuietStream(client) }
    XCTAssertEqual(failure(readEvent(fd: client))?.kind, .badRequest)
    Self.sendData(data: try Self.frame(command: .ping), to: client)
    XCTAssertEqual(Self.exitCode(of: Self.readResponse(fd: client)), 0, "a refused stream leaves the connection serving")
  }

  func testTheOneShotCommandStreamsUntilTheStreamEnds() throws {
    useRuntime(runtimeWithApplications([]))
    var lines: [BridgeAXAnswer?] = []
    let status = AccessibilityService.handleAction("quiet", arguments: ["--pid", String(Self.exitedPid)]) { data in
      lines.append(try? JSONDecoder().decode(BridgeAXAnswer.self, from: data))
      return true
    }
    XCTAssertEqual(status, 0)
    XCTAssertEqual(lines, [.quiescence(.targetExited(pid: Self.exitedPid))])

    let lostOutputStatus = AccessibilityService.handleAction("quiet", arguments: ["--pid", String(Self.exitedPid)]) { _ in false }
    XCTAssertEqual(lostOutputStatus, 1, "output that could not be written fails the command")
  }

  func testQuietIsRefusedOutsideAStream() {
    XCTAssertEqual(AccessibilityService.handleRequest(["verb": "quiet"])["error_kind"] as? String, "bad_request")
  }

  private func openSettingsStream(_ runtime: FBAXFakeRuntime, setting: String = "reduce-motion") throws -> Int32 {
    useRuntime(runtime)
    startServerExclusive(exclusive: true)
    let client = connectClient()
    Self.sendData(
      data: try Self.frame(command: .accessibility(.deviceSettingChanges(setting))),
      to: client)
    return client
  }

  func testASettingsObserverIsRegisteredBeforeTheInitialReadAndRereadsAuthoritatively() throws {
    let runtime = FBAXFakeRuntime()
    let setting = NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)
    runtime.deviceSettings[setting] = false
    runtime.deviceSettingReadHandler = {
      runtime.deviceSettingReadHandler = nil
      runtime.deviceSettings[setting] = true
      runtime.deviceSettingMonitor?.deliver()
    }
    let client = try openSettingsStream(runtime)
    defer { closeQuietStream(client) }

    XCTAssertEqual(readEvent(fd: client), .settingSnapshot(BridgeAXSettingSnapshot(setting: "reduce-motion", enabled: false)))
    XCTAssertEqual(readEvent(fd: client), .settingSnapshot(BridgeAXSettingSnapshot(setting: "reduce-motion", enabled: true)))
    XCTAssertEqual(runtime.operations.compactMap { $0 as? String }.filter { $0 == "settingRead" }.count, 2)
  }

  func testSettingsNotificationBurstsCoalesceIntoOneAuthoritativeReread() throws {
    let runtime = FBAXFakeRuntime()
    let setting = NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)
    runtime.deviceSettings[setting] = false
    let client = try openSettingsStream(runtime)
    defer { closeQuietStream(client) }
    XCTAssertEqual(snapshot(readEvent(fd: client))?.enabled, false)

    runtime.deviceSettings[setting] = true
    for _ in 0..<3 {
      runtime.deviceSettingMonitor?.deliver()
    }
    XCTAssertEqual(snapshot(readEvent(fd: client))?.enabled, true)
    XCTAssertEqual(runtime.operations.compactMap { $0 as? String }.filter { $0 == "settingRead" }.count, 2)
  }

  func testAnUnavailableSettingIsTypedAndEndsTheStream() throws {
    let client = try openSettingsStream(FBAXFakeRuntime())
    defer { closeQuietStream(client) }
    XCTAssertEqual(
      readEvent(fd: client),
      .failure(BridgeAXFailure(message: "setting unavailable", kind: .capabilityUnavailable)))
    Self.assertEOF(fd: client)
  }

  func testOnlyReduceMotionPublishesChanges() throws {
    let client = try openSettingsStream(FBAXFakeRuntime(), setting: "reduce-transparency")
    defer { closeQuietStream(client) }
    XCTAssertEqual(failure(readEvent(fd: client))?.kind, .capabilityUnavailable)
    Self.sendData(data: try Self.frame(command: .ping), to: client)
    XCTAssertEqual(Self.exitCode(of: Self.readResponse(fd: client)), 0, "a refused stream leaves the connection serving")
  }

  func testUnavailableNativeSettingObservationIsTyped() throws {
    let runtime = FBAXFakeRuntime()
    runtime.deviceSettingMonitorOutcome = .unavailable("notification unavailable")
    let client = try openSettingsStream(runtime)
    defer { closeQuietStream(client) }
    XCTAssertEqual(readEvent(fd: client), .failure(BridgeAXFailure(message: "notification unavailable", kind: .capabilityUnavailable)))
    Self.assertEOF(fd: client)
    XCTAssertFalse(runtime.operations.contains { ($0 as? String) == "settingRead" })
  }

  func testSettingObservationIsInvalidatedAfterOutputFailure() {
    let runtime = FBAXFakeRuntime()
    runtime.deviceSettings[NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)] = false
    useRuntime(runtime)
    let status = AccessibilityService.handleAction("settings-observe", arguments: ["--setting", "reduce-motion"]) { _ in false }
    XCTAssertEqual(status, 1)
    XCTAssertEqual(runtime.deviceSettingMonitor?.isInvalidated, true)
  }

  func testCombinedSettingsPublishCompleteValuesAndObserveOtherDomains() throws {
    let runtime = FBAXFakeRuntime()
    for setting in [FBAXDeviceSetting.reduceMotion, .reduceTransparency, .buttonShapes, .increaseContrast] {
      runtime.deviceSettings[NSNumber(value: setting.rawValue)] = false
    }
    let client = try openSettingsStream(runtime, setting: "state-settings")
    defer { closeQuietStream(client) }
    let initial = try XCTUnwrap(snapshot(readEvent(fd: client)))
    XCTAssertEqual(
      Set(runtime.deviceSettingMonitoredSettings ?? []),
      Set(
        [
          FBAXDeviceSetting.reduceMotion, .reduceTransparency, .buttonShapes, .increaseContrast,
        ].map { NSNumber(value: $0.rawValue) }))
    XCTAssertEqual(initial.enabled, false)
    let initialSettings = initial.otherSettings
    XCTAssertEqual(Set(initialSettings.keys), ["button-shapes", "reduce-transparency", "increase-contrast"])
    XCTAssertTrue(initialSettings.values.allSatisfy { $0 == .success(BridgeAXSettingResponse(enabled: false)) })
    runtime.deviceSettings[NSNumber(value: FBAXDeviceSetting.buttonShapes.rawValue)] = true
    (runtime.deviceSettingMonitors[NSNumber(value: FBAXDeviceSetting.buttonShapes.rawValue)] as? FBAXFakeDeviceSettingMonitor)?.deliver()
    let changed = try XCTUnwrap(snapshot(readEvent(fd: client))?.otherSettings)
    XCTAssertEqual(changed["button-shapes"]?.enabled, true)
    XCTAssertEqual(changed["reduce-transparency"]?.enabled, false)
  }

  func testCombinedSettingsPreservePerSettingReadFailure() throws {
    let runtime = FBAXFakeRuntime()
    runtime.deviceSettings[NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)] = false
    let client = try openSettingsStream(runtime, setting: "state-settings")
    defer { closeQuietStream(client) }
    let settings = try XCTUnwrap(snapshot(readEvent(fd: client))?.otherSettings)
    XCTAssertEqual(settings["button-shapes"]?.failure?.kind, .capabilityUnavailable)
    runtime.deviceSettings[NSNumber(value: FBAXDeviceSetting.buttonShapes.rawValue)] = true
    runtime.deviceSettingMonitor?.deliver()
    let recovered = try XCTUnwrap(snapshot(readEvent(fd: client))?.otherSettings)
    XCTAssertEqual(recovered["button-shapes"]?.enabled, true)
  }

  func testCombinedSettingsPreservePartialObservationFailures() throws {
    for (outcome, kind) in [
      (FBAXDeviceSettingMonitorOutcome.unavailable("notification missing"), BridgeAXWire.ErrorKind.capabilityUnavailable),
      (FBAXDeviceSettingMonitorOutcome.failed("registration failed"), .readerUnavailable),
    ] {
      let runtime = FBAXFakeRuntime()
      let motion = NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)
      let shapes = NSNumber(value: FBAXDeviceSetting.buttonShapes.rawValue)
      let contrast = NSNumber(value: FBAXDeviceSetting.increaseContrast.rawValue)
      for setting in [FBAXDeviceSetting.reduceMotion, .reduceTransparency, .buttonShapes, .increaseContrast] {
        runtime.deviceSettings[NSNumber(value: setting.rawValue)] = false
      }
      runtime.deviceSettingMonitorOutcomes[contrast] = outcome
      var initialReads = 0
      runtime.deviceSettingReadHandler = {
        initialReads += 1
        guard initialReads == 3 else { return }
        runtime.deviceSettingReadHandler = nil
        // Deliver the burst on the stream's thread after all initial values were captured.
        runtime.deviceSettings[motion] = true
        runtime.deviceSettings[shapes] = true
        (runtime.deviceSettingMonitors[motion] as? FBAXFakeDeviceSettingMonitor)?.deliver()
        (runtime.deviceSettingMonitors[shapes] as? FBAXFakeDeviceSettingMonitor)?.deliver()
        (runtime.deviceSettingMonitors[shapes] as? FBAXFakeDeviceSettingMonitor)?.deliver()
      }
      let client = try openSettingsStream(runtime, setting: "state-settings")
      defer {
        closeQuietStream(client)
        XCTAssertTrue(runtime.deviceSettingMonitors.allValues.compactMap { $0 as? FBAXFakeDeviceSettingMonitor }.allSatisfy { $0.isInvalidated })
      }
      let initial = try XCTUnwrap(snapshot(readEvent(fd: client)))
      XCTAssertEqual(initial.enabled, false)
      let settings = initial.otherSettings
      XCTAssertEqual(Set(settings.keys), ["reduce-transparency", "button-shapes", "increase-contrast"])
      XCTAssertEqual(settings["increase-contrast"]?.failure?.kind, kind)
      XCTAssertEqual(settings["increase-contrast"]?.failure?.message, outcome.failureReason)
      XCTAssertNil(settings["increase-contrast"]?.enabled)
      XCTAssertEqual(settings["button-shapes"]?.enabled, false)
      XCTAssertEqual(settings["reduce-transparency"]?.enabled, false)
      XCTAssertEqual(runtime.deviceSettingMonitors.count, 3)

      let changed = try XCTUnwrap(snapshot(readEvent(fd: client)))
      XCTAssertEqual(changed.enabled, true)
      let changedSettings = changed.otherSettings
      XCTAssertEqual(changedSettings["button-shapes"]?.enabled, true)
      XCTAssertEqual(changedSettings["increase-contrast"]?.failure?.kind, kind)
      XCTAssertNil(changedSettings["increase-contrast"]?.enabled)
      let operations = runtime.operations.compactMap { $0 as? String }.filter { $0 == "settingMonitor" || $0 == "settingRead" }
      XCTAssertEqual(Array(operations.prefix(4)), Array(repeating: "settingMonitor", count: 4))
      XCTAssertEqual(operations.filter { $0 == "settingRead" }.count, 6)
    }
  }

  func testCombinedSettingsRequireReduceMotionObservation() throws {
    for (outcome, kind) in [
      (FBAXDeviceSettingMonitorOutcome.unavailable("notification missing"), BridgeAXWire.ErrorKind.capabilityUnavailable),
      (FBAXDeviceSettingMonitorOutcome.failed("registration failed"), .readerUnavailable),
    ] {
      let runtime = FBAXFakeRuntime()
      let motion = NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)
      runtime.deviceSettingMonitorOutcomes[motion] = outcome
      let client = try openSettingsStream(runtime, setting: "state-settings")
      defer { closeQuietStream(client) }
      XCTAssertEqual(failure(readEvent(fd: client))?.kind, kind)
      Self.assertEOF(fd: client)
      XCTAssertEqual(runtime.deviceSettingMonitoredSettings, [motion])
      XCTAssertEqual(runtime.deviceSettingMonitors.count, 0)
      XCTAssertFalse(runtime.operations.contains { ($0 as? String) == "settingRead" })
    }
  }

  func testCombinedSettingsInvalidateAllMonitorsOnSourceOrOutputFailure() {
    for sourceFailure in [false, true] {
      let runtime = FBAXFakeRuntime()
      for setting in [FBAXDeviceSetting.reduceMotion, .reduceTransparency, .buttonShapes, .increaseContrast] {
        runtime.deviceSettings[NSNumber(value: setting.rawValue)] = false
      }
      if sourceFailure { runtime.deviceSettingReadOutcome = .failed("read failed") }
      useRuntime(runtime)
      let status = AccessibilityService.handleAction("settings-observe", arguments: ["--setting", "state-settings"]) { _ in sourceFailure }
      XCTAssertEqual(status, 1)
      XCTAssertEqual(runtime.deviceSettingMonitors.count, 4)
      XCTAssertTrue(runtime.deviceSettingMonitors.allValues.compactMap { $0 as? FBAXFakeDeviceSettingMonitor }.allSatisfy { $0.isInvalidated })
    }
  }

  func testSettingsObserveIsRefusedOutsideAStream() {
    XCTAssertEqual(
      AccessibilityService.handleRequest(["verb": "settings-observe", "setting": "reduce-motion"])["error_kind"] as? String,
      "bad_request")
  }

  func testSettingsCLIReportsSourceFailureEvenWhenOutputSucceeds() throws {
    for (outcome, kind) in [
      (FBAXDeviceSettingOutcome.unavailable("setting unavailable"), "capability_unavailable"),
      (FBAXDeviceSettingOutcome.failed("read failed"), "reader_unavailable"),
    ] {
      let runtime = FBAXFakeRuntime()
      runtime.deviceSettingReadOutcome = outcome
      useRuntime(runtime)
      var lines: [[String: Any]] = []
      let status = AccessibilityService.handleAction("settings-observe", arguments: ["--setting", "reduce-motion"]) { data in
        if let answer = try? JSONDecoder().decode(BridgeAXAnswer.self, from: data) { lines.append(answerFields(answer)) }
        return true
      }
      XCTAssertEqual(status, 1, "the stream's failed state must reach the CLI exit status")
      XCTAssertEqual(lines.count, 1)
      XCTAssertEqual(lines.first?["error_kind"] as? String, kind)
    }
  }

  func testSettingsCLIOutputFailureStopsTheStream() {
    let runtime = FBAXFakeRuntime()
    runtime.deviceSettings[NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)] = false
    useRuntime(runtime)
    let status = AccessibilityService.handleAction("settings-observe", arguments: ["--setting", "reduce-motion"]) { _ in false }
    XCTAssertEqual(status, 1)
  }

  func testTheTunablesParseFromArgv() {
    let request = AXBridgeArguments.request(action: "quiet", arguments: ["--busy-threshold-ms", "5", "--quiet-window-ms", "7", "--pid", "9"])
    XCTAssertEqual(request as NSDictionary, ["verb": "quiet", "busyThresholdMs": 5, "quietWindowMs": 7, "pid": 9])
  }
}

extension BridgeAXOutcome<BridgeAXSettingResponse> {
  /// The setting's state, when it was read.
  fileprivate var enabled: Bool? {
    guard case let .success(response) = self else { return nil }
    return response.enabled
  }

  fileprivate var failure: BridgeAXFailure? {
    guard case let .failure(failure) = self else { return nil }
    return failure
  }
}
