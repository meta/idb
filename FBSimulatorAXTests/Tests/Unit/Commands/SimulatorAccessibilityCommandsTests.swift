/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
import FBControlCore
@testable import FBSimulatorAX
import FBSimulatorBridgeProtocol
@testable import FBSimulatorControl
import XCTest
import os

private final class AccessibilityCustomActionTarget: NSObject {
  private let result: Bool
  private(set) var performedAction: NSAccessibilityCustomAction?
  private(set) var scalarActionInvocationCount = 0

  init(result: Bool = true) {
    self.result = result
  }

  @objc func runAccessibilityAction(_ action: NSAccessibilityCustomAction) -> Bool {
    performedAction = action
    return result
  }

  @objc func runVoidAccessibilityAction(_ action: NSAccessibilityCustomAction) {
    performedAction = action
  }

  @objc func runScalarAccessibilityAction(_ value: Int) -> Bool {
    scalarActionInvocationCount += 1
    return result
  }

  @objc func runVoidScalarAccessibilityAction(_ value: Double) {
    scalarActionInvocationCount += 1
  }
}

final class SimulatorAccessibilityCommandsTests: XCTestCase {

  // MARK: - Properties

  private var fixture: AccessibilityTestFixture?
  private var dispatcher: AXTranslationDispatcher?
  private var simulator: Simulator!

  // MARK: - Helpers

  /// The attributes a default-keys read requests for an element whose children it walks.
  private var allSerializationAttributes: Set<BridgeAXTranslatorAttribute> {
    singleElementSerializationAttributes.union([.children])
  }

  /// The attributes a default-keys read requests for a single element (no children recursion). Role and
  /// role description bring what their conversion reads.
  private var singleElementSerializationAttributes: Set<BridgeAXTranslatorAttribute> {
    [
      .frame, .role, .isRemoteElement, .label, .value, .identifier, .help, .isEnabled, .customActions, .roleDescription, .subrole,
      .traits,
    ]
  }

  /// The attributes requested for AXLabel and frame key filtering over a tree.
  private var labelAndFrameFilteredAttributes: Set<BridgeAXTranslatorAttribute> {
    [.frame, .label, .children]
  }

  /// The attributes requested for AXLabel, type, and frame key filtering on a single element; type is
  /// derived from the role.
  private var labelTypeFrameFilteredAttributes: Set<BridgeAXTranslatorAttribute> {
    [.frame, .label, .role, .isRemoteElement]
  }

  /// Each element is read in exactly one multiple-attribute request naming `attributes`, sent straight to the
  /// accessibility service, and never through the platform element. A frontmost root's frame is read first,
  /// in a request of its own, by the SpringBoard staleness check.
  private func assertReadInOneRequest(
    _ element: AXPMacPlatformElementDouble, attributes: Set<BridgeAXTranslatorAttribute>, afterStalenessCheck: Bool = false,
    _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let expected: [Set<BridgeAXTranslatorAttribute>] = afterStalenessCheck ? [[.frame], attributes] : [attributes]
    XCTAssertEqual(rawRequests(naming: element).map(Set.init), expected, message, file: file, line: line)
  }

  /// The attributes of each multiple-attribute request the accessibility service received for `element`.
  private func rawRequests(naming element: AXPMacPlatformElementDouble) -> [[BridgeAXTranslatorAttribute]] {
    let objectID = element.translation.objectID
    return fixture!.device.accessibilityRequests.compactMap { request -> [BridgeAXTranslatorAttribute]? in
      let request = request as AnyObject
      guard (request.value(forKey: "requestType") as? NSNumber)?.intValue == BridgeAXTranslatorRequestType.multipleAttribute.rawValue,
        (request.value(forKey: "translation") as? AXPTranslationObjectDouble)?.objectID == objectID
      else {
        return nil
      }
      let numbers = (request.value(forKey: "parameters") as? NSDictionary)?["attributes"] as? [NSNumber] ?? []
      return numbers.compactMap { BridgeAXTranslatorAttribute(rawValue: $0.intValue) }
    }
  }

  private func assertProfilingData(
    _ profile: AccessibilityProfile?,
    expectedElements: Int64,
    expectedAttributeFetches: Int64
  ) {
    XCTAssertNotNil(profile, "Profiling data should be present")
    // The accessibility backend must carry the translator profile shape.
    guard case let .translator(profilingData)? = profile else {
      return XCTFail("the accessibility backend must report a translator profile, got \(String(describing: profile))")
    }
    XCTAssertEqual(profilingData.elementCount, expectedElements, "Element count mismatch")
    XCTAssertEqual(profilingData.attributeFetchCount, expectedAttributeFetches, "Attribute fetch count mismatch")
    XCTAssertGreaterThanOrEqual(profilingData.xpcCallCount, 0, "XPC call count should be non-negative")
    XCTAssertGreaterThanOrEqual(profilingData.translationDuration, 0, "Translation duration should be non-negative")
    XCTAssertGreaterThanOrEqual(profilingData.elementConversionDuration, 0, "Element conversion duration should be non-negative")
    XCTAssertGreaterThanOrEqual(profilingData.serializeDuration, 0, "Serialize duration should be non-negative")
    // The core, which telemetry reads across both backends by name. A read cannot have taken less time in
    // total than the phases it is made of.
    XCTAssertGreaterThan(profilingData.totalDuration, 0, "Total duration should be positive")
    XCTAssertGreaterThanOrEqual(
      profilingData.totalDuration,
      profilingData.acquireDuration + profilingData.readDuration + profilingData.serializeDuration,
      "The phases must fit inside the total"
    )
  }

  // MARK: - Core Test Helpers

  @discardableResult
  private func assertFlatOutput(
    withProfiling enableProfiling: Bool,
    childElements: [AXPMacPlatformElementDouble]
  ) async throws -> AccessibilityElementsResponse {
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)

    var options = AccessibilityRequestOptions()
    options.format = .default
    options.enableProfiling = enableProfiling

    let response = try await element.serialize(with: options)
    element.close()

    let result = response.legacyElementsObject() as! [Any]
    XCTAssertEqual(result.count, 4, "Flat format should have 4 elements (root + 3 children)")

    let expected: [[String: Any]] = [
      [
        "AXLabel": "App Window",
        "AXFrame": "{{0, 0}, {390, 844}}",
        "AXValue": NSNull(),
        "AXUniqueId": NSNull(),
        "type": "Application",
        "title": NSNull(),
        "frame": ["x": 0, "y": 0, "width": 390, "height": 844],
        "help": NSNull(),
        "enabled": true,
        "custom_actions": [] as [Any],
        "role": "AXApplication",
        "role_description": "application",
        "subrole": NSNull(),
        "content_required": false,
        "pid": 12345,
        "traits": NSNull(),
      ],
      [
        "AXLabel": "Confirm Action",
        "AXFrame": "{{20, 100}, {350, 30}}",
        "AXValue": NSNull(),
        "AXUniqueId": NSNull(),
        "type": "StaticText",
        "title": NSNull(),
        "frame": ["x": 20, "y": 100, "width": 350, "height": 30],
        "help": NSNull(),
        "enabled": true,
        "custom_actions": [] as [Any],
        "role": "AXStaticText",
        "role_description": "text",
        "subrole": NSNull(),
        "content_required": false,
        "pid": 12345,
        "traits": NSNull(),
      ],
      [
        "AXLabel": "OK",
        "AXFrame": "{{20, 750}, {150, 44}}",
        "AXValue": NSNull(),
        "AXUniqueId": "ok_button",
        "type": "Button",
        "title": NSNull(),
        "frame": ["x": 20, "y": 750, "width": 150, "height": 44],
        "help": NSNull(),
        "enabled": true,
        "custom_actions": [] as [Any],
        "role": "AXButton",
        "role_description": "button",
        "subrole": NSNull(),
        "content_required": false,
        "pid": 12345,
        "traits": NSNull(),
      ],
      [
        "AXLabel": "Cancel",
        "AXFrame": "{{200, 750}, {150, 44}}",
        "AXValue": NSNull(),
        "AXUniqueId": "cancel_button",
        "type": "Button",
        "title": NSNull(),
        "frame": ["x": 200, "y": 750, "width": 150, "height": 44],
        "help": NSNull(),
        "enabled": true,
        "custom_actions": [] as [Any],
        "role": "AXButton",
        "role_description": "button",
        "subrole": NSNull(),
        "content_required": false,
        "pid": 12345,
        "traits": NSNull(),
      ],
    ]

    XCTAssertEqual(result as NSArray, expected as NSArray)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(result))

    assertReadInOneRequest(
      fixture!.rootElement!, attributes: allSerializationAttributes, afterStalenessCheck: true,
      "All serialization properties should be accessed for root element"
    )
    for child in childElements {
      assertReadInOneRequest(
        child, attributes: allSerializationAttributes,
        "All serialization properties should be accessed for child element"
      )
    }

    return response
  }

  @discardableResult
  private func assertElementAtPoint(
    withProfiling enableProfiling: Bool,
    point: CGPoint,
    element elementDouble: AXPMacPlatformElementDouble,
    expected: [String: Any]
  ) async throws -> AccessibilityElementsResponse {
    fixture!.translator.macPlatformElementResult = elementDouble

    let element = try await simulator.accessibility.resolveElement(for: .point(point))

    var options = AccessibilityRequestOptions()
    options.format = .default
    options.enableProfiling = enableProfiling

    let response = try await element.serialize(with: options)
    element.close()

    let result = response.legacyElementsObject() as! [String: Any]
    XCTAssertEqual(result as NSDictionary, expected as NSDictionary)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(result))

    assertReadInOneRequest(
      elementDouble, attributes: singleElementSerializationAttributes,
      "Single element at point should access all properties except children"
    )

    return response
  }

  @discardableResult
  private func assertNestedOutput(
    withProfiling enableProfiling: Bool,
    childElements: [AXPMacPlatformElementDouble]
  ) async throws -> AccessibilityElementsResponse {
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)

    var options = AccessibilityRequestOptions()
    options.format = .nested
    options.enableProfiling = enableProfiling

    let response = try await element.serialize(with: options)
    element.close()

    let result = response.legacyElementsObject() as! [Any]
    XCTAssertEqual(result.count, 1, "Nested format should have 1 root element")

    let expected: [[String: Any]] = [
      [
        "AXLabel": "App Window",
        "AXFrame": "{{0, 0}, {390, 844}}",
        "AXValue": NSNull(),
        "AXUniqueId": NSNull(),
        "type": "Application",
        "title": NSNull(),
        "frame": ["x": 0, "y": 0, "width": 390, "height": 844],
        "help": NSNull(),
        "enabled": true,
        "custom_actions": [] as [Any],
        "role": "AXApplication",
        "role_description": "application",
        "subrole": NSNull(),
        "content_required": false,
        "pid": 12345,
        "traits": NSNull(),
        "children": [
          [
            "AXLabel": "Confirm Action",
            "AXFrame": "{{20, 100}, {350, 30}}",
            "AXValue": NSNull(),
            "AXUniqueId": NSNull(),
            "type": "StaticText",
            "title": NSNull(),
            "frame": ["x": 20, "y": 100, "width": 350, "height": 30],
            "help": NSNull(),
            "enabled": true,
            "custom_actions": [] as [Any],
            "role": "AXStaticText",
            "role_description": "text",
            "subrole": NSNull(),
            "content_required": false,
            "pid": 12345,
            "traits": NSNull(),
            "children": [] as [Any],
          ] as [String: Any],
          [
            "AXLabel": "OK",
            "AXFrame": "{{20, 750}, {150, 44}}",
            "AXValue": NSNull(),
            "AXUniqueId": "ok_button",
            "type": "Button",
            "title": NSNull(),
            "frame": ["x": 20, "y": 750, "width": 150, "height": 44],
            "help": NSNull(),
            "enabled": true,
            "custom_actions": [] as [Any],
            "role": "AXButton",
            "role_description": "button",
            "subrole": NSNull(),
            "content_required": false,
            "pid": 12345,
            "traits": NSNull(),
            "children": [] as [Any],
          ] as [String: Any],
          [
            "AXLabel": "Cancel",
            "AXFrame": "{{200, 750}, {150, 44}}",
            "AXValue": NSNull(),
            "AXUniqueId": "cancel_button",
            "type": "Button",
            "title": NSNull(),
            "frame": ["x": 200, "y": 750, "width": 150, "height": 44],
            "help": NSNull(),
            "enabled": true,
            "custom_actions": [] as [Any],
            "role": "AXButton",
            "role_description": "button",
            "subrole": NSNull(),
            "content_required": false,
            "pid": 12345,
            "traits": NSNull(),
            "children": [] as [Any],
          ] as [String: Any],
        ] as [[String: Any]],
      ]
    ]

    XCTAssertEqual(result as NSArray, expected as NSArray)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(result))

    assertReadInOneRequest(
      fixture!.rootElement!, attributes: allSerializationAttributes, afterStalenessCheck: true,
      "All serialization properties should be accessed for root element"
    )
    for child in childElements {
      assertReadInOneRequest(
        child, attributes: allSerializationAttributes,
        "All serialization properties should be accessed for child element"
      )
    }

    return response
  }

  @discardableResult
  private func assertKeyFiltering(
    withProfiling enableProfiling: Bool,
    childElements: [AXPMacPlatformElementDouble]
  ) async throws -> AccessibilityElementsResponse {
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)

    var options = AccessibilityRequestOptions()
    options.format = .default
    options.keys = Set([AXKeys.label, .frameDict])
    options.enableProfiling = enableProfiling

    let response = try await element.serialize(with: options)
    element.close()

    let result = response.legacyElementsObject() as! [Any]
    XCTAssertEqual(result.count, 4, "Should have 4 elements")

    let expected: [[String: Any]] = [
      [
        "AXLabel": "App Window",
        "frame": ["x": 0, "y": 0, "width": 390, "height": 844],
      ],
      [
        "AXLabel": "Confirm Action",
        "frame": ["x": 20, "y": 100, "width": 350, "height": 30],
      ],
      [
        "AXLabel": "OK",
        "frame": ["x": 20, "y": 750, "width": 150, "height": 44],
      ],
      [
        "AXLabel": "Cancel",
        "frame": ["x": 200, "y": 750, "width": 150, "height": 44],
      ],
    ]

    XCTAssertEqual(result as NSArray, expected as NSArray)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(result))

    assertReadInOneRequest(
      fixture!.rootElement!, attributes: labelAndFrameFilteredAttributes, afterStalenessCheck: true,
      "Only label and frame properties should be accessed for root element"
    )
    for child in childElements {
      assertReadInOneRequest(
        child, attributes: labelAndFrameFilteredAttributes,
        "Only label and frame properties should be accessed for child element"
      )
    }

    return response
  }

  @discardableResult
  private func assertElementAtPointKeyFiltering(withProfiling enableProfiling: Bool) async throws -> AccessibilityElementsResponse {
    let titleLabel = AccessibilityTestElementBuilder.staticText(
      withLabel: "Confirm Action",
      frame: NSRect(x: 20, y: 100, width: 350, height: 30)
    )
    fixture!.translator.macPlatformElementResult = titleLabel

    let element = try await simulator.accessibility.resolveElement(for: .point(CGPoint(x: 100, y: 115)))

    var options = AccessibilityRequestOptions()
    options.format = .default
    options.keys = Set([AXKeys.label, .type, .frameDict])
    options.enableProfiling = enableProfiling

    let response = try await element.serialize(with: options)
    element.close()

    let result = response.legacyElementsObject() as! [String: Any]

    let expected: [String: Any] = [
      "AXLabel": "Confirm Action",
      "type": "StaticText",
      "frame": ["x": 20, "y": 100, "width": 350, "height": 30],
    ]

    XCTAssertEqual(result as NSDictionary, expected as NSDictionary)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(result))

    assertReadInOneRequest(
      titleLabel, attributes: labelTypeFrameFilteredAttributes,
      "Only label, role (for type), and frame properties should be accessed with key filtering"
    )

    return response
  }

  // MARK: - Setup/Teardown

  override func tearDown() {
    simulator = nil
    fixture?.tearDown()
    fixture = nil
    super.tearDown()
  }

  /// Creates and activates the fixture with the given root element tree, then
  /// builds a real `Simulator`, a mock translation dispatcher, and registers an
  /// `SimulatorAccessibilityCommands` with that dispatcher injected into the
  /// simulator's command cache. Production paths that resolve `accessibility`
  /// on the simulator will return it.
  private func setUp(
    withRootElement rootElement: AXPMacPlatformElementDouble,
    transport: (any AXTranslationTransport)? = nil,
    launchCtl: (any LaunchCtlCommands)? = nil,
    displays: any DisplayCommands = DisplayCommandsDouble([.success(.failed(.unsupported("displayinfo")))]),
    processesStarted: [pid_t: Date] = [:],
    processesRunning: Set<pid_t> = [],
    stallWatchEnvironment: AXStallWatch.Environment = AXStallWatch.Environment(),
    holding: (types: Set<BridgeAXTranslatorRequestType>, hold: TransportHold)? = nil
  ) throws {
    fixture = AccessibilityTestFixture.bootedSimulator()
    fixture!.rootElement = rootElement
    try fixture!.setUp()

    let sim = SimulatorTestSupport.testableSimulator(withDevice: fixture!.device)
    let dispatcher = Simulator.createAccessibilityTranslationDispatcher(withTranslator: fixture!.translator)
    self.dispatcher = dispatcher
    // CoreSimulator's client over the device double, unless a test injects its own: the double vends no
    // services for the bridge transport to look up.
    let sending = transport ?? CoreSimulatorAXTranslationTransport(device: sim.device)
    let commands = SimulatorAccessibilityCommands(
      simulator: sim, translationDispatcher: dispatcher,
      transport: holding.map { HoldingTransport(sending, holding: $0.types, hold: $0.hold) } ?? sending, launchCtl: launchCtl,
      displays: displays,
      processStartDate: { processesStarted[$0] }, processIsRunning: { processesRunning.contains($0) },
      stallWatchEnvironment: stallWatchEnvironment)
    sim.commandCache.register(commands, as: SimulatorAccessibilityCommands.self)

    simulator = sim
  }

  // MARK: - Default Element Factories

  private var defaultTitleLabel: AXPMacPlatformElementDouble {
    AccessibilityTestElementBuilder.staticText(withLabel: "Confirm Action", frame: NSRect(x: 20, y: 100, width: 350, height: 30))
  }

  private var defaultOkButton: AXPMacPlatformElementDouble {
    AccessibilityTestElementBuilder.button(withLabel: "OK", identifier: "ok_button", frame: NSRect(x: 20, y: 750, width: 150, height: 44))
  }

  private var defaultCancelButton: AXPMacPlatformElementDouble {
    AccessibilityTestElementBuilder.button(withLabel: "Cancel", identifier: "cancel_button", frame: NSRect(x: 200, y: 750, width: 150, height: 44))
  }

  private func defaultRoot(withChildren children: [AXPMacPlatformElementDouble]) -> AXPMacPlatformElementDouble {
    AccessibilityTestElementBuilder.application(withLabel: "App Window", frame: NSRect(x: 0, y: 0, width: 390, height: 844), children: children)
  }

  private var defaultElementTree: AXPMacPlatformElementDouble {
    defaultRoot(withChildren: [defaultTitleLabel, defaultOkButton, defaultCancelButton])
  }

  /// Sends a translator request with each client type through the dispatcher's bridge callback for the open
  /// element's token, as the translator does when it acts on the element, returning each answer.
  @discardableResult
  private func sendThroughBridgeCallback(clientTypes: [UInt64], root: AXPTranslationObjectDouble? = nil) -> [AnyObject?] {
    let token = (root ?? fixture!.translator.frontmostApplicationResult)?.bridgeDelegateToken ?? ""
    return clientTypes.map {
      AccessibilityTranslatorRequests.send(AccessibilityTranslatorRequests.make(clientType: $0), through: dispatcher, token: token)
    }
  }

  /// The client type of each request a test sent through the bridge callback, among everything `requests` holds:
  /// those are the only requests with no request type of their own.
  private func bridgeCallbackClientTypes(_ requests: [Any]) -> [UInt64] {
    requests
      .filter { (($0 as AnyObject).value(forKey: "requestType") as? NSNumber)?.intValue == 0 }
      .compactMap { AccessibilityTranslatorRequests.clientType(of: $0) }
  }

  // MARK: - Tests

  func testTheDispatcherForwardsTranslatorRequestsWithTheClientTypeTheTranslatorStamped() async throws {
    try setUp(withRootElement: defaultElementTree)
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    defer { element.close() }

    sendThroughBridgeCallback(clientTypes: [0, 5])

    XCTAssertEqual(bridgeCallbackClientTypes(fixture!.device.accessibilityRequests as! [Any]), [0, 0])
  }

  func testTranslatorRequestsGoThroughTheInjectedTransportWithTheirClient() async throws {
    let root = AXPTranslationObjectDouble(pid: 12345, objectID: 0)
    let transport = AXTranslationTransportDouble(root: root)
    try setUp(withRootElement: defaultElementTree, transport: transport)
    let element = try await simulator.accessibility.resolveElement(for: .application(pid: 12345), clientType: .xctest)
    defer { element.close() }

    sendThroughBridgeCallback(clientTypes: [0, 5], root: root)

    XCTAssertEqual(bridgeCallbackClientTypes(transport.requests), [AXClientType.xctest.rawValue, AXClientType.xctest.rawValue])
    XCTAssertEqual(fixture!.device.accessibilityRequests.count, 0, "nothing reaches CoreSimulator's client")
  }

  func testTheRequestThatResolvesAnElementIsWatched() async throws {
    let observation = try await resolveWhileHeld(.application(pid: 12345), holding: [.application])

    XCTAssertEqual(observation?.requestKind, "application")
    XCTAssertEqual(observation?.baselineMilliseconds, 250)
  }

  func testTheRequestsThatSearchForAMarkerAreWatched() async throws {
    let observation = try await resolveWhileHeld(
      .marker(value: "OK", key: .label, depth: 10, ignoresCase: false), holding: [.multipleAttribute],
      transport: nil, tree: defaultRoot(withChildren: [defaultTitleLabel, defaultOkButton, defaultCancelButton]))

    XCTAssertEqual(observation?.requestKind, "multiple_attribute", "the search's first read was watched")
  }

  /// Resolves `query` with the first request of a type in `holding` held for 1.2 s past its baseline, and returns
  /// what the stall observer was told about it.
  private func resolveWhileHeld(
    _ query: AccessibilityElementQuery, holding: Set<BridgeAXTranslatorRequestType>,
    transport: (any AXTranslationTransport)? = AXTranslationTransportDouble(root: AXPTranslationObjectDouble(pid: 12345, objectID: 0)),
    tree: AXPMacPlatformElementDouble? = nil
  ) async throws -> AccessibilityStallObservation? {
    let host = FakeStallWatchHost()
    let hold = TransportHold()
    try setUp(
      withRootElement: tree ?? defaultElementTree, transport: transport, stallWatchEnvironment: host.environment,
      holding: (holding, hold))
    let observations = OSAllocatedUnfairLock<[AccessibilityStallObservation]>(initialState: [])
    let accessibility = try XCTUnwrap(simulator).accessibility
    let resolving = Task {
      try await accessibility.resolveElement(
        for: query, clientType: .noClient, stallObserver: { observation in observations.withLock { $0.append(observation) } })
    }
    await Task.detached { hold.waitUntilHolding() }.value
    host.runDue()
    host.advance(by: 1_200_000_000)
    hold.release()
    let element = try await resolving.value
    element.close()
    return observations.withLock { $0.first }
  }

  func testEveryReadCarriesItsMetricsWithoutAProfile() async throws {
    try setUp(withRootElement: defaultElementTree)
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    defer { element.close() }

    let response = try await element.serialize(with: AccessibilityRequestOptions())

    XCTAssertNil(response.profilingData, "no profile was asked for")
    let metrics = try XCTUnwrap(response.translatorMetrics)
    XCTAssertEqual(metrics.elementCount, 4, "the root and its three children")
    XCTAssertEqual(metrics.transport, .coreSimulator, "named by the transport that carried the read")
    XCTAssertEqual(metrics.acquireRoundTrips, 2, "the frontmost lookup and the SpringBoard staleness check")
    XCTAssertNotNil(metrics.slowestRequest)
    let document = String(decoding: try response.formattedOutputJSON(format: .complete), as: UTF8.self)
    XCTAssertFalse(document.contains("translatorMetrics"), "the metrics never reach the document")
  }

  func testAnUntokenedRequestIsAnsweredEmptyWithoutARoundTrip() async throws {
    let root = AXPTranslationObjectDouble(pid: 12345, objectID: 0)
    let transport = AXTranslationTransportDouble(root: root)
    try setUp(withRootElement: defaultElementTree, transport: transport)
    let element = try await simulator.accessibility.resolveElement(for: .application(pid: 12345))
    defer { element.close() }
    let request = AccessibilityTranslatorRequests.make(clientType: 0)
    request?.setValue(1, forKey: "requestType")

    let response = try XCTUnwrap(AccessibilityTranslatorRequests.send(request, through: dispatcher, token: ""))

    XCTAssertNil(response.value(forKey: "resultData"))
    XCTAssertEqual(transport.requests.map(\.requestType), [1], "only the application lookup reached the service")
  }

  func testATransportThatDoesNotAnswerYieldsTheEmptyResponse() async throws {
    try setUp(withRootElement: defaultElementTree)
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    defer { element.close() }
    fixture!.device.accessibilityResponseHandler = { _, respond in respond(nil) }

    let response = try XCTUnwrap(sendThroughBridgeCallback(clientTypes: [0]).first ?? nil, "the translator always gets an answer")
    XCTAssertNil(response.value(forKey: "resultData"), "an unanswered request reads as empty")
  }

  func testTheDispatcherStampsTheRequestedClientOnTheTranslatorsRequests() async throws {
    try setUp(withRootElement: defaultElementTree)
    let element = try await simulator.accessibility.resolveElement(for: .frontmost, clientType: .xctest)
    defer { element.close() }

    sendThroughBridgeCallback(clientTypes: [0, 5])

    XCTAssertEqual(
      bridgeCallbackClientTypes(fixture!.device.accessibilityRequests as! [Any]), [AXClientType.xctest.rawValue, AXClientType.xctest.rawValue])
  }

  func testAFrontmostRootIsResolvedInOneLookup() async throws {
    try setUp(withRootElement: defaultElementTree)
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    defer { element.close() }

    XCTAssertEqual(fixture!.translator.rawLookups, [.frontmostApplication])
  }

  func testAccessibilityCommandsProducesCorrectFlatOutput() async throws {
    let children = [defaultTitleLabel, defaultOkButton, defaultCancelButton]
    try setUp(withRootElement: defaultRoot(withChildren: children))
    _ = try await assertFlatOutput(withProfiling: false, childElements: children)
  }

  func testAccessibilityCommandsProducesCorrectFlatOutputWithProfiling() async throws {
    let children = [defaultTitleLabel, defaultOkButton, defaultCancelButton]
    try setUp(withRootElement: defaultRoot(withChildren: children))
    let response = try await assertFlatOutput(withProfiling: true, childElements: children)
    // 4 elements x 15 properties (all except actionNames) = 60 attribute fetches
    assertProfilingData(response.profilingData, expectedElements: 4, expectedAttributeFetches: 60)
  }

  func testAccessibilityCommandsProducesCorrectNestedOutput() async throws {
    let children = [defaultTitleLabel, defaultOkButton, defaultCancelButton]
    try setUp(withRootElement: defaultRoot(withChildren: children))
    _ = try await assertNestedOutput(withProfiling: false, childElements: children)
  }

  func testAccessibilityCommandsProducesCorrectNestedOutputWithProfiling() async throws {
    let children = [defaultTitleLabel, defaultOkButton, defaultCancelButton]
    try setUp(withRootElement: defaultRoot(withChildren: children))
    let response = try await assertNestedOutput(withProfiling: true, childElements: children)
    // 4 elements x 15 properties (all except actionNames) = 60 attribute fetches
    assertProfilingData(response.profilingData, expectedElements: 4, expectedAttributeFetches: 60)
  }

  func testAccessibilityCommandsRespectsKeyFiltering() async throws {
    let children = [defaultTitleLabel, defaultOkButton, defaultCancelButton]
    try setUp(withRootElement: defaultRoot(withChildren: children))
    _ = try await assertKeyFiltering(withProfiling: false, childElements: children)
  }

  func testAccessibilityCommandsRespectsKeyFilteringWithProfiling() async throws {
    let children = [defaultTitleLabel, defaultOkButton, defaultCancelButton]
    try setUp(withRootElement: defaultRoot(withChildren: children))
    let response = try await assertKeyFiltering(withProfiling: true, childElements: children)
    // 4 elements x 3 properties (AXFrame always, label, frame dict) = 12 attribute fetches
    assertProfilingData(response.profilingData, expectedElements: 4, expectedAttributeFetches: 12)

    let expectedKeys: Set<String> = Set([AXKeys.frame.rawValue, AXKeys.label.rawValue, AXKeys.frameDict.rawValue])
    XCTAssertEqual(response.profilingData?.translatorProfile?.fetchedKeys, expectedKeys, "fetchedKeys should match exactly the keys that were requested")
  }

  // `TapOptions.duration` asks for a long-press. The accessibility backend performs `AXPress`, which is
  // instantaneous and has nowhere to put a hold, so the request is refused rather than quietly served as
  // an ordinary tap — a test asking for a long-press and getting a tap passes for the wrong reason.
  func testAccessibilityTapRefusesAHoldDuration() async throws {
    try setUp(withRootElement: defaultElementTree)
    let okButton = AccessibilityTestElementBuilder.button(
      withLabel: "OK",
      identifier: "ok_button",
      frame: NSRect(x: 20, y: 750, width: 150, height: 44)
    )
    fixture!.translator.macPlatformElementResult = okButton

    let automation = try simulator.uiAutomation(backend: .accessibility)
    do {
      try await automation.tap(.point(CGPoint(x: 95, y: 772)), options: TapOptions(duration: 2))
      XCTFail("a hold this backend cannot perform must be refused")
    } catch let error as UIAutomationError {
      guard case let .operationUnsupported(backend, operation) = error else {
        return XCTFail("expected operationUnsupported, got \(error)")
      }
      XCTAssertEqual(backend, .accessibility)
      XCTAssertEqual(operation, "A tap with a hold duration")
    }

    XCTAssertFalse(
      okButton.accessedProperties.contains("accessibilityActionNames"),
      "a refused tap must not reach the element at all"
    )
  }

  func testAMarkerMatchBuildsItsPlatformElementOnlyWhenActedOn() async throws {
    // Resolution names the root by its translation too, so only acting builds an element.
    let okButton = defaultOkButton
    try setUp(withRootElement: defaultRoot(withChildren: [defaultTitleLabel, okButton, defaultCancelButton]))
    func elementsBuilt() -> Int {
      fixture!.translator.methodCalls.compactMap { $0 as? String }.filter { $0 == "macPlatformElementFromTranslation" }.count
    }

    let match = try await simulator.accessibility.resolveElement(for: .marker(value: "OK", key: .label, depth: 10, ignoresCase: false))
    defer { match.close() }
    XCTAssertEqual(elementsBuilt(), 0, "resolving the root and reading the tree to find the match build no elements")

    try await match.tap()

    XCTAssertEqual(elementsBuilt(), 1, "acting on the match builds its element")
    XCTAssertEqual(okButton.translation.bridgeDelegateToken, fixture!.translator.frontmostApplicationResult?.bridgeDelegateToken)
  }

  func testAccessibilityPerformTapOnButtonSucceeds() async throws {
    try setUp(withRootElement: defaultElementTree)

    let okButton = AccessibilityTestElementBuilder.button(
      withLabel: "OK",
      identifier: "ok_button",
      frame: NSRect(x: 20, y: 750, width: 150, height: 44)
    )
    fixture!.translator.macPlatformElementResult = okButton

    let element = try await simulator.accessibility.resolveElement(for: .point(CGPoint(x: 95, y: 772)))

    let label = try await element.stringValue(forSearchableKey: .label)
    XCTAssertEqual(label, "OK")

    try await (element as AccessibilityElement).tap()

    var options = AccessibilityRequestOptions()
    options.format = .nested
    let response = try await element.serialize(with: options)

    let result = response.legacyElementsObject() as! [String: Any]
    let expected: [String: Any] = [
      "AXLabel": "OK",
      "AXFrame": "{{20, 750}, {150, 44}}",
      "AXValue": NSNull(),
      "AXUniqueId": "ok_button",
      "type": "Button",
      "title": NSNull(),
      "frame": ["x": 20, "y": 750, "width": 150, "height": 44],
      "help": NSNull(),
      "enabled": true,
      "custom_actions": [] as [Any],
      "role": "AXButton",
      "role_description": "button",
      "subrole": NSNull(),
      "content_required": false,
      "pid": 12345,
      "traits": NSNull(),
      "children": [] as [Any],
    ]
    XCTAssertEqual(result as NSDictionary, expected as NSDictionary)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(result))

    element.close()

    XCTAssertTrue(
      rawRequests(naming: okButton).contains { $0.contains(.label) },
      "Tap operation should read the label"
    )
    XCTAssertTrue(
      okButton.accessedProperties.contains("accessibilityActionNames"),
      "Tap operation should access action names"
    )
  }

  func testAccessibilityPerformCustomActionUsesExactAdvertisedName() async throws {
    let card = AXPMacPlatformElementDouble(
      label: "Story card",
      identifier: "story_card",
      role: "AXGroup",
      frame: NSRect(x: 20, y: 100, width: 350, height: 200),
      enabled: true,
      actionNames: nil,
      customActionNames: ["Dismiss"],
      children: nil
    )
    try setUp(withRootElement: card)
    fixture!.translator.macPlatformElementResult = card

    let element = try await simulator.accessibility.resolveElement(for: .point(CGPoint(x: 100, y: 150)))
    try await element.performCustomAction(named: "Dismiss")
    XCTAssertEqual(card.performedCustomActions, ["Dismiss"])
    element.close()
  }

  func testAccessibilityPerformCustomActionInvokesTargetSelector() {
    let target = AccessibilityCustomActionTarget()
    let action = NSAccessibilityCustomAction(
      name: "Dismiss",
      target: target,
      selector: #selector(AccessibilityCustomActionTarget.runAccessibilityAction(_:))
    )

    XCTAssertEqual(action.selector.map(NSStringFromSelector), "runAccessibilityAction:")
    XCTAssertTrue(invokeAccessibilityCustomAction(action))
    XCTAssertIdentical(target.performedAction, action)
  }

  func testAccessibilityPerformCustomActionReportsTargetSelectorFailure() {
    let target = AccessibilityCustomActionTarget(result: false)
    let action = NSAccessibilityCustomAction(
      name: "Dismiss",
      target: target,
      selector: #selector(AccessibilityCustomActionTarget.runAccessibilityAction(_:))
    )

    XCTAssertFalse(invokeAccessibilityCustomAction(action))
    XCTAssertIdentical(target.performedAction, action)
  }

  func testAccessibilityPerformCustomActionAcceptsVoidTargetSelector() {
    let target = AccessibilityCustomActionTarget()
    let action = NSAccessibilityCustomAction(
      name: "Dismiss",
      target: target,
      selector: #selector(AccessibilityCustomActionTarget.runVoidAccessibilityAction(_:))
    )

    XCTAssertTrue(invokeAccessibilityCustomAction(action))
    XCTAssertIdentical(target.performedAction, action)
  }

  func testAccessibilityPerformCustomActionRejectsScalarTargetSelectorsWithoutDispatch() {
    let target = AccessibilityCustomActionTarget()
    let selectors = [
      #selector(AccessibilityCustomActionTarget.runScalarAccessibilityAction(_:)),
      #selector(AccessibilityCustomActionTarget.runVoidScalarAccessibilityAction(_:)),
    ]
    for selector in selectors {
      let action = NSAccessibilityCustomAction(name: "Dismiss", target: target, selector: selector)
      XCTAssertFalse(invokeAccessibilityCustomAction(action), NSStringFromSelector(selector))
    }
    XCTAssertEqual(target.scalarActionInvocationCount, 0)
    XCTAssertNil(target.performedAction)
  }

  func testAccessibilityCustomActionReportsHandlerFailure() async throws {
    let card = AXPMacPlatformElementDouble(
      label: "Story card",
      identifier: "story_card",
      role: "AXGroup",
      frame: NSRect(x: 20, y: 100, width: 350, height: 200),
      enabled: true,
      actionNames: nil,
      customActionNames: ["Dismiss"],
      customActionResult: false,
      children: nil
    )
    try setUp(withRootElement: card)
    fixture!.translator.macPlatformElementResult = card

    let element = try await simulator.accessibility.resolveElement(for: .point(CGPoint(x: 100, y: 150)))
    do {
      try await element.performCustomAction(named: "Dismiss")
      XCTFail("Expected the failed custom action to be rejected")
    } catch AccessibilityError.customActionFailed(let name) {
      XCTAssertEqual(name, "Dismiss")
    }
    XCTAssertEqual(card.performedCustomActions, ["Dismiss"])
    element.close()
  }

  func testAccessibilityPerformCustomActionUsesExactMarkerMatch() async throws {
    let containing = AXPMacPlatformElementDouble(
      label: "Story card details",
      identifier: "story_card_details",
      role: "AXGroup",
      frame: NSRect(x: 20, y: 100, width: 350, height: 200),
      enabled: true,
      actionNames: nil,
      customActionNames: ["Dismiss"],
      children: nil
    )
    let exact = AXPMacPlatformElementDouble(
      label: "Story card",
      identifier: "story_card",
      role: "AXGroup",
      frame: NSRect(x: 20, y: 320, width: 350, height: 200),
      enabled: true,
      actionNames: nil,
      customActionNames: ["Dismiss"],
      children: nil
    )
    try setUp(withRootElement: defaultRoot(withChildren: [containing, exact]))

    let automation = try simulator.uiAutomation(backend: .accessibility)
    try await automation.performCustomAction(
      named: "Dismiss",
      on: .marker(value: "Story card", key: .label, depth: 10)
    )

    XCTAssertTrue(containing.performedCustomActions.isEmpty)
    XCTAssertEqual(exact.performedCustomActions, ["Dismiss"])
  }

  func testAccessibilityCustomActionRejectsMissingNameWithoutDispatch() async throws {
    let card = AXPMacPlatformElementDouble(
      label: "Story card",
      identifier: "story_card",
      role: "AXGroup",
      frame: NSRect(x: 20, y: 100, width: 350, height: 200),
      enabled: true,
      actionNames: nil,
      customActionNames: ["Dismiss"],
      children: nil
    )
    try setUp(withRootElement: card)
    fixture!.translator.macPlatformElementResult = card

    let element = try await simulator.accessibility.resolveElement(for: .point(CGPoint(x: 100, y: 150)))
    do {
      try await element.performCustomAction(named: "Delete")
      XCTFail("Expected the unadvertised custom action to be rejected")
    } catch AccessibilityError.customActionUnsupported(let name, _) {
      XCTAssertEqual(name, "Delete")
    }
    XCTAssertTrue(card.performedCustomActions.isEmpty)
    element.close()
  }

  func testAccessibilityCustomActionRejectsDuplicateNamesWithoutDispatch() async throws {
    let card = AXPMacPlatformElementDouble(
      label: "Story card",
      identifier: "story_card",
      role: "AXGroup",
      frame: NSRect(x: 20, y: 100, width: 350, height: 200),
      enabled: true,
      actionNames: nil,
      customActionNames: ["Dismiss", "Dismiss"],
      children: nil
    )
    try setUp(withRootElement: card)
    fixture!.translator.macPlatformElementResult = card

    let element = try await simulator.accessibility.resolveElement(for: .point(CGPoint(x: 100, y: 150)))
    do {
      try await element.performCustomAction(named: "Dismiss")
      XCTFail("Expected duplicate custom action names to be rejected")
    } catch AccessibilityError.customActionAmbiguous(let name, let count) {
      XCTAssertEqual(name, "Dismiss")
      XCTAssertEqual(count, 2)
    }
    XCTAssertTrue(card.performedCustomActions.isEmpty)
    element.close()
  }

  func testDisplayBoundPointReadRoutesAndRotatesWithoutChangingReturnedFrame() async throws {
    let frame = CGRect(x: 60, y: 100, width: 40, height: 40)
    let button = AccessibilityTestElementBuilder.button(withLabel: "Target", identifier: "target", frame: frame)
    let display = SimulatorDisplay(
      uniqueID: "selected-display", name: "Selected", activity: .active, isPrimary: false, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: .clockwise)
    let displays = DisplayCommandsDouble(.selected(display))
    displays.identities.remember([SimulatorAccessibilityDisplay(uniqueID: "selected-display", displayID: 42)])
    try setUp(withRootElement: button, displays: displays)
    let automation = try simulator.uiAutomation(backend: .accessibility)
    let response = try await automation.describe(.point(CGPoint(x: 80, y: 120)), options: AccessibilityRequestOptions())
    XCTAssertEqual(displays.reads, 1)
    XCTAssertEqual(fixture!.translator.rawHitTests, [AXPTranslatorDouble.HitTest(point: CGPoint(x: 120, y: 320), displayID: 42)])
    XCTAssertEqual(response.screen?.width, 400)
    XCTAssertEqual(response.screen?.height, 600)
    XCTAssertEqual(response.screen?.display?.uniqueID, "selected-display")
    XCTAssertEqual(response.screen?.display?.rotation, 90)
    guard case let .single(element) = response.elements else { return XCTFail("Expected point element") }
    XCTAssertEqual((element.frame ?? nil)?.rect, frame)
  }

  func testDisplayGeometryOverridesRootBoundsForFrontmostAndMarkerReads() async throws {
    let legacy = SimulatorInteractionDisplay.legacy(
      SimulatorDisplayGeometry(bounds: CGRect(x: 0, y: 0, width: 2007, height: 2853), scale: 3, rotation: .clockwise))
    let context = AXTranslationDisplay.sole(legacy)
    try setUp(withRootElement: defaultElementTree, displays: DisplayCommandsDouble(.sole(legacy)))
    let automation = try simulator.uiAutomation(backend: .accessibility)
    for query: AccessibilityElementQuery in [.frontmost, .marker(value: "OK", key: .label, depth: 10)] {
      let response = try await automation.describe(query, options: AccessibilityRequestOptions())
      XCTAssertEqual(response.screen?.width, 951)
      XCTAssertEqual(response.screen?.height, 669)
      XCTAssertEqual(response.screen?.display?.rotation, 90)
      XCTAssertNil(response.screen?.display?.uniqueID)
    }
  }

  func testDisplayBoundPointRejectsOutOfBoundsBeforeTranslatorLookup() async throws {
    let legacy = SimulatorInteractionDisplay.legacy(
      SimulatorDisplayGeometry(bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: .clockwise))
    try setUp(withRootElement: defaultElementTree, displays: DisplayCommandsDouble(.sole(legacy)))
    do {
      _ = try await simulator.accessibility.resolveElement(for: .point(CGPoint(x: 401, y: 120)))
      XCTFail("Expected invalid display point")
    } catch let SimulatorDisplayInteractionError.invalidPoint(point, bounds) {
      XCTAssertEqual(point, CGPoint(x: 401, y: 120))
      XCTAssertEqual(bounds, CGSize(width: 400, height: 600))
    }
    XCTAssertEqual(fixture!.translator.rawHitTests, [], "an invalid point is never hit-tested")
  }

  func testRemoteContentRegionBeyondTheDisplaySkipsUntranslatablePoints() async throws {
    let appElement = AccessibilityTestElementBuilder.application(
      withLabel: "App", frame: NSRect(x: 0, y: 0, width: 600, height: 400), children: [])
    let remoteElement = AccessibilityTestElementBuilder.button(
      withLabel: "Remote", identifier: "remote", frame: NSRect(x: 0, y: 200, width: 600, height: 100))
    let legacy = SimulatorInteractionDisplay.legacy(
      SimulatorDisplayGeometry(bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: .upright))
    try setUp(withRootElement: appElement, displays: DisplayCommandsDouble(.sole(legacy)))
    let remoteTranslation = AXPTranslationObjectDouble()
    remoteTranslation.pid = 99999
    fixture!.translator.objectAtPointResult = remoteTranslation
    fixture!.translator.macPlatformElementResultsByPid = [99999: remoteElement]

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    var options = AccessibilityRequestOptions()
    options.remoteContentOptions = AccessibilityRemoteContentOptions(
      gridStepSize: 100, region: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let response = try await element.serialize(with: options)
    element.close()

    let labels = (response.legacyElementsObject() as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["AXLabel"] as? String }
    XCTAssertTrue(labels.contains("Remote"))
  }

  func testAccessibilityElementAtPointReturnsElement() async throws {
    try setUp(withRootElement: defaultElementTree)

    let cancelButton = AccessibilityTestElementBuilder.button(
      withLabel: "Cancel",
      identifier: "cancel_button",
      frame: NSRect(x: 200, y: 750, width: 150, height: 44)
    )

    let expected: [String: Any] = [
      "AXLabel": "Cancel",
      "AXFrame": "{{200, 750}, {150, 44}}",
      "AXValue": NSNull(),
      "AXUniqueId": "cancel_button",
      "type": "Button",
      "title": NSNull(),
      "frame": ["x": 200, "y": 750, "width": 150, "height": 44],
      "help": NSNull(),
      "enabled": true,
      "custom_actions": [] as [Any],
      "role": "AXButton",
      "role_description": "button",
      "subrole": NSNull(),
      "content_required": false,
      "pid": 12345,
      "traits": NSNull(),
    ]

    _ = try await assertElementAtPoint(withProfiling: false, point: CGPoint(x: 275, y: 772), element: cancelButton, expected: expected)
  }

  func testAccessibilityElementAtPointReturnsElementWithProfiling() async throws {
    try setUp(withRootElement: defaultElementTree)

    let cancelButton = AccessibilityTestElementBuilder.button(
      withLabel: "Cancel",
      identifier: "cancel_button",
      frame: NSRect(x: 200, y: 750, width: 150, height: 44)
    )

    let expected: [String: Any] = [
      "AXLabel": "Cancel",
      "AXFrame": "{{200, 750}, {150, 44}}",
      "AXValue": NSNull(),
      "AXUniqueId": "cancel_button",
      "type": "Button",
      "title": NSNull(),
      "frame": ["x": 200, "y": 750, "width": 150, "height": 44],
      "help": NSNull(),
      "enabled": true,
      "custom_actions": [] as [Any],
      "role": "AXButton",
      "role_description": "button",
      "subrole": NSNull(),
      "content_required": false,
      "pid": 12345,
      "traits": NSNull(),
    ]

    let response = try await assertElementAtPoint(withProfiling: true, point: CGPoint(x: 275, y: 772), element: cancelButton, expected: expected)
    // 1 element x 15 properties (no children) = 15 attribute fetches
    assertProfilingData(response.profilingData, expectedElements: 1, expectedAttributeFetches: 15)
  }

  func testAccessibilityElementAtPointRespectsKeyFiltering() async throws {
    try setUp(withRootElement: defaultElementTree)
    _ = try await assertElementAtPointKeyFiltering(withProfiling: false)
  }

  func testAccessibilityElementAtPointRespectsKeyFilteringWithProfiling() async throws {
    try setUp(withRootElement: defaultElementTree)
    let response = try await assertElementAtPointKeyFiltering(withProfiling: true)
    // 1 element x 4 properties (AXFrame always, label, role for type, frame dict) = 4 attribute fetches
    assertProfilingData(response.profilingData, expectedElements: 1, expectedAttributeFetches: 4)

    let expectedKeys: Set<String> = Set([AXKeys.frame.rawValue, AXKeys.label.rawValue, AXKeys.type.rawValue, AXKeys.frameDict.rawValue])
    XCTAssertEqual(response.profilingData?.translatorProfile?.fetchedKeys, expectedKeys, "fetchedKeys should match exactly the keys that were requested")
  }

  // MARK: - Coverage Calculation Tests

  func testCoverageCalculationDisabledByDefault() async throws {
    try setUp(withRootElement: defaultElementTree)

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)

    let options = AccessibilityRequestOptions()
    let response = try await element.serialize(with: options)
    element.close()
    XCTAssertNil(response.coverage?.frame, "Coverage should be nil when collectFrameCoverage is not enabled")
  }

  func testCoverageCalculationWithDefaultFixture() async throws {
    try setUp(withRootElement: defaultElementTree)

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)

    var options = AccessibilityRequestOptions()
    options.collectFrameCoverage = true
    let response = try await element.serialize(with: options)
    element.close()
    XCTAssertNotNil(response.coverage?.frame, "Coverage should be returned when collectFrameCoverage is enabled")

    let coverage = response.coverage!.frame
    XCTAssertGreaterThan(coverage, 0.0, "Coverage should be greater than 0")
    XCTAssertLessThan(coverage, 0.15, "Coverage should be low since only 3 small elements")
  }

  func testCoverageCalculationWithSafariLikeLayout() async throws {
    let navBar = AccessibilityTestElementBuilder.staticText(
      withLabel: "Navigation Bar",
      frame: NSRect(x: 0, y: 0, width: 390, height: 44)
    )

    let urlBar = AccessibilityTestElementBuilder.staticText(
      withLabel: "URL Bar",
      frame: NSRect(x: 0, y: 44, width: 390, height: 50)
    )

    let bottomToolbar = AccessibilityTestElementBuilder.staticText(
      withLabel: "Bottom Toolbar",
      frame: NSRect(x: 0, y: 700, width: 390, height: 144)
    )

    let root = AccessibilityTestElementBuilder.application(
      withLabel: "Safari",
      frame: NSRect(x: 0, y: 0, width: 390, height: 844),
      children: [navBar, urlBar, bottomToolbar]
    )

    try setUp(withRootElement: root)

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)

    var options = AccessibilityRequestOptions()
    options.collectFrameCoverage = true
    let response = try await element.serialize(with: options)
    element.close()
    XCTAssertNotNil(response.coverage?.frame)

    let coverage = response.coverage!.frame
    XCTAssertGreaterThan(coverage, 0.2, "Coverage should be > 20% from bars")
    XCTAssertLessThan(coverage, 0.4, "Coverage should be < 40% due to empty WebView area")
  }

  func testCoverageCalculationWithFullCoverage() async throws {
    let fullCoverageElement = AccessibilityTestElementBuilder.staticText(
      withLabel: "Full Coverage",
      frame: NSRect(x: 0, y: 0, width: 390, height: 844)
    )

    let root = AccessibilityTestElementBuilder.application(
      withLabel: "App Window",
      frame: NSRect(x: 0, y: 0, width: 390, height: 844),
      children: [fullCoverageElement]
    )

    try setUp(withRootElement: root)

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)

    var options = AccessibilityRequestOptions()
    options.collectFrameCoverage = true
    let response = try await element.serialize(with: options)
    element.close()
    XCTAssertNotNil(response.coverage?.frame)

    let coverage = response.coverage!.frame
    XCTAssertGreaterThanOrEqual(coverage, 0.99, "Coverage should be near 100% when element covers full screen")
  }

  func testCoverageCalculationSkipsApplicationElement() async throws {
    let root = AccessibilityTestElementBuilder.application(
      withLabel: "App Window",
      frame: NSRect(x: 0, y: 0, width: 390, height: 844),
      children: []
    )

    try setUp(withRootElement: root)

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)

    var options = AccessibilityRequestOptions()
    options.collectFrameCoverage = true
    let response = try await element.serialize(with: options)
    element.close()
    XCTAssertNotNil(response.coverage?.frame)

    let coverage = response.coverage!.frame
    XCTAssertEqual(coverage, 0.0, accuracy: 0.001, "Coverage should be 0 when only Application element exists")
  }

  // Coverage is computed from the serialized model, so it can only measure frames the read actually
  // serialized. Requesting it therefore widens the key set with what it reads — the frame to measure and
  // the type that identifies the application root it must skip — rather than silently reporting nothing
  // for a narrow `--key`.
  //
  // This costs no extra work on the wire: the walk fetches the frame for every node regardless of the
  // key set, so the widening only changes what is emitted.
  func testRequestingCoverageWidensTheKeySetToTheAttributesItReads() async throws {
    let bar = AccessibilityTestElementBuilder.staticText(
      withLabel: "Navigation Bar",
      frame: NSRect(x: 0, y: 0, width: 390, height: 422)
    )
    try setUp(
      withRootElement: AccessibilityTestElementBuilder.application(
        withLabel: "App Window",
        frame: NSRect(x: 0, y: 0, width: 390, height: 844),
        children: [bar]
      ))

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    var options = AccessibilityRequestOptions()
    options.keys = [.label]
    options.collectFrameCoverage = true
    let response = try await element.serialize(with: options)
    element.close()

    let coverage = try XCTUnwrap(response.coverage?.frame, "coverage is collected despite the narrow key set")
    XCTAssertEqual(coverage, 0.5, accuracy: 0.01, "the bar covers the upper half; the Application root is skipped")

    let first = try XCTUnwrap((response.legacyElementsObject() as? [Any])?.first as? [String: Any])
    XCTAssertEqual(
      Set(first.keys),
      [AXKeys.label.rawValue, AXKeys.frameDict.rawValue, AXKeys.type.rawValue],
      "the requested key, widened by exactly what the dimensions read: the frame to measure, the type "
        + "identifying the root to skip, and the label `content` counts as perceivable"
    )
  }

  func testAdditionalFrameCoverageIsNilWithoutRemoteContent() async throws {
    try setUp(withRootElement: defaultElementTree)

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)

    var options = AccessibilityRequestOptions()
    options.collectFrameCoverage = true
    let response = try await element.serialize(with: options)
    element.close()
    XCTAssertNotNil(response.coverage?.frame, "coverage should be reported when collectFrameCoverage is enabled")
    XCTAssertNil(response.coverage?.additional, "the additional coverage should be nil when no remote content is discovered")
  }

  func testRemoteContentDiscoveryMergesDiscoveredElement() async throws {
    // The frontmost app (pid 12345) is an AXApplication with no children, so the
    // main traversal marks no coverage. A separate-process element (pid 99999)
    // sits mid-screen and must be found via grid hit-testing and merged into the
    // flat output, with the additional coverage reflecting the newly covered area.
    let appElement = AccessibilityTestElementBuilder.application(
      withLabel: "App",
      frame: NSRect(x: 0, y: 0, width: 390, height: 844),
      children: []
    )
    let remoteElement = AccessibilityTestElementBuilder.button(
      withLabel: "Remote WebView Content",
      identifier: "remote_button",
      frame: NSRect(x: 0, y: 400, width: 390, height: 100)
    )
    try setUp(withRootElement: appElement)

    // Object-at-point hit-testing returns a translation with a distinct pid that
    // maps to the remote element; the frontmost translation (pid 12345) still
    // resolves to the app element.
    let remoteTranslation = AXPTranslationObjectDouble()
    remoteTranslation.pid = 99999
    fixture!.translator.objectAtPointResult = remoteTranslation
    fixture!.translator.macPlatformElementResultsByPid = [99999: remoteElement]

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    var options = AccessibilityRequestOptions()
    options.collectFrameCoverage = true
    var remoteOptions = AccessibilityRemoteContentOptions()
    remoteOptions.gridStepSize = 50
    options.remoteContentOptions = remoteOptions
    let response = try await element.serialize(with: options)
    element.close()

    XCTAssertNotNil(response.coverage?.additional, "the additional coverage should be set when remote content is discovered")

    let elements = response.legacyElementsObject() as! [Any]
    let labels = elements.compactMap { ($0 as? [String: Any])?["AXLabel"] as? String }
    XCTAssertEqual(elements.count, 2, "App element plus one discovered remote element")
    XCTAssertTrue(labels.contains("Remote WebView Content"), "Discovered remote element should be merged into the output")
  }

  // MARK: - The element filter inside the walk

  /// A root whose three children are one keeper and two elements `.interactable` drops — no label, no
  /// identifier, and `StaticText`, which is not an actionable role.
  private func filterableRoot() -> AXPMacPlatformElementDouble {
    AccessibilityTestElementBuilder.application(
      withLabel: "App Window",
      frame: NSRect(x: 0, y: 0, width: 390, height: 844),
      children: [
        AccessibilityTestElementBuilder.button(
          withLabel: "OK", identifier: "ok_button", frame: NSRect(x: 0, y: 0, width: 100, height: 44)
        ),
        AccessibilityTestElementBuilder.staticText(withLabel: "", frame: NSRect(x: 0, y: 100, width: 390, height: 44)),
        AccessibilityTestElementBuilder.staticText(withLabel: "", frame: NSRect(x: 0, y: 200, width: 390, height: 44)),
      ]
    )
  }

  /// Profiles a whole-tree read of `filterableRoot()` under `filter`. Installs the fixture, so it may
  /// be called only once per test — the translator swizzle refuses a second install.
  private func profile(withFilter filter: AccessibilityElementFilter) async throws -> AccessibilityProfile? {
    try setUp(withRootElement: filterableRoot())
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    var options = AccessibilityRequestOptions()
    options.enableProfiling = true
    options.filter = filter
    let response = try await element.serialize(with: options)
    element.close()
    return response.profilingData
  }

  /// Reads `filterableRoot()` under `filter` with coverage on. Installs the fixture, so it may be
  /// called only once per test.
  private func coverage(withFilter filter: AccessibilityElementFilter) async throws -> AccessibilityCoverage? {
    try setUp(withRootElement: filterableRoot())
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    var options = AccessibilityRequestOptions()
    options.collectFrameCoverage = true
    options.filter = filter
    let response = try await element.serialize(with: options)
    element.close()
    return response.coverage
  }

  // Under the default filter nothing is dropped, so the two ratios describe the same set of elements
  // and must agree exactly.
  func testWalkedCoverageEqualsReportedCoverageUnderTheDefaultFilter() async throws {
    let measured = try await coverage(withFilter: .all)
    let coverage = try XCTUnwrap(measured)
    XCTAssertEqual(coverage.walked, coverage.frame, accuracy: 0.0001, "with nothing dropped the two are one number")
    XCTAssertGreaterThan(coverage.frame, 0, "the fixture's children cover part of the screen")
  }

  // Under a filter that drops elements the two diverge, and that gap is the point: `frame` is what the
  // caller receives, `walked` is what was there to receive. The fixture drops two static texts that
  // between them cover more screen than the one button that survives.
  func testWalkedCoverageExceedsReportedCoverageWhenTheFilterDrops() async throws {
    let measured = try await coverage(withFilter: .interactable)
    let coverage = try XCTUnwrap(measured)
    XCTAssertGreaterThan(
      coverage.walked, coverage.frame,
      "the dropped static texts are counted by the walk and not by the report"
    )
  }

  /// A screen shaped like a real one: full-screen containers nesting a little actual content. This is
  /// what saturates a single coverage ratio — the containers alone cover the whole screen — so it is
  /// what the dimensions have to tell apart.
  private func containerHeavyRoot() -> AXPMacPlatformElementDouble {
    let button = AccessibilityTestElementBuilder.button(
      withLabel: "OK", identifier: "ok_button", frame: NSRect(x: 0, y: 0, width: 390, height: 211)
    )
    let innerContainer = AccessibilityTestElementBuilder.staticText(
      withLabel: "", frame: NSRect(x: 0, y: 0, width: 390, height: 844)
    )
    return AccessibilityTestElementBuilder.application(
      withLabel: "App Window",
      frame: NSRect(x: 0, y: 0, width: 390, height: 844),
      children: [
        AccessibilityTestElementBuilder.application(
          withLabel: "Inner", frame: NSRect(x: 0, y: 0, width: 390, height: 844), children: [button, innerContainer]
        )
      ]
    )
  }

  // The point of reporting several ratios: on a container-heavy screen the aggregate one saturates and
  // says nothing, while the dimensions measured over the same walk still discriminate. Here the
  // unlabeled full-screen container fills `walked`, and only the quarter-screen button is interactable.
  func testCoverageDimensionsDiscriminateWhereTheAggregateSaturates() async throws {
    try setUp(withRootElement: containerHeavyRoot())
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    var options = AccessibilityRequestOptions()
    options.format = .nested
    options.collectFrameCoverage = true
    let response = try await element.serialize(with: options)
    element.close()

    let coverage = try XCTUnwrap(response.coverage)
    XCTAssertEqual(coverage.walked, 1.0, accuracy: 0.01, "the full-screen container covers everything")
    XCTAssertEqual(coverage.frame, 1.0, accuracy: 0.01, "nothing was filtered, so the report matches the walk")
    XCTAssertEqual(try XCTUnwrap(coverage.content), 0.25, accuracy: 0.01, "only the labelled button is perceivable content")
    XCTAssertEqual(
      try XCTUnwrap(coverage.leaf), 1.0, accuracy: 0.01,
      "both leaves count — the unlabeled container is childless, so it is one"
    )
  }

  // A flat read carries no `children`, so it cannot say which elements are leaves and declines to guess
  // rather than calling every element one.
  func testLeafAndContentCoverageAreAbsentForAFlatRead() async throws {
    try setUp(withRootElement: containerHeavyRoot())
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    var options = AccessibilityRequestOptions()
    options.format = .default
    options.collectFrameCoverage = true
    let response = try await element.serialize(with: options)
    element.close()

    let coverage = try XCTUnwrap(response.coverage)
    XCTAssertNil(coverage.leaf, "a flat read has no tree structure to read leaves from")
    XCTAssertNil(coverage.content, "content is leaf-based too, so a flat read cannot report it either")
  }

  // The interactable dimension is measured over the walk, so asking to be shown less does not change
  // what it reports — which is the whole reason it exists rather than being reached via `--filter`.
  func testContentCoverageIsIndependentOfTheRequestedFilter() async throws {
    try setUp(withRootElement: containerHeavyRoot())
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    var options = AccessibilityRequestOptions()
    options.format = .nested
    options.collectFrameCoverage = true
    options.filter = .interactable
    let response = try await element.serialize(with: options)
    element.close()

    let coverage = try XCTUnwrap(response.coverage)
    XCTAssertEqual(try XCTUnwrap(coverage.content), 0.25, accuracy: 0.01, "the same number the unfiltered read reports")
    XCTAssertEqual(coverage.frame, 0.25, accuracy: 0.01, "while the reported coverage follows the filter")
    XCTAssertEqual(coverage.walked, 1.0, accuracy: 0.01, "and the walk is unchanged")
  }

  // MARK: - Profiling collector lifetime

  // The dispatcher times both acquisition phases — `perform(withTranslator:)` and
  // `macPlatformElement(fromTranslation:)` — and writes each to `request.collector`, which exists from
  // the moment the request does.
  //
  // The double burns 20 ms in each of those calls, so each phase has 20 ms to report. Asserting a floor
  // rather than a sign is what distinguishes a wired-up measurement from a discarded one.
  func testTheTranslatorProfileReportsAcquisitionTime() async throws {
    try setUp(withRootElement: defaultRoot(withChildren: []))
    fixture!.translator.frontmostApplicationDelay = 0.02

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    defer { element.close() }
    var options = AccessibilityRequestOptions()
    options.enableProfiling = true
    let response = try await element.serialize(with: options)
    let profile = try XCTUnwrap(response.profilingData?.translatorProfile)

    XCTAssertGreaterThanOrEqual(profile.translationDuration, 0.02, "the 20 ms spent resolving the translation is reported")
    XCTAssertEqual(profile.elementConversionDuration, 0, "a raw read builds no element, so there is no conversion to time")
    XCTAssertGreaterThan(profile.serializeDuration, 0, "alongside the phase that was already measured")
    XCTAssertGreaterThanOrEqual(profile.acquireDuration, 0.02, "and the core rolls acquisition up")
  }

  // The mechanism behind the above, pinned directly rather than through a read: a request has somewhere
  // to record from the moment it exists, so every dispatcher measurement taken before `serialize` lands.
  func testARequestBeginsWithACollector() {
    XCTAssertNotNil(AXTranslationRequest(kind: .frontmostApplication).collector)
  }

  // The baseline the filtered read below is measured against: every node serialized.
  func testAllFilterProfileCountsCoverEveryNode() async throws {
    assertProfilingData(try await profile(withFilter: .all), expectedElements: 4, expectedAttributeFetches: 60)
  }

  // The filter does not change what the walk does or costs: both filters serialize all four nodes for
  // the same 60 fetches, and the filter decides afterwards which two are reported. The count matches
  // the unfiltered walk exactly because the filter never requests the verdict it could match on — a
  // verdict that is null on this backend anyway.
  func testInteractableFilterProfileCountsMatchTheUnfilteredWalk() async throws {
    assertProfilingData(try await profile(withFilter: .interactable), expectedElements: 4, expectedAttributeFetches: 60)
  }

  // Remote content is discovered after the walk and appended to the output, and the filter runs over
  // that merged list — an element is kept or dropped on what it is, not on which traversal found it.
  func testRemoteContentDiscoveryHonoursTheElementFilter() async throws {
    let appElement = AccessibilityTestElementBuilder.application(
      withLabel: "App", frame: NSRect(x: 0, y: 0, width: 390, height: 844), children: []
    )
    // Unlabeled, unidentified StaticText — exactly what `.interactable` exists to drop.
    let remoteElement = AccessibilityTestElementBuilder.staticText(
      withLabel: "", frame: NSRect(x: 0, y: 400, width: 390, height: 100)
    )
    try setUp(withRootElement: appElement)

    let remoteTranslation = AXPTranslationObjectDouble()
    remoteTranslation.pid = 99999
    fixture!.translator.objectAtPointResult = remoteTranslation
    fixture!.translator.macPlatformElementResultsByPid = [99999: remoteElement]

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    var options = AccessibilityRequestOptions()
    options.filter = .interactable
    options.collectFrameCoverage = true
    options.remoteContentOptions = AccessibilityRemoteContentOptions(gridStepSize: 50)
    let response = try await element.serialize(with: options)
    element.close()

    XCTAssertNotNil(
      response.coverage?.additional,
      "the element was discovered — its coverage is counted even though the filter then drops it"
    )
    let elements = try XCTUnwrap(response.legacyElementsObject() as? [Any])
    XCTAssertEqual(elements.count, 1, "only the labeled app root survives; the discovered element is filtered out")
  }

  // MARK: - Marker Search Tests (accessibilityElementMatching)

  func testAccessibilityElementMatchingFindsDescendantByLabel() async throws {
    try setUp(withRootElement: defaultElementTree)

    let root = try await simulator.accessibility.resolveElement(for: .frontmost)
    let result = try await root.searchElement(withValue: "OK", forKey: .label, depth: 10)
    let element = try XCTUnwrap(result.match)
    defer { element.close() }
    XCTAssertEqual(result.diagnostics?.unmatchedValues, ["App Window", "Confirm Action"])
    XCTAssertEqual(result.diagnostics?.truncated, false)

    let elementLabel = try await element.stringValue(forSearchableKey: .label)
    XCTAssertEqual(elementLabel, "OK")
  }

  func testAccessibilityElementMatchingFindsByUniqueID() async throws {
    try setUp(withRootElement: defaultElementTree)

    let element = try await simulator.accessibility.resolveElement(for: .marker(value: "cancel_button", key: .uniqueID, depth: 10))
    defer { element.close() }

    let elementLabel = try await element.stringValue(forSearchableKey: .label)
    XCTAssertEqual(elementLabel, "Cancel")
  }

  func testAccessibilityElementMatchingIsSubstringMatch() async throws {
    try setUp(withRootElement: defaultElementTree)

    // "Conf" is a substring of the "Confirm Action" static text label.
    let element = try await simulator.accessibility.resolveElement(for: .marker(value: "Conf", key: .label, depth: 10))
    defer { element.close() }

    let elementLabel = try await element.stringValue(forSearchableKey: .label)
    XCTAssertEqual(elementLabel, "Confirm Action")
  }

  func testAccessibilityElementMatchingMatchesRootAtDepthZero() async throws {
    try setUp(withRootElement: defaultElementTree)

    // depth 0 only inspects the root element itself.
    let element = try await simulator.accessibility.resolveElement(for: .marker(value: "App Window", key: .label, depth: 0))
    defer { element.close() }

    let elementLabel = try await element.stringValue(forSearchableKey: .label)
    XCTAssertEqual(elementLabel, "App Window")
  }

  func testAccessibilityElementMatchingByRoleReturnsFirstDFSMatch() async throws {
    try setUp(withRootElement: defaultElementTree)

    // Root is AXApplication, first child is AXStaticText; the first AXButton in DFS order is "OK".
    let element = try await simulator.accessibility.resolveElement(for: .marker(value: "AXButton", key: .role, depth: 10))
    defer { element.close() }

    let elementLabel = try await element.stringValue(forSearchableKey: .label)
    XCTAssertEqual(elementLabel, "OK")
  }

  func testSearchReturnsNonmatchingIdentifiersOnly() async throws {
    let child = AccessibilityTestElementBuilder.button(
      withLabel: "Unrelated label", identifier: "button_id", frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    try setUp(withRootElement: defaultRoot(withChildren: [child]))
    let root = try await simulator.accessibility.resolveElement(for: .frontmost)
    let result = try await root.searchElement(withValue: "missing", forKey: .uniqueID, depth: 10)
    XCTAssertNil(result.match)
    XCTAssertEqual(result.diagnostics?.unmatchedValues, ["button_id"])
    XCTAssertNil(result.diagnostics?.readError)
  }

  func testALegacyReadReportsTheClientItNamedAndOnlyThen() async throws {
    try setUp(withRootElement: defaultElementTree)
    let reader = AccessibilityUIAutomation(simulator: simulator, transport: .bridge)

    let named = try await reader.describe(.frontmost, options: AccessibilityRequestOptions(format: .complete, clientType: .xctest))
    XCTAssertEqual(named.client, AccessibilityClientReport(clientType: .xctest))
    let clientTypes = fixture!.device.accessibilityRequests.compactMap { AccessibilityTranslatorRequests.clientType(of: $0) }
    XCTAssertFalse(clientTypes.isEmpty)
    XCTAssertEqual(Set(clientTypes), [AXClientType.xctest.rawValue], "every request the read sends carries the client")

    let unnamed = try await reader.describe(.frontmost, options: AccessibilityRequestOptions(format: .complete))
    XCTAssertNil(unnamed.client)
  }

  func testLegacyWaitCarriesTheTraversalNonmatches() async throws {
    try setUp(withRootElement: defaultElementTree)
    let reader = AccessibilityUIAutomation(simulator: simulator, transport: .bridge)
    do {
      try await reader.wait(.marker(value: "missing", key: .label, depth: 10), timeout: 0, pollInterval: 0)
      XCTFail("a missing label must time out")
    } catch let UIAutomationError.timedOut(_, _, _, _, diagnostics) {
      XCTAssertEqual(diagnostics?.unmatchedValues, ["App Window", "Confirm Action", "OK", "Cancel"])
      XCTAssertNil(diagnostics?.readError)
    }
    try await reader.wait(.marker(value: "OK", key: .label, depth: 10), timeout: 0, pollInterval: 0)
  }

  func testAccessibilityElementMatchingNotFoundThrows() async throws {
    try setUp(withRootElement: defaultElementTree)

    do {
      let element = try await simulator.accessibility.resolveElement(for: .marker(value: "DefinitelyMissing", key: .label, depth: 10))
      element.close()
      XCTFail("Expected matching to throw for a missing element")
    } catch {
      XCTAssertTrue(
        "\(error)".contains("not found"),
        "Expected a not-found error, got: \(error)"
      )
    }
  }

  func testAccessibilityElementMatchingRespectsDepthBound() async throws {
    // Build a tree where the target is two levels below the root:
    // root -> container -> deepButton
    let deepButton = AccessibilityTestElementBuilder.button(
      withLabel: "Deep",
      identifier: "deep_id",
      frame: NSRect(x: 0, y: 0, width: 10, height: 10)
    )
    let container = AccessibilityTestElementBuilder.application(
      withLabel: "Container",
      frame: NSRect(x: 0, y: 0, width: 390, height: 844),
      children: [deepButton]
    )
    let root = AccessibilityTestElementBuilder.application(
      withLabel: "App Window",
      frame: NSRect(x: 0, y: 0, width: 390, height: 844),
      children: [container]
    )
    try setUp(withRootElement: root)

    let shallowRoot = try await simulator.accessibility.resolveElement(for: .frontmost)
    let shallow = try await shallowRoot.searchElement(withValue: "Deep", forKey: .label, depth: 1)
    XCTAssertNil(shallow.match)
    XCTAssertEqual(shallow.diagnostics?.unmatchedValues, ["App Window", "Container"])

    let deepRoot = try await simulator.accessibility.resolveElement(for: .frontmost)
    let deep = try await deepRoot.searchElement(withValue: "Deep", forKey: .label, depth: 2)
    XCTAssertEqual(deep.diagnostics?.unmatchedValues, ["App Window", "Container"])
    let found = try XCTUnwrap(deep.match)
    defer { found.close() }
    let foundLabel = try await found.stringValue(forSearchableKey: .label)
    XCTAssertEqual(foundLabel, "Deep")
  }

  /// The `complete` document as untyped Foundation — what a consumer parsing the emitted JSON sees.
  private static func documentObject(_ response: AccessibilityElementsResponse) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(response.document),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }
    return object
  }

  // MARK: - Serialize-to-Data Golden / Envelope Tests

  func testSerializedEnvelopeDefaultContainsOnlyElements() async throws {
    try setUp(withRootElement: defaultElementTree)
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    let response = try await element.serialize(with: AccessibilityRequestOptions())
    element.close()

    let dict = try response.legacyEnvelopeObject()
    XCTAssertEqual(Set(dict.keys), ["elements"], "Default envelope must carry elements only")
  }

  // Profiling is reported by the `complete` document, not the legacy envelope: the envelope's bytes are
  // frozen, so a caller asking for timings gets them by asking for the format that can carry them.
  func testCompleteDocumentWithProfilingContainsProfile() async throws {
    try setUp(withRootElement: defaultElementTree)
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    var options = AccessibilityRequestOptions(format: .complete)
    options.enableProfiling = true
    let response = try await element.serialize(with: options)
    element.close()

    XCTAssertEqual(Set(try response.legacyEnvelopeObject().keys), ["elements"], "the legacy envelope never carries profiling")

    let dict = Self.documentObject(response)
    let profile = try XCTUnwrap(dict["profile"] as? [String: Any])
    XCTAssertEqual(
      Set(profile.keys),
      [
        // The core, spelled the same on every backend.
        "element_count",
        "total_duration_ms",
        "acquire_duration_ms",
        "read_duration_ms",
        "serialize_duration_ms",
        // Translator-only fields.
        "attribute_fetch_count",
        "xpc_call_count",
        "translation_duration_ms",
        "element_conversion_duration_ms",
        "total_xpc_duration_ms",
      ],
      "Profile envelope keys changed"
    )
  }

  func testBothBackendsSpellTheProfileCoreTheSameWay() throws {
    let translator = AccessibilityElementsResponse(
      elements: .tree([]),
      profilingData: .translator(
        AccessibilityProfilingData(
          elementCount: 1, totalDuration: 1, acquireDuration: 0.5, readDuration: 0.25,
          serializeDuration: 0.25, attributeFetchCount: 1, xpcCallCount: 1, translationDuration: 0.5,
          elementConversionDuration: 0, totalXPCDuration: 0.25, fetchedKeys: []
        ))
    )
    let guestBridge = AccessibilityElementsResponse(
      elements: .tree([]),
      profilingData: .guestBridge(
        AXBridgeProfile(
          elementCount: 1, totalDuration: 1, acquireDuration: 0.5, readDuration: 0.25,
          serializeDuration: 0.25, traversal: .viewHierarchy
        ))
    )
    let core: Set<String> = [
      "element_count", "total_duration_ms", "acquire_duration_ms", "read_duration_ms", "serialize_duration_ms",
    ]
    for response in [translator, guestBridge] {
      let profile = try XCTUnwrap(Self.documentObject(response)["profile"] as? [String: Any])
      XCTAssertTrue(
        core.isSubset(of: Set(profile.keys)),
        "the core is missing from \(String(describing: response.profilingData)): \(core.subtracting(Set(profile.keys)))"
      )
    }
  }

  func testCompleteDocumentWithCoverageContainsCoverage() async throws {
    try setUp(withRootElement: defaultElementTree)
    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    var options = AccessibilityRequestOptions(format: .complete)
    options.collectFrameCoverage = true
    let response = try await element.serialize(with: options)
    element.close()

    XCTAssertEqual(Set(try response.legacyEnvelopeObject().keys), ["elements"], "the legacy envelope never carries coverage")

    let coverage = try XCTUnwrap(Self.documentObject(response)["coverage"] as? [String: Any])
    XCTAssertNotNil(coverage["frame"], "Coverage must carry frame")
    XCTAssertTrue(coverage["additional"] is NSNull, "No remote content -> additional is null, but keeps its key")
  }

  // MARK: - SpringBoard diagnosis (zero-framed root)

  func testFrontmostReportsSpringBoardNotRunningWhenZeroFramedRootPidIsDead() async throws {
    // A zero-framed root whose owning pid (12345) is not a live launchd service, with no SpringBoard running.
    let zeroFrameRoot = AccessibilityTestElementBuilder.application(withLabel: "App", frame: .zero, children: [])
    let launchCtl = LaunchCtlDouble.with(running: [:])
    try setUp(withRootElement: zeroFrameRoot, launchCtl: launchCtl)

    do {
      let element = try await simulator.accessibility.resolveElement(for: .frontmost)
      element.close()
      XCTFail("Expected springBoardNotRunning")
    } catch AccessibilityError.springBoardNotRunning {}
  }

  func testAZeroFramedRootWhoseProcessExitedWhileSpringBoardIsFreshlyRunning() async throws {
    // The root names a process (12345) that has exited, and SpringBoard is running under a new pid (4242): the
    // state the simulator's accessibility service is in for a few seconds after SpringBoard restarts.
    let zeroFrameRoot = AccessibilityTestElementBuilder.application(withLabel: "App", frame: .zero, children: [])
    let launchCtl = LaunchCtlDouble.with(running: ["com.apple.SpringBoard": 4242])
    try setUp(withRootElement: zeroFrameRoot, launchCtl: launchCtl, processesStarted: [4242: Date().addingTimeInterval(-2)])

    do {
      let element = try await simulator.accessibility.resolveElement(for: .frontmost)
      element.close()
      XCTFail("Expected springBoardRestarting")
    } catch let AccessibilityError.springBoardRestarting(exitedProcessIdentifier, restartedAgo) {
      XCTAssertEqual(exitedProcessIdentifier, 12345)
      XCTAssertEqual(restartedAgo, 2, accuracy: 1)
    }
  }

  func testAZeroFramedRootWhoseProcessExitedWhileSpringBoardHasBeenRunning() async throws {
    // The root names a process (12345) that has exited, and SpringBoard (4243) has been running all along: an
    // application exited, which is not a SpringBoard condition.
    let zeroFrameRoot = AccessibilityTestElementBuilder.application(withLabel: "App", frame: .zero, children: [])
    let launchCtl = LaunchCtlDouble.with(running: ["com.apple.SpringBoard": 4243])
    try setUp(withRootElement: zeroFrameRoot, launchCtl: launchCtl, processesStarted: [4243: Date().addingTimeInterval(-3600)])

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    defer { element.close() }

    let response = try await element.serialize(with: AccessibilityRequestOptions())
    XCTAssertEqual(response.translatorMetrics?.elementCount, 1, "read as it is: not a SpringBoard condition")
  }

  func testAZeroFramedRootWhoseProcessIsLiveIsReadAsItIs() async throws {
    // A zero frame alone is not stale: the owning pid is still a live service.
    let zeroFrameRoot = AccessibilityTestElementBuilder.application(withLabel: "App", frame: .zero, children: [])
    let launchCtl = LaunchCtlDouble.with(running: ["com.apple.SpringBoard": 12345])
    try setUp(withRootElement: zeroFrameRoot, launchCtl: launchCtl)

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    defer { element.close() }

    let response = try await element.serialize(with: AccessibilityRequestOptions())
    XCTAssertEqual(response.translatorMetrics?.elementCount, 1, "a live pid means the hierarchy is healthy")
  }

  func testAZeroFramedRootWhoseProcessTheHostSeesRunningIsReadWithoutLaunchCtl() async throws {
    // launchctl lists nothing, which would report SpringBoard as not running, but the host sees 12345 running.
    let zeroFrameRoot = AccessibilityTestElementBuilder.application(withLabel: "App", frame: .zero, children: [])
    try setUp(withRootElement: zeroFrameRoot, launchCtl: LaunchCtlDouble.with(running: [:]), processesRunning: [12345])

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    defer { element.close() }

    let response = try await element.serialize(with: AccessibilityRequestOptions())
    XCTAssertEqual(response.translatorMetrics?.elementCount, 1, "a running process means the hierarchy is healthy")
  }

  // MARK: - Frontmost nil-translation (describe-all SpringBoard-down classification)

  func testFrontmostDescribeAllReturnsSpringBoardNotRunningWhenSpringBoardDown() async throws {
    try setUp(withRootElement: defaultElementTree, launchCtl: LaunchCtlDouble.with(running: [:]))
    fixture!.translator.frontmostApplicationResult = nil

    do {
      let element = try await simulator.accessibility.resolveElement(for: .frontmost)
      element.close()
      XCTFail("Expected springBoardNotRunning")
    } catch AccessibilityError.springBoardNotRunning {
      // Expected: the describe-all failure is re-classified to the precise root cause.
    }
  }

  func testFrontmostDescribeAllStaysNoTranslationObjectWhenSpringBoardRunning() async throws {
    // SpringBoard is up, so a nil translation is some other failure (e.g. a transient) — unchanged.
    try setUp(withRootElement: defaultElementTree, launchCtl: LaunchCtlDouble.with(running: ["com.apple.SpringBoard": 4321]))
    fixture!.translator.frontmostApplicationResult = nil

    do {
      let element = try await simulator.accessibility.resolveElement(for: .frontmost)
      element.close()
      XCTFail("Expected noTranslationObject")
    } catch let error as AccessibilityError {
      // Re-classification fires only when SpringBoard is confirmed down.
      guard case .noTranslationObject = error else {
        return XCTFail("Expected noTranslationObject, got \(error)")
      }
      XCTAssertEqual(error.errorDescription, "The simulator's accessibility service named no frontmost application")
    }
  }

  func testAtPointDescribeStaysNoTranslationObjectWhenTranslationIsNil() async throws {
    try setUp(withRootElement: defaultElementTree)
    // The at-point path can legitimately specify an invalid point, so it is never re-classified.
    fixture!.translator.objectAtPointResult = nil

    do {
      let element = try await simulator.accessibility.resolveElement(for: .point(CGPoint(x: 10, y: 10)))
      element.close()
      XCTFail("Expected noTranslationObject")
    } catch let error as AccessibilityError {
      // The point path is never re-classified, whatever SpringBoard's state.
      guard case .noTranslationObject = error else {
        return XCTFail("Expected noTranslationObject, got \(error)")
      }
      XCTAssertEqual(
        error.errorDescription,
        "No accessibility element at (10.0, 10.0): the point may be off-screen or covered by a fullscreen dialog")
    }
  }

  // MARK: - Frontmost pid

  func testResolveFrontmostElementExposesProcessIdentifier() async throws {
    let root = AccessibilityTestElementBuilder.application(withLabel: "App", frame: CGRect(x: 0, y: 0, width: 100, height: 100), children: [])
    try setUp(withRootElement: root)

    let element = try await simulator.accessibility.resolveElement(for: .frontmost)
    defer { element.close() }

    XCTAssertEqual(element.processIdentifier, 12345, "the resolved frontmost element must expose the backing app's pid")
  }

  func testResolveApplicationByPidExposesProcessIdentifier() async throws {
    // A by-pid target reads that specific app (regardless of what is frontmost), surfacing its pid. The service
    // answers the application-object request.
    let root = AccessibilityTestElementBuilder.application(withLabel: "App", frame: CGRect(x: 0, y: 0, width: 100, height: 100), children: [])
    let transport = AXTranslationTransportDouble(root: AXPTranslationObjectDouble(pid: 777, objectID: 0))
    try setUp(withRootElement: root, transport: transport)

    let element = try await simulator.accessibility.resolveElement(for: .application(pid: 777))
    defer { element.close() }

    XCTAssertEqual(element.processIdentifier, 777, "a by-pid resolve reads the app with that pid")
    XCTAssertEqual(transport.requests.map(\.requestType), [1], "one application-object request reaches the transport")
    XCTAssertEqual(transport.requests.first?.parameters?[BridgeAXTranslatorRequestType.pidParameterKey] as? NSNumber, 777)
  }

  // MARK: - Concurrent access to the shared translator

  func testConcurrentActionsEnterTheSharedTranslatorOneAtATime() async throws {
    let ok = defaultOkButton
    let cancel = defaultCancelButton
    try setUp(withRootElement: defaultRoot(withChildren: [defaultTitleLabel, ok, cancel]))
    let tracker = TranslatorEntryTracker()
    ok.pressHook = { tracker.enter() }
    cancel.pressHook = { tracker.enter() }
    let sim = simulator!
    let okMatch = try await sim.accessibility.resolveElement(for: .marker(value: "OK", key: .label, depth: 10, ignoresCase: false))
    let cancelMatch = try await sim.accessibility.resolveElement(for: .marker(value: "Cancel", key: .label, depth: 10, ignoresCase: false))
    defer {
      okMatch.close()
      cancelMatch.close()
    }

    async let first: Void = okMatch.tap()
    async let second: Void = cancelMatch.tap()
    _ = try await (first, second)

    // The translator singleton's internal state is not synchronized, so an action — which goes through the
    // translator's platform element — runs on its one serial queue, even with the first held open waiting
    // for a peer.
    XCTAssertEqual(tracker.maxActive, 1, "actions enter the shared translator strictly one at a time")
  }

  func testConcurrentRawResolutionsDoNotWaitForEachOther() async throws {
    try setUp(withRootElement: defaultElementTree)
    let tracker = TranslatorEntryTracker()
    fixture!.translator.resolutionEnterHook = { tracker.enter() }

    let sim = simulator!
    async let first = sim.accessibility.resolveElement(for: .frontmost)
    async let second = sim.accessibility.resolveElement(for: .frontmost)
    let elements = try await [first, second]
    for element in elements {
      element.close()
    }

    // A raw resolution touches only the transport, not the translator singleton whose work is serialized
    // onto one queue, so the first, held open waiting for a peer, is joined by the second.
    XCTAssertEqual(tracker.maxActive, 2, "raw resolutions run alongside each other")
  }

  // MARK: - Marker search

  /// `App Window` → [`Outer` → [`OK nested`], `OK`]: the nested match comes first depth-first, the shallow one
  /// first breadth-first, so which one a search returns says how it walked.
  private var markerSearchTree: AXPMacPlatformElementDouble {
    let nested = AccessibilityTestElementBuilder.button(
      withLabel: "OK nested", identifier: "ok_nested", frame: NSRect(x: 20, y: 300, width: 150, height: 44))
    let outer = AccessibilityTestElementBuilder.element(
      withLabel: "Outer", frame: NSRect(x: 0, y: 200, width: 390, height: 200), children: [nested])
    let shallow = AccessibilityTestElementBuilder.button(
      withLabel: "OK", identifier: "ok_button", frame: NSRect(x: 20, y: 750, width: 150, height: 44))
    return defaultRoot(withChildren: [outer, shallow])
  }

  private func markerMatchLabel(_ element: AccessibilityElement) async throws -> String? {
    var options = AccessibilityRequestOptions()
    options.keys = [.label]
    let response = try await element.serialize(with: options)
    guard case let .single(match) = response.elements else {
      XCTFail("a marker read yields one element, got \(response.elements)")
      return nil
    }
    return match.label ?? nil
  }

  func testMarkerResolvesTheFirstContainingMatchDepthFirst() async throws {
    try setUp(withRootElement: markerSearchTree)
    let element = try await simulator.accessibility.resolveElement(
      for: .marker(value: "OK", key: .label, depth: 10, ignoresCase: false))
    defer { element.close() }

    let label = try await markerMatchLabel(element)
    XCTAssertEqual(label, "OK", "an element equal to the marker wins over an earlier one that only contains it")
  }

  func testMarkerDoesNotDescendPastItsDepth() async throws {
    try setUp(withRootElement: markerSearchTree)
    let element = try await simulator.accessibility.resolveElement(
      for: .marker(value: "OK", key: .label, depth: 1, ignoresCase: false))
    defer { element.close() }

    let label = try await markerMatchLabel(element)
    XCTAssertEqual(label, "OK", "a depth of one reaches the root's children and no further")
  }

  func testMarkerMatchCarriesTheRootFrameAndReadsItsOwnValues() async throws {
    try setUp(withRootElement: markerSearchTree)
    let element = try await simulator.accessibility.resolveElement(
      for: .marker(value: "ok_button", key: .uniqueID, depth: 10, ignoresCase: false))
    defer { element.close() }

    XCTAssertEqual(element.rootBounds, CGRect(x: 0, y: 0, width: 390, height: 844), "the root's frame, read before ownership passed")
    let frame = try await element.frame()
    XCTAssertEqual(frame, CGRect(x: 20, y: 750, width: 150, height: 44))
    let label = try await element.stringValue(forSearchableKey: .label)
    XCTAssertEqual(label, "OK")
  }

  func testMarkerMissThrowsNotFoundWithItsDepth() async throws {
    try setUp(withRootElement: markerSearchTree)
    do {
      let element = try await simulator.accessibility.resolveElement(
        for: .marker(value: "Missing", key: .label, depth: 10, ignoresCase: false))
      element.close()
      XCTFail("a marker matching nothing should throw")
    } catch AccessibilityError.elementNotFound(let key, let value, let depth) {
      XCTAssertEqual(key, "AXLabel")
      XCTAssertEqual(value, "Missing")
      XCTAssertEqual(depth, 10)
    }
  }

  func testSearchRecordsTheNonmatchingValuesItVisitedBeforeTheMatch() async throws {
    try setUp(withRootElement: markerSearchTree)
    let root = try await simulator.accessibility.resolveElement(for: .frontmost)
    let result = try await root.searchElement(withValue: "nested", forKey: .label, depth: 10)
    defer { result.match?.close() }

    XCTAssertNotNil(result.match)
    XCTAssertEqual(result.diagnostics?.unmatchedValues, ["App Window", "Outer"])
  }

  func testSearchReadsTheTreeToItsDepthBeforeMatching() async throws {
    let shallow = AccessibilityTestElementBuilder.button(
      withLabel: "OK", identifier: "ok_button", frame: NSRect(x: 20, y: 750, width: 150, height: 44))
    let nested = AccessibilityTestElementBuilder.button(
      withLabel: "OK nested", identifier: "ok_nested", frame: NSRect(x: 20, y: 300, width: 150, height: 44))
    let outer = AccessibilityTestElementBuilder.element(
      withLabel: "Outer", frame: NSRect(x: 0, y: 200, width: 390, height: 200), children: [nested])
    try setUp(withRootElement: defaultRoot(withChildren: [outer, shallow]))
    let element = try await simulator.accessibility.resolveElement(
      for: .marker(value: "nested", key: .label, depth: 10, ignoresCase: false))
    defer { element.close() }

    XCTAssertTrue(
      rawRequests(naming: shallow).contains { $0.contains(.label) },
      "the sibling after the match is read with the rest of the tree; the match is still the first one")
  }

  func testSearchMissRecordsEveryValueItVisited() async throws {
    try setUp(withRootElement: markerSearchTree)
    let root = try await simulator.accessibility.resolveElement(for: .frontmost)
    let result = try await root.searchElement(withValue: "Missing", forKey: .label, depth: 10)

    XCTAssertNil(result.match)
    XCTAssertEqual(result.diagnostics?.unmatchedValues, ["App Window", "Outer", "OK nested", "OK"])
  }
}

/// Counts how many resolutions are inside the translator at once. `enter()` brackets
/// the translator call: the first caller is held until a peer arrives (or the bounded
/// wait elapses), giving an overlap every chance to be observed — so a serialized
/// implementation shows `maxActive == 1` deterministically rather than by lucky timing.
private final class TranslatorEntryTracker: @unchecked Sendable {
  private let lock = NSLock()
  private let peerArrived = DispatchSemaphore(value: 0)
  private var active = 0
  private(set) var maxActive = 0

  func enter() {
    lock.lock()
    active += 1
    maxActive = max(maxActive, active)
    let sawPeer = active >= 2
    lock.unlock()
    if sawPeer {
      peerArrived.signal()
    } else {
      _ = peerArrived.wait(timeout: .now() + 2.0)
    }
    lock.lock()
    active -= 1
    lock.unlock()
  }
}
