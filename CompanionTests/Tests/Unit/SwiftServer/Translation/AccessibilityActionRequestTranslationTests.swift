/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import CoreGraphics
@preconcurrency import FBControlCore
import FBSimulatorAX
@preconcurrency import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import XCTest

/// Pins the `accessibility_action` request → action translation: which handler a request reaches,
/// what each endpoint resolves to, which requests are refused, and the sentence a non-simulator
/// target is refused with. A request that stops being refused is the dangerous direction -- it
/// reaches the simulator and does something the caller did not ask for.
final class AccessibilityActionRequestTranslationTests: XCTestCase {

  private func action(
    _ mutate: (inout Idb_AccessibilityActionRequest) -> Void
  ) throws -> AccessibilityActionRequestTranslation.Action {
    var request = Idb_AccessibilityActionRequest()
    mutate(&request)
    return try AccessibilityActionRequestTranslation.action(from: request)
  }

  /// A drag between two points far enough apart that the default delta is legal.
  private func drag(
    _ mutate: (inout Idb_AccessibilityActionRequest) -> Void = { _ in }
  ) throws -> AccessibilityActionRequestTranslation.Action {
    try action {
      $0.point = .with { point in
        point.x = 10
        point.y = 20
      }
      $0.drag = .with { drag in
        drag.point = .with { point in
          point.x = 200
          point.y = 20
        }
      }
      mutate(&$0)
    }
  }

  private func assertRejected(
    _ mutate: (inout Idb_AccessibilityActionRequest) -> Void,
    mentioning fragment: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try drag(mutate), file: file, line: line) { error in
      guard let status = error as? RPCError else {
        return XCTFail("expected a RPCError, got \(error)", file: file, line: line)
      }
      XCTAssertEqual(status.code, .invalidArgument, file: file, line: line)
      let message = status.message ?? ""
      XCTAssertTrue(
        message.contains(fragment), "\"\(message)\" does not mention \(fragment)", file: file, line: line)
    }
  }

  func testWaitPreservesMarkerBackendAndTiming() throws {
    let translated = try action {
      $0.marker = "com.apple.settings.general"
      $0.matchKey = .uniqueID
      $0.depth = 12
      $0.wait = .with {
        $0.backend = .axbridge
        $0.timeout = 30
        $0.pollInterval = 0.25
      }
    }
    XCTAssertEqual(
      translated,
      .wait(
        query: .marker(value: "com.apple.settings.general", key: .uniqueID, depth: 12),
        backend: UIAutomationBackend(resolvedName: .axBridgeExclusive), timeout: 30, pollInterval: 0.25))
  }

  func testWaitRejectsInvalidRequests() {
    var valid = Idb_AccessibilityActionRequest.with {
      $0.marker = "Settings"
      $0.wait = .with {
        $0.timeout = 10
        $0.pollInterval = 0.5
      }
    }
    var invalid = [Idb_AccessibilityActionRequest]()
    for duration in [-1, Double.nan, Double.infinity] {
      var request = valid
      request.wait.timeout = duration
      invalid.append(request)
    }
    for interval in [0, -1, Double.nan, Double.infinity, 1e20] {
      var request = valid
      request.wait.pollInterval = interval
      invalid.append(request)
    }
    var request = valid
    request.target = nil
    invalid.append(request)
    request = valid
    request.point = .init()
    invalid.append(request)
    request = valid
    request.ignoreCase = true
    invalid.append(request)
    valid.wait.backend = .UNRECOGNIZED(99)
    invalid.append(valid)
    for request in invalid {
      XCTAssertThrowsError(try AccessibilityActionRequestTranslation.action(from: request)) { error in
        XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
      }
    }
  }

  func testWaitDistinguishesFoundTimeoutAndFailure() async throws {
    let found = try await AccessibilityActionRequestTranslation.waitResponse {}
    XCTAssertEqual(found.waitResult, .found)
    XCTAssertTrue(found.hasWait)
    XCTAssertEqual(found.wait.result, .found)
    XCTAssertEqual(found.wait.message, "")
    XCTAssertFalse(found.wait.hasDiagnostics)
    let timeout = try await AccessibilityActionRequestTranslation.waitResponse {
      throw UIAutomationError.timedOut(backend: .accessibility, key: "AXLabel", value: "missing", timeout: 1)
    }
    XCTAssertEqual(timeout.waitResult, .timedOut)
    XCTAssertTrue(timeout.hasWait)
    XCTAssertEqual(timeout.wait.result, .timedOut)
    XCTAssertTrue(timeout.wait.message.contains("AXLabel"))
    XCTAssertTrue(timeout.wait.message.contains("missing"))
    XCTAssertFalse(timeout.wait.hasDiagnostics)
    do {
      _ = try await AccessibilityActionRequestTranslation.waitResponse {
        throw UIAutomationError.applicationNotResponding(backend: .accessibility, pid: 123)
      }
      XCTFail("a failed read must not become a timeout")
    } catch let error as UIAutomationError {
      guard case .applicationNotResponding = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testWaitCarriesFinalProbeDiagnostics() async throws {
    for diagnostics in [
      AccessibilitySearchDiagnostics(unmatchedValues: ["Settings", "General"], truncated: true),
      AccessibilitySearchDiagnostics(unmatchedValues: ["Settings"], readTruncated: true),
      AccessibilitySearchDiagnostics(truncated: true, readTruncated: true),
      AccessibilitySearchDiagnostics(readTruncated: false),
      AccessibilitySearchDiagnostics(),
      AccessibilitySearchDiagnostics(readError: "application unavailable"),
    ] {
      let response = try await AccessibilityActionRequestTranslation.waitResponse {
        throw UIAutomationError.timedOut(
          backend: .accessibility, key: "AXLabel", value: "missing", timeout: 1, diagnostics: diagnostics)
      }
      XCTAssertEqual(response.waitResult, .timedOut)
      XCTAssertTrue(response.hasWait)
      XCTAssertEqual(response.wait.result, .timedOut)
      XCTAssertTrue(response.wait.hasDiagnostics)
      XCTAssertEqual(response.wait.diagnostics.unmatchedValues, diagnostics.unmatchedValues)
      XCTAssertEqual(response.wait.diagnostics.truncated, diagnostics.truncated || diagnostics.readTruncated == true)
      XCTAssertEqual(response.wait.diagnostics.hasReadTruncated, diagnostics.readTruncated != nil)
      XCTAssertEqual(response.wait.diagnostics.readTruncated, diagnostics.readTruncated ?? false)
      XCTAssertTrue(response.wait.diagnostics.hasSampleTruncated)
      XCTAssertEqual(response.wait.diagnostics.sampleTruncated, diagnostics.truncated)
      XCTAssertEqual(response.wait.diagnostics.readError, diagnostics.readError ?? "")
      XCTAssertEqual(
        response.wait.message,
        "The accessibility backend timed out after 1.0s waiting for an element whose AXLabel contains \"missing\"")
    }
  }

  func testWaitPreservesCancellation() async throws {
    do {
      _ = try await AccessibilityActionRequestTranslation.waitResponse {
        throw CancellationError()
      }
      XCTFail("cancelled wait must not report a result")
    } catch {
      XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
    }
  }

  // MARK: - Backend

  private let guest = UIAutomationBackend(resolvedName: .axBridgeExclusive)

  func testTapCarriesTheRequestedBackend() throws {
    let translated = try action {
      $0.backend = .axbridge
      $0.marker = "GETTING STARTED"
      $0.tap = .init()
    }
    XCTAssertEqual(
      translated,
      .tap(
        query: .marker(value: "GETTING STARTED", key: .label, depth: 0), backend: guest, expectedValue: nil,
        expectedKey: .label))
  }

  func testScrollCarriesTheRequestedBackend() throws {
    let translated = try action {
      $0.backend = .axbridge
      $0.marker = "Notification Center"
      $0.scroll = .with { $0.direction = .down }
    }
    XCTAssertEqual(
      translated,
      .scroll(query: .marker(value: "Notification Center", key: .label, depth: 0), backend: guest, direction: .down))
  }

  func testSetValueCarriesTheRequestedBackend() throws {
    let translated = try action {
      $0.backend = .axbridge
      $0.marker = "Search"
      $0.setValue = .with { $0.value = "hello" }
    }
    XCTAssertEqual(
      translated,
      .setValue(query: .marker(value: "Search", key: .label, depth: 0), backend: guest, value: "hello"))
  }

  func testDragCarriesTheRequestedBackend() throws {
    guard case let .drag(source, destination, backend, _) = try drag({ $0.backend = .axbridge }) else {
      return XCTFail("expected a drag")
    }
    XCTAssertEqual(source, .point(CGPoint(x: 10, y: 20)))
    XCTAssertEqual(destination, .point(CGPoint(x: 200, y: 20)))
    XCTAssertEqual(backend, guest)
  }

  func testAnUnaskedBackendIsTheDefault() throws {
    let translated = try action {
      $0.marker = "General"
      $0.tap = .init()
    }
    XCTAssertEqual(
      translated,
      .tap(
        query: .marker(value: "General", key: .label, depth: 0), backend: .accessibility, expectedValue: nil,
        expectedKey: .label))
  }

  func testAnUnknownBackendIsRefused() {
    XCTAssertThrowsError(
      try action {
        $0.backend = .UNRECOGNIZED(99)
        $0.marker = "General"
        $0.tap = .init()
      }
    ) { error in
      XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
    }
  }

  func testWaitCarriesTheRequestLevelBackend() throws {
    let translated = try action {
      $0.backend = .axbridge
      $0.marker = "Settings"
      $0.wait = .with {
        $0.timeout = 10
        $0.pollInterval = 0.5
      }
    }
    XCTAssertEqual(
      translated,
      .wait(
        query: .marker(value: "Settings", key: .label, depth: 0),
        backend: guest, timeout: 10, pollInterval: 0.5))
  }

  func testTheRequestLevelBackendWinsOverWaitsOwn() throws {
    // Set to different values only a version-skewed client would send; the request-level field is
    // the one that is not deprecated, so it decides.
    let translated = try action {
      $0.backend = .ax
      $0.marker = "Settings"
      $0.wait = .with {
        $0.backend = .axbridge
        $0.timeout = 10
        $0.pollInterval = 0.5
      }
    }
    XCTAssertEqual(
      translated,
      .wait(
        query: .marker(value: "Settings", key: .label, depth: 0),
        backend: UIAutomationBackend(resolvedName: .ax), timeout: 10, pollInterval: 0.5))
  }

  // MARK: - Routing

  func testADragRequestBecomesADrag() throws {
    guard case let .drag(source, destination, _, _) = try drag() else {
      return XCTFail("a request carrying a drag must not reach another action")
    }
    XCTAssertEqual(source, .point(CGPoint(x: 10, y: 20)))
    XCTAssertEqual(destination, .point(CGPoint(x: 200, y: 20)))
  }

  func testARequestWithNoActionIsRefused() {
    XCTAssertThrowsError(try action { _ in }) { error in
      guard let status = error as? RPCError else {
        return XCTFail("expected a RPCError, got \(error)")
      }
      // Also what an action added after this companion was built deserializes as.
      XCTAssertEqual(status.code, .invalidArgument)
    }
  }

  // MARK: - Endpoints

  func testAMarkerEndpointCarriesItsOwnKeyAndDepth() throws {
    let action = try action {
      $0.marker = "Photo"
      $0.matchKey = .uniqueID
      $0.depth = 5
      $0.drag = .with { drag in
        drag.marker = "Album"
        drag.destinationMatchKey = .label
        drag.destinationDepth = 3
      }
    }
    guard case let .drag(source, destination, _, _) = action else {
      return XCTFail("expected a drag")
    }
    XCTAssertEqual(source, .marker(value: "Photo", key: .uniqueID, depth: 5))
    XCTAssertEqual(destination, .marker(value: "Album", key: .label, depth: 3))
  }

  func testAMarkerEndpointResolvesCaseSensitively() throws {
    // The request leaves its case option unset, so every translated marker matches
    // case-sensitively. Spelled out rather than relying on the enum default.
    let action = try action {
      $0.marker = "Photo"
      $0.matchKey = .uniqueID
      $0.depth = 5
      $0.drag = .with { drag in
        drag.marker = "Album"
        drag.destinationMatchKey = .label
        drag.destinationDepth = 3
      }
    }
    guard case let .drag(source, destination, _, _) = action else {
      return XCTFail("expected a drag")
    }
    XCTAssertEqual(source, .marker(value: "Photo", key: .uniqueID, depth: 5, ignoresCase: false))
    XCTAssertEqual(destination, .marker(value: "Album", key: .label, depth: 3, ignoresCase: false))
  }

  func testAMarkerEndpointCarriesIgnoreCase() throws {
    let action = try action {
      $0.marker = "Photo"
      $0.matchKey = .uniqueID
      $0.depth = 5
      $0.ignoreCase = true
      $0.drag = .with { drag in
        drag.marker = "Album"
        drag.destinationMatchKey = .label
        drag.destinationDepth = 3
      }
    }
    guard case let .drag(source, destination, _, _) = action else {
      return XCTFail("expected a drag")
    }
    XCTAssertEqual(source, .marker(value: "Photo", key: .uniqueID, depth: 5, ignoresCase: true))
    XCTAssertEqual(destination, .marker(value: "Album", key: .label, depth: 3, ignoresCase: true))
  }

  func testAMissingSourceIsRefusedByName() {
    // Unlike a scroll, a drag has nothing sensible to do with the frontmost app.
    assertRejected({ $0.target = nil }, mentioning: "source")
  }

  func testAMissingDestinationIsRefusedByName() {
    assertRejected({ $0.drag.destination = nil }, mentioning: "destination")
  }

  func testDraggingAnElementOntoItselfIsRefused() {
    // The gesture would run and change nothing, which reads to the caller as a silent no-op.
    assertRejected(
      {
        $0.drag.point = .with { point in
          point.x = 10
          point.y = 20
        }
      }, mentioning: "same element")
  }

  // MARK: - Options

  func testUnsetOptionsAreTheDefaults() throws {
    guard case let .drag(_, _, _, options) = try drag() else {
      return XCTFail("expected a drag")
    }
    // Zero is unset on the wire and none of these are useful at zero, so the server's defaults
    // stand in -- a press of zero would make the gesture a flick.
    XCTAssertEqual(options, DragOptions())
  }

  func testEveryOptionIsCarriedThrough() throws {
    let action = try drag {
      $0.drag.pressDuration = 1
      $0.drag.duration = 2
      $0.drag.releaseDuration = 0.25
      $0.drag.delta = 5
    }
    guard case let .drag(_, _, _, options) = action else {
      return XCTFail("expected a drag")
    }
    XCTAssertEqual(
      options, DragOptions(pressDuration: 1, duration: 2, releaseDuration: 0.25, delta: 5))
  }

  func testEveryNegativeOptionIsRefusedByNameAndValue() {
    assertRejected({ $0.drag.pressDuration = -1 }, mentioning: "press_duration")
    assertRejected({ $0.drag.pressDuration = -1 }, mentioning: "-1")
    assertRejected({ $0.drag.duration = -1 }, mentioning: "duration")
    assertRejected({ $0.drag.releaseDuration = -1 }, mentioning: "release_duration")
    assertRejected({ $0.drag.delta = -1 }, mentioning: "delta")
  }

  func testADeltaAtOrAboveTheDistanceIsRefusedShowingBoth() {
    // One sample means one jump, which iOS reads as a flick rather than a drag. The two points are
    // 190 apart, so a delta of 190 samples the path exactly once.
    assertRejected({ $0.drag.delta = 190 }, mentioning: "190")
    assertRejected({ $0.drag.delta = 500 }, mentioning: "500")
  }

  func testADeltaIsNotCheckedAgainstAMarkerEndpoint() throws {
    // A marker's position is resolved by the backend, so there is no distance to compare against
    // here; the backend rejects it once it knows one.
    let action = try action {
      $0.marker = "Photo"
      $0.drag = .with { drag in
        drag.marker = "Album"
        drag.delta = 10_000
      }
    }
    guard case let .drag(_, _, _, options) = action else {
      return XCTFail("expected a drag")
    }
    XCTAssertEqual(options.delta, 10_000)
  }

  // MARK: - Targets that cannot drag

  /// A drag needs the HID stack, so the executor refuses one on anything but a simulator. Pins the
  /// sentence a device caller reads: `errorDescription` is what grpc-swift puts on the wire.
  func testADragOnANonSimulatorNamesTheOperationAndTheTarget() {
    let error = IDBCommandError.simulatorOnlyOperation(
      operation: "drag by accessibility", targetDescription: "iPhone 15 | Booted | iOS 17.0")
    XCTAssertEqual(
      error.errorDescription,
      "Target is not a simulator, cannot drag by accessibility: iPhone 15 | Booted | iOS 17.0")
  }
}
