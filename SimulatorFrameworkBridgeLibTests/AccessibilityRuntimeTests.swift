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
import XCTest

private let kAXElementType = "XC_kAXXCAttributeElementType"
private let kAXLabel = "XC_kAXXCAttributeLabel"
private let kAXValue = "XC_kAXXCAttributeValue"
private let kAXChildren = "XC_kAXXCAttributeChildren"
private let kAXFrame = "XC_kAXXCAttributeFrame"
private let kAXAutomationType = "XC_kAXXCAttributeAutomationType"
private let kAXVisiblePoint = "XC_kAXXCAttributeVisiblePoint"
private let kNodeIsEnabled = "FBIsEnabled"
private let kNodeTranslatorRole = "FBTranslatorRole"

// The pid every test that needs a readable application uses. Arbitrary, but a plausible one — nothing in
// the reader treats any particular value specially beyond the non-positive rejection.
private let kAppPid: pid_t = 4321

private func FBAXTestsErrorWithCode(_ code: Int32) -> NSError {
  return NSError(domain: "XCTAutomationErrorDomain", code: 1, userInfo: [FBAXAccessibilityErrorKey: NSNumber(value: code), NSLocalizedDescriptionKey: "runtime said no"])
}

/**
 * Drives `AccessibilityService.handleRequest` against a fake `FBAXRuntime`, reaching outcomes a real simulator only
 * produces against a dead, mid-launch or SIGSTOP-ed application.
 */
final class AccessibilityRuntimeTests: XCTestCase {
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

  // MARK: - Encoding normalisation

  func testTypesOnlyDropsOffsetsAndKeepsTypes() {
    let examples = [
      // Already normalised: nothing to drop.
      "v@:": "v@:",
      "Q@:": "Q@:",
      // The common case — a return, self, selector and their offsets.
      "Q16@0:8": "Q@:",
      "@24@0:8Q16": "@@:Q",
      "v24@0:8@16": "v@:@",
      // Blocks, out-parameters, const char * and bare pointers keep their punctuation.
      "v32@0:8@?24": "v@:@?",
      "@40@0:8@16^@24@32": "@@:@^@@",
      "@24@0:8r*16": "@@:r*",
      // A pointer to an opaque struct — the shape `AXUIElementRef` arrives as.
      "^{__AXUIElement=}16@0:8": "^{__AXUIElement=}@:",
      // Digits inside an aggregate are part of the type and survive; the frame numbers around them do not.
      "{FBAXQuad=[4i]}32@0:8{FBAXPair=ii}16": "{FBAXQuad=[4i]}@:{FBAXPair=ii}",
      "[8i]16@0:8": "[8i]@:",
      "(u=i[2c])16@0:8": "(u=i[2c])@:",
      // Nested aggregates: the depth counter has to come back to zero before dropping resumes.
      "{a={b=[4i]}}24@0:8i16": "{a={b=[4i]}}@:i",
      // The empty encoding is not a crash.
      "": "",
    ]
    for encoding in examples.keys {
      assertEqualObjects(FBAXTypesOnly(encoding), axValue(examples, encoding), "normalising \(String(describing: encoding))")
    }
  }

  // The table in the runtime may be written with or without offsets.
  func testTypesOnlyMakesRuntimeAndHandWrittenEncodingsAgree() throws {
    let length = try XCTUnwrap(class_getInstanceMethod(NSString.self, #selector(getter: NSString.length)))
    assertEqualObjects(FBAXTypesOnly(try XCTUnwrap(method_getTypeEncoding(length))), FBAXTypesOnly("Q@:"))

    let objectAtIndex = try XCTUnwrap(class_getInstanceMethod(NSArray.self, #selector(NSArray.object(at:))))
    assertEqualObjects(FBAXTypesOnly(try XCTUnwrap(method_getTypeEncoding(objectAtIndex))), FBAXTypesOnly("@@:Q"))
  }

  func testTypesOnlyIsIdempotent() {
    for encoding in ["Q16@0:8", "{FBAXQuad=[4i]}32@0:8{FBAXPair=ii}16", "v32@0:8@?24"] {
      let once = FBAXTypesOnly(encoding)
      assertEqualObjects(FBAXTypesOnly(once), once, "normalising \(String(describing: encoding)) twice")
    }
  }

  // MARK: - Bound signature checking

  // Runs against the guest's copies of the frameworks; a shape that moved only inside an iOS runtime
  // image would pass against the host's.
  func testEveryBoundSignatureAgreesWithTheRuntime() {
    let warnings = FBAXSignatureWarnings()
    assertEqualObjects(warnings, [], "\(String(describing: warnings.joined(separator: "\n")))")
  }

  func testSignatureAgreesWithTheRuntime() {
    XCTAssertNil(FBAXSignatureMismatch("NSString", "length", false, "Q@:"))
    XCTAssertNil(FBAXSignatureMismatch("NSString", "stringWithUTF8String:", true, "@@:r*"))
    XCTAssertNil(FBAXSignatureMismatch("NSArray", "objectAtIndex:", false, "@@:Q"))
  }

  // Offsets differ by ABI, so the check must not fire on them.
  func testSignatureIgnoresFrameSizesAndOffsets() {
    XCTAssertNil(FBAXSignatureMismatch("NSString", "length", false, "Q16@0:8"))
    XCTAssertNil(FBAXSignatureMismatch("NSArray", "objectAtIndex:", false, "@24@0:8Q16"))
  }

  func testSignatureKeepsDigitsInsideAggregateEncodings() {
    XCTAssertNil(FBAXSignatureMismatch("FBAXSignatureProbe", "quadFromPair:", false, "{FBAXQuad=[4i]}@:{FBAXPair=ii}"))

    let mismatch = FBAXSignatureMismatch("FBAXSignatureProbe", "quadFromPair:", false, "{FBAXQuad=[8i]}@:{FBAXPair=ii}")
    XCTAssertNotNil(mismatch, "an array length inside the struct is a different type and must not be dropped")
  }

  func testSignatureMismatchNamesWhatItFoundAndWhatItAssumed() {
    let mismatch = FBAXSignatureMismatch("NSString", "length", false, "i@:")
    XCTAssertNotNil(mismatch)
    XCTAssertTrue(((mismatch)?.contains("-[NSString length]") == true), "\(String(describing: mismatch))")
    XCTAssertTrue(((mismatch)?.contains("Q@:") == true), "the encoding found must be named: \(String(describing: mismatch))")
    XCTAssertTrue(((mismatch)?.contains("i@:") == true), "the encoding assumed must be named: \(String(describing: mismatch))")
  }

  func testSignatureMismatchReportedForMissingClassOrSelector() {
    let absentClass = FBAXSignatureMismatch("FBAXNoSuchClass", "length", false, "Q@:")
    XCTAssertNotNil(absentClass)
    XCTAssertTrue(((absentClass)?.contains("FBAXNoSuchClass") == true), "\(String(describing: absentClass))")

    XCTAssertNotNil(FBAXSignatureMismatch("NSString", "fbaxNoSuchSelector", false, "Q@:"))
  }

  func testSignatureDistinguishesClassFromInstanceMethods() {
    XCTAssertNotNil(FBAXSignatureMismatch("NSString", "length", true, "Q@:"))
    XCTAssertNotNil(FBAXSignatureMismatch("NSString", "stringWithUTF8String:", false, "@@:r*"))
  }

  // MARK: - Read-error classification

  // Too broad and a reader bug reads as "the app isn't there"; too narrow and a dead app is an untyped error.
  func testEachActionableAXCodeClassifiesAsItsOwnCondition() {
    let unavailable = FBAXReadOutcome.failure(forAttributeError: FBAXTestsErrorWithCode(FBAXError.serverNotFound.rawValue))
    XCTAssertEqual(unavailable.status, FBAXReadStatus.applicationUnavailable)

    let notResponding = FBAXReadOutcome.failure(forAttributeError: FBAXTestsErrorWithCode(FBAXError.ipcTimeout.rawValue))
    XCTAssertEqual(notResponding.status, FBAXReadStatus.applicationNotResponding, "an IPC timeout classifies as application-not-responding, not unavailable")

    for code in [NSNumber(value: FBAXError.invalidUIElement.rawValue), NSNumber(value: FBAXError.success.rawValue), NSNumber(value: -1)] {
      let outcome = FBAXReadOutcome.failure(forAttributeError: FBAXTestsErrorWithCode(code.int32Value))
      XCTAssertEqual(outcome.status, FBAXReadStatus.failed, "AX code \(String(describing: code)) must stay an opaque failure")
    }
  }

  // `nil` reaches the classifier whenever the runtime returns false without populating the out-parameter.
  func testErrorWithoutAnAccessibilityCodeIsAPlainFailure() {
    XCTAssertEqual(FBAXReadOutcome.failure(forAttributeError: nil).status, FBAXReadStatus.failed)

    let foreign = NSError(domain: NSCocoaErrorDomain, code: -25215, userInfo: nil)
    let outcome = FBAXReadOutcome.failure(forAttributeError: foreign)
    XCTAssertEqual(outcome.status, FBAXReadStatus.failed, "the code must be read from the userInfo, not the NSError code")
  }

  // MARK: - Hit-test outcomes

  func testHitTestErrorClassification() {
    XCTAssertNil(FBAXHitTestOutcome(forHitTestError: FBAXError.success.rawValue, hasElement: true), "success with an element returns nil; the caller wraps the element")
    // Success with no element out is still nothing at the point, not a contradiction to report.
    XCTAssertEqual(FBAXHitTestOutcome(forHitTestError: FBAXError.success.rawValue, hasElement: false)?.status, FBAXHitTestStatus.empty)
    XCTAssertEqual(FBAXHitTestOutcome(forHitTestError: FBAXError.serverNotFound.rawValue, hasElement: false)?.status, FBAXHitTestStatus.applicationUnavailable, "server-not-found classifies as application-unavailable, not empty")
    XCTAssertEqual(FBAXHitTestOutcome(forHitTestError: FBAXError.invalidUIElement.rawValue, hasElement: false)?.status, FBAXHitTestStatus.empty, "a genuinely empty point")
    XCTAssertEqual(FBAXHitTestOutcome(forHitTestError: FBAXError.ipcTimeout.rawValue, hasElement: false)?.status, FBAXHitTestStatus.applicationNotResponding, "an IPC timeout classifies as application-not-responding, not empty or unavailable")
    // A hit-test that went wrong must not look like blank space, and says which code it got, by name when it has one.
    for (code, reason) in [
      (FBAXError.failure.rawValue, "the hit-test failed with AX error -25200 (kAXErrorFailure)"),
      (-25204, "the hit-test failed with AX error -25204 (kAXErrorCannotComplete)"),
      (-25214, "the hit-test failed with AX error -25214 (kAXErrorCalledOnNonMainThread)"),
      (-1, "the hit-test failed with AX error -1"),
    ] {
      let outcome = FBAXHitTestOutcome(forHitTestError: code, hasElement: false)
      XCTAssertEqual(outcome?.status, FBAXHitTestStatus.failed, "AX code \(code)")
      XCTAssertEqual(outcome?.failureReason, reason)
    }
  }

  func testHitOnASeededPointAnswersWithTheElementAndItsOwningPid() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("XCUIElementTypeButton"), owningProcessIdentifier: kAppPid)

    let response = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "pid": NSNumber(value: kAppPid), "x": NSNumber(value: 10), "y": NSNumber(value: 20)])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(response, "pid"), NSNumber(value: kAppPid))
    assertEqualObjects(axValue(axValue(response, "tree"), kAXElementType), "XCUIElementTypeButton")
    XCTAssertEqual(runtime.lastHitTestProcessIdentifier, kAppPid, "an explicit pid must scope the hit-test")
    XCTAssertNil(runtime.lastHitTestDisplayIdentifier, "no displayID must use the unscoped hit-test")
    XCTAssertEqual(runtime.lastHitTestPoint.x, 10)
    XCTAssertEqual(runtime.lastHitTestPoint.y, 20)
  }

  func testHitOnAContainerOverAControl() {
    func element(_ type: String, _ frame: CGRect, automationType: FBXCUIElementType? = nil, children: [FBAXFakeElement] = []) -> FBAXFakeElement {
      let element = FBAXFakeElement.readable(type)
      var attributes: [String: Any] = [kAXElementType: type, kAXLabel: type, kAXFrame: NSValue(cgRect: frame)]
      attributes[kAXAutomationType] = automationType.map { NSNumber(value: $0.rawValue) }
      element.attributes = attributes
      element.children = children
      return element
    }
    let title = element("FollowTitle", CGRect(x: 300, y: 256, width: 40, height: 16))
    let follow = element("FollowButton", CGRect(x: 288, y: 248, width: 70, height: 32), automationType: .button, children: [title])
    let name = element("NameButton", CGRect(x: 52, y: 248, width: 225, height: 18), automationType: .button)
    let header = element("Header", CGRect(x: 0, y: 237, width: 402, height: 54), children: [name, follow])

    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(header, owningProcessIdentifier: kAppPid)
    let onFollow = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "pid": NSNumber(value: kAppPid), "x": 323, "y": 264])
    assertEqualObjects(axValue(axValue(onFollow, "tree"), kAXElementType), "FollowButton", "a hit on a container names the control under the point, not the text inside it")

    let besideEverything = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "pid": NSNumber(value: kAppPid), "x": 280, "y": 285])
    assertEqualObjects(axValue(axValue(besideEverything, "tree"), kAXElementType), "Header", "a point under no child stays on the element the hit-test returned")
  }

  func testHitOnAContainerWithAChildThatRaises() {
    let follow = FBAXFakeElement.readable("FollowButton")
    follow.attributes = [kAXElementType: "FollowButton", kAXLabel: "FollowButton", kAXFrame: NSValue(cgRect: CGRect(x: 288, y: 248, width: 70, height: 32))]
    let broken = FBAXFakeElement.readable("Broken")
    broken.readRaiseReason = "a child that raises when read"
    let header = FBAXFakeElement.readable("Header")
    header.attributes = [kAXElementType: "Header", kAXLabel: "Header", kAXFrame: NSValue(cgRect: CGRect(x: 0, y: 237, width: 402, height: 54))]
    header.children = [follow, broken]

    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(header, owningProcessIdentifier: kAppPid)
    let pastBrokenChild = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "pid": NSNumber(value: kAppPid), "x": 323, "y": 264])
    assertEqualObjects(axValue(axValue(pastBrokenChild, "tree"), kAXElementType), "FollowButton", "a child that raises is skipped, not fatal to the hit-test")

    header.readRaiseReason = "the hit element raises when read for its children"
    let brokenHit = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "pid": NSNumber(value: kAppPid), "x": 323, "y": 264])
    assertEqualObjects(axValue(brokenHit, "ok"), NSNumber(value: false), "the hit element's own attribute read still reports its failure")
  }

  func testDisplayHitTestAndWriteForwardIndependentDisplayIdentity() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("XCUIElementTypeButton"), owningProcessIdentifier: kAppPid)
    for verb in ["hittest", "perform"] {
      let response = AccessibilityService.handleRequest([
        "verb": verb, "action": "press", "pid": kAppPid, "x": 80, "y": 120, "displayID": 42, "clientType": 0,
      ])
      assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
      XCTAssertEqual(runtime.lastHitTestDisplayIdentifier, NSNumber(value: 42))
      XCTAssertEqual(runtime.lastHitTestPoint, CGPoint(x: 80, y: 120))
      XCTAssertEqual(runtime.lastHitTestProcessIdentifier, kAppPid)
    }
  }

  func testADisplayHitTestClaimsTheRequestedClientAndAWriteClaimsNone() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("XCUIElementTypeButton"), owningProcessIdentifier: kAppPid)
    let unnamed = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "pid": kAppPid, "x": 80, "y": 120, "displayID": 42])
    assertEqualObjects(axValue(unnamed, "ok"), NSNumber(value: true))
    XCTAssertEqual(runtime.lastHitTestClientType, NSNumber(value: 0))

    let named = AccessibilityService.handleRequest(["verb": "hittest", "pid": kAppPid, "x": 80, "y": 120, "displayID": 42, "clientType": 4])
    assertEqualObjects(axValue(named, "ok"), NSNumber(value: true))
    XCTAssertEqual(runtime.lastHitTestClientType, NSNumber(value: 4))

    // Straight after a named hit-test, so a write that reused its client would leave 4 behind.
    let write = AccessibilityService.handleRequest([
      "verb": "perform", "action": "press", "pid": kAppPid, "x": 80, "y": 120, "displayID": 42, "clientType": 4,
    ])
    assertEqualObjects(axValue(write, "ok"), NSNumber(value: true))
    XCTAssertEqual(runtime.lastHitTestClientType, NSNumber(value: 0), "a write's target is resolved as no client")
  }

  func testASemanticReadClaimsTheRequestedClientOnEveryTranslatorRead() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("original")
    runtime.translatorAttributeValues = [33: "translated"]
    for (clientType, expected) in [(NSNumber(value: 4), 4), (NSNumber(value: 0), 0)] {
      let before = runtime.translatorRequests.count
      var request: [String: Any] = ["verb": "describe", "clientType": 0, "pid": kAppPid, "traversal": "semantic"]
      request["clientType"] = clientType

      let response = AccessibilityService.handleRequest(request)

      assertEqualObjects(response["ok"], true)
      let requests = runtime.translatorRequests as NSArray as? [[String: Any]] ?? []
      let sent = requests.dropFirst(before).map { $0["clientType"] as? Int }
      XCTAssertFalse(sent.isEmpty)
      XCTAssertEqual(Set(sent), [expected])
    }
  }

  func testMalformedDisplayIdentityNeverReachesHitTesting() {
    for value: Any in [0, -1, 1.5, 4_294_967_296, true, "3", NSNull()] {
      let response = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "x": 1, "y": 2, "displayID": value])
      assertEqualObjects(axValue(response, "error_kind"), "bad_request")
    }
    XCTAssertEqual(runtime.hitTestCount, 0)
  }

  func testDisplayHitTestExceptionsRemainInsideRuntimeBoundary() {
    runtime.raiseOnOperation = "hitTest"
    let response = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "x": 1, "y": 2, "displayID": 42])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    XCTAssertNotNil(axValue(response, "error"))
  }

  func testHitWithNoPidIsDisplayWideAndReportsTheOwningPid() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("XCUIElementTypeCell"), owningProcessIdentifier: 99)

    let response = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2)])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(response, "pid"), NSNumber(value: 99), "the owning pid must come from the outcome")
    XCTAssertEqual(runtime.lastHitTestProcessIdentifier, 0, "no pid means a display-wide hit-test")
  }

  func testEmptyPointIsASuccessfulEmptyResult() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.empty()

    let response = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2)])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(response, "empty"), NSNumber(value: true))
    XCTAssertNil(axValue(response, "tree"))
    XCTAssertNil(axValue(response, "error"))
  }

  func testUnavailableApplicationIsTaggedAndNamesThePidWhenSeeded() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.applicationUnavailable()

    let seeded = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "pid": NSNumber(value: kAppPid), "x": NSNumber(value: 1), "y": NSNumber(value: 2)])
    assertEqualObjects(axValue(seeded, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(seeded, "error_kind"), "application_unavailable")
    assertEqualObjects(axValue(seeded, "error"), "pid 4321 has no accessibility server to hit-test")

    assertEqualObjects(axValue(seeded, "pid"), NSNumber(value: kAppPid), "a tagged failure names the process it is about")

    let systemWide = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2)])
    assertEqualObjects(axValue(systemWide, "error_kind"), "application_unavailable")
    assertEqualObjects(axValue(systemWide, "error"), "no accessibility server responded to the system-wide hit-test")
    XCTAssertNil(axValue(systemWide, "pid"), "a display-wide hit-test nothing answered has no process to name")
  }

  func testNotRespondingAndUnavailableProduceDistinctErrorKinds() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.applicationNotResponding()

    let seeded = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "pid": NSNumber(value: kAppPid), "x": NSNumber(value: 1), "y": NSNumber(value: 2)])
    assertEqualObjects(axValue(seeded, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(seeded, "error_kind"), "application_not_responding")
    assertEqualObjects(axValue(seeded, "error"), "pid 4321 did not respond to the hit-test before it timed out")
    assertEqualObjects(axValue(seeded, "timeout_seconds"), NSNumber(value: 5))
    assertEqualObjects(axValue(seeded, "pid"), NSNumber(value: kAppPid))

    let systemWide = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2)])
    assertEqualObjects(axValue(systemWide, "error_kind"), "application_not_responding")
    assertEqualObjects(axValue(systemWide, "error"), "the application at the hit-test point did not respond before it timed out")
    assertEqualObjects(axValue(systemWide, "timeout_seconds"), NSNumber(value: 5))
    XCTAssertNil(axValue(systemWide, "empty"), "empty must not be set on a not-responding response")
  }

  func testFailedHitTestIsARuntimeFailureCarryingTheReason() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.failed("AXUIElementCreateSystemWide returned NULL")

    let response = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2)])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error"), "AXUIElementCreateSystemWide returned NULL")
    assertEqualObjects(axValue(response, "error_kind"), "runtime_failed", "a reader failure must not be tagged as an unavailable application")
    XCTAssertNil(axValue(response, "ax_error"))

    runtime.hitTestOutcome = FBAXHitTestOutcome.failed(withAXError: -25200)
    let coded = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2)])
    assertEqualObjects(axValue(coded, "error"), "the hit-test failed with AX error -25200 (kAXErrorFailure)")
    assertEqualObjects(axValue(coded, "error_kind"), "runtime_failed")
    assertEqualObjects(axValue(coded, "ax_error"), NSNumber(value: -25200))
  }

  func testHitElementThatCannotBeReadIsReportedFromTheReadOutcome() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.applicationUnavailable(), owningProcessIdentifier: kAppPid)
    let unavailable = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2)])
    assertEqualObjects(axValue(unavailable, "error_kind"), "application_unavailable")
    assertEqualObjects(axValue(unavailable, "error"), "pid 4321 has no accessibility server")
    assertEqualObjects(axValue(unavailable, "pid"), NSNumber(value: kAppPid), "the pid the hit-test attributed it to is still named")

    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.applicationNotResponding(), owningProcessIdentifier: kAppPid)
    let notResponding = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2)])
    assertEqualObjects(axValue(notResponding, "error_kind"), "application_not_responding")
    assertEqualObjects(axValue(notResponding, "error"), "pid 4321 did not respond to the read of the hit element before it timed out")
    assertEqualObjects(axValue(notResponding, "timeout_seconds"), NSNumber(value: 5))

    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.failed(FBAXTestsErrorWithCode(FBAXError.invalidUIElement.rawValue)), owningProcessIdentifier: kAppPid)
    let failed = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2)])
    assertEqualObjects(axValue(failed, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(failed, "error"), "failed to read the hit element")
    assertEqualObjects(axValue(failed, "error_kind"), "runtime_failed")
    assertEqualObjects(axValue(failed, "ax_error"), NSNumber(value: FBAXError.invalidUIElement.rawValue))
    assertEqualObjects(axValue(failed, "pid"), NSNumber(value: kAppPid))
  }

  // MARK: - The default frontmost method

  func testFrontmostReadForwardsDisplayAndRejectsUnscopedRunningBoard() {
    runtime.windowServerOutcome = FBAXFrontmostOutcome.resolved(kAppPid)
    let root = FBAXFakeElement.readable("UIApplication")
    let window = FBAXFakeElement.readable("UIWindow")
    window.attributes["XC_kAXXCAttributeWindowDisplayId"] = 42
    root.children = [window]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": 10, "y": 20, "displayID": 42])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    XCTAssertEqual(runtime.lastFrontmostDisplayIdentifier, NSNumber(value: 42))
    let unsupported = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": 10, "y": 20, "displayID": 42, "method": "runningboard"])
    assertEqualObjects(axValue(unsupported, "ok"), NSNumber(value: false))
    XCTAssertEqual(runtime.runningBoardCount, 0)
  }

  func testAFrontmostReadWithNoMethodAsksTheWindowServer() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.empty()
    runtime.windowServerOutcome = FBAXFrontmostOutcome.resolved(kAppPid)
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": NSNumber(value: 201), "y": NSNumber(value: 437)])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(response, "pid"), NSNumber(value: kAppPid))
    assertEqualObjects(axValue(response, "method"), "window-server", "the response names the resolver that ran")
    XCTAssertEqual(runtime.windowServerCount, 1)
    XCTAssertNil(runtime.lastFrontmostDisplayIdentifier, "no displayID must use the unscoped window-server lookup")
    XCTAssertEqual(runtime.hitTestCount, 0, "the anchor is not consulted for the authoritative frontmost")
  }

  // MARK: - Raises while answering

  func testARaiseWhileAnsweringBecomesAResponseAndLeavesTheReaderAnswering() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.readRaiseReason = "the runtime went away mid-read"

    let raised = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])
    assertEqualObjects(axValue(raised, "ok"), NSNumber(value: false))
    XCTAssertTrue(((axValue(raised, "error") as? String)?.contains("the runtime went away mid-read") == true), "the response must carry what was raised: \(String(describing: axValue(raised, "error")))")

    // The point of answering rather than aborting: the next request is still served.
    runtime.readRaiseReason = nil
    let after = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])
    assertEqualObjects(axValue(after, "ok"), NSNumber(value: true), "the reader must still answer after a raise: \(String(describing: after))")
  }

  // MARK: - Request validation

  // Arguments are rejected after the runtime is reached, hence the fake.
  func testMalformedArgumentsAreReportedAsABadRequest() {
    let hitTest = AccessibilityService.handleRequest(["verb": "hittest", "clientType": 0, "x": "left", "y": NSNumber(value: 2)])
    assertEqualObjects(axValue(hitTest, "error"), "hittest requires numeric x and y")
    assertEqualObjects(axValue(hitTest, "error_kind"), "bad_request")
    XCTAssertEqual(runtime.hitTestCount, 0, "a rejected request must not reach the runtime")

    let describe = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0])
    assertEqualObjects(axValue(describe, "error"), "describe requires either a numeric pid or the frontmost anchor (x, y)")
    assertEqualObjects(axValue(describe, "error_kind"), "bad_request")
  }

  // MARK: - The single-fetch read

  // A fake element carrying `attributes`, with `children` beneath it.
  private func FBAXTestsNode(_ attributes: [String: Any], _ children: [FBAXFakeElement]) -> FBAXFakeElement {
    let element = FBAXFakeElement.readable("UIView")
    element.attributes = attributes
    element.children = children
    return element
  }

  private func FBAXTestsSnapshotRequest(_ extra: [String: Any]) -> [String: Any] {
    var request: [String: Any] =
      ["verb": "describe", "clientType": 0, "pid": NSNumber(value: kAppPid), "traversal": "single-fetch"]
    request.merge(extra) { _, new in new }
    return request
  }

  func testTheSingleFetchReadCostsOneRoundTripForTheWholeTree() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode(
      ["XC_kAXXCAttributeLabel": "root"],
      [FBAXTestsNode(["XC_kAXXCAttributeLabel": "a"], []), FBAXTestsNode(["XC_kAXXCAttributeLabel": "b"], [])]
    )

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true), "the single fetch must answer: \(String(describing: response))")
    XCTAssertEqual(runtime.snapshotCount, 1, "a three-node tree must cost exactly one fetch")
    assertEqualObjects(axValue(axValue(response, "phases"), "mach_round_trips"), NSNumber(value: 1))
  }

  // The fake numbers attributes differently from the runtime, so a hardcoded number would fail here.
  func testSnapshotAttributesAreMappedBackFromNumbersToNames() {
    runtime.applicationElements[NSNumber(value: kAppPid)] =
      FBAXTestsNode(["XC_kAXXCAttributeLabel": "Cancel", "XC_kAXXCAttributeIdentifier": "cancel-button"], [])

    let tree = axValue(AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:])), "tree")
    assertEqualObjects(axValue(tree, "XC_kAXXCAttributeLabel"), "Cancel")
    assertEqualObjects(axValue(tree, "XC_kAXXCAttributeIdentifier"), "cancel-button")
    XCTAssertTrue(((runtime.lastSnapshotAttributeNames as NSArray?)?.contains("XC_kAXXCAttributeLabel") == true), "the fetch must ask for the names the request resolved to, got: \(String(describing: runtime.lastSnapshotAttributeNames))")
  }

  // The snapshot also answers a children *attribute* of raw element references; only the nesting is usable.
  func testSnapshotChildrenComeFromTheNestingAndNotTheChildrenAttribute() {
    let child = FBAXTestsNode(["XC_kAXXCAttributeLabel": "child"], [])
    let root = FBAXTestsNode(
      ["XC_kAXXCAttributeLabel": "root", "XC_kAXXCAttributeChildren": ["a raw element reference"]],
      [child]
    )
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let tree = axValue(AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:])), "tree")
    let children = axValue(tree, "XC_kAXXCAttributeChildren")
    XCTAssertEqual(axCount(children), 1, "children must come from the nesting: \(String(describing: children))")
    assertEqualObjects(axValue((children as? NSArray)?.firstObject, "XC_kAXXCAttributeLabel"), "child")
  }

  // The app's own serialization nests a table header's search field both under its container and directly
  // under the table.
  func testSnapshotElementNestedUnderTwoParentsIsReportedUnderTheFirstOnly() {
    let field = FBAXFakeElement.readable("UISearchBarTextField")
    field.children = [FBAXFakeElement.readable("UIImageView")]
    let container = FBAXFakeElement.readable("_UISearchBarSearchContainerView")
    container.children = [field]
    let table = FBAXFakeElement.readable("UITableView")
    table.children = [container, field, FBAXFakeElement.readable("Cell")]
    runtime.applicationElements[NSNumber(value: kAppPid)] = table

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest(["maxDepth": NSNumber(value: 5), "maxNodes": NSNumber(value: 5)]))
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    let children = axValue(axValue(response, "tree"), kAXChildren)
    assertEqualObjects(axValue(axValue(axValue(axValue(children, 0), kAXChildren), 0), kAXLabel), "UISearchBarTextField")
    XCTAssertEqual(axCount(children), 2)
    assertEqualObjects(axValue(axValue(children, 1), kAXLabel), "Cell", "the second nesting is skipped without spending the budget")
    assertEqualObjects(axValue(response, "truncated"), NSNumber(value: false))
  }

  // The pid of the process drawing a hosted subtree in the boundary tests below. Distinct from `kAppPid`
  // is all that matters: the boundary predicate is ownership changing, not any particular value.
  private var kRemotePid: pid_t { 8765 }

  // A tree in which another process draws a subtree — the shape of a web view's page, a photo picker or an
  // autofill sheet. The snapshot served by the host process names the boundary element and cannot
  // serialize beneath it; the per-node walk crosses because the server bridges each walked read.
  private func FBAXTestsTreeWithProcessBoundary() -> FBAXFakeElement {
    let link = FBAXTestsNode(["XC_kAXXCAttributeLabel": "Example Domain"], [])
    let page = FBAXTestsNode(["XC_kAXXCAttributeLabel": "web page"], [link])
    let boundary = FBAXTestsNode(["XC_kAXXCAttributeLabel": "remote element"], [page])
    let webView = FBAXTestsNode(["XC_kAXXCAttributeLabel": "web view"], [boundary])
    let root = FBAXTestsNode(["XC_kAXXCAttributeLabel": "root"], [webView])
    root.owningProcessIdentifier = kAppPid
    webView.owningProcessIdentifier = kAppPid
    boundary.owningProcessIdentifier = kRemotePid
    page.owningProcessIdentifier = kRemotePid
    link.owningProcessIdentifier = kRemotePid
    return root
  }

  // The boundary node in a single-fetch response of the tree above: root -> web view -> remote element.
  private func FBAXTestsBoundaryNode(_ response: [String: Any]) -> Any? {
    let webViews = axValue(axValue(response, "tree"), "XC_kAXXCAttributeChildren")
    return (axValue((webViews as? NSArray)?.firstObject, "XC_kAXXCAttributeChildren") as? NSArray)?.firstObject
  }

  // A snapshot stops where another process draws; the boundary arrives as a childless stub.
  func testTheSingleFetchReadContinuesAcrossAProcessBoundary() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsTreeWithProcessBoundary()

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true), "the read must answer: \(String(describing: response))")
    let boundary = FBAXTestsBoundaryNode(response)
    let hosted = axValue(boundary, "XC_kAXXCAttributeChildren")
    XCTAssertEqual(axCount(hosted), 1, "the hosted subtree must be beneath the boundary: \(String(describing: boundary))")
    assertEqualObjects(axValue((hosted as? NSArray)?.firstObject, "XC_kAXXCAttributeLabel"), "web page")
    XCTAssertEqual(runtime.snapshotCount, 2, "one fetch for the tree and one to continue across the boundary")
    assertEqualObjects(axValue(axValue(response, "phases"), "mach_round_trips"), NSNumber(value: 2))
    assertEqualObjects(axValue(response, "truncated"), NSNumber(value: false))
  }

  func testBothTraversalsAnswerTheSameDocumentAcrossAProcessBoundary() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsTreeWithProcessBoundary()

    let walked = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])
    let fetched = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(walked, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(fetched, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(walked, "tree"), axValue(fetched, "tree"))
  }

  func testAContinuationContinuesAcrossAFurtherBoundary() {
    let innermost = FBAXTestsNode(["XC_kAXXCAttributeLabel": "innermost"], [])
    innermost.owningProcessIdentifier = 111
    let root = FBAXTestsTreeWithProcessBoundary()
    let link = root.children[0].children[0].children[0].children[0]
    link.children = [innermost]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true), "the read must answer: \(String(describing: response))")
    XCTAssertEqual(runtime.snapshotCount, 3, "each boundary costs its own continuation")
    let rendered = String(describing: axValue(response, "tree"))
    XCTAssertTrue(((Optional(rendered))?.contains("innermost") == true), "the twice-hosted subtree must be in the tree: \(String(describing: rendered))")
  }

  func testAProcessBoundaryWhoseOwnerIsNotServingKeepsTheStub() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsTreeWithProcessBoundary()
    runtime.snapshotContinuationError = NSError(domain: "FBAXTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "the owner is not serving"])

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true), "a failed continuation must not fail the read: \(String(describing: response))")
    let boundary = FBAXTestsBoundaryNode(response)
    assertEqualObjects(axValue(boundary, "XC_kAXXCAttributeLabel"), "remote element")
    XCTAssertEqual(axCount(axValue(boundary, "XC_kAXXCAttributeChildren")), 0, "the stub stays childless: \(String(describing: boundary))")
    XCTAssertEqual(runtime.snapshotCount, 2, "the continuation must have been attempted")
    assertEqualObjects(axValue(response, "truncated"), NSNumber(value: false))
  }

  func testAProcessBoundaryAtTheDepthBoundReportsTruncationWithoutFetching() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsTreeWithProcessBoundary()

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest(["maxDepth": NSNumber(value: 2)]))
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(response, "truncated"), NSNumber(value: true), "the hosted subtree is beyond the bound")
    XCTAssertEqual(runtime.snapshotCount, 1, "nothing below the bound is worth a fetch")
  }

  func testTheNodeBudgetHoldsAcrossAProcessBoundary() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsTreeWithProcessBoundary()

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest(["maxNodes": NSNumber(value: 3)]))
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(response, "truncated"), NSNumber(value: true), "the hosted subtree must not fit in three nodes")
    let boundary = FBAXTestsBoundaryNode(response)
    assertEqualObjects(axValue(boundary, "XC_kAXXCAttributeLabel"), "remote element")
    XCTAssertEqual(axCount(axValue(boundary, "XC_kAXXCAttributeChildren")), 0, "the budget ran out at the boundary: \(String(describing: boundary))")
  }

  func testTheSingleFetchReadHonoursTheDepthBound() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode(
      ["XC_kAXXCAttributeLabel": "root"],
      [FBAXTestsNode(["XC_kAXXCAttributeLabel": "deep"], [])]
    )

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest(["maxDepth": NSNumber(value: 0)]))
    assertEqualObjects(axValue(response, "truncated"), NSNumber(value: true), "a tree cut at the depth bound reports truncation")
    XCTAssertNil(axValue(axValue(response, "tree"), "XC_kAXXCAttributeChildren"), "nothing below the bound is reported")
  }

  func testTheSingleFetchReadHonoursTheNodeBudget() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode(
      ["XC_kAXXCAttributeLabel": "root"],
      [FBAXTestsNode([:], []), FBAXTestsNode([:], [])]
    )

    // Two nodes of budget for a three-node tree: the root and one child fit, the second does not.
    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest(["maxNodes": NSNumber(value: 2)]))
    assertEqualObjects(axValue(response, "truncated"), NSNumber(value: true))
    XCTAssertEqual(axCount(axValue(axValue(response, "tree"), "XC_kAXXCAttributeChildren")), 1)
  }

  func testARuntimeWithoutSnapshotSupportIsReportedRatherThanReadAsEmpty() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode(["XC_kAXXCAttributeLabel": "root"], [])
    runtime.snapshotError = NSError(domain: "FBAXBridgeSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "no userTestingSnapshotForElement:"])

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    XCTAssertTrue(((axValue(response, "error") as? String)?.contains("no userTestingSnapshotForElement:") == true), "the response must carry why the fetch could not be performed: \(String(describing: axValue(response, "error")))")
  }

  // The server answers NULL under kAXErrorSuccess when it will not accept the options.
  func testASnapshotThatAnswersNothingIsAFailureRatherThanAnEmptyTree() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode(["XC_kAXXCAttributeLabel": "root"], [])
    runtime.snapshotAnswersNothing = true

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    XCTAssertNil(axValue(response, "tree"))
  }

  func testMalformedSnapshotRootsAreNotEmptyTrees() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode([:], [])
    for root in ["bad root", NSNull(), NSNumber(value: 1), [] as [Any]] as [Any] {
      // The fake indexes responses across requests as well as continuations.
      runtime.snapshotResults = Array(repeating: root, count: Int(runtime.snapshotCount) + 1)
      let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
      assertEqualObjects(response, ["ok": false, "error": "the single-fetch read returned a shape with no root node"])
    }
    XCTAssertEqual(runtime.snapshotOwnerElements.count, 0)
  }

  func testMalformedSnapshotChildrenDoNotConsumeTheNodeBudget() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode([:], [])
    runtime.snapshotResults = [
      [
        "UIAccessibilitySnapshotKeyChildren": [
          NSNull(),
          ["UIAccessibilitySnapshotKeyAttributes": [7: "child"]],
          "bad child",
        ]
      ]
    ]
    runtime.snapshotNameMappings = [[7: kAXLabel]]

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest(["maxNodes": 2]))
    assertEqualObjects(axValue(response, "tree"), [kAXChildren: [[kAXLabel: "child", kAXChildren: []]]])
    assertEqualObjects(axValue(response, "truncated"), false)
  }

  func testMalformedSnapshotAttributesAndNestingAreIgnored() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode([:], [])
    runtime.snapshotResults = [
      [
        "UIAccessibilitySnapshotKeyAttributes": ["not", "a", "dictionary"],
        "UIAccessibilitySnapshotKeyChildren": ["not": "an array"],
      ]
    ]

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(response, "tree"), [kAXChildren: []])
    assertEqualObjects(axValue(response, "truncated"), false)
  }

  func testEachSnapshotFetchUsesItsOwnAttributeMapping() {
    let root = FBAXTestsNode([:], [])
    root.owningProcessIdentifier = kAppPid
    let boundary = FBAXTestsNode([:], [])
    boundary.owningProcessIdentifier = kRemotePid
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    runtime.snapshotResults = [
      [
        "UIAccessibilitySnapshotKeyElement": root,
        "UIAccessibilitySnapshotKeyAttributes": [7: "root"],
        "UIAccessibilitySnapshotKeyChildren": [
          [
            "UIAccessibilitySnapshotKeyElement": boundary,
            "UIAccessibilitySnapshotKeyAttributes": [7: "stub"],
          ]
        ],
      ],
      [
        "UIAccessibilitySnapshotKeyElement": boundary,
        "UIAccessibilitySnapshotKeyAttributes": [7: "remote-id", 42: "remote-label", 99: "unknown"],
      ],
    ]
    runtime.snapshotNameMappings = [[7: kAXLabel], [7: "XC_kAXXCAttributeIdentifier", 42: kAXLabel]]

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(
      axValue(response, "tree"),
      [
        kAXLabel: "root",
        kAXChildren: [
          [
            kAXLabel: "remote-label", "XC_kAXXCAttributeIdentifier": "remote-id", kAXChildren: [],
          ]
        ],
      ])
    XCTAssertEqual(runtime.snapshotCount, 2)
    assertEqualObjects(runtime.snapshotOwnerElements, [root, boundary, boundary])
  }

  func testSnapshotWithoutANumericMappingOmitsAttributes() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode([:], [])
    runtime.snapshotResults = [["UIAccessibilitySnapshotKeyAttributes": [7: "unmapped"]]]

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(response, "tree"), [kAXChildren: []])
    assertEqualObjects(axValue(response, "ok"), true)
  }

  func testSnapshotContinuationWithoutAnErrorKeepsTheStub() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsTreeWithProcessBoundary()
    runtime.snapshotContinuationAnswersNothing = true

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(FBAXTestsBoundaryNode(response), [kAXLabel: "remote element", kAXChildren: []])
    assertEqualObjects(axValue(response, "ok"), true)
    assertEqualObjects(axValue(response, "truncated"), false)
    XCTAssertEqual(runtime.snapshotCount, 2)
  }

  func testSnapshotContinuationLimitRetainsTheLastStub() {
    var subtree = FBAXTestsNode([kAXLabel: "65"], [])
    subtree.owningProcessIdentifier = 1065
    for index in (0..<65).reversed() {
      let parent = FBAXTestsNode([kAXLabel: String(index)], [subtree])
      parent.owningProcessIdentifier = pid_t(1000 + index)
      subtree = parent
    }
    runtime.applicationElements[NSNumber(value: kAppPid)] = subtree

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    XCTAssertEqual(runtime.snapshotCount, 65, "one initial fetch plus 64 continuations")
    assertEqualObjects(axValue(response, "truncated"), true)
    var node = axValue(response, "tree")
    for index in 0...65 {
      assertEqualObjects(axValue(node, kAXLabel), String(index))
      let children = axValue(node, kAXChildren) as? NSArray
      XCTAssertEqual(children?.count, index == 65 ? 0 : 1)
      node = children?.firstObject
    }
  }

  func testSnapshotOwnerQueriesSkipNonLeavesAndNodesBeyondTheBudget() {
    let leaf = FBAXTestsNode([:], [])
    let middle = FBAXTestsNode([:], [leaf])
    let root = FBAXTestsNode([:], [middle])
    for element in [root, middle, leaf] {
      element.owningProcessIdentifier = kAppPid
    }
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest(["maxNodes": 2]))
    assertEqualObjects(axValue(response, "truncated"), true)
    assertEqualObjects(runtime.snapshotOwnerElements, [root])
    assertEqualObjects(runtime.operations, ["automationRead", "applicationElement", "snapshot", "snapshotOwner"])
  }

  func testAnUnknownSnapshotOwnerDisablesDescendantOwnerQueries() {
    let root = FBAXTestsNode([:], [FBAXTestsNode([:], [])])
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(response, "ok"), true)
    assertEqualObjects(runtime.snapshotOwnerElements, [root])
  }

  func testAnExceptionAtADescendantOwnerAbortsBeforeTheNextSibling() {
    let bad = FBAXTestsNode([:], [])
    bad.snapshotOwnerRaiseReason = "descendant ownership failed"
    let root = FBAXTestsNode([:], [bad, FBAXTestsNode([:], [])])
    root.owningProcessIdentifier = kAppPid
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(response, ["ok": false, "error": "the reader raised while answering: descendant ownership failed"])
    assertEqualObjects(runtime.snapshotOwnerElements, [root, bad])
    bad.snapshotOwnerRaiseReason = nil
    assertEqualObjects(axValue(AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:])), "ok"), true)
  }

  // A snapshot answers frames as `AXValue`, not the `NSValue` the per-node walk answers with.
  func testASnapshotFrameIsUnwrappedFromAnAXValue() {
    runtime.applicationElements[NSNumber(value: kAppPid)] =
      FBAXTestsNode([kAXFrame: FBAXFakeRectValue.withRect(CGRect(x: 16, y: 293, width: 370, height: 52))], [])

    let frame = axValue(axValue(AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:])), "tree"), kAXFrame)
    assertEqualObjects(axValue(frame, "X"), NSNumber(value: 16))
    assertEqualObjects(axValue(frame, "Y"), NSNumber(value: 293))
    assertEqualObjects(axValue(frame, "Width"), NSNumber(value: 370))
    assertEqualObjects(axValue(frame, "Height"), NSNumber(value: 52))
  }

  // Named in the request because a default read does not ask for the visible point.
  func testASnapshotVisiblePointIsUnwrappedFromAnAXValue() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode(
      [
        kAXFrame: FBAXFakeRectValue.withRect(CGRect(x: 16, y: 293, width: 370, height: 52)),
        kAXVisiblePoint: FBAXFakePointValue.withPoint(CGPoint(x: 201, y: 319)),
      ],
      []
    )

    let tree = axValue(
      AccessibilityService.handleRequest(
        FBAXTestsSnapshotRequest(["attributes": [kAXFrame, kAXVisiblePoint]])
      ), "tree")
    assertEqualObjects(axValue(axValue(tree, kAXVisiblePoint), "X"), NSNumber(value: 201))
    assertEqualObjects(axValue(axValue(tree, kAXVisiblePoint), "Y"), NSNumber(value: 319))
    assertEqualObjects(axValue(axValue(tree, kAXFrame), "X"), NSNumber(value: 16), "the frame on the same node is unwrapped the same way")
  }

  func testAnUnrecognisedFrameValueIsEmittedAsNull() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode([kAXFrame: "not a frame"], [])

    let frame = axValue(axValue(AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:])), "tree"), kAXFrame)
    XCTAssertNil(frame, "no frame rather than one at the origin")
  }

  func testAnUnrecognisedPointValueIsEmittedAsNull() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode([kAXVisiblePoint: "not a point"], [])

    let point = axValue(
      axValue(
        AccessibilityService.handleRequest(
          FBAXTestsSnapshotRequest(
            ["attributes": [kAXVisiblePoint]]
          )
        ), "tree"), kAXVisiblePoint)
    XCTAssertNil(point, "no point rather than one a tap could land on")
  }

  // MARK: - A snapshot the application did not answer

  // An application that did not answer a snapshot in time is still serializing that tree, so another
  // snapshot sent to it waits behind that work, and the work piles up for as long as reads keep coming.
  func testASnapshotSentWhileTheApplicationIsStillBusyWithTheLastOneIsNotSent() {
    let root = FBAXTestsNode(["XC_kAXXCAttributeLabel": "root"], [])
    root.readStatus = .applicationNotResponding
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    runtime.snapshotError = FBAXTestsErrorWithCode(FBAXError.ipcTimeout.rawValue)

    let first = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(first, "error_kind"), "application_not_responding")
    let second = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(second, "error_kind"), "application_not_responding")
    assertEqualObjects(axValue(second, "pid"), NSNumber(value: kAppPid))
    XCTAssertEqual(runtime.snapshotCount, 1)
    assertEqualObjects(axValue(second, "outstanding"), NSNumber(value: true))
    assertEqualObjects(
      axValue(second, "error"),
      "pid \(kAppPid) is still working on an earlier read it did not respond to before it timed out; nothing larger was sent to it")
  }

  func testASnapshotSentOnceTheApplicationHasCaughtUpIsSent() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXTestsNode(["XC_kAXXCAttributeLabel": "root"], [])
    runtime.snapshotError = FBAXTestsErrorWithCode(FBAXError.ipcTimeout.rawValue)
    _ = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    runtime.snapshotError = nil

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true), "the read must answer: \(String(describing: response))")
    XCTAssertEqual(runtime.snapshotCount, 2)
  }

  func testASnapshotOfAnotherApplicationIsSentWhileOneIsStillBusy() {
    let busy = FBAXTestsNode(["XC_kAXXCAttributeLabel": "busy"], [])
    busy.readStatus = .applicationNotResponding
    runtime.applicationElements[NSNumber(value: kAppPid)] = busy
    runtime.applicationElements[NSNumber(value: kAppPid + 1)] = FBAXTestsNode(["XC_kAXXCAttributeLabel": "other"], [])
    runtime.snapshotError = FBAXTestsErrorWithCode(FBAXError.ipcTimeout.rawValue)
    _ = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest([:]))
    runtime.snapshotError = nil

    let response = AccessibilityService.handleRequest(FBAXTestsSnapshotRequest(["pid": NSNumber(value: kAppPid + 1)]))
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true), "the read must answer: \(String(describing: response))")
    assertEqualObjects(axValue(axValue(response, "tree"), "XC_kAXXCAttributeLabel"), "other")
    XCTAssertEqual(runtime.snapshotCount, 2)
  }

  // MARK: - Write outcomes

  func testWriteErrorClassification() {
    XCTAssertEqual(FBAXWriteOutcome(forWriteError: FBAXError.success.rawValue).status, FBAXWriteStatus.written)
    XCTAssertEqual(FBAXWriteOutcome(forWriteError: FBAXError.serverNotFound.rawValue).status, FBAXWriteStatus.applicationUnavailable)

    // A timeout is the application being slow, not the application being gone — tagging it unavailable would
    // tell the host to stop retrying something that is still there. It is not a plain failure either: a plain
    // failure means the write did not happen, and a timeout does not say that.
    XCTAssertEqual(FBAXWriteOutcome(forWriteError: FBAXError.ipcTimeout.rawValue).status, FBAXWriteStatus.applicationNotResponding)

    // Every other code is opaque, and the diagnostic has to carry it: triage happens from the wire response
    // alone, and "the write failed" without the number says nothing actionable.
    let rejected = FBAXWriteOutcome(forWriteError: -25201)
    XCTAssertEqual(rejected.status, FBAXWriteStatus.failed)
    XCTAssertTrue(((rejected.failureReason)?.contains("-25201") == true), "\(String(describing: rejected.failureReason))")
  }

  func testRejectedPressUsesNativeActivation() {
    var fallbackCount = 0
    let outcome = FBAXWriteOutcome(forPressError: -25200) {
      fallbackCount += 1
      return FBAXWriteOutcome.written()
    }

    XCTAssertEqual(outcome.status, FBAXWriteStatus.written)
    XCTAssertEqual(fallbackCount, 1)
  }

  func testRejectedPressPreservesNativeActivationFailure() {
    let outcome = FBAXWriteOutcome(forPressError: -25200) {
      FBAXWriteOutcome.failed("native activation could not reach the element")
    }

    XCTAssertEqual(outcome.status, FBAXWriteStatus.failed)
    XCTAssertEqual(outcome.failureReason, "native activation could not reach the element")
  }

  func testOtherPressOutcomesDoNotAttemptNativeActivation() {
    let cases: [(Int32, FBAXWriteStatus)] = [
      (FBAXError.success.rawValue, .written),
      (FBAXError.serverNotFound.rawValue, .applicationUnavailable),
      (FBAXError.ipcTimeout.rawValue, .applicationNotResponding),
      (FBAXError.invalidUIElement.rawValue, .failed),
      (-25201, .failed),
    ]
    for (error, expectedStatus) in cases {
      var fallbackCount = 0
      let outcome = FBAXWriteOutcome(forPressError: error) {
        fallbackCount += 1
        return FBAXWriteOutcome.written()
      }

      XCTAssertEqual(outcome.status, expectedStatus, "AX error \(error)")
      if expectedStatus == .failed {
        XCTAssertTrue(outcome.failureReason?.contains(String(error)) == true)
      } else {
        XCTAssertNil(outcome.failureReason)
      }
      XCTAssertEqual(fallbackCount, 0, "AX error \(error)")
    }
  }

  // `FBAXSignatureWarnings` sweeps only ObjC selectors; a C entry point has nothing but this presence check.
  func testTheAXRuntimeWriteEntryPointsResolve() {
    XCTAssertTrue(dlopen(FBAXPathAXRuntime, RTLD_NOW) != nil, "AXRuntime could not be opened")
    XCTAssertTrue(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AXUIElementPerformAction") != nil)
    XCTAssertTrue(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AXUIElementSetAttributeValue") != nil)
  }

  func testLiveRuntimeSetsAFiveSecondMessagingTimeout() throws {
    XCTAssertNotNil(dlopen(FBAXPathAXRuntime, RTLD_NOW))
    let scope = UnsafeMutableRawPointer(bitPattern: -2)
    let create = unsafeBitCast(try XCTUnwrap(dlsym(scope, "AXUIElementCreateSystemWide")), to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
    let set = unsafeBitCast(try XCTUnwrap(dlsym(scope, "AXUIElementSetMessagingTimeout")), to: (@convention(c) (UnsafeMutableRawPointer, Float) -> Int32).self)
    let get = unsafeBitCast(try XCTUnwrap(dlsym(scope, "AXUIElementMessagingTimeout")), to: (@convention(c) () -> Float).self)
    let system = try XCTUnwrap(create())
    let original = get()
    defer {
      _ = set(system, Float(original) / 1000)
      Unmanaged<AnyObject>.fromOpaque(system).release()
    }
    XCTAssertEqual(set(system, 1), 0)
    var error: NSString?
    XCTAssertNotNil(FBAXLiveRuntime(error: &error), String(describing: error))
    XCTAssertEqual(get(), 5000)
  }

  // Optional in the live runtime; this asserts it is present today, not that the code requires it.
  func testTheAutomationModeReadEntryPointResolves() {
    XCTAssertTrue(dlopen(FBAXPathAXRuntime, RTLD_NOW) != nil, "AXRuntime could not be opened")
    XCTAssertTrue(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXSAutomationEnabled") != nil)
  }

  // MARK: - Guest phase reporting

  func testADescribeReportsItsWalkAndRoundTripCount() {
    let leaf = FBAXFakeElement.readable("UIButton")
    let root = FBAXFakeElement.readable("UIApplication")
    root.children = [leaf]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])
    let phases = axValue(response, "phases")

    XCTAssertNotNil(phases, "phases must be present on every describe response")
    assertEqualObjects(axValue(phases, "mach_round_trips"), NSNumber(value: 2), "one round trip per node, root plus leaf")
    XCTAssertNotNil(axValue(phases, "traverse_ms"))
    XCTAssertGreaterThanOrEqual(((axValue(phases, "traverse_ms") as? NSNumber)?.doubleValue ?? 0), 0.0)
  }

  // MARK: - The per-element walk

  // An application that did not answer in time is still working on the read it missed, so a read sent to
  // it afterwards waits behind that work.
  func testAWalkThatMeetsAChildThatDidNotAnswerStopsBeforeItsSibling() {
    let root = FBAXFakeElement.readable("UIApplication")
    root.children = [FBAXFakeElement.applicationNotResponding(), FBAXFakeElement.readable("UIButton")]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])

    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error_kind"), "application_not_responding")
    assertEqualObjects(axValue(response, "pid"), NSNumber(value: kAppPid))
    assertEqualObjects(axValue(response, "error"), "pid \(kAppPid) did not respond to the read of its element tree before it timed out")
    assertEqualObjects(runtime.operations, ["automationRead", "applicationElement", "readAttributes", "readAttributes"])
  }

  // The walk crosses into processes that draw part of the tree. One of those not answering says nothing
  // about the application, whose reads do not queue behind it.
  func testAWalkThatMeetsAnotherProcessThatDidNotAnswerStillReadsTheApplication() {
    let stalled = FBAXFakeElement.applicationNotResponding()
    stalled.owningProcessIdentifier = kRemotePid
    let button = FBAXFakeElement.readable("UIButton")
    button.owningProcessIdentifier = kAppPid
    let root = FBAXFakeElement.readable("UIApplication")
    root.owningProcessIdentifier = kAppPid
    root.children = [stalled, button]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])

    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(axValue(response, "tree"), kAXChildren), [[kAXElementType: "UIButton", kAXLabel: "UIButton", kAXChildren: []]])
  }

  func testAWalkThatMeetsAnotherProcessThatDidNotAnswerDoesNotAskThatProcessAgain() {
    let stalled = FBAXFakeElement.applicationNotResponding()
    stalled.owningProcessIdentifier = kRemotePid
    let sibling = FBAXFakeElement.readable("UIWebView")
    sibling.owningProcessIdentifier = kRemotePid
    let root = FBAXFakeElement.readable("UIApplication")
    root.owningProcessIdentifier = kAppPid
    root.children = [stalled, sibling]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])

    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(axValue(response, "tree"), kAXChildren), [])
    assertEqualObjects(runtime.operations, ["automationRead", "applicationElement", "readAttributes", "readAttributes"])
  }

  // MARK: - Automation mode on the describe path

  // Absent is not false: a host that does not know the field must leave the device alone.
  func testAnAbsentAutomationFieldMutatesNothing() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.automationMode = false

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])

    assertEqualObjects(runtime.automationModeWrites, [], "an absent field must not write")
    assertEqualObjects(axValue(axValue(response, "automation"), "enabled"), NSNumber(value: false), "the state is still reported")
    assertEqualObjects(axValue(axValue(response, "automation"), "asserted"), NSNumber(value: false))
  }

  func testRequestingAutomationModeWritesAndReportsAsserted() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.automationMode = false

    let response =
      AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid), "automationMode": NSNumber(value: true)])

    assertEqualObjects(runtime.automationModeWrites, [NSNumber(value: true)])
    assertEqualObjects(axValue(axValue(response, "automation"), "enabled"), NSNumber(value: true))
    assertEqualObjects(axValue(axValue(response, "automation"), "asserted"), NSNumber(value: true), "this read changed the device")
  }

  func testRequestingAModeTheDeviceIsAlreadyInWritesNothing() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.automationMode = true

    let response =
      AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid), "automationMode": NSNumber(value: true)])

    assertEqualObjects(runtime.automationModeWrites, [], "nothing to change, so nothing is written")
    assertEqualObjects(axValue(axValue(response, "automation"), "enabled"), NSNumber(value: true))
    assertEqualObjects(axValue(axValue(response, "automation"), "asserted"), NSNumber(value: false), "it was already in that mode")
  }

  func testRequestingAutomationModeOffTurnsItOff() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.automationMode = true

    let response =
      AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid), "automationMode": NSNumber(value: false)])

    assertEqualObjects(runtime.automationModeWrites, [NSNumber(value: false)])
    assertEqualObjects(axValue(axValue(response, "automation"), "enabled"), NSNumber(value: false))
    assertEqualObjects(axValue(axValue(response, "automation"), "asserted"), NSNumber(value: true))
  }

  // A preference write can be accepted and silently not apply.
  func testFailedAutomationModeWriteReportsAssertedFalse() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.automationMode = false
    runtime.automationModeWriteFails = true

    let response =
      AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid), "automationMode": NSNumber(value: true)])

    assertEqualObjects(runtime.automationModeWrites, [NSNumber(value: true)], "the write was attempted")
    assertEqualObjects(axValue(axValue(response, "automation"), "enabled"), NSNumber(value: false), "enabled reads back NO after the failed write")
    assertEqualObjects(axValue(axValue(response, "automation"), "asserted"), NSNumber(value: false), "asserted is NO when the write did not take")
  }

  // Records when the mode is asserted relative to frontmost discovery on a fused read whose discovery
  // fails. The mode decides how much structure a read sees, so that order is observable behaviour.
  func testAFusedFrontmostReadOrdersAutomationAndWindowServerOperations() {
    runtime.automationMode = false
    runtime.windowServerOutcome = FBAXFrontmostOutcome.unresolved("window-server frontmost returned no application object")

    let response = AccessibilityService.handleRequest([
      "verb": "describe", "traversal": "view-hierarchy", "clientType": 0,
      "x": NSNumber(value: 207),
      "y": NSNumber(value: 448),
      "automationMode": NSNumber(value: true),
    ])

    assertEqualObjects(axValue(response, "error_kind"), "frontmost_unresolved")
    // The mode is asserted even though this read goes on to fail, so a retry meets a guest that already
    // has automation on.
    assertEqualObjects(runtime.operations, ["automationRead", "automationWrite", "windowServerFrontmost"])
    assertEqualObjects(runtime.automationModeWrites, [NSNumber(value: true)])
  }

  // MARK: - Device settings

  func testEveryDeviceSettingNameReadsThroughItsSemanticSetting() {
    let settings = [
      "reduce-motion": NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue),
      "reduce-transparency": NSNumber(value: FBAXDeviceSetting.reduceTransparency.rawValue),
      "button-shapes": NSNumber(value: FBAXDeviceSetting.buttonShapes.rawValue),
      "voiceover": NSNumber(value: FBAXDeviceSetting.voiceOver.rawValue),
    ]
    for (name, setting) in settings {
      runtime.deviceSettings[setting] = NSNumber(value: true)

      let response = AccessibilityService.handleRequest(["verb": "settings-get", "setting": name])

      assertEqualObjects(axValue(response, "ok"), NSNumber(value: true), "\(String(describing: name))")
      assertEqualObjects(axValue(response, "enabled"), NSNumber(value: true), "\(String(describing: name))")
    }
  }

  func testDeviceSettingWriteReturnsReadBackState() {
    runtime.deviceSettings[NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)] = NSNumber(value: false)

    let response = AccessibilityService.handleRequest(
      [
        "verb": "settings-set",
        "setting": "reduce-motion",
        "enabled": NSNumber(value: true),
      ]
    )

    assertEqualObjects(runtime.deviceSettingWrites, ([["setting": NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue), "enabled": NSNumber(value: true)]]))
    assertEqualObjects(axValue(response, "enabled"), NSNumber(value: true))
  }

  func testUnavailableDeviceSettingIsANamedFailure() {
    let response = AccessibilityService.handleRequest(
      [
        "verb": "settings-get",
        "setting": "voiceover",
      ]
    )

    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error_kind"), "capability_unavailable")
    XCTAssertTrue(((axValue(response, "error") as? String)?.contains("unavailable") == true))
  }

  func testUnavailableDeviceSettingWriteDoesNotReachRuntime() {
    let response = AccessibilityService.handleRequest(
      [
        "verb": "settings-set",
        "setting": "voiceover",
        "enabled": NSNumber(value: true),
      ]
    )

    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error_kind"), "capability_unavailable")
    assertEqualObjects(runtime.deviceSettingWrites, [])
  }

  func testMalformedDeviceSettingRequestsAreRefused() {
    let unknown = AccessibilityService.handleRequest(
      [
        "verb": "settings-get",
        "setting": "future-setting",
      ]
    )
    let missingValue = AccessibilityService.handleRequest(
      [
        "verb": "settings-set",
        "setting": "reduce-motion",
      ]
    )

    assertEqualObjects(axValue(unknown, "error_kind"), "bad_request")
    assertEqualObjects(axValue(missingValue, "error_kind"), "bad_request")
    assertEqualObjects(runtime.deviceSettingWrites, [])
  }

  // MARK: - Write dispatch

  // Seeds the hit-test so a point-addressed write lands on an element reporting `attributes`, and hands the
  // element back so a test can assert the write acted on that one.
  @discardableResult
  private func seedHitElement(withAttributes attributes: [String: Any]) -> FBAXFakeElement {
    let element = FBAXFakeElement()
    element.attributes = attributes
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(element, owningProcessIdentifier: kAppPid)
    return element
  }

  private func FBAXTestsPress() -> [String: Any] {
    return ["verb": "perform", "x": NSNumber(value: 1), "y": NSNumber(value: 2), "action": "press"]
  }

  func testEveryActionNameReachesTheRuntimeAsItsSemanticAction() {
    let actions = [
      "press": NSNumber(value: FBAXAction.press.rawValue),
      "scroll-up": NSNumber(value: FBAXAction.scrollUp.rawValue),
      "scroll-down": NSNumber(value: FBAXAction.scrollDown.rawValue),
      "scroll-left": NSNumber(value: FBAXAction.scrollLeft.rawValue),
      "scroll-right": NSNumber(value: FBAXAction.scrollRight.rawValue),
      "scroll-to-visible": NSNumber(value: FBAXAction.scrollToVisible.rawValue),
    ]
    var performed: UInt = 0
    for name in actions.keys {
      self.seedHitElement(withAttributes: [:])
      let response =
        AccessibilityService.handleRequest(["verb": "perform", "x": NSNumber(value: 10), "y": NSNumber(value: 20), "action": name])
      assertEqualObjects(axValue(response, "ok"), NSNumber(value: true), "\(String(describing: name))")
      assertEqualObjects(axValue(response, "pid"), NSNumber(value: kAppPid), "\(String(describing: name))")
      performed += 1
      XCTAssertEqual(runtime.performCount, performed, "\(String(describing: name)) must reach the runtime")
      XCTAssertEqual(runtime.lastPerformedAction.rawValue, ((axValue(actions, name) as? NSNumber)?.uintValue ?? 0), "\(String(describing: name))")
    }
  }

  func testUnknownActionIsRejectedWithoutReachingTheRuntime() {
    self.seedHitElement(withAttributes: [:])
    for action in ["pres", "AXPress", "", NSNumber(value: 123), NSNull()] as [Any] {
      let response =
        AccessibilityService.handleRequest(["verb": "perform", "x": NSNumber(value: 1), "y": NSNumber(value: 2), "action": action])
      assertEqualObjects(axValue(response, "ok"), NSNumber(value: false), "\(String(describing: action))")
      XCTAssertTrue(((axValue(response, "error") as? String)?.hasPrefix("unsupported action:") == true), "\(String(describing: axValue(response, "error")))")
    }
    assertEqualObjects(axValue(AccessibilityService.handleRequest(["verb": "perform", "x": NSNumber(value: 1), "y": NSNumber(value: 2)]), "error"), "unsupported action: (nil)")
    XCTAssertEqual(runtime.hitTestCount, 0, "a request that cannot be understood must not reach the application")
    XCTAssertEqual(runtime.performCount, 0)
  }

  func testAWriteRequiresNumericCoordinates() {
    self.seedHitElement(withAttributes: [:])
    let requests: [[String: Any]] = [
      ["verb": "perform", "action": "press"],
      ["verb": "perform", "action": "press", "x": NSNumber(value: 1)],
      ["verb": "perform", "action": "press", "x": "1", "y": NSNumber(value: 2)],
      ["verb": "setvalue", "value": "hello"],
      ["verb": "setvalue", "value": "hello", "x": NSNumber(value: 1), "y": NSNull()],
    ]
    for request in requests {
      let response = AccessibilityService.handleRequest(request)
      assertEqualObjects(axValue(response, "ok"), NSNumber(value: false), "\(String(describing: request))")
      assertEqualObjects(axValue(response, "error"), "a write requires numeric x and y", "\(String(describing: request))")
    }
    XCTAssertEqual(runtime.hitTestCount, 0)
  }

  func testAWriteOnEmptySpaceIsASuccessfulEmptyResult() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.empty()
    let requests: [[String: Any]] = [
      FBAXTestsPress(),
      ["verb": "setvalue", "x": NSNumber(value: 1), "y": NSNumber(value: 2), "value": "hello"],
    ]
    for request in requests {
      let response = AccessibilityService.handleRequest(request)
      assertEqualObjects(axValue(response, "ok"), NSNumber(value: true), "\(String(describing: axValue(request, "verb")))")
      assertEqualObjects(axValue(response, "empty"), NSNumber(value: true), "\(String(describing: axValue(request, "verb")))")
      XCTAssertNil(axValue(response, "error"), "\(String(describing: axValue(request, "verb")))")
    }
    XCTAssertEqual(runtime.performCount, 0, "nothing at the point means nothing to write to")
    XCTAssertEqual(runtime.setValueCount, 0)
  }

  func testAWriteToAnUnavailableApplicationIsTaggedAndNamesThePidWhenKnown() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.applicationUnavailable()
    let unhit = AccessibilityService.handleRequest(FBAXTestsPress())
    assertEqualObjects(axValue(unhit, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(unhit, "error_kind"), "application_unavailable")
    assertEqualObjects(axValue(unhit, "error"), "no accessibility server responded to the write")
    assertEqualObjects(axValue(unhit, "effect"), "none")

    self.seedHitElement(withAttributes: [:])
    runtime.writeOutcome = FBAXWriteOutcome.applicationUnavailable()
    let died = AccessibilityService.handleRequest(FBAXTestsPress())
    assertEqualObjects(axValue(died, "error_kind"), "application_unavailable")
    assertEqualObjects(axValue(died, "error"), "pid 4321 has no accessibility server to accept the write")
    assertEqualObjects(axValue(died, "effect"), "unknown")
  }

  func testAFailedHitTestBeforeAWriteSendsNothing() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.failed(withAXError: -25200)
    for request in [FBAXTestsPress(), ["verb": "setvalue", "x": NSNumber(value: 1), "y": NSNumber(value: 2), "value": "hello"]] {
      let response = AccessibilityService.handleRequest(request)
      assertEqualObjects(axValue(response, "ok"), NSNumber(value: false), "\(String(describing: axValue(request, "verb")))")
      assertEqualObjects(axValue(response, "error"), "the hit-test failed with AX error -25200 (kAXErrorFailure)")
      assertEqualObjects(axValue(response, "error_kind"), "runtime_failed")
      assertEqualObjects(axValue(response, "ax_error"), NSNumber(value: -25200))
      assertEqualObjects(axValue(response, "effect"), "none")
    }
    XCTAssertEqual(runtime.performCount, 0)
    XCTAssertEqual(runtime.setValueCount, 0)
  }

  func testAnUnansweredHitTestBeforeAWriteSendsNothing() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.applicationNotResponding()
    let response = AccessibilityService.handleRequest(FBAXTestsPress())
    assertEqualObjects(axValue(response, "error_kind"), "application_not_responding")
    assertEqualObjects(axValue(response, "error"), "the application did not respond to the write before it timed out")
    assertEqualObjects(axValue(response, "timeout_seconds"), NSNumber(value: 5))
    assertEqualObjects(axValue(response, "effect"), "none")
    XCTAssertEqual(runtime.performCount, 0)
  }

  func testAnAssertionThatCannotBeReadSendsNothing() {
    var request: [String: Any] = FBAXTestsPress()
    request["assertKey"] = kAXLabel
    request["assertValue"] = "General"

    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.applicationNotResponding(), owningProcessIdentifier: kAppPid)
    let unanswered = AccessibilityService.handleRequest(request)
    assertEqualObjects(axValue(unanswered, "error_kind"), "application_not_responding")
    assertEqualObjects(axValue(unanswered, "error"), "pid 4321 did not respond to the write before it timed out")
    assertEqualObjects(axValue(unanswered, "timeout_seconds"), NSNumber(value: 5))
    assertEqualObjects(axValue(unanswered, "effect"), "none")

    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.failed(FBAXTestsErrorWithCode(FBAXError.failure.rawValue)), owningProcessIdentifier: kAppPid)
    let failed = AccessibilityService.handleRequest(request)
    assertEqualObjects(axValue(failed, "error"), "could not read XC_kAXXCAttributeLabel to check the assertion")
    assertEqualObjects(axValue(failed, "error_kind"), "runtime_failed")
    assertEqualObjects(axValue(failed, "ax_error"), NSNumber(value: FBAXError.failure.rawValue))
    XCTAssertNil(axValue(failed, "timeout_seconds"), "only an application that did not respond was given a timeout")
    assertEqualObjects(axValue(failed, "effect"), "none")
    XCTAssertEqual(runtime.performCount, 0)
  }

  func testAnAssertionThatCannotBeReadIsReportedAgainstTheHitPid() {
    var request: [String: Any] = FBAXTestsPress()
    request["assertKey"] = kAXLabel
    request["assertValue"] = "General"

    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.applicationNotResponding(), owningProcessIdentifier: kAppPid)
    let unanswered = AccessibilityService.handleRequest(request)
    assertEqualObjects(axValue(unanswered, "error"), "pid 4321 did not respond to the write before it timed out")
    assertEqualObjects(axValue(unanswered, "pid"), kAppPid)

    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.applicationUnavailable(), owningProcessIdentifier: kAppPid)
    let unavailable = AccessibilityService.handleRequest(request)
    assertEqualObjects(axValue(unavailable, "error"), "pid 4321 has no accessibility server to accept the write")
    assertEqualObjects(axValue(unavailable, "pid"), kAppPid)
  }

  // No element populates `XC_kAXXCAttributeUserTestingActions`, so there is no pre-check on it.
  func testAnActionIsPerformedWhateverTheElementAdvertises() {
    for advertised in [["AXScrollToVisible"], [], NSNull()] as [Any] {
      self.seedHitElement(withAttributes: ["XC_kAXXCAttributeUserTestingActions": advertised])
      assertEqualObjects(axValue(AccessibilityService.handleRequest(FBAXTestsPress()), "ok"), NSNumber(value: true), "\(String(describing: advertised))")
    }
    XCTAssertEqual(runtime.performCount, 3)
  }

  func testWriteAssertionsPreserveNSStringUnicodeEquality() {
    let actual = "\u{00E9}"
    let equivalent = "e\u{0301}"
    XCTAssertFalse((actual as NSString).isEqual(to: equivalent))
    XCTAssertEqual(actual, equivalent)

    for useDescription in [false, true] {
      for verb in ["perform", "setvalue"] {
        let opaque = FBAXFakeOpaqueValue()
        opaque.descriptionValue = actual
        let value: Any = useDescription ? opaque : actual
        seedHitElement(withAttributes: [kAXLabel: value])
        let performedBefore = runtime.performCount
        let setBefore = runtime.setValueCount
        var request: [String: Any] = [
          "verb": verb, "x": 1, "y": 2, "action": "press", "value": "replacement",
          "assertKey": kAXLabel, "assertValue": equivalent,
        ]

        let rejected = AccessibilityService.handleRequest(request)
        assertEqualObjects(axValue(rejected, "ok"), false)
        assertEqualObjects(axValue(rejected, "error_kind"), "assertion_failed")
        XCTAssertEqual(runtime.performCount, performedBefore)
        XCTAssertEqual(runtime.setValueCount, setBefore)

        request["assertValue"] = actual
        assertEqualObjects(axValue(AccessibilityService.handleRequest(request), "ok"), true)
        XCTAssertEqual(runtime.performCount, performedBefore + (verb == "perform" ? 1 : 0))
        XCTAssertEqual(runtime.setValueCount, setBefore + (verb == "setvalue" ? 1 : 0))
      }
    }
  }

  func testAnAssertionThatDoesNotMatchRefusesTheWrite() {
    self.seedHitElement(withAttributes: [kAXLabel: "Wi-Fi"])

    let response = AccessibilityService.handleRequest(
      [
        "verb": "perform",
        "x": NSNumber(value: 200),
        "y": NSNumber(value: 711),
        "action": "press",
        "assertKey": kAXLabel,
        "assertValue": "General",
      ]
    )
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error_kind"), "assertion_failed")
    assertEqualObjects(axValue(response, "error"), "the element at (200.0, 711.0) has XC_kAXXCAttributeLabel Wi-Fi, expected General")
    assertEqualObjects(axValue(response, "effect"), "none")
    XCTAssertEqual(runtime.performCount, 0, "a write must not land on an element that is not the one named")
  }

  func testAnAssertionThatMatchesAllowsTheWrite() {
    self.seedHitElement(withAttributes: [kAXLabel: "General"])

    let pressed = AccessibilityService.handleRequest(
      [
        "verb": "perform",
        "x": NSNumber(value: 1),
        "y": NSNumber(value: 2),
        "action": "press",
        "assertKey": kAXLabel,
        "assertValue": "General",
      ]
    )
    assertEqualObjects(axValue(pressed, "ok"), NSNumber(value: true))
    XCTAssertEqual(runtime.performCount, 1)

    let written = AccessibilityService.handleRequest(
      [
        "verb": "setvalue",
        "x": NSNumber(value: 1),
        "y": NSNumber(value: 2),
        "value": "hello",
        "assertKey": kAXLabel,
        "assertValue": "General",
      ]
    )
    assertEqualObjects(axValue(written, "ok"), NSNumber(value: true), "the assertion is not specific to one write verb")
    XCTAssertEqual(runtime.setValueCount, 1)
  }

  func testAnAssertionKeyAndValueAreOnlyMeaningfulTogether() {
    self.seedHitElement(withAttributes: [kAXLabel: "General"])
    for partial in [["assertKey": kAXLabel], ["assertValue": "General"]] {
      var request: [String: Any] = FBAXTestsPress()
      request.merge(partial) { _, new in new }
      let response = AccessibilityService.handleRequest(request)
      assertEqualObjects(axValue(response, "ok"), NSNumber(value: false), "\(String(describing: partial))")
      assertEqualObjects(axValue(response, "error"), "assertKey and assertValue are only meaningful together")
    }
    XCTAssertEqual(runtime.hitTestCount, 0)
  }

  func testAnAssertionOnAnAttributeTheReaderDoesNotFetchIsRejected() {
    self.seedHitElement(withAttributes: [kAXLabel: "General"])
    var request: [String: Any] = FBAXTestsPress()
    request["assertKey"] = "XC_kAXXCAttributeIsVisible"
    request["assertValue"] = "1"

    let response = AccessibilityService.handleRequest(request)
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error"), "XC_kAXXCAttributeIsVisible is not an attribute a write can assert on")
    XCTAssertEqual(runtime.hitTestCount, 0)
  }

  func testSetValueSendsTheValueAndTheHitElementToTheRuntime() {
    let element = self.seedHitElement(withAttributes: [kAXLabel: "Name"])

    let response =
      AccessibilityService.handleRequest(["verb": "setvalue", "x": NSNumber(value: 30), "y": NSNumber(value: 40), "value": "hello"])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(response, "pid"), NSNumber(value: kAppPid))
    XCTAssertEqual(runtime.setValueCount, 1)
    assertEqualObjects(runtime.lastWrittenValue, "hello")
    assertEqualObjects(runtime.lastWrittenElement, element, "the write must act on the element the hit-test found")
    XCTAssertEqual(runtime.performCount, 0, "a set-value is not an action")
    assertEqualObjects(runtime.operations, ["hitTest", "setValue"])
  }

  func testSetValueTimeoutSucceedsWhenTheRequestedValueIsReadable() {
    self.seedHitElement(withAttributes: [kAXValue: "hello"])
    runtime.writeOutcome = FBAXWriteOutcome.applicationNotResponding()

    let response = AccessibilityService.handleRequest(["verb": "setvalue", "x": 30, "y": 40, "value": "hello"])

    assertEqualObjects(response, ["ok": true, "pid": kAppPid])
    XCTAssertEqual(runtime.setValueCount, 1)
    assertEqualObjects(runtime.operations, ["hitTest", "setValue", "readAttributes"])
  }

  func testSetValueConfirmsADelayedValueWithoutRepeatingTheWrite() {
    for firstRead in [FBAXReadOutcome.applicationNotResponding(), FBAXReadOutcome.read([kAXValue: "old"])] {
      self.seedHitElement(withAttributes: [:])
      runtime.writeOutcome = FBAXWriteOutcome.applicationNotResponding()
      runtime.readOutcomes = [firstRead, FBAXReadOutcome.read([kAXValue: "hello"])]
      runtime.operations.removeAllObjects()
      let writesBefore = runtime.setValueCount

      let response = AccessibilityService.handleRequest(["verb": "setvalue", "x": 30, "y": 40, "value": "hello"])

      assertEqualObjects(response, ["ok": true, "pid": kAppPid])
      XCTAssertEqual(runtime.setValueCount, writesBefore + 1)
      assertEqualObjects(runtime.operations, ["hitTest", "setValue", "readAttributes", "readAttributes"])
      XCTAssertEqual(runtime.readOutcomes.count, 0)
    }
  }

  func testSetValueTimeoutIsPreservedWithoutAnExactStringValue() {
    let cases: [(String, Any?)] = [
      ("hello", "different"),
      ("hello", nil),
      ("hello", NSNull()),
      ("123", NSNumber(value: 123)),
      ("\u{00E9}", "e\u{0301}"),
    ]
    runtime.writeOutcome = FBAXWriteOutcome.applicationNotResponding()
    for (requested, actual) in cases {
      self.seedHitElement(withAttributes: actual.map { [kAXValue: $0] } ?? [:])
      runtime.operations.removeAllObjects()
      let writesBefore = runtime.setValueCount

      let response = AccessibilityService.handleRequest(["verb": "setvalue", "x": 30, "y": 40, "value": requested])

      assertEqualObjects(axValue(response, "error_kind"), "application_not_responding")
      assertEqualObjects(axValue(response, "pid"), kAppPid)
      assertEqualObjects(axValue(response, "timeout_seconds"), NSNumber(value: 5))
      XCTAssertEqual(runtime.setValueCount, writesBefore + 1)
      assertEqualObjects(runtime.operations, ["hitTest", "setValue", "readAttributes", "readAttributes"])
      assertEqualObjects(axValue(response, "effect"), "unknown")
    }
  }

  func testSetValueTimeoutIsPreservedWhenTheValueCannotBeRead() {
    let cases: [(FBAXReadStatus, String?)] = [
      (.applicationUnavailable, nil),
      (.applicationNotResponding, nil),
      (.failed, nil),
      (.read, "value read failed"),
    ]
    runtime.writeOutcome = FBAXWriteOutcome.applicationNotResponding()
    for (status, raiseReason) in cases {
      let element = self.seedHitElement(withAttributes: [kAXValue: "hello"])
      element.readStatus = status
      element.readRaiseReason = raiseReason
      runtime.operations.removeAllObjects()
      let writesBefore = runtime.setValueCount

      let response = AccessibilityService.handleRequest(["verb": "setvalue", "x": 30, "y": 40, "value": "hello"])

      assertEqualObjects(axValue(response, "error_kind"), "application_not_responding")
      assertEqualObjects(axValue(response, "pid"), kAppPid)
      XCTAssertEqual(runtime.setValueCount, writesBefore + 1)
      let reads = status == .applicationNotResponding ? ["readAttributes", "readAttributes"] : ["readAttributes"]
      assertEqualObjects(runtime.operations, ["hitTest", "setValue"] + reads)
    }
  }

  func testUnavailableSetValueDoesNotReadTheValue() {
    self.seedHitElement(withAttributes: [kAXValue: "hello"])
    runtime.writeOutcome = FBAXWriteOutcome.applicationUnavailable()

    let response = AccessibilityService.handleRequest(["verb": "setvalue", "x": 30, "y": 40, "value": "hello"])

    assertEqualObjects(axValue(response, "error_kind"), "application_unavailable")
    XCTAssertEqual(runtime.setValueCount, 1)
    assertEqualObjects(runtime.operations, ["hitTest", "setValue"])
  }

  func testSetValueRequiresAStringValue() {
    self.seedHitElement(withAttributes: [:])
    for value in [NSNumber(value: 123), ["hello"], ["a": NSNumber(value: 1)], NSNull()] as [Any] {
      let response = AccessibilityService.handleRequest(["verb": "setvalue", "x": NSNumber(value: 1), "y": NSNumber(value: 2), "value": value])
      assertEqualObjects(axValue(response, "ok"), NSNumber(value: false), "\(String(describing: type(of: value)))")
      assertEqualObjects(axValue(response, "error"), "setvalue requires a string value", "\(String(describing: type(of: value)))")
    }
    assertEqualObjects(axValue(AccessibilityService.handleRequest(["verb": "setvalue", "x": NSNumber(value: 1), "y": NSNumber(value: 2)]), "error"), "setvalue requires a string value")
    XCTAssertEqual(runtime.hitTestCount, 0)
    XCTAssertEqual(runtime.setValueCount, 0)
  }

  func testAFailedWriteIsARuntimeFailureCarryingTheRuntimeReason() {
    self.seedHitElement(withAttributes: [:])
    runtime.writeOutcome = FBAXWriteOutcome.failed(withAXError: -25205)
    let coded = AccessibilityService.handleRequest(FBAXTestsPress())
    assertEqualObjects(axValue(coded, "error"), "the accessibility runtime rejected the write with AX error -25205 (kAXErrorAttributeUnsupported)")
    assertEqualObjects(axValue(coded, "error_kind"), "runtime_failed")
    assertEqualObjects(axValue(coded, "ax_error"), NSNumber(value: -25205))
    assertEqualObjects(axValue(coded, "pid"), NSNumber(value: kAppPid))

    runtime.writeOutcome = FBAXWriteOutcome.failed("the application did not respond to the write before it timed out")
    let response = AccessibilityService.handleRequest(FBAXTestsPress())
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error"), "the application did not respond to the write before it timed out")
    assertEqualObjects(axValue(response, "error_kind"), "runtime_failed")
    XCTAssertNil(axValue(response, "ax_error"))
    assertEqualObjects(axValue(response, "effect"), "unknown")
  }

  func testAWriteWithAnExplicitPidScopesTheHitTest() {
    self.seedHitElement(withAttributes: [:])
    var request: [String: Any] = FBAXTestsPress()
    request["pid"] = NSNumber(value: kAppPid)

    assertEqualObjects(axValue(AccessibilityService.handleRequest(request), "ok"), NSNumber(value: true))
    XCTAssertEqual(runtime.lastHitTestProcessIdentifier, kAppPid)

    assertEqualObjects(axValue(AccessibilityService.handleRequest(FBAXTestsPress()), "ok"), NSNumber(value: true))
    XCTAssertEqual(runtime.lastHitTestProcessIdentifier, 0, "no pid means a display-wide hit-test")
  }

  // MARK: - Attribute value coercion

  func testPointValuedAttributeIsCarriedThroughStructurally() {
    let point = ["X": NSNumber(value: 201), "Y": NSNumber(value: 789.5)]
    let root = FBAXFakeElement.readable("UIApplication")
    root.attributes = [kAXElementType: "UIApplication", kAXVisiblePoint: point]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let emitted = axValue(axValue(AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)]), "tree"), kAXVisiblePoint)
    XCTAssertTrue((emitted is NSDictionary), "a point stays structured, got \(String(describing: type(of: emitted)))")
    assertEqualObjects(axValue(emitted, "X"), NSNumber(value: 201))
    assertEqualObjects(axValue(emitted, "Y"), NSNumber(value: 789.5))
  }

  func testTheFrameAttributeIsCarriedThroughStructurally() {
    let root = FBAXFakeElement.readable("UIApplication")
    root.attributes = [
      kAXElementType: "UIApplication",
      kAXFrame: ["X": NSNumber(value: 0), "Y": NSNumber(value: 791), "Width": NSNumber(value: 402), "Height": NSNumber(value: 83)],
    ]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let emitted = axValue(axValue(AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)]), "tree"), kAXFrame)
    XCTAssertTrue((emitted is NSDictionary), "the frame stays structured, got \(String(describing: type(of: emitted)))")
    assertEqualObjects(axValue(emitted, "Width"), NSNumber(value: 402))
  }

  // XCTest's reader returns an `NSError` as the attribute's value for any AX failure other than no-value or
  // unsupported.
  func testAnAttributeThatFailedToReadIsEmittedAsItsValue() {
    let failure = NSError(domain: "AXError", code: -25204, userInfo: [NSLocalizedDescriptionKey: "kAXErrorCannotComplete"])
    let root = FBAXFakeElement.readable("UIApplication")
    root.attributes = [kAXElementType: "UIApplication", kAXLabel: failure]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let tree = axValue(AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)]), "tree")
    // Left out, which the host reads the same as null: a failure is not the attribute's value.
    XCTAssertNil(axValue(tree, kAXLabel), "a failure is not the attribute's value")
    assertEqualObjects(axValue(axValue(tree, "FBAttributeReadFailures"), kAXLabel), "kAXErrorCannotComplete", "the failed key is named with its reason rather than silently reading as no value")
  }

  // MARK: - The translator vocabulary seam

  func testATranslatorReadOfALeafAtTheDepthCapDoesNotReportTruncation() {
    let root = FBAXFakeElement.readable("UIApplication")
    root.attributes = [kAXElementType: "UIApplication"]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    runtime.translatorAttributeValues = [NSNumber(value: BridgeAXTranslatorAttribute.label.rawValue): "Settings"]

    let response = AccessibilityService.handleRequest(
      [
        "verb": "describe", "clientType": 0,
        "pid": NSNumber(value: kAppPid),
        "traversal": "semantic",
        "maxDepth": NSNumber(value: 0),
      ]
    )

    assertEqualObjects(axValue(response, "truncated"), NSNumber(value: false), "truncated is NO when the depth cap cut nothing")
  }

  func testATranslatorWalkCostsTwoRoundTripsPerNode() {
    let root = FBAXFakeElement.readable("UIApplication")
    root.attributes = [kAXElementType: "UIApplication"]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    runtime.translatorAttributeValues = [
      NSNumber(value: BridgeAXTranslatorAttribute.label.rawValue): "Settings",
      NSNumber(value: BridgeAXTranslatorAttribute.children.rawValue): [FBAXFakeElement.readable("UIView"), FBAXFakeElement.readable("UIView")],
    ]

    _ = AccessibilityService.handleRequest(
      [
        "verb": "describe", "clientType": 0,
        "pid": NSNumber(value: kAppPid),
        "traversal": "semantic",
        "maxDepth": NSNumber(value: 1),
      ]
    )

    // Three nodes: the root and its two children. Two requests each — one batch of attributes, one for
    // children, which the handler special-cases out of the batch and so cannot be folded into it.
    XCTAssertEqual(runtime.translatorReadCount, 6)
  }

  func testATranslatorReadEmitsTheEnabledAnswerItFetched() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.translatorAttributeValues = [NSNumber(value: BridgeAXTranslatorAttribute.label.rawValue): "General", NSNumber(value: BridgeAXTranslatorAttribute.isEnabled.rawValue): NSNumber(value: false)]

    let response =
      AccessibilityService.handleRequest(["verb": "describe", "clientType": 0, "pid": NSNumber(value: kAppPid), "traversal": "semantic"])

    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(axValue(response, "tree"), kNodeIsEnabled), NSNumber(value: false), "the fetched enabled answer must reach the wire")
  }

  func testATranslatorReadEmitsTheTranslatorsOwnRoleUnmapped() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.translatorAttributeValues = [NSNumber(value: BridgeAXTranslatorAttribute.role.rawValue): NSNumber(value: 9)]

    let tree =
      axValue(AccessibilityService.handleRequest(["verb": "describe", "clientType": 0, "pid": NSNumber(value: kAppPid), "traversal": "semantic"]), "tree")

    assertEqualObjects(axValue(tree, kNodeTranslatorRole), NSNumber(value: 9))
    XCTAssertNil(axValue(tree, kAXElementType), "the translator role must not be emitted under the elementType key")
  }

  // The host derives `interactable` from the XCTest key, so the point must land under it.
  func testATranslatorReadEmitsTheVisiblePoint() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.translatorAttributeValues = [
      NSNumber(value: BridgeAXTranslatorAttribute.visiblePoint.rawValue): NSValue(cgPoint: CGPoint(x: 201, y: 311))
    ]

    let tree =
      axValue(AccessibilityService.handleRequest(["verb": "describe", "clientType": 0, "pid": NSNumber(value: kAppPid), "traversal": "semantic"]), "tree")

    assertEqualObjects(axValue(axValue(tree, "XC_kAXXCAttributeVisiblePoint"), "X"), NSNumber(value: 201))
    assertEqualObjects(axValue(axValue(tree, "XC_kAXXCAttributeVisiblePoint"), "Y"), NSNumber(value: 311))
  }

  func testATranslatorReadEmitsTheTraitsBitmask() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.translatorAttributeValues = [NSNumber(value: BridgeAXTranslatorAttribute.traits.rawValue): NSNumber(value: 1 << 6)]

    let tree =
      axValue(AccessibilityService.handleRequest(["verb": "describe", "clientType": 0, "pid": NSNumber(value: kAppPid), "traversal": "semantic"]), "tree")

    assertEqualObjects(axValue(tree, "FBTraits"), NSNumber(value: 1 << 6))
  }

  func testATranslatorReadEmitsAPerElementIdentity() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.translatorAttributeValues = [NSNumber(value: BridgeAXTranslatorAttribute.memoryAddress.rawValue): NSNumber(value: 0x600001234560)]

    let tree =
      axValue(AccessibilityService.handleRequest(["verb": "describe", "clientType": 0, "pid": NSNumber(value: kAppPid), "traversal": "semantic"]), "tree")

    assertEqualObjects(axValue(tree, "FBElementIdentity"), NSNumber(value: 0x600001234560))
  }

  func testATranslatorReadThatCannotBePerformedIsAFailureNotAnEmptyTree() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.translatorAttributeValues = nil

    let response =
      AccessibilityService.handleRequest(["verb": "describe", "clientType": 0, "pid": NSNumber(value: kAppPid), "traversal": "semantic"])

    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    XCTAssertNil(axValue(response, "tree"), "a read that could not be performed must not answer with a tree")
  }

  // The translator answers synthesized defaults for a pid that names no process; only the availability
  // probe fails this.
  func testATranslatorReadOfAnUnavailableApplicationFailsRatherThanFabricatingARoot() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.applicationUnavailable()
    runtime.translatorAttributeValues = [NSNumber(value: BridgeAXTranslatorAttribute.role.rawValue): NSNumber(value: 1), NSNumber(value: BridgeAXTranslatorAttribute.isEnabled.rawValue): NSNumber(value: true)]

    let response =
      AccessibilityService.handleRequest(["verb": "describe", "clientType": 0, "pid": NSNumber(value: kAppPid), "traversal": "semantic"])

    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error_kind"), "application_unavailable")
    XCTAssertNil(axValue(response, "tree"), "a process with no accessibility server must not answer with a root")
  }

  func testAFusedFrontmostTranslatorReadStillNamesTheResolverThatRan() {
    runtime.windowServerOutcome = FBAXFrontmostOutcome.resolved(kAppPid)
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.translatorAttributeValues = [NSNumber(value: BridgeAXTranslatorAttribute.label.rawValue): "SampleApp"]

    let response =
      AccessibilityService.handleRequest(["verb": "describe", "clientType": 0, "x": NSNumber(value: 201), "y": NSNumber(value: 437), "traversal": "semantic"])

    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(response, "pid"), NSNumber(value: kAppPid))
    assertEqualObjects(axValue(response, "method"), "window-server")
  }

  private func translatorRequest(_ extra: [String: Any] = [:]) -> [String: Any] {
    var request: [String: Any] = ["verb": "describe", "clientType": 0, "pid": kAppPid, "traversal": "semantic"]
    request.merge(extra) { _, new in new }
    return request
  }

  func testTranslatorBatchAndChildrenRequestsPreserveElementIdentity() {
    let root = FBAXFakeElement.readable("UIApplication")
    let child = FBAXFakeElement.readable("UIView")
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    runtime.translatorResponses = [[33: "root"], [8: [child]], [33: "child"], [:]]

    let response = AccessibilityService.handleRequest(translatorRequest())

    assertEqualObjects(axValue(response, "tree"), [kAXLabel: "root", kAXChildren: [[kAXLabel: "child", kAXChildren: []]]])
    let requests = runtime.translatorRequests.compactMap { $0 as? [String: Any] }
    let batch = [33, 21, 25, 53, 32, 27, 45, 51, 112, 77, 128]
    assertEqualObjects(requests.compactMap { $0["attributes"] }, [batch, [8], batch, [8]])
    assertEqualObjects(requests.compactMap { $0["element"] }, [root, root, child, child])
    assertEqualObjects(runtime.lastReadAttributes, [kAXElementType])
    assertEqualObjects(axValue(axValue(response, "phases"), "mach_round_trips"), 4)
  }

  func testTranslatorRequestsChildrenAtTheDepthLimit() {
    let root = FBAXFakeElement.readable("UIApplication")
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    runtime.translatorResponses = [[:], [8: [FBAXFakeElement.readable("child")]]]

    let response = AccessibilityService.handleRequest(translatorRequest(["maxDepth": 0]))

    assertEqualObjects(axValue(response, "tree"), [kAXChildren: []])
    assertEqualObjects(axValue(response, "truncated"), true)
    XCTAssertEqual(runtime.translatorReadCount, 2)
    assertEqualObjects((runtime.translatorRequests.lastObject as? [String: Any])?["attributes"], [8])
  }

  func testTranslatorSkipsAnOrdinaryFailedChildAndKeepsItsSibling() {
    let root = FBAXFakeElement.readable("UIApplication")
    let failed = FBAXFakeElement.readable("failed")
    let sibling = FBAXFakeElement.readable("sibling")
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    runtime.translatorResponses = [[:], [8: [failed, sibling]], NSNull(), [33: "sibling"], [:]]

    let response = AccessibilityService.handleRequest(translatorRequest())

    assertEqualObjects(axValue(response, "tree"), [kAXChildren: [[kAXLabel: "sibling", kAXChildren: []]]])
    assertEqualObjects(axValue(response, "truncated"), false)
    XCTAssertEqual(runtime.translatorReadCount, 5)
  }

  func testTranslatorNilChildrenAreAnEmptySuccessfulNode() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.translatorResponses = [[:], NSNull()]

    let response = AccessibilityService.handleRequest(translatorRequest())

    assertEqualObjects(axValue(response, "ok"), true)
    assertEqualObjects(axValue(response, "tree"), [kAXChildren: []])
    assertEqualObjects(axValue(response, "truncated"), false)
  }

  func testTranslatorChildListExceptionsAbortAndLeaveTheNextRequestUsable() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.translatorAttributeValues = [:]
    runtime.translatorRaiseAtRead = 2

    let response = AccessibilityService.handleRequest(translatorRequest())

    assertEqualObjects(response, ["ok": false, "error": "the reader raised while answering: translator read 2 failed"])
    XCTAssertEqual(runtime.translatorReadCount, 2)
    runtime.translatorRaiseAtRead = 0
    assertEqualObjects(axValue(AccessibilityService.handleRequest(translatorRequest()), "ok"), true)
  }

  func testTranslatorChildExceptionsAbortBeforeTheNextSibling() {
    let root = FBAXFakeElement.readable("UIApplication")
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    runtime.translatorResponses = [[:], [8: [FBAXFakeElement.readable("bad"), FBAXFakeElement.readable("sibling")]]]
    runtime.translatorRaiseAtRead = 3

    let response = AccessibilityService.handleRequest(translatorRequest())

    assertEqualObjects(response, ["ok": false, "error": "the reader raised while answering: translator read 3 failed"])
    XCTAssertEqual(runtime.translatorReadCount, 3)
  }

  func testTranslatorBudgetCountsFailedChildren() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.translatorResponses = [[:], [8: [FBAXFakeElement.readable("bad"), FBAXFakeElement.readable("sibling")]], NSNull()]

    let response = AccessibilityService.handleRequest(translatorRequest(["maxNodes": 2]))

    assertEqualObjects(axValue(response, "tree"), [kAXChildren: []])
    assertEqualObjects(axValue(response, "truncated"), true)
    XCTAssertEqual(runtime.translatorReadCount, 3)
  }

  // MARK: - Unreachable explanations

  private func unreachableRoot(_ visible: Any = false) -> FBAXFakeElement {
    let root = FBAXFakeElement.readable("UIApplication")
    root.attributes = ["XC_kAXXCAttributeIsVisible": visible, "XC_kAXXCAttributeCenterPoint": ["X": 12, "Y": 34]]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    return root
  }

  private func explanationRequest() -> [String: Any] {
    return ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid, "explainUnreachable": true]
  }

  func testUnreachableExplanationReadsTheDisplayWideHitElement() {
    _ = unreachableRoot()
    let overlay = FBAXFakeElement.readable("Overlay")
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(overlay, owningProcessIdentifier: 9000)

    let response = AccessibilityService.handleRequest(explanationRequest())

    let explanation = axValue(axValue(response, "tree"), "FBExplainedBy")
    assertEqualObjects(explanation, [kAXElementType: "Overlay", kAXLabel: "Overlay"])
    XCTAssertEqual(runtime.lastHitTestProcessIdentifier, 0)
    XCTAssertEqual(runtime.lastHitTestPoint, CGPoint(x: 12, y: 34))
    assertEqualObjects(runtime.lastReadAttributes, [kAXElementType, kAXLabel, "XC_kAXXCAttributeIdentifier", kAXFrame, "XC_kAXXCAttributeAutomationType"])
    assertEqualObjects(runtime.operations, ["automationRead", "applicationElement", "readAttributes", "hitTest", "readAttributes"])
    assertEqualObjects(axValue(axValue(response, "phases"), "mach_round_trips"), 3)
  }

  func testUnreachableExplanationOmitsOrdinaryHitTestFailure() {
    _ = unreachableRoot()
    runtime.hitTestOutcome = FBAXHitTestOutcome.applicationNotResponding()

    let response = AccessibilityService.handleRequest(explanationRequest())

    assertEqualObjects(axValue(response, "ok"), true)
    XCTAssertNil(axValue(axValue(response, "tree"), "FBExplainedBy"))
    assertEqualObjects(axValue(axValue(response, "phases"), "mach_round_trips"), 2)
  }

  func testUnreachableExplanationOmitsOrdinaryAttributeReadFailure() {
    _ = unreachableRoot()
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.applicationUnavailable(), owningProcessIdentifier: 9000)

    let response = AccessibilityService.handleRequest(explanationRequest())

    assertEqualObjects(axValue(response, "ok"), true)
    XCTAssertNil(axValue(axValue(response, "tree"), "FBExplainedBy"))
    assertEqualObjects(axValue(axValue(response, "phases"), "mach_round_trips"), 3)
  }

  func testUnreachableExplanationReadExceptionAbortsAndRecovers() {
    _ = unreachableRoot()
    let overlay = FBAXFakeElement.readable("Overlay")
    overlay.readRaiseReason = "explanation failed"
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(overlay, owningProcessIdentifier: 9000)

    assertEqualObjects(AccessibilityService.handleRequest(explanationRequest()), ["ok": false, "error": "the reader raised while answering: explanation failed"])
    overlay.readRaiseReason = nil
    assertEqualObjects(axValue(AccessibilityService.handleRequest(explanationRequest()), "ok"), true)
  }

  func testVisibilityExceptionAbortsBeforeHitTestingAndNextRequestRecovers() {
    let visibility = FBAXFakeVisibilityValue()
    visibility.raises = true
    let root = unreachableRoot(visibility)
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("Overlay"), owningProcessIdentifier: 9000)

    assertEqualObjects(AccessibilityService.handleRequest(explanationRequest()), ["ok": false, "error": "the reader raised while answering: visibility failed"])
    XCTAssertEqual(runtime.hitTestCount, 0)

    root.attributes = ["XC_kAXXCAttributeIsVisible": false, "XC_kAXXCAttributeCenterPoint": ["X": 12, "Y": 34]]
    assertEqualObjects(axValue(AccessibilityService.handleRequest(explanationRequest()), "ok"), true)
    XCTAssertEqual(runtime.hitTestCount, 1)
  }

  // Each value is read once, when its node is built, so a coordinate that raises fails the read before anything is
  // hit-tested.
  func testCentreCoordinateExceptionAbortsBeforeHitTestingAndNextRequestRecovers() {
    let coordinate = FBAXFakeVisibilityValue()
    coordinate.raisesOnNumericRead = true
    let root = unreachableRoot(false)
    let centre: [String: Any] = ["X": coordinate, "Y": 34]
    root.attributes = ["XC_kAXXCAttributeIsVisible": false, "XC_kAXXCAttributeCenterPoint": centre]
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("Overlay"), owningProcessIdentifier: 9000)

    assertEqualObjects(AccessibilityService.handleRequest(explanationRequest()), ["ok": false, "error": "the reader raised while answering: geometry coordinate failed"])
    XCTAssertEqual(runtime.hitTestCount, 0)

    root.attributes = ["XC_kAXXCAttributeIsVisible": false, "XC_kAXXCAttributeCenterPoint": ["X": 12, "Y": 34]]
    assertEqualObjects(axValue(AccessibilityService.handleRequest(explanationRequest()), "ok"), true)
    XCTAssertEqual(runtime.hitTestCount, 1)
  }

  func testReachableAndUnclassifiedNodesDoNotRequestExplanations() {
    for visible in [true, "unknown", NSNull()] as [Any] {
      _ = unreachableRoot(visible)
      assertEqualObjects(axValue(AccessibilityService.handleRequest(explanationRequest()), "ok"), true)
    }
    XCTAssertEqual(runtime.hitTestCount, 0)
  }

  // MARK: - Private attribute values

  func testWrongGeometryTypesAndMalformedDictionariesBecomeNull() {
    let root = FBAXFakeElement.readable("UIApplication")
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    let values: [(String, Any)] = [
      (kAXFrame, NSValue(cgPoint: CGPoint(x: 1, y: 2))),
      (kAXVisiblePoint, NSValue(cgRect: CGRect(x: 1, y: 2, width: 3, height: 4))),
      (kAXFrame, ["X": 1, "Y": 2]),
      (kAXVisiblePoint, ["X": 1]),
    ]
    for (key, value) in values {
      root.attributes = [key: value]
      let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid])
      assertEqualObjects(axValue(response, "ok"), true)
      XCTAssertNil(axValue(axValue(response, "tree"), key), "\(key) as \(value)")
    }
  }

  // The typed node carries a frame's and a point's coordinates; anything else in the dictionary is not part of it.
  func testGeometryDictionariesCarryTheirCoordinates() {
    let root = FBAXFakeElement.readable("UIApplication")
    let frame = ["X": 1, "Y": 2, "Width": 3, "Height": 4, "extra": 5]
    let point = ["X": 1, "Y": 2, "extra": 3]
    root.attributes = [kAXFrame: frame, kAXVisiblePoint: point]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let tree = axValue(AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid]), "tree")

    assertEqualObjects(axValue(tree, kAXFrame), ["X": 1, "Y": 2, "Width": 3, "Height": 4])
    assertEqualObjects(axValue(tree, kAXVisiblePoint), ["X": 1, "Y": 2])
  }

  func testOpaqueValuesUseTheirDescriptionAndContainDescriptionExceptions() {
    let value = FBAXFakeOpaqueValue()
    let root = FBAXFakeElement.readable("UIApplication")
    root.attributes = ["XC_kAXXCAttributeValue": value]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    let request: [String: Any] = ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid]

    assertEqualObjects(axValue(axValue(AccessibilityService.handleRequest(request), "tree"), "XC_kAXXCAttributeValue"), "opaque accessibility value")
    value.raiseReason = "description failed"
    assertEqualObjects(AccessibilityService.handleRequest(request), ["ok": false, "error": "the reader raised while answering: description failed"])
    value.raiseReason = nil
    assertEqualObjects(axValue(AccessibilityService.handleRequest(request), "ok"), true)
  }

  func testCoreGraphicsDictionaryExceptionsAreObservableInsideObjectiveC() {
    for rectangle in [false, true] {
      let healthy = FBAXGeometryDictionaryProbe(rectangle, false)
      assertEqualObjects(healthy["accepted"], true)
      assertEqualObjects(healthy["raised"], false)
      XCTAssertGreaterThan((healthy["lookups"] as? NSNumber)?.intValue ?? 0, 0)

      let raised = FBAXGeometryDictionaryProbe(rectangle, true)
      assertEqualObjects(raised["accepted"], false)
      assertEqualObjects(raised["raised"], true)
      assertEqualObjects(raised["reason"], "geometry dictionary lookup failed")
      XCTAssertGreaterThan((raised["lookups"] as? NSNumber)?.intValue ?? 0, 0)
    }
  }

  func testGeometryDictionaryExceptionsAreContainedAndTheNextRequestSucceeds() {
    let root = FBAXFakeElement.readable("UIApplication")
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    for key in [kAXFrame, "XC_kAXXCAttributeVisiblePoint", "XC_kAXXCAttributeCenterPoint"] {
      let value = FBAXGeometryDictionaryProbeValue.geometry()
      value.raises = true
      root.attributes = [key: value]
      let request: [String: Any] = ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid, "attributes": [key]]
      assertEqualObjects(
        AccessibilityService.handleRequest(request),
        ["ok": false, "error": "the reader raised while answering: geometry dictionary lookup failed"])
      XCTAssertGreaterThan(value.lookups, 0)
      root.attributes = [key: ["X": 1, "Y": 2, "Width": 3, "Height": 4]]
      assertEqualObjects(axValue(AccessibilityService.handleRequest(request), "ok"), true)
    }
  }

  func testGeometryDictionariesAreDetachedBeforeExplanationAndSerialization() throws {
    let root = FBAXFakeElement.readable("UIApplication")
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("Overlay"), owningProcessIdentifier: 9000)
    let centerKey = "XC_kAXXCAttributeCenterPoint"
    for key in [kAXFrame, kAXVisiblePoint, centerKey] {
      let value = FBAXGeometryDictionaryProbeValue.geometry()
      value.maximumSuccessfulLookups = UInt(value.count)
      XCTAssertGreaterThan(value.maximumSuccessfulLookups, 0)
      root.attributes = ["XC_kAXXCAttributeIsVisible": false, key: value]
      let hitTestsBefore = runtime.hitTestCount

      // As the host decodes it off the wire.
      let decoded = AccessibilityService.handleRequest(explanationRequest())

      assertEqualObjects(decoded["ok"], true)
      let expected = key == kAXFrame ? ["X": 1, "Y": 2, "Width": 3, "Height": 4] : ["X": 1, "Y": 2]
      assertEqualObjects(axValue(axValue(decoded, "tree"), key), expected)
      XCTAssertEqual(value.lookups, value.maximumSuccessfulLookups)
      XCTAssertEqual(runtime.hitTestCount, hitTestsBefore + (key == centerKey ? 1 : 0))
      if key == centerKey {
        XCTAssertEqual(runtime.lastHitTestPoint, CGPoint(x: 1, y: 2))
        XCTAssertNotNil(axValue(axValue(decoded, "tree"), "FBExplainedBy"))
      }
    }
  }

  func testOuterAttributeContainersAreDetachedUnderTheRuntimeGuard() throws {
    let root = FBAXFakeElement.readable("UIApplication")
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    let attributes = FBAXGeometryDictionaryProbeValue.attributes()
    runtime.attributeRead = attributes
    attributes.raises = true
    let request: [String: Any] = ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid]

    assertEqualObjects(AccessibilityService.handleRequest(request), ["ok": false, "error": "the reader raised while answering: geometry dictionary lookup failed"])

    attributes.raises = false
    attributes.lookups = 0
    attributes.maximumSuccessfulLookups = UInt(attributes.count)
    let decoded = AccessibilityService.handleRequest(request)
    assertEqualObjects(decoded["ok"], true)
    assertEqualObjects(axValue(decoded["tree"], kAXElementType), "UIApplication")
    assertEqualObjects(axValue(decoded["tree"], kAXLabel), "label")
    XCTAssertEqual(attributes.lookups, attributes.maximumSuccessfulLookups)
    runtime.attributeRead = nil
    assertEqualObjects(axValue(AccessibilityService.handleRequest(request), "ok"), true)
  }

  func testGeometryAccessorExceptionsAreContained() {
    let root = FBAXFakeElement.readable("UIApplication")
    runtime.applicationElements[NSNumber(value: kAppPid)] = root
    for access in ["type", "value"] {
      root.attributes = [kAXFrame: FBAXFakeGeometryValue.throwing(onAccess: access)]
      let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid])
      assertEqualObjects(response, ["ok": false, "error": "the reader raised while answering: geometry \(access) failed"])
    }
  }

  func testFailedChildReadsStillConsumeTheNodeBudget() {
    let root = FBAXFakeElement.readable("UIApplication")
    root.children = [FBAXFakeElement.failed(nil), FBAXFakeElement.readable("sibling")]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid, "maxNodes": 1])

    assertEqualObjects(axValue(axValue(response, "tree"), kAXChildren), [])
    assertEqualObjects(axValue(response, "truncated"), true)
    assertEqualObjects(runtime.operations, ["automationRead", "applicationElement", "readAttributes", "readAttributes"])
  }

  func testFailedDeviceSettingOutcomesRetainTheRuntimeReason() {
    runtime.deviceSettings[NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)] = false
    runtime.deviceSettingReadOutcome = FBAXDeviceSettingOutcome.failed("read failed")
    runtime.deviceSettingWriteOutcome = FBAXDeviceSettingOutcome.failed("write failed")

    assertEqualObjects(AccessibilityService.handleRequest(["verb": "settings-get", "setting": "reduce-motion"]), ["ok": false, "error": "read failed", "error_kind": "reader_unavailable"])
    assertEqualObjects(AccessibilityService.handleRequest(["verb": "settings-set", "setting": "reduce-motion", "enabled": true]), ["ok": false, "error": "write failed", "error_kind": "reader_unavailable"])
  }

  func testDeviceSettingWriteReportsADifferentAuthoritativeState() {
    runtime.deviceSettings[NSNumber(value: FBAXDeviceSetting.reduceMotion.rawValue)] = false
    runtime.deviceSettingWriteOutcome = FBAXDeviceSettingOutcome.resolved(false)

    let response = AccessibilityService.handleRequest(["verb": "settings-set", "setting": "reduce-motion", "enabled": true])

    assertEqualObjects(response, ["ok": true, "enabled": false])
    assertEqualObjects(runtime.deviceSettingWrites, [["setting": FBAXDeviceSetting.reduceMotion.rawValue, "enabled": true]])
  }

  func testBothWriteCommandsReportApplicationTimeoutWithTheOwningPid() {
    self.seedHitElement(withAttributes: [:])
    runtime.writeOutcome = FBAXWriteOutcome.applicationNotResponding()
    for request in [FBAXTestsPress(), ["verb": "setvalue", "x": 1, "y": 2, "value": "text"]] {
      assertEqualObjects(AccessibilityService.handleRequest(request), ["ok": false, "error": "pid 4321 did not respond to the write before it timed out", "error_kind": "application_not_responding", "pid": kAppPid, "effect": "unknown", "timeout_seconds": 5])
    }
    XCTAssertEqual(runtime.performCount, 1)
    XCTAssertEqual(runtime.setValueCount, 1)
  }

  // MARK: - Request-named attributes

  // The fake echoes what it holds, so only the ask can be asserted.
  func testARequestNamingAttributesIsReadWithThem() {
    let root = FBAXFakeElement.readable("UIApplication")
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    _ = AccessibilityService.handleRequest(
      [
        "verb": "describe", "traversal": "view-hierarchy", "clientType": 0,
        "pid": NSNumber(value: kAppPid),
        "attributes": [kAXLabel, kAXVisiblePoint],
      ]
    )
    assertEqualObjects(runtime.lastReadAttributes, ([kAXLabel, kAXVisiblePoint, kAXChildren]))
  }

  func testARequestNamingNoAttributesIsReadWithTheDefaultList() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")

    _ = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])
    assertEqualObjects(
      runtime.lastReadAttributes,
      ([
        "XC_kAXXCAttributeElementType", "XC_kAXXCAttributeElementBaseType", kAXLabel,
        "XC_kAXXCAttributeValue", "XC_kAXXCAttributeIdentifier", kAXFrame,
        "XC_kAXXCAttributeAutomationType", "XC_kAXXCAttributeTraits", kAXChildren,
      ]))
  }

  func testTheChildrenAttributeIsAlwaysRead() {
    let root = FBAXFakeElement.readable("UIApplication")
    root.children = [FBAXFakeElement.readable("XCUIElementTypeWindow")]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response =
      AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid), "attributes": [kAXLabel]])
    XCTAssertTrue(((runtime.lastReadAttributes as NSArray?)?.contains(kAXChildren) == true), "children is always read")
    assertEqualObjects(axValue(axValue(axValue(axValue(response, "tree"), kAXChildren), 0), kAXElementType), "XCUIElementTypeWindow")
  }

  func testAMalformedAttributeListFallsBackToTheDefault() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    let defaultCount = 9

    for malformed in ["XC_kAXXCAttributeLabel", [], [NSNumber(value: 123)], ["a": NSNumber(value: 1)]] as [Any] {
      _ = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid), "attributes": malformed])
      XCTAssertEqual((runtime.lastReadAttributes?.count ?? 0), defaultCount, "a \(String(describing: type(of: malformed))) list falls back")
    }

    _ = AccessibilityService.handleRequest(
      [
        "verb": "describe", "traversal": "view-hierarchy", "clientType": 0,
        "pid": NSNumber(value: kAppPid),
        "attributes": [kAXLabel, NSNumber(value: 123), kAXVisiblePoint],
      ]
    )
    assertEqualObjects(runtime.lastReadAttributes, ([kAXLabel, kAXVisiblePoint, kAXChildren]), "a non-string member is dropped and the rest survives")
  }

  func testAWriteCanAssertOnlyOnAnAttributeItNames() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("XCUIElementTypeButton"), owningProcessIdentifier: kAppPid)

    let unnamed = AccessibilityService.handleRequest(
      [
        "verb": "perform", "x": NSNumber(value: 10), "y": NSNumber(value: 20), "action": "press",
        "assertKey": kAXVisiblePoint, "assertValue": "anything",
      ]
    )
    assertEqualObjects(axValue(unnamed, "ok"), NSNumber(value: false), "an unfetched key is not assertable")
    assertEqualObjects(axValue(unnamed, "error_kind"), "bad_request")

    let named = AccessibilityService.handleRequest(
      [
        "verb": "perform", "x": NSNumber(value: 10), "y": NSNumber(value: 20), "action": "press",
        "attributes": [kAXVisiblePoint],
        "assertKey": kAXVisiblePoint, "assertValue": "anything",
      ]
    )
    assertNotEqualObjects(axValue(named, "error_kind"), "bad_request", "naming the key makes it assertable")
  }

  // MARK: - Describe outcomes

  func testDescribeReadsTheTreeAndReportsThePid() {
    let root = FBAXFakeElement.readable("UIApplication")
    root.children = [FBAXFakeElement.readable("XCUIElementTypeWindow")]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid), "maxDepth": NSNumber(value: 5)])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(response, "pid"), NSNumber(value: kAppPid))
    assertEqualObjects(axValue(response, "truncated"), NSNumber(value: false))
    assertEqualObjects(axValue(axValue(response, "tree"), kAXElementType), "UIApplication")
    assertEqualObjects(axValue(axValue(axValue(axValue(response, "tree"), kAXChildren), 0), kAXElementType), "XCUIElementTypeWindow")
  }

  func testDescribeWithNoApplicationElementIsAFailureNamingThePid() {
    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error"), "no application element for pid 4321")
  }

  func testDescribeOfAnUnreadableRootIsTaggedUnavailable() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.applicationUnavailable()

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error_kind"), "application_unavailable")
    assertEqualObjects(axValue(response, "error"), "pid 4321 has no accessibility server")
    assertEqualObjects(axValue(response, "pid"), NSNumber(value: kAppPid))
  }

  func testDescribeOfARootThatDidNotAnswerIsTaggedNotResponding() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.applicationNotResponding()

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error_kind"), "application_not_responding")
    assertEqualObjects(axValue(response, "error"), "pid 4321 did not respond to the read of its element tree before it timed out")
    assertEqualObjects(axValue(response, "timeout_seconds"), NSNumber(value: 5))
    assertEqualObjects(axValue(response, "pid"), NSNumber(value: kAppPid))
  }

  func testDescribeOfAFailedRootQuotesTheRuntimeOrSaysItReportedNothing() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.failed(FBAXTestsErrorWithCode(FBAXError.invalidUIElement.rawValue))
    let quoted = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])
    assertEqualObjects(axValue(quoted, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(quoted, "error_kind"), "runtime_failed")
    assertEqualObjects(axValue(quoted, "ax_error"), NSNumber(value: FBAXError.invalidUIElement.rawValue))
    assertEqualObjects(axValue(quoted, "pid"), NSNumber(value: kAppPid))
    assertEqualObjects(axValue(quoted, "error"), "failed to read the element tree for pid 4321: runtime said no")

    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.failed(nil)
    let silent = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid)])
    assertEqualObjects(axValue(silent, "error"), "failed to read the element tree for pid 4321: the accessibility runtime reported no error")
    assertEqualObjects(axValue(silent, "error_kind"), "runtime_failed")
    XCTAssertNil(axValue(silent, "ax_error"))
  }

  func testAnUnreadableChildIsDroppedWithoutFailingTheRead() {
    let root = FBAXFakeElement.readable("UIApplication")
    root.children = [
      FBAXFakeElement.readable("first"),
      FBAXFakeElement.applicationUnavailable(),
      FBAXFakeElement.failed(FBAXTestsErrorWithCode(FBAXError.ipcTimeout.rawValue)),
      FBAXFakeElement.readable("last"),
    ]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid), "maxDepth": NSNumber(value: 5)])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true), "an unreadable child must not fail the whole read")
    let children = axValue(axValue(response, "tree"), kAXChildren)
    XCTAssertEqual(axCount(children), 2, "only the readable children survive")
    assertEqualObjects(axValue(axValue(children, 0), kAXLabel), "first")
    assertEqualObjects(axValue(axValue(children, 1), kAXLabel), "last", "a later sibling must survive an earlier failure")
    assertEqualObjects(axValue(response, "truncated"), NSNumber(value: false), "a dropped child is not truncation")
  }

  // UIKit lists a table header's search field both under its container and directly under the table.
  func testAnElementListedUnderTwoParentsIsReportedUnderTheFirstOnly() {
    let field = FBAXFakeElement.readable("UISearchBarTextField")
    field.children = [FBAXFakeElement.readable("UIImageView")]
    let container = FBAXFakeElement.readable("_UISearchBarSearchContainerView")
    container.children = [field]
    let table = FBAXFakeElement.readable("UITableView")
    table.children = [container, field, FBAXFakeElement.readable("Cell")]
    runtime.applicationElements[NSNumber(value: kAppPid)] = table

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid), "maxDepth": NSNumber(value: 5), "maxNodes": NSNumber(value: 5)])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    let children = axValue(axValue(response, "tree"), kAXChildren)
    assertEqualObjects(axValue(axValue(axValue(axValue(children, 0), kAXChildren), 0), kAXLabel), "UISearchBarTextField")
    XCTAssertEqual(axCount(children), 2)
    assertEqualObjects(axValue(axValue(children, 1), kAXLabel), "Cell", "the second listing is skipped without spending the budget")
    assertEqualObjects(axValue(response, "truncated"), NSNumber(value: false))
  }

  func testDepthCapMarksTheReadTruncated() {
    let root = FBAXFakeElement.readable("UIApplication")
    let child = FBAXFakeElement.readable("XCUIElementTypeWindow")
    child.children = [FBAXFakeElement.readable("XCUIElementTypeButton")]
    root.children = [child]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let cut = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid), "maxDepth": NSNumber(value: 1)])
    assertEqualObjects(axValue(cut, "truncated"), NSNumber(value: true))
    XCTAssertEqual(axCount(axValue(axValue(axValue(axValue(cut, "tree"), kAXChildren), 0), kAXChildren)), 0, "descent stopped at the cap")

    let whole = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid), "maxDepth": NSNumber(value: 5)])
    assertEqualObjects(axValue(whole, "truncated"), NSNumber(value: false))
    XCTAssertEqual(axCount(axValue(axValue(axValue(axValue(whole, "tree"), kAXChildren), 0), kAXChildren)), 1)
  }

  func testNodeBudgetExhaustionMarksTheReadTruncated() {
    let root = FBAXFakeElement.readable("UIApplication")
    root.children = [
      FBAXFakeElement.readable("first"),
      FBAXFakeElement.readable("second"),
      FBAXFakeElement.readable("third"),
    ]
    runtime.applicationElements[NSNumber(value: kAppPid)] = root

    let response =
      AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": NSNumber(value: kAppPid), "maxDepth": NSNumber(value: 5), "maxNodes": NSNumber(value: 2)])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(response, "truncated"), NSNumber(value: true))
    XCTAssertEqual(axCount(axValue(axValue(response, "tree"), kAXChildren)), 2, "the walk stopped when the budget ran out")
  }

  // MARK: - Frontmost dispatch

  func testCenterPointResolvesTheAnchorsOwnerAndIsEchoedBack() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("leaf"), owningProcessIdentifier: kAppPid)
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")

    let response = AccessibilityService.handleRequest(
      ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": NSNumber(value: 201), "y": NSNumber(value: 437), "method": "center-point"]
    )
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: true))
    assertEqualObjects(axValue(response, "pid"), NSNumber(value: kAppPid))
    assertEqualObjects(axValue(response, "method"), "center-point")
    XCTAssertEqual(runtime.hitTestCount, 1)
    XCTAssertEqual(runtime.lastHitTestProcessIdentifier, 0, "the frontmost hit-test is display-wide")
    XCTAssertEqual(runtime.lastHitTestPoint.x, 201, "the request's anchor is what gets hit-tested")
  }

  func testEachFrontmostMethodIsDispatchedToItsOwnResolverAndEchoedBack() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")
    runtime.windowServerOutcome = FBAXFrontmostOutcome.resolved(kAppPid)
    runtime.runningBoardOutcome = FBAXFrontmostOutcome.resolved(kAppPid)

    let windowServer =
      AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2), "method": "window-server"])
    assertEqualObjects(axValue(windowServer, "method"), "window-server")
    XCTAssertEqual(runtime.windowServerCount, 1)
    XCTAssertEqual(runtime.runningBoardCount, 0)
    XCTAssertEqual(runtime.hitTestCount, 0)

    let runningBoard =
      AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2), "method": "runningboard"])
    assertEqualObjects(axValue(runningBoard, "method"), "runningboard")
    XCTAssertEqual(runtime.runningBoardCount, 1)
    XCTAssertEqual(runtime.windowServerCount, 1, "the window-server resolver must not run again")
  }

  func testAFailedResolverDoesNotFallBackToAnotherMethod() {
    runtime.windowServerOutcome = FBAXFrontmostOutcome.unresolved("the window server did not answer")
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("leaf"), owningProcessIdentifier: kAppPid)
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")

    let response =
      AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2), "method": "window-server"])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error"), "the window server did not answer")
    // A strategy that could not answer is about the strategy, not about any one application — so it is its
    // own kind, and must not be reported as an application the caller should go and reconfigure.
    assertEqualObjects(axValue(response, "error_kind"), "frontmost_unresolved")
    XCTAssertEqual(runtime.hitTestCount, 0, "no fallback to the positional resolver")
    XCTAssertEqual(runtime.runningBoardCount, 0, "no fallback to RunningBoard")
  }

  func testCenterPointCarriesEachNonResolvingOutcomeThroughAsItsOwnKind() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.empty()
    let empty = AccessibilityService.handleRequest(
      ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": NSNumber(value: 9999), "y": NSNumber(value: 9999), "method": "center-point"]
    )
    assertEqualObjects(axValue(empty, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(empty, "error"), "system-wide hit-test at (9999.0, 9999.0) found no element")
    assertEqualObjects(axValue(empty, "error_kind"), "frontmost_unresolved")

    runtime.hitTestOutcome = FBAXHitTestOutcome.applicationUnavailable()
    let unavailable = AccessibilityService.handleRequest(
      ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": NSNumber(value: 5), "y": NSNumber(value: 6), "method": "center-point"]
    )
    assertEqualObjects(axValue(unavailable, "error"), "no accessibility server responded to the system-wide hit-test at (5.0, 6.0)")
    assertEqualObjects(axValue(unavailable, "error_kind"), "application_unavailable")
    XCTAssertNil(axValue(unavailable, "pid"), "a frontmost query that resolved nothing has no process to name")

    runtime.hitTestOutcome = FBAXHitTestOutcome.applicationNotResponding()
    let notResponding = AccessibilityService.handleRequest(
      ["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": NSNumber(value: 5), "y": NSNumber(value: 6), "method": "center-point"]
    )
    assertEqualObjects(axValue(notResponding, "error"), "the application at (5.0, 6.0) did not respond to the system-wide hit-test before it timed out")
    assertEqualObjects(axValue(notResponding, "error_kind"), "application_not_responding")
    assertEqualObjects(axValue(notResponding, "timeout_seconds"), NSNumber(value: 5))
  }

  func testAnUnsupportedFrontmostMethodConsultsNoResolver() {
    let response =
      AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2), "method": "not-a-method"])
    assertEqualObjects(axValue(response, "ok"), NSNumber(value: false))
    assertEqualObjects(axValue(response, "error"), "unsupported frontmost method: not-a-method")
    assertEqualObjects(axValue(response, "error_kind"), "frontmost_unresolved")
    XCTAssertEqual(runtime.hitTestCount, 0)
    XCTAssertEqual(runtime.windowServerCount, 0)
    XCTAssertEqual(runtime.runningBoardCount, 0)
  }

  func testANonStringMethodFallsBackToTheDefault() {
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("leaf"), owningProcessIdentifier: kAppPid)
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("UIApplication")

    runtime.windowServerOutcome = FBAXFrontmostOutcome.resolved(kAppPid)

    let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "x": NSNumber(value: 1), "y": NSNumber(value: 2), "method": NSNumber(value: 7)])
    assertEqualObjects(axValue(response, "method"), "window-server")
    XCTAssertEqual(runtime.windowServerCount, 1)
  }

  // MARK: - Decoded request coercion

  private var flagCoercionCases: [(Any, Bool)] {
    [("YES", true), ("1", true), ("false", false), ("0", false), (NSNumber(value: 2), true), (NSNumber(value: -1), true), (NSNumber(value: 0), false)]
  }

  func testEachTraversalSelectsItsWalk() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("original")
    runtime.translatorAttributeValues = [33: "translated"]
    // traversal, label read, snapshots taken, translator reads made
    let expected: [(String, String, Int, Int)] = [
      ("view-hierarchy", "original", 0, 0),
      ("single-fetch", "original", 1, 0),
      ("semantic", "translated", 0, 2),
    ]
    for (traversal, label, snapshots, translatorReads) in expected {
      let snapshotsBefore = runtime.snapshotCount
      let translatorReadsBefore = runtime.translatorReadCount

      let response = AccessibilityService.handleRequest(["verb": "describe", "clientType": 0, "pid": kAppPid, "traversal": traversal])

      assertEqualObjects(response["ok"], true)
      assertEqualObjects(axValue(response["tree"], kAXLabel), label)
      XCTAssertEqual(Int(runtime.snapshotCount) - Int(snapshotsBefore), snapshots, traversal)
      XCTAssertEqual(Int(runtime.translatorReadCount) - Int(translatorReadsBefore), translatorReads, traversal)
    }
  }

  func testExplanationFlagPreservesFoundationBooleanCoercion() {
    _ = unreachableRoot()
    runtime.hitTestOutcome = FBAXHitTestOutcome.hit(FBAXFakeElement.readable("overlay"), owningProcessIdentifier: 9000)
    for (value, enabled) in flagCoercionCases {
      let before = runtime.hitTestCount

      let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid, "explainUnreachable": value])

      assertEqualObjects(response["ok"], true)
      XCTAssertEqual(axValue(response["tree"], "FBExplainedBy") != nil, enabled)
      XCTAssertEqual(runtime.hitTestCount - before, enabled ? 1 : 0)
    }
  }

  func testMalformedTraversalFlagsAreRefusedAndRecover() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("root")
    for value in [NSNull(), [], [:]] as [Any] {
      let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid, "explainUnreachable": value])

      assertEqualObjects(response, ["ok": false, "error_kind": "bad_request", "error": "explainUnreachable must be a boolean"])
      assertEqualObjects(AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid])["ok"], true)
    }
    for value in [NSNull(), [], [:], true, "sideways"] as [Any] {
      let response = AccessibilityService.handleRequest(["verb": "describe", "clientType": 0, "pid": kAppPid, "traversal": value])

      assertEqualObjects(response["ok"], false)
      assertEqualObjects(response["error_kind"], "bad_request")
      let error = response["error"] as? String ?? ""
      XCTAssertTrue(error.hasPrefix("unsupported traversal: "), error)
      XCTAssertTrue(error.hasSuffix("; expected one of view-hierarchy, semantic, single-fetch"), error)
      assertEqualObjects(AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid])["ok"], true)
    }
    XCTAssertEqual(runtime.snapshotCount, 0)
    XCTAssertEqual(runtime.translatorReadCount, 0)
    XCTAssertEqual(runtime.hitTestCount, 0)
  }

  func testAnUnknownClientTypeIsRefusedAndRecovers() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("root")
    for value in [12, -1, "xctest"] as [Any] {
      let response = AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "pid": kAppPid, "clientType": value])

      assertEqualObjects(response["ok"], false)
      assertEqualObjects(response["error_kind"], "bad_request")
      let error = response["error"] as? String ?? ""
      XCTAssertTrue(error.hasPrefix("unsupported client type: "), error)
      XCTAssertTrue(error.hasSuffix("; expected an integer from 0 to 11"), error)
      assertEqualObjects(AccessibilityService.handleRequest(["verb": "describe", "traversal": "view-hierarchy", "clientType": 0, "pid": kAppPid])["ok"], true)
    }
  }

  func testAClientTypeOnAnXCTestTraversalIsRefused() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("root")
    for traversal in ["view-hierarchy", "single-fetch"] {
      var request: [String: Any] = ["verb": "describe", "traversal": "view-hierarchy", "pid": kAppPid, "clientType": 4]
      request["traversal"] = traversal
      let response = AccessibilityService.handleRequest(request)

      assertEqualObjects(response["ok"], false)
      assertEqualObjects(response["error_kind"], "bad_request")
      XCTAssertEqual(
        response["error"] as? String,
        "a client type applies only to the semantic traversal: \(traversal) makes no translator request")
    }
    XCTAssertEqual(runtime.snapshotCount, 0)
    XCTAssertEqual(runtime.translatorReadCount, 0)
  }

  func testSnapshotSelectionDoesNotInterpretUnusedTraversalFlags() {
    runtime.applicationElements[NSNumber(value: kAppPid)] = FBAXFakeElement.readable("root")

    let response = AccessibilityService.handleRequest(["verb": "describe", "clientType": 0, "pid": kAppPid, "traversal": "single-fetch", "explainUnreachable": NSNull()])

    assertEqualObjects(response["ok"], true)
    assertEqualObjects(axValue(response["tree"], kAXLabel), "root")
    XCTAssertEqual(runtime.snapshotCount, 1)
    XCTAssertEqual(runtime.translatorReadCount, 0)
    XCTAssertEqual(runtime.hitTestCount, 0)
  }

  // A value of the wrong type is named as JSON names it; a list or an object by its kind, not its contents.
  func testUnsupportedVerbNamesWhatWasSent() {
    let cases: [(Any, String)] = [(123, "123"), (1.5, "1.5"), (true, "true"), (NSNull(), "null"), (["describe"], "an array"), (["a": 1], "an object")]
    for (value, description) in cases {
      let response = AccessibilityService.handleRequest(["verb": value])

      assertEqualObjects(response, ["ok": false, "error_kind": "bad_request", "error": "unsupported verb: \(description)"])
    }
    assertEqualObjects(runtime.operations, [])
  }

  // A value of the wrong type is named as JSON names it; a list or an object by its kind, not its contents.
  func testUnsupportedActionNamesWhatWasSent() {
    let cases: [(Any, String)] = [(123, "123"), (1.5, "1.5"), (true, "true"), (NSNull(), "null"), (["press"], "an array"), (["a": 1], "an object")]
    for (value, description) in cases {
      let response = AccessibilityService.handleRequest(["verb": "perform", "action": value, "x": 1, "y": 2])

      assertEqualObjects(response, ["ok": false, "error_kind": "bad_request", "error": "unsupported action: \(description)"])
    }
    assertEqualObjects(runtime.operations, [])
  }

}

private func axValue(_ object: Any?, _ key: AnyHashable, file: StaticString = #filePath, line: UInt = #line) -> Any? {
  if let dictionary = object as? NSDictionary { return dictionary[key] }
  if let array = object as? NSArray, let index = key as? Int { return array[index] }
  if object != nil { XCTFail("Expected a dictionary or array", file: file, line: line) }
  return nil
}

private func assertEqualObjects(_ lhs: Any?, _ rhs: Any?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
  if let lhs {
    XCTAssertTrue((lhs as AnyObject as? NSObject)?.isEqual(rhs) == true, message, file: file, line: line)
  } else {
    XCTAssertNil(rhs, message, file: file, line: line)
  }
}

private func assertNotEqualObjects(_ lhs: Any?, _ rhs: Any?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
  if let lhs {
    XCTAssertFalse((lhs as AnyObject as? NSObject)?.isEqual(rhs) == true, message, file: file, line: line)
  } else {
    XCTAssertNotNil(rhs, message, file: file, line: line)
  }
}

private func axCount(_ object: Any?, file: StaticString = #filePath, line: UInt = #line) -> Int {
  guard let object else { return 0 }
  if let array = object as? NSArray { return array.count }
  XCTFail("Expected an array", file: file, line: line)
  return 0

}
