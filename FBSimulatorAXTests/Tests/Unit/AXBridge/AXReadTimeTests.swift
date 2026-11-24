/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import AccessibilityPlatformTranslation
@testable import FBSimulatorAX
import FBSimulatorBridgeProtocol
@testable import FBSimulatorControl
import Foundation
import Testing

/// Answers root lookups with `root` and leaves every other request unanswered, as a service that resolves
/// the application but then stops answering does.
private final class RootOnlyTransportDouble: AXTranslationTransport, @unchecked Sendable {
  let kind = AXTranslationTransportKind.bridge
  let abandonedRequests = 0
  private let root: AXPTranslationObjectDouble
  private let lock = NSLock()
  private var _requestTypes: [UInt64] = []

  init(root: AXPTranslationObjectDouble) {
    self.root = root
  }

  var requestTypes: [UInt64] { lock.withLock { _requestTypes } }

  func send(_ request: AXPTranslatorRequest, timeout: TimeInterval) -> AXPTranslatorResponse? {
    lock.withLock { _requestTypes.append(request.requestType) }
    switch BridgeAXTranslatorRequestType(rawValue: Int(request.requestType)) {
    case .application, .frontmostApplication, .hitTest:
      let response = AXPTranslatorResponse.empty() as? AXPTranslatorResponse
      response?.setValue(root, forKey: "resultData")
      return response
    case .attribute, .multipleAttribute, nil:
      return nil
    }
  }
}

/// Records the timeout each request was given, and answers root lookups with `root` and element reads with
/// nothing to read.
private final class TimeoutRecordingTransportDouble: AXTranslationTransport, @unchecked Sendable {
  let kind = AXTranslationTransportKind.bridge
  private let root: AXPTranslationObjectDouble
  private let lock = NSLock()
  private var _timeouts: [TimeInterval] = []
  let abandonedRequests: Int

  init(root: AXPTranslationObjectDouble, abandonedRequests: Int = 0) {
    self.root = root
    self.abandonedRequests = abandonedRequests
  }

  var timeouts: [TimeInterval] { lock.withLock { _timeouts } }

  func send(_ request: AXPTranslatorRequest, timeout: TimeInterval) -> AXPTranslatorResponse? {
    lock.withLock { _timeouts.append(timeout) }
    let response = AXPTranslatorResponse.empty() as? AXPTranslatorResponse
    if BridgeAXTranslatorRequestType(rawValue: Int(request.requestType)) != .multipleAttribute {
      response?.setValue(root, forKey: "resultData")
    } else {
      response?.resultData = [NSNumber(value: BridgeAXTranslatorAttribute.frame.rawValue): NSValue(rect: NSRect(x: 0, y: 0, width: 1, height: 1))] as NSDictionary
    }
    return response
  }
}

/// Answers nothing, while an earlier request it gave up on is still outstanding.
private final class AbandonedBehindTransportDouble: AXTranslationTransport {
  let kind = AXTranslationTransportKind.bridge
  let abandonedRequests = 1

  func send(_ request: AXPTranslatorRequest, timeout: TimeInterval) -> AXPTranslatorResponse? {
    nil
  }
}

/// A guest that never answers within the time it is given.
private actor SilentGuestTransportDouble: AXBridgeTransport {
  private(set) var receiveTimeouts: [TimeInterval] = []

  func send(_ request: AXBridgeRequest) async throws -> AXBridgeReply {
    throw AXBridgeError.guestFailure("the double only answers bounded round trips")
  }

  func send(_ request: AXBridgeRequest, receiveTimeout: TimeInterval) async throws -> AXBridgeReply {
    receiveTimeouts.append(receiveTimeout)
    throw AXBridgeError.guestNotAnswering(after: receiveTimeout)
  }
}

@objc private final class GuestDevice: NSObject {
  @objc let UDID = NSUUID()
  @objc var deviceType: NSObject? { nil }
}

@Suite("How an accessibility read spends its time", .serialized)
final class AXReadTimeTests {

  private static let pid: pid_t = 12345

  private static func reference(_ objectID: UInt64) -> AXPTranslationObjectDouble {
    AXPTranslationObjectDouble(pid: pid, objectID: objectID)
  }

  private let fixture = AccessibilityTestFixture.bootedSimulator()
  /// Held here: the commands hold their simulator weakly.
  private var simulator: Simulator?

  private func commands(
    transport: any AXTranslationTransport, launchCtl: any LaunchCtlCommands
  ) throws -> SimulatorAccessibilityCommands {
    fixture.rootElement = AccessibilityTestElementBuilder.application(withLabel: "App", frame: .zero, children: [])
    try fixture.setUp()
    let simulator = SimulatorTestSupport.testableSimulator(withDevice: fixture.device)
    self.simulator = simulator
    return SimulatorAccessibilityCommands(
      simulator: simulator,
      translationDispatcher: Simulator.createAccessibilityTranslationDispatcher(withTranslator: fixture.translator),
      transport: transport, launchCtl: launchCtl,
      displays: DisplayCommandsDouble([.success(.failed(.unsupported("displayinfo")))]))
  }

  // MARK: - Unanswered requests

  @Test func anUnansweredElementStopsTheReadAfterOneTimeout() {
    let transport = AXRawTranslationTransportDouble(
      elements: [1: [.role: 1, .label: "App", .children: [Self.reference(2), Self.reference(3)]]],
      waitsOutUnanswered: true)
    let reader = AXRawTranslationReader(
      transport: transport, clientType: .noClient, timeout: 0.05, collector: AccessibilityProfilingCollector(), token: "token")

    let start = ContinuousClock.now
    #expect {
      _ = try reader.read(Self.reference(1), plan: AXReadPlan(keys: AXKeys.defaultSet, depth: .unlimited))
    } throws: { error in
      guard case AccessibilityError.serviceNotAnswering(.request(kind: "multiple_attribute", timeout: 0.05), _, _) = error else {
        return false
      }
      return true
    }
    let elapsed = ContinuousClock.now - start

    // The request count, not the elapsed time, shows only one request was waited out: a loaded host can take longer
    // than a second timeout to wait out one.
    #expect(transport.requests.count == 2, "the root, then the first child, which went unanswered")
    #expect(elapsed >= .milliseconds(50), "the unanswered request was waited out")
  }

  @Test func anUnansweredFrontmostLookupIsReportedAsNoElement() async throws {
    let commands = try commands(
      transport: AXRawTranslationTransportDouble(elements: [:]),
      launchCtl: LaunchCtlDouble.with(running: ["com.apple.SpringBoard": Self.pid]))

    do {
      _ = try await commands.resolveElement(for: .frontmost, clientType: .noClient)
      Issue.record("an unanswered frontmost lookup must fail the read")
    } catch AccessibilityError.serviceNotAnswering(.request(kind: "frontmost", _), _, _) {}
  }

  @Test func aFrontmostReadWhoseStalenessCheckGoesUnansweredFails() async throws {
    let transport = RootOnlyTransportDouble(root: Self.reference(0))
    let commands = try commands(
      transport: transport, launchCtl: LaunchCtlDouble.with(running: ["com.apple.SpringBoard": Self.pid]))

    do {
      _ = try await commands.resolveElement(for: .frontmost, clientType: .noClient)
      Issue.record("an unanswered staleness check must fail the read")
    } catch AccessibilityError.serviceNotAnswering(.request(kind: "multiple_attribute", _), _, _) {}
    #expect(
      transport.requestTypes.filter { $0 == UInt64(BridgeAXTranslatorRequestType.multipleAttribute.rawValue) }.count == 1,
      "the staleness check's request, and nothing after it")
  }

  // MARK: - Timing

  @Test func aQueryThatRunsOutOfTimeStopsAtItsTimeout() {
    let children = (2...6).map { Self.reference(UInt64($0)) }
    var elements: [UInt64: [BridgeAXTranslatorAttribute: Any]] = [1: [.role: 1, .children: children]]
    for child in children {
      elements[child.objectID] = [.role: 2]
    }
    let transport = AXRawTranslationTransportDouble(elements: elements, delay: 0.05)
    let reader = AXRawTranslationReader(
      transport: transport, clientType: .noClient, timeout: 1, collector: AccessibilityProfilingCollector(), token: "token",
      queryTimeout: 0.12)

    #expect {
      _ = try reader.read(Self.reference(1), plan: AXReadPlan(attributes: [.role], depth: .unlimited))
    } throws: { error in
      guard case AccessibilityError.serviceNotAnswering(.query(timeout: 0.12), _, _) = error else { return false }
      return true
    }
    #expect(transport.requests.count < 6, "the query stopped before reading every element")
  }

  @Test func anUnansweredRequestThatSpendsTheLastOfTheQueryIsTheQuerysFailure() {
    let transport = AXRawTranslationTransportDouble(elements: [:], waitsOutUnanswered: true)
    let reader = AXRawTranslationReader(
      transport: transport, clientType: .noClient, timeout: 0.1, collector: AccessibilityProfilingCollector(), token: "token",
      queryTimeout: 0.1)

    #expect {
      _ = try reader.read(Self.reference(1), plan: AXReadPlan(attributes: [], depth: .limited(0)))
    } throws: { error in
      guard case AccessibilityError.serviceNotAnswering(.query(timeout: 0.1), _, _) = error else { return false }
      return true
    }
  }

  @Test func aReadUsesTheSimulatorsTimingUnlessItAsksForItsOwn() async throws {
    let transport = TimeoutRecordingTransportDouble(root: Self.reference(0))
    let commands = try commands(
      transport: transport, launchCtl: LaunchCtlDouble.with(running: ["com.apple.SpringBoard": Self.pid]))

    let byDefault = try await commands.resolveElement(for: .application(pid: Self.pid), clientType: .noClient)
    byDefault.close()
    #expect(transport.timeouts.first == SimulatorAccessibilityTiming.default.elementTimeout)

    let asked = SimulatorAccessibilityTiming(elementTimeout: 1.5, queryTimeout: 30)
    let own = try await commands.resolveElement(for: .application(pid: Self.pid), clientType: .noClient, timing: asked)
    own.close()
    #expect(transport.timeouts.last == 1.5)
  }

  @Test func aDisplayLookupThatRunsOutOfTimeFailsAsAReadDoes() async throws {
    let display = SimulatorDisplay(
      uniqueID: "selected", name: "Selected", activity: .active, isPrimary: false, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: .upright)
    let displays = DisplayCommandsDouble(.selected(display))
    await #expect {
      _ = try await displays.accessibilityID(
        for: display, transport: SilentGuestTransportDouble(), timing: SimulatorAccessibilityTiming(elementTimeout: 1, queryTimeout: 0.5))
    } throws: { error in
      guard case AccessibilityError.serviceNotAnswering(.query(timeout: 0.5), _, _) = error else { return false }
      return true
    }
  }

  @Test func theGuestsRoundTripIsBoundedByTheQueryTimeoutAndFailsAsTheHostDoes() async throws {
    let transport = SilentGuestTransportDouble()
    let reader = AXBridgeUIAutomation(
      simulator: SimulatorTestSupport.testableSimulator(withDevice: GuestDevice()), transport: transport, persistence: .exclusive)

    var options = AccessibilityRequestOptions()
    options.timing = SimulatorAccessibilityTiming(elementTimeout: 1, queryTimeout: 0.5)
    await #expect {
      _ = try await reader.describe(.application(pid: Self.pid), options: options)
    } throws: { error in
      guard case AccessibilityError.serviceNotAnswering(.query(timeout: 0.5), _, _) = error else { return false }
      return true
    }
    _ = try? await reader.describe(.application(pid: Self.pid), options: AccessibilityRequestOptions())
    #expect(await transport.receiveTimeouts == [0.5, SimulatorAccessibilityTiming.default.queryTimeout])
  }

  @Test func aFailedReadSaysHowItEnded() {
    #expect(AccessibilityReadOutcome(failure: AccessibilityError.serviceNotAnswering(.request(kind: "frontmost", timeout: 5), elapsed: 5, behindAbandoned: 0)) == .abortedUnanswered)
    #expect(AccessibilityReadOutcome(failure: AccessibilityError.serviceNotAnswering(.query(timeout: 10), elapsed: 10, behindAbandoned: 0)) == .abortedDeadline)
    #expect(AccessibilityReadOutcome(failure: AccessibilityError.springBoardNotRunning) == nil)
  }

  // MARK: - Abandoned requests

  @Test func aReadCountsTheRequestsItSentBehindAnAbandonedOne() async throws {
    let commands = try commands(
      transport: TimeoutRecordingTransportDouble(root: Self.reference(0), abandonedRequests: 1),
      launchCtl: LaunchCtlDouble.with(running: ["com.apple.SpringBoard": Self.pid]))

    let element = try await commands.resolveElement(for: .application(pid: Self.pid), clientType: .noClient)
    defer { element.close() }
    let response = try await element.serialize(with: AccessibilityRequestOptions())

    let metrics = try #require(response.translatorMetrics)
    #expect(metrics.requestsBehindAbandoned == metrics.roundTrips, "every request went out behind the abandoned one")
    #expect(metrics.requestsBehindAbandoned > 0)
  }

  @Test func aReadThatFailsBehindAnAbandonedRequestSaysSo() {
    let transport = AbandonedBehindTransportDouble()
    let reader = AXRawTranslationReader(
      transport: transport, clientType: .noClient, timeout: 0.01, collector: AccessibilityProfilingCollector(), token: "token")

    #expect {
      _ = try reader.read(Self.reference(1), plan: AXReadPlan(attributes: [], depth: .limited(0)))
    } throws: { error in
      guard case AccessibilityError.serviceNotAnswering(.request, _, behindAbandoned: 1) = error else { return false }
      return true
    }
  }

  // MARK: - Cancellation

  @Test func cancellingAReadStopsItsWalk() async throws {
    let children = (2...6).map { Self.reference(UInt64($0)) }
    var elements: [UInt64: [BridgeAXTranslatorAttribute: Any]] = [1: [.role: 1, .children: children]]
    for child in children {
      elements[child.objectID] = [.role: 2]
    }
    let transport = AXRawTranslationTransportDouble(elements: elements, delay: 0.05)
    let dispatcher = Simulator.createAccessibilityTranslationDispatcher(withTranslator: AXPTranslatorDouble())
    let request = AXTranslationRequest(kind: .frontmostApplication, transport: transport)
    let root = Self.reference(1)

    let read = Task {
      _ = try await dispatcher.performUnserialized(cancelling: request.cancellation) {
        try request.snapshot(of: root, plan: AXReadPlan(attributes: [.role], depth: .unlimited))
      }
    }
    try await Task.sleep(nanoseconds: 60 * NSEC_PER_MSEC)
    read.cancel()
    await #expect(throws: CancellationError.self) { try await read.value }
    #expect(transport.requests.count < 6, "the walk stopped rather than reading every element")
  }
}
