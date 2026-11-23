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
import SimulatorIPC
import UIKit
import XCTest

private let kAppPid: pid_t = 4321

/// The accessibility answer a guest frame carries, decoded from the frame's bytes as the host decodes it: against the
/// request it answers, as the outcome its verb answers with.
private enum GuestFrame<Success: Codable & Equatable & Sendable> {
  static func answer(
    in frame: Data, for request: BridgeRequest, file: StaticString = #filePath, line: UInt = #line
  ) throws -> BridgeAXOutcome<Success> {
    let result = try BridgeResponse.decode(frame, for: request).result
    XCTAssertEqual(result.answers.count, 1, "an accessibility request has one answer", file: file, line: line)
    let answer = try XCTUnwrap(result.accessibility, "the frame carries no accessibility answer", file: file, line: line)
    return try outcome(of: answer)
  }

  static func outcome(of answer: BridgeAXAnswer) throws -> BridgeAXOutcome<Success> {
    let success: Any
    switch answer {
    case let .failure(failure): return .failure(failure)
    case let .tree(answer): success = answer
    case let .hitTest(answer): success = answer
    case let .write(answer): success = answer
    case let .setting(answer): success = answer
    case let .displays(answer): success = answer
    case let .settingSnapshot(answer): success = answer
    case let .quiescence(answer): success = answer
    }
    guard let success = success as? Success else {
      throw UnexpectedOutcome(description: "expected \(Success.self), got \(answer)")
    }
    return .success(success)
  }
}

private struct UnexpectedOutcome: Error, CustomStringConvertible {
  let description: String
}

private func success<Success>(_ outcome: BridgeAXOutcome<Success>) throws -> Success {
  guard case let .success(success) = outcome else { throw UnexpectedOutcome(description: "expected an answer, got \(outcome)") }
  return success
}

private func failure<Success>(_ outcome: BridgeAXOutcome<Success>) throws -> BridgeAXFailure {
  guard case let .failure(failure) = outcome else { throw UnexpectedOutcome(description: "expected a failure, got \(outcome)") }
  return failure
}

/**
 * The guest's side of the accessibility wire contract. Each request goes through the guest's real dispatch against a
 * fake `FBAXRuntime`, and the frame it would send is decoded with the shared `BridgeAXOutcome` types, so a frame the
 * host's types cannot read fails here rather than on a simulator.
 */
final class AccessibilityWireContractTests: XCTestCase {
  private var runtime: FBAXFakeRuntime!

  override func setUp() {
    super.setUp()
    runtime = FBAXFakeRuntime()
    FBAXClientProvider.setRuntimeForTesting(runtime)
  }

  override func tearDown() {
    // The substitution is process-wide, so leaving it set would leak into every other test in the bundle.
    FBAXClientProvider.setRuntimeForTesting(nil)
    runtime = nil
    super.tearDown()
  }

  private let frameID = "contract"

  /// The frame the guest sends for `request`.
  private func frame(_ request: BridgeAXRequest) throws -> Data {
    let sent = BridgeRequest(command: request.command, id: frameID)
    return try BridgeResponse(request: sent, result: BridgeServices.execute(request.command)).encoded()
  }

  private func answer<Success>(
    _ request: BridgeAXRequest, as _: Success.Type, file: StaticString = #filePath, line: UInt = #line
  ) throws -> BridgeAXOutcome<Success> {
    try GuestFrame<Success>.answer(in: frame(request), for: BridgeRequest(command: request.command, id: frameID), file: file, line: line)
  }

  private func options(
    traversal: BridgeAXTraversal = .viewHierarchy, maxNodes: Int = BridgeAXReadOptions.defaultMaxNodes, attributes: [String]? = nil,
    explainUnreachable: Bool = false
  ) -> BridgeAXReadOptions {
    BridgeAXReadOptions(
      maxDepth: BridgeAXReadOptions.defaultMaxDepth, maxNodes: maxNodes, attributes: attributes, explainUnreachable: explainUnreachable,
      traversal: traversal, automationMode: nil, clientType: .noClient)
  }

  private func press(assertion: BridgeAXWriteAssertion? = nil) -> BridgeAXRequest {
    .write(BridgeAXWriteRequest(kind: .perform(.press), x: 200, y: 711, pid: nil, assertion: assertion))
  }

  private func seedHitElement(_ attributes: [String: Any]) {
    let element = FBAXFakeElement()
    element.attributes = attributes
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(element, owningProcessIdentifier: kAppPid)
  }

  // MARK: - Reads

  func testAReadByPidDecodesAsATypedTree() throws {
    let root = FBAXFakeElement.readable("UIApplication")
    let button = FBAXFakeElement()
    button.attributes = [
      BridgeAXWire.Node.elementType.rawValue: "UIButton",
      BridgeAXWire.Node.label.rawValue: "Wi-Fi",
      BridgeAXWire.Node.value.rawValue: "On",
      BridgeAXWire.Node.identifier.rawValue: "wifi",
      BridgeAXWire.Node.frame.rawValue: NSValue(cgRect: CGRect(x: 16, y: 293, width: 370, height: 52)),
      BridgeAXWire.Node.automationType.rawValue: NSNumber(value: 9),
    ]
    root.children = [button]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let read = try success(answer(.read(pid: kAppPid, options: options()), as: BridgeAXTreeResponse.self))

    XCTAssertEqual(read.pid, kAppPid)
    XCTAssertFalse(read.truncated)
    XCTAssertNil(read.method, "a read by pid resolved nothing")
    XCTAssertNotNil(read.automation)
    XCTAssertNotNil(read.phases?.traverseMilliseconds)
    XCTAssertNotNil(read.phases?.machRoundTrips)
    XCTAssertEqual(read.tree.elementType, .string("UIApplication"))
    let child = try XCTUnwrap(read.tree.children?.first)
    XCTAssertEqual(child.elementType, .string("UIButton"))
    XCTAssertEqual(child.label, .string("Wi-Fi"))
    XCTAssertEqual(child.value, .string("On"))
    XCTAssertEqual(child.identifier, .string("wifi"))
    XCTAssertEqual(child.frame, BridgeAXRect(x: 16, y: 293, width: 370, height: 52))
    XCTAssertEqual(child.automationType, .integer(9))
    XCTAssertEqual(child.children, [], "a leaf the guest read carries an empty list")
  }

  func testAFrontmostReadNamesHowItResolvedTheApplication() throws {
    runtime.windowServerOutcome = FBAXFrontmostOutcome.resolved(kAppPid)
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")

    let read = try success(
      answer(.readFrontmost(x: 201, y: 437, method: .windowServer, options: options()), as: BridgeAXTreeResponse.self))

    XCTAssertEqual(read.pid, kAppPid)
    XCTAssertEqual(read.method, .windowServer)
  }

  func testAFrontmostReadReportsTheModalItFound() throws {
    runtime.windowServerOutcome = FBAXFrontmostOutcome.resolved(kAppPid)
    let root = FBAXFakeElement.readable("UIApplication")
    root.children = [FBAXFakeElement.readable("SBAlertItemWindow")]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let read = try success(
      answer(.readFrontmost(x: 201, y: 437, method: .windowServer, options: options()), as: BridgeAXTreeResponse.self))

    XCTAssertEqual(read.modal?.kind, .system)
    XCTAssertEqual(read.modal?.elementType, "SBAlertItemWindow")
  }

  func testAReadThatRanOutOfNodesSaysSo() throws {
    let root = FBAXFakeElement.readable("UIApplication")
    root.children = [FBAXFakeElement.readable("UIWindow"), FBAXFakeElement.readable("UIWindow")]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    // Two nodes of budget for a three-node tree.
    let read = try success(
      answer(.read(pid: kAppPid, options: options(traversal: .singleFetch, maxNodes: 2)), as: BridgeAXTreeResponse.self))

    XCTAssertTrue(read.truncated)
    XCTAssertEqual(read.tree.children?.count, 1)
  }

  func testATranslatorReadCarriesTheTranslatorsOwnAnswers() throws {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.translatorAttributeValues = [
      NSNumber(value: BridgeAXTranslatorAttribute.label.rawValue): "General",
      NSNumber(value: BridgeAXTranslatorAttribute.isEnabled.rawValue): NSNumber(value: false),
      NSNumber(value: BridgeAXTranslatorAttribute.role.rawValue): NSNumber(value: 9),
      NSNumber(value: BridgeAXTranslatorAttribute.subrole.rawValue): NSNumber(value: 12),
      NSNumber(value: BridgeAXTranslatorAttribute.traits.rawValue): NSNumber(value: 1),
      NSNumber(value: BridgeAXTranslatorAttribute.memoryAddress.rawValue): NSNumber(value: UInt64(105_553_116_266_496)),
    ]

    let read = try success(answer(.read(pid: kAppPid, options: options(traversal: .semantic)), as: BridgeAXTreeResponse.self))

    XCTAssertEqual(read.tree.label, .string("General"))
    XCTAssertEqual(read.tree.isEnabled, false)
    XCTAssertEqual(read.tree.translatorRole, 9)
    XCTAssertEqual(read.tree.translatorSubrole, 12)
    XCTAssertEqual(read.tree.traits, 1)
    XCTAssertEqual(read.tree.elementIdentity, 105_553_116_266_496)
    XCTAssertNil(read.tree.elementType, "the translator's role is not an element type")
  }

  func testAnUnreachableElementCarriesWhatAnsweredInItsPlace() throws {
    let root = FBAXFakeElement.readable("UIApplication")
    root.attributes = [
      BridgeAXWire.Node.isVisible.rawValue: NSNumber(value: false),
      BridgeAXWire.Node.centerPoint.rawValue: ["X": 12, "Y": 34],
    ]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("Overlay"), owningProcessIdentifier: 9000)

    let read = try success(
      answer(.read(pid: kAppPid, options: options(explainUnreachable: true)), as: BridgeAXTreeResponse.self))

    XCTAssertEqual(read.tree.isVisible, false)
    XCTAssertEqual(read.tree.centerPoint, BridgeAXPoint(x: 12, y: 34))
    XCTAssertEqual(read.tree.explainedBy?.elementType, .string("Overlay"))
  }

  // MARK: - Hit-tests and writes

  func testAHitTestAnswersWithTheElementAndItsOwner() throws {
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("XCUIElementTypeButton"), owningProcessIdentifier: kAppPid)

    let hit = try success(
      answer(.hitTest(x: 10, y: 20, attributes: nil, clientType: .noClient, pid: kAppPid), as: BridgeAXHitTestResponse.self))

    guard case let .element(node, pid) = hit else { return XCTFail("expected an element, got \(hit)") }
    XCTAssertEqual(pid, kAppPid)
    XCTAssertEqual(node.elementType, .string("XCUIElementTypeButton"))
  }

  func testAHitTestOnEmptySpaceAnswersWithNothing() throws {
    runtime.hitTestOutcome = FBAXHitTestOutcome.empty()

    let hit = try success(
      answer(.hitTest(x: 10, y: 20, attributes: nil, clientType: .noClient, pid: kAppPid), as: BridgeAXHitTestResponse.self))

    XCTAssertEqual(hit, .empty)
  }

  func testAWriteAnswersWithTheApplicationItWroteTo() throws {
    for request in [press(), .write(BridgeAXWriteRequest(kind: .setValue("hello"), x: 1, y: 2, pid: nil, assertion: nil))] {
      seedHitElement([BridgeAXWire.Node.value.rawValue: "hello"])
      XCTAssertEqual(try success(answer(request, as: BridgeAXWriteResponse.self)), .written(pid: kAppPid), "\(request.verb)")
    }
  }

  func testAWriteOnEmptySpaceAnswersWithNothing() throws {
    runtime.hitTestOutcome = FBAXHitTestOutcome.empty()

    XCTAssertEqual(try success(answer(press(), as: BridgeAXWriteResponse.self)), .empty)
  }

  // MARK: - The typed answer

  // The guest builds each verb's answer as the shared type the host decodes it as; the frame is that value encoded.
  func testEachVerbIsAnsweredWithItsOwnTypedOutcome() throws {
    let root = FBAXFakeElement.readable("UIApplication")
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    guard case let .tree(read) = AccessibilityService.handleRequest(.read(pid: kAppPid, options: options())) else {
      return XCTFail("a read is answered with a tree")
    }
    XCTAssertEqual(read.tree.elementType, .string("UIApplication"))
    XCTAssertEqual(read.pid, kAppPid)

    runtime.hitTestOutcome = FBAXHitTestOutcome.empty()
    XCTAssertEqual(
      AccessibilityService.handleRequest(.hitTest(x: 1, y: 2, attributes: nil, clientType: .noClient, pid: kAppPid)), .hitTest(.empty))
    XCTAssertEqual(AccessibilityService.handleRequest(press()), .write(.empty))

    runtime.deviceSettings[NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)] = NSNumber(value: true)
    XCTAssertEqual(
      AccessibilityService.handleRequest(.deviceSettingRead("reduce-motion")), .setting(BridgeAXSettingResponse(enabled: true)))

    runtime.displayInventoryOutcome = .available([FBAXDisplayIdentity(uniqueID: "main", displayID: 1)])
    XCTAssertEqual(
      AccessibilityService.handleRequest(.displays),
      .displays(
        BridgeAXDisplayInventory(
          displayScopedInteractions: true, displayScopedTrees: true, displayScopedQuiescence: true,
          displays: [.init(uniqueID: "main", displayID: 1)])))

    XCTAssertEqual(
      AccessibilityService.handleRequest(parameters: Data(#"{"verb":"hittest","clientType":0,"x":"left","y":2}"#.utf8)),
      .failure(BridgeAXFailure(message: "hittest requires numeric x and y", kind: .badRequest)))
  }

  // MARK: - Settings and displays

  func testADeviceSettingAnswersWithItsState() throws {
    let reduceMotion = NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)
    runtime.deviceSettings[reduceMotion] = NSNumber(value: false)
    XCTAssertEqual(
      try success(answer(.deviceSettingRead("reduce-motion"), as: BridgeAXSettingResponse.self)), BridgeAXSettingResponse(enabled: false))
    XCTAssertEqual(
      try success(answer(.deviceSettingWrite("reduce-motion", enabled: true), as: BridgeAXSettingResponse.self)),
      BridgeAXSettingResponse(enabled: true))
  }

  func testTheDisplayInventoryDecodes() throws {
    runtime.displayInventoryOutcome = .available([
      FBAXDisplayIdentity(uniqueID: "outer", displayID: 42),
      FBAXDisplayIdentity(uniqueID: "continuous-inner", displayID: 71),
    ])

    XCTAssertEqual(
      try success(answer(.displays, as: BridgeAXDisplayInventory.self)),
      BridgeAXDisplayInventory(
        displayScopedInteractions: true, displayScopedTrees: true, displayScopedQuiescence: true,
        displays: [.init(uniqueID: "outer", displayID: 42), .init(uniqueID: "continuous-inner", displayID: 71)]))
  }

  // MARK: - Failures

  func testAnUnavailableApplicationNamesItsPid() throws {
    runtime.hitTestOutcome = FBAXHitTestOutcome.applicationUnavailable()

    XCTAssertEqual(
      try failure(answer(.hitTest(x: 1, y: 2, attributes: nil, clientType: .noClient, pid: kAppPid), as: BridgeAXHitTestResponse.self)),
      BridgeAXFailure(message: "pid 4321 has no accessibility server to hit-test", kind: .applicationUnavailable, pid: kAppPid))
  }

  func testAnApplicationThatDidNotAnswerSaysHowLongItWaited() throws {
    runtime.hitTestOutcome = FBAXHitTestOutcome.applicationNotResponding()

    XCTAssertEqual(
      try failure(answer(.hitTest(x: 1, y: 2, attributes: nil, clientType: .noClient, pid: kAppPid), as: BridgeAXHitTestResponse.self)),
      BridgeAXFailure(
        message: "pid 4321 did not respond to the hit-test before it timed out", kind: .applicationNotResponding, pid: kAppPid, timeoutSeconds: 5))
  }

  func testAReadRefusedBehindAnUnansweredOneIsOutstanding() throws {
    let root = FBAXFakeElement.readable("UIApplication")
    root.readStatus = .applicationNotResponding
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    runtime.snapshotError = NSError(
      domain: "XCTAutomationErrorDomain", code: 1,
      userInfo: [FBAXAccessibilityErrorKey: NSNumber(value: FBAXError.ipcTimeout.rawValue), NSLocalizedDescriptionKey: "runtime said no"])
    let request = BridgeAXRequest.read(pid: kAppPid, options: options(traversal: .singleFetch))

    XCTAssertNil(try failure(answer(request, as: BridgeAXTreeResponse.self)).outstanding)
    let refused = try failure(answer(request, as: BridgeAXTreeResponse.self))

    XCTAssertEqual(refused.kind, .applicationNotResponding)
    XCTAssertEqual(refused.pid, kAppPid)
    XCTAssertEqual(refused.outstanding, true)
    XCTAssertNotNil(refused.timeoutSeconds)
  }

  func testARuntimeFailureCarriesTheAXErrorAndWhatTheWriteMayHaveDone() throws {
    seedHitElement([:])
    runtime.writeOutcome = FBAXWriteOutcome.failed(withAXError: -25205)

    XCTAssertEqual(
      try failure(answer(press(), as: BridgeAXWriteResponse.self)),
      BridgeAXFailure(
        message: "the accessibility runtime rejected the write with AX error -25205 (kAXErrorAttributeUnsupported)", kind: .runtimeFailed,
        pid: kAppPid, axError: -25205, effect: .unknown))
  }

  func testARefusedAssertionSentNothing() throws {
    seedHitElement([BridgeAXWire.Node.label.rawValue: "Wi-Fi"])

    XCTAssertEqual(
      try failure(answer(press(assertion: BridgeAXWriteAssertion(key: .label, value: "General")), as: BridgeAXWriteResponse.self)),
      BridgeAXFailure(
        message: "the element at (200.0, 711.0) has XC_kAXXCAttributeLabel Wi-Fi, expected General", kind: .assertionFailed,
        effect: BridgeAXWire.Effect.none))
  }

  func testAnUnresolvedFrontmostApplicationIsItsOwnKind() throws {
    runtime.windowServerOutcome = FBAXFrontmostOutcome.unresolved("the window server did not answer")

    let unresolved = try failure(
      answer(.readFrontmost(x: 201, y: 437, method: .windowServer, options: options()), as: BridgeAXTreeResponse.self))

    XCTAssertEqual(unresolved.kind, .frontmostUnresolved)
    XCTAssertEqual(unresolved.message?.contains("the window server did not answer"), true, "\(String(describing: unresolved.message))")
  }

  func testUnavailableAndFailedSettingsAreDistinctKinds() throws {
    XCTAssertEqual(try failure(answer(.deviceSettingRead("voiceover"), as: BridgeAXSettingResponse.self)).kind, .capabilityUnavailable)

    runtime.deviceSettings[NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)] = NSNumber(value: false)
    runtime.deviceSettingReadOutcome = FBAXDeviceSettingOutcome.failed("read failed")
    XCTAssertEqual(
      try failure(answer(.deviceSettingRead("reduce-motion"), as: BridgeAXSettingResponse.self)),
      BridgeAXFailure(message: "read failed", kind: .readerUnavailable))
  }

  func testAFrameThatIsNotARequestIsABadRequest() throws {
    let result = BridgeServices.undecodedAccessibility(.missingPoint(.hitTest))
    let request = BridgeRequest(command: .accessibility(.hitTest(x: 0, y: 0, attributes: nil, clientType: .noClient)), id: "undecoded")
    let frame = try BridgeResponse(request: request, result: result).encoded()

    XCTAssertEqual(
      try failure(GuestFrame<BridgeAXHitTestResponse>.answer(in: frame, for: request)),
      BridgeAXFailure(message: "hittest requires numeric x and y", kind: .badRequest))
  }

  func testARaiseWhileAnsweringIsAFailureOfNoKind() throws {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.readRaiseReason = "the runtime went away mid-read"

    let raised = try failure(answer(.read(pid: kAppPid, options: options()), as: BridgeAXTreeResponse.self))

    XCTAssertNil(raised.kind)
    XCTAssertEqual(raised.message?.contains("the runtime went away mid-read"), true, "\(String(describing: raised.message))")
  }
}

// MARK: - Streams

// The frames of the two streams, read off a real serve socket as the host reads them.
extension BridgeServerSocketTests {
  private func useContractRuntime(_ runtime: FBAXFakeRuntime) {
    FBAXClientProvider.setRuntimeForTesting(runtime)
    addTeardownBlock { FBAXClientProvider.setRuntimeForTesting(nil) }
  }

  private func openStream(_ runtime: FBAXFakeRuntime, _ request: BridgeAXRequest) throws -> (client: Int32, request: BridgeRequest) {
    useContractRuntime(runtime)
    startServerExclusive(exclusive: true)
    let client = connectClient()
    let sent = BridgeRequest(command: request.command)
    Self.sendData(data: try sent.encoded().framed(), to: client)
    return (client, sent)
  }

  private func closeStream(_ client: Int32) {
    close(client)
    finishServer()
  }

  /// The next frame's bytes, exactly as the guest wrote them.
  private func readFrameBytes(fd: Int32) throws -> Data {
    let header = try XCTUnwrap(Self.readBytes(length: 4, from: fd))
    let length = (UInt32(header[0]) << 24) | (UInt32(header[1]) << 16) | (UInt32(header[2]) << 8) | UInt32(header[3])
    return try XCTUnwrap(Self.readBytes(length: Int(length), from: fd))
  }

  private func nextEvent<Success>(_: Success.Type, on stream: (client: Int32, request: BridgeRequest)) throws -> BridgeAXOutcome<Success> {
    try GuestFrame<Success>.answer(in: readFrameBytes(fd: stream.client), for: stream.request)
  }

  private func quiescenceMonitor(of runtime: FBAXFakeRuntime, requests: Int) throws -> FBAXFakeQuiescenceMonitor {
    let deadline = Date(timeIntervalSinceNow: 5)
    while deadline.timeIntervalSinceNow > 0 {
      if let monitor = runtime.quiescenceMonitors.lastObject as? FBAXFakeQuiescenceMonitor, monitor.requests.count >= requests {
        return monitor
      }
      usleep(1000)
    }
    throw UnexpectedOutcome(description: "timed out waiting for \(requests) quiescence requests")
  }

  private func runtimeServing(_ pids: [pid_t]) -> FBAXFakeRuntime {
    let runtime = FBAXFakeRuntime()
    runtime.automationMode = true
    for pid in pids {
      runtime.applicationElements[NSNumber(value: pid)] = FBAXFakeElement.readable("UIApplication")
    }
    return runtime
  }

  func testAQuietApplicationAndItsFinishedTouchesDecode() throws {
    let pid = getpid()
    let runtime = runtimeServing([pid])
    let stream = try openStream(runtime, .quiescence(pid: pid, busyThresholdMs: 5000, quietWindowMs: 0))
    defer { closeStream(stream.client) }

    let monitor = try quiescenceMonitor(of: runtime, requests: 2)
    monitor.deliver(.runLoopIdle, pid: pid)
    monitor.deliver(.animationsInactive, pid: pid)
    XCTAssertEqual(try success(nextEvent(BridgeAXQuiescenceEvent.self, on: stream)), .state(.quiet, busySignals: [], pid: pid))
    _ = try quiescenceMonitor(of: runtime, requests: 4)
    monitor.deliver(.touchesCompleted, pid: pid)
    XCTAssertEqual(try success(nextEvent(BridgeAXQuiescenceEvent.self, on: stream)), .touchesCompleted(pid: pid))
  }

  // Long enough a threshold that the first signal is always answered within it, however loaded the machine.
  func testABusyApplicationNamesTheSignalsHoldingItBusy() throws {
    let pid = getpid()
    let runtime = runtimeServing([pid])
    let stream = try openStream(runtime, .quiescence(pid: pid, busyThresholdMs: 500, quietWindowMs: 0))
    defer { closeStream(stream.client) }

    let monitor = try quiescenceMonitor(of: runtime, requests: 2)
    monitor.deliver(.runLoopIdle, pid: pid)
    XCTAssertEqual(
      try success(nextEvent(BridgeAXQuiescenceEvent.self, on: stream)), .state(.busy, busySignals: [.animationsInactive], pid: pid))
  }

  func testAQuiescenceStreamFollowingTheFrontmostApplicationSaysWhenItMoves() throws {
    let (first, second) = (getpid(), getppid())
    let runtime = runtimeServing([first, second])
    runtime.windowServerOutcome = .resolved(first)
    let stream = try openStream(runtime, .quiescence(pid: nil, busyThresholdMs: 5000, quietWindowMs: 0))
    defer { closeStream(stream.client) }

    let monitor = try quiescenceMonitor(of: runtime, requests: 2)
    runtime.windowServerOutcome = .resolved(second)
    monitor.deliver(.applicationStateChanged, pid: second)

    XCTAssertEqual(try success(nextEvent(BridgeAXQuiescenceEvent.self, on: stream)), .targetChanged(pid: second))
  }

  func testAQuiescenceStreamForAnExitedApplicationSaysSo() throws {
    // Above the kernel's highest pid, so certain not to be running.
    let exited: pid_t = 99999
    let stream = try openStream(runtimeServing([]), .quiescence(pid: exited, busyThresholdMs: nil, quietWindowMs: nil))
    defer { closeStream(stream.client) }

    XCTAssertEqual(try success(nextEvent(BridgeAXQuiescenceEvent.self, on: stream)), .targetExited(pid: exited))
  }

  func testASettingsSnapshotCarriesTheOtherSettingsAsTheirOwnOutcomes() throws {
    let runtime = FBAXFakeRuntime()
    for setting in [FBAXDeviceSetting.reduceMotion, .reduceTransparency, .buttonShapes, .increaseContrast] {
      runtime.deviceSettings[NSNumber(value: setting.rawValue)] = false
    }
    runtime.deviceSettingMonitorOutcomes[NSNumber(value: FBAXDeviceSetting.increaseContrast.rawValue)] = FBAXDeviceSettingMonitorOutcome.unavailable("notification missing")
    let stream = try openStream(runtime, .deviceSettingChanges("state-settings"))
    defer { closeStream(stream.client) }

    let snapshot = try success(nextEvent(BridgeAXSettingSnapshot.self, on: stream))

    XCTAssertEqual(snapshot.setting, "state-settings")
    XCTAssertEqual(snapshot.enabled, false)
    XCTAssertEqual(snapshot.otherSettings["button-shapes"], .success(BridgeAXSettingResponse(enabled: false)))
    XCTAssertEqual(snapshot.otherSettings["reduce-transparency"], .success(BridgeAXSettingResponse(enabled: false)))
    XCTAssertEqual(
      snapshot.otherSettings["increase-contrast"], .failure(BridgeAXFailure(message: "notification missing", kind: .capabilityUnavailable)))
  }

  func testAnUnavailableSettingsStreamFailsWithItsKind() throws {
    let stream = try openStream(FBAXFakeRuntime(), .deviceSettingChanges("reduce-motion"))
    defer { closeStream(stream.client) }

    XCTAssertEqual(
      try failure(nextEvent(BridgeAXSettingSnapshot.self, on: stream)),
      BridgeAXFailure(message: "setting unavailable", kind: .capabilityUnavailable))
  }
}

private extension Data {
  /// The frame a client writes: the request after its length.
  func framed() throws -> Data {
    var frame = try IPCFrame.header(forSize: count)
    frame.append(self)
    return frame
  }
}
