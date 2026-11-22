/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorAX
import FBSimulatorBridgeProtocol
@testable import FBSimulatorControl
import XCTest

/// Reads a real accessibility tree out of the provided simulator through the accessibility-translation
/// backend: the host's `AXPTranslator`, answered by CoreSimulatorBridge inside the simulator. The
/// doubles-backed suites cover serialization; nothing else walks a live tree on this backend.
///
/// Reads the frontmost application, the path `describe-all` takes: the translator resolves it through
/// CoreSimulatorBridge itself, so unlike the axbridge suite this needs no window server.
final class AXTranslationSmokeTests: ProvidedSimulatorTestCase {

  private static let bundleID = "com.apple.Preferences"

  private func launchApplication() async throws {
    let simulator = self.simulator!
    let configuration = ApplicationLaunchConfiguration(
      bundleID: Self.bundleID,
      bundleName: nil,
      arguments: [],
      environment: [:],
      waitForDebugger: false,
      launchMode: .foregroundIfRunning)
    _ = try await simulator.application.launch(configuration)
    addTeardownBlock {
      // Leased-resource discipline: this suite may not own the simulator, so it leaves behind only
      // what it found.
      try? await simulator.application.kill(bundleID: Self.bundleID)
    }
  }

  /// Retries a read with no application object or nothing beneath its root, while the freshly launched
  /// application's accessibility server starts. Any other failure throws on the first attempt.
  private func describeFrontmost(retries: Int = 4) async throws -> AccessibilityElementsResponse {
    let automation = try simulator.uiAutomation(backend: .accessibility)
    let options = AccessibilityRequestOptions()
    for attempt in 0...retries {
      do {
        let response = try await automation.describe(.frontmost, options: options)
        if response.elements.elements.count > 1 || attempt == retries {
          return response
        }
      } catch AccessibilityError.noTranslationObject where attempt < retries {}
      try await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
    }
    preconditionFailure("The retry loop returns or throws")
  }

  func testTranslatorReadsElementTree() async throws {
    try await launchApplication()
    let response = try await describeFrontmost()

    let elements = response.elements.elements
    XCTAssertGreaterThan(elements.count, 1, "The application should serialize more than its root")
    XCTAssertEqual(response.backend, .ax)

    let types = elements.compactMap { $0.type ?? nil }
    XCTAssertTrue(
      types.contains("Application"),
      "Expected an application element in the tree, got types: \(Set(types).sorted().prefix(10))")

    let screen = try XCTUnwrap(response.screen, "A tree read should report the screen it was taken against")
    XCTAssertGreaterThan(screen.width, 0)
    XCTAssertGreaterThan(screen.height, 0)
    let frames = elements.compactMap { $0.frame ?? nil }
    XCTAssertTrue(
      frames.contains { ($0.width ?? 0) > 0 && ($0.height ?? 0) > 0 },
      "At least one element should cover a non-empty area")
  }

  /// The two host backends must read the same tree: `ax` over idb's connection to CoreSimulatorBridge, and
  /// `ax-coresimulator` through CoreSimulator's own client to the same service. Each reports its own name.
  func testBothHostBackendsReadTheSameTree() async throws {
    try await launchApplication()
    _ = try await describeFrontmost()

    let ax = try simulator.uiAutomation(backend: .accessibility)
    let coreSimulator = try simulator.uiAutomation(backend: .coreSimulatorAccessibility)
    for clientType in [AXClientType.noClient, .xctest] {
      func read(_ automation: any UIAutomation, as name: UIAutomationBackendName) async throws -> [AccessibilityDocumentElement] {
        let response = try await automation.describe(
          .frontmost, options: AccessibilityRequestOptions(keys: Self.comparedKeys, clientType: clientType))
        XCTAssertEqual(response.backend, name)
        return response.elements.elements
      }
      try await assertSettledReadsAgree(
        expected: { try await read(coreSimulator, as: .axCoreSimulator) }, actual: { try await read(ax, as: .ax) },
        "client \(clientType)")
    }
  }

  /// A process that holds its connection to CoreSimulatorBridge across a restart of the bridge, as the companion
  /// does, must read straight after the restart, not merely on a later attempt. Element handles from before the
  /// restart are not reused — the restarted bridge's translator knows none of them — so the read resolves its
  /// root afresh.
  func testTheFirstReadAfterCoreSimulatorBridgeRestartsSucceeds() async throws {
    try await launchApplication()
    _ = try await describeFrontmost()

    let commands = SimulatorAccessibilityCommands(
      simulator: simulator, transport: CoreSimulatorBridgeAXTranslationTransport(connector: .simulator(simulator)))
    func read() async throws -> Int {
      let element = try await commands.resolveElement(for: .frontmost, clientType: .noClient)
      defer { element.close() }
      return try await element.serialize(with: AccessibilityRequestOptions()).elements.elements.count
    }
    let before = try await read()
    XCTAssertGreaterThan(before, 1, "the connection is established and reads before the restart")

    _ = try await simulator.launchCtl.stopService(withName: "com.apple.CoreSimulator.bridge")

    let after = try await read()
    XCTAssertGreaterThan(after, 1, "the first read after the restart reaches the restarted bridge")
  }

  /// After SpringBoard restarts, frontmost reads must come back to a live root on their own: a running process,
  /// with a frame, not the SpringBoard that died. Each observation is attached so a failure shows whether the
  /// read stuck on the dead process.
  func testFrontmostRecoversAfterSpringBoardRestarts() async throws {
    try await launchApplication()
    _ = try await describeFrontmost()
    try SimulatorControlFrameworkLoader.accessibilityFrameworks.loadPrivateFrameworks(simulator.logger)
    let launchCtl = simulator.launchCtl
    let transport = CoreSimulatorBridgeAXTranslationTransport(connector: .simulator(simulator))
    let dispatcher = simulator.accessibilityTranslationDispatcher
    func observe() async -> AXElementSnapshot? {
      let request = AXTranslationRequest(kind: .frontmostApplication, clientType: .noClient, transport: transport)
      defer { dispatcher.popRequest(request) }
      guard let root = try? await dispatcher.rootHandle(withRequest: request) else {
        return nil
      }
      return try? await dispatcher.performUnserialized(cancelling: request.cancellation) {
        try request.snapshot(of: root, plan: AXReadPlan(attributes: [], depth: .limited(1)))
      }
    }
    func springBoardPid() async throws -> pid_t? {
      try await launchCtl.listServices()["com.apple.SpringBoard"] ?? nil
    }
    var log: [String] = []
    func record(_ line: String) {
      log.append(line)
    }
    defer {
      add(XCTAttachment(string: log.joined(separator: "\n")))
    }

    // On the home screen SpringBoard is itself the frontmost application, which is where a restart was seen to
    // leave reads answering for the process that died.
    try await simulator.application.kill(bundleID: Self.bundleID)
    try await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
    let currentSpringBoard = try await springBoardPid()
    let deadSpringBoard = try XCTUnwrap(currentSpringBoard)
    let observed = await observe()
    let before = try XCTUnwrap(observed, "frontmost resolves before SpringBoard restarts")
    XCTAssertEqual(before.pid, deadSpringBoard, "SpringBoard is frontmost on the home screen")
    record("before: springboard=\(deadSpringBoard) root pid=\(before.pid) frame=\(before.frame) children=\(before.children.count)")
    _ = try await launchCtl.stopService(withName: "com.apple.SpringBoard")

    let start = Date()
    func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(start)) }
    var newSpringBoard: pid_t?
    while Date().timeIntervalSince(start) < 60 {
      if let pid = try await springBoardPid(), pid != deadSpringBoard {
        newSpringBoard = pid
        break
      }
      try await Task.sleep(nanoseconds: 250 * NSEC_PER_MSEC)
    }
    record("\(elapsed()) springboard replaced: \(newSpringBoard.map { "\($0)" } ?? "not within 60s")")
    _ = try XCTUnwrap(newSpringBoard, "launchd relaunches SpringBoard")

    var recovered: AXElementSnapshot?
    while Date().timeIntervalSince(start) < 90 {
      let root = await observe()
      var live = false
      if let root {
        live = try await launchCtl.processIsRunning(processIdentifier: root.pid)
      }
      record("\(elapsed()) root " + (root.map { "pid=\($0.pid) live=\(live) frame=\($0.frame) children=\($0.children.count)" } ?? "none"))
      if let root, live, root.pid != deadSpringBoard, root.frame != .zero {
        recovered = root
        break
      }
      try await Task.sleep(nanoseconds: 500 * NSEC_PER_MSEC)
    }
    XCTAssertNotNil(recovered, "a frontmost read reaches a live root again")
  }

  private static let comparedKeys = AXKeys.defaultSet.union([.expanded, .placeholder, .hidden, .focused])

  /// Asserts `actual` reports what `expected` does. The application may still be settling, so the comparison
  /// is made only across a window in which two `expected` reads agree: the `actual` read between them then
  /// saw the same tree. Element by element, so a mismatch names the element rather than printing two trees.
  private func assertSettledReadsAgree(
    expected: () async throws -> [AccessibilityDocumentElement],
    actual: () async throws -> [AccessibilityDocumentElement],
    _ context: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    var settled: (actual: [AccessibilityDocumentElement], expected: [AccessibilityDocumentElement])?
    for _ in 0..<5 {
      let before = try await expected()
      let candidate = try await actual()
      let after = try await expected()
      if before == after {
        settled = (candidate, after)
        break
      }
      try await Task.sleep(nanoseconds: NSEC_PER_SEC)
    }
    let (actualElements, expectedElements) = try XCTUnwrap(
      settled, "\(context): the tree never held still between two reads", file: file, line: line)
    XCTAssertGreaterThan(expectedElements.count, 1, context, file: file, line: line)
    XCTAssertEqual(actualElements.count, expectedElements.count, context, file: file, line: line)
    for (index, (actualElement, expectedElement)) in zip(actualElements, expectedElements).enumerated() {
      XCTAssertEqual(actualElement, expectedElement, "\(context), element \(index)", file: file, line: line)
    }
  }
}
