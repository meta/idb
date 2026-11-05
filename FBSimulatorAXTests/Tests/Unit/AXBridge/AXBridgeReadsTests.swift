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
@testable import FBSimulatorServices
import Foundation
import XCTest

/// Coverage for the axbridge read path that does not require a live simulator.
final class AXBridgeReadsTests: XCTestCase {

  // MARK: - AXTreeRead envelope parsing

  func testParsesTreeFromOkEnvelope() throws {
    let tree: [String: Any] = [
      AXWire.Node.label.rawValue: "General",
      AXWire.Node.identifier.rawValue: "com.apple.settings.general",
    ]
    let data = try treeAnswer(tree, pid: 42)
    let parsed = try AXTreeRead(wholeTreeResponse: data, pid: 42)
    XCTAssertEqual(parsed.tree.label, BridgeAXScalar.string("General"))
    XCTAssertEqual(parsed.tree.identifier, BridgeAXScalar.string("com.apple.settings.general"))
    XCTAssertFalse(parsed.truncated, "a whole-tree read with no truncated flag is a complete tree")
  }

  func testParsesTruncatedFlagWhenGuestReportsAPartialTree() throws {
    // A guest walk cut short by the depth or node bound tags its envelope `truncated: true`, so the
    // conformer can warn the tree is incomplete rather than pass it off as whole.
    let tree: [String: Any] = [AXWire.Node.label.rawValue: "root"]
    let data = try treeAnswer(tree, pid: 42, truncated: true)
    let parsed = try AXTreeRead(wholeTreeResponse: data, pid: 42)
    XCTAssertTrue(parsed.truncated, "the guest's truncation flag must be surfaced to the caller")
  }

  func testParsesTheAutomationStateFromTheEnvelope() throws {
    let tree: [String: Any] = [AXWire.Node.label.rawValue: "root"]
    let data = try treeAnswer(tree, pid: 42, automation: BridgeAXAutomationState(enabled: true, asserted: false))
    let parsed = try AXTreeRead(wholeTreeResponse: data, pid: 42)
    XCTAssertEqual(parsed.automation?.enabled, true)
    XCTAssertEqual(parsed.automation?.asserted, false)
  }

  // Nil, not `enabled: false`: a guest predating the field did not say what mode the device was in, which is a
  // different fact from saying it was off.
  func testAnEnvelopeWithoutAutomationReportsNothingRatherThanOff() throws {
    let tree: [String: Any] = [AXWire.Node.label.rawValue: "root"]
    let data = try treeAnswer(tree, pid: 42)
    let parsed = try AXTreeRead(wholeTreeResponse: data, pid: 42)
    XCTAssertNil(parsed.automation, "an absent automation object must not read as automation mode being off")
  }

  func testSurfacesGuestErrorMessage() throws {
    // An untagged failure (no `error_kind`) is an opaque `guestFailure` carrying the guest's own
    // message, so callers see the real cause.
    let data = try failureAnswer("the accessibility server is not responding")
    XCTAssertThrowsError(try AXTreeRead(wholeTreeResponse: data, pid: 7)) { error in
      guard case AXBridgeError.guestFailure = error else {
        return XCTFail("an untagged failure should be a guestFailure, got: \(error)")
      }
      XCTAssertTrue("\(error)".contains("the accessibility server is not responding"), "unexpected error: \(error)")
    }
  }

  func testApplicationUnavailableErrorKindThrowsTypedCase() throws {
    // The guest error becomes the backend-neutral error shared with the accessibility backend.
    let data = try failureAnswer("no application element for pid 7", kind: "application_unavailable")
    XCTAssertThrowsError(try AXTreeRead(wholeTreeResponse: data, pid: 7)) { error in
      guard case let AXBridgeError.applicationUnavailable(pid) = error else {
        return XCTFail("a tagged failure should be applicationUnavailable, got: \(error)")
      }
      XCTAssertEqual(pid, 7)
    }
  }

  // MARK: - What the parser does with the guest's failure kind and reason

  func testFusedFrontmostRaisesTheGuestsKindAndCarriesItsReason() throws {
    // The reader's binding failure text is the most actionable message the guest produces; it reaches the caller
    // intact and as its own case.
    let data = try failureAnswer("XCTAccessibilityFramework unavailable — is XCTAutomationSupport loaded?", kind: "reader_unavailable")
    XCTAssertThrowsError(try AXTreeRead(frontmostResponse: data, method: .centerPoint)) { error in
      guard case let AXBridgeError.readerUnavailable(reason) = error else {
        return XCTFail("expected readerUnavailable, got: \(error)")
      }
      XCTAssertEqual(reason, "XCTAccessibilityFramework unavailable — is XCTAutomationSupport loaded?")
      XCTAssertTrue("\(error)".contains("XCTAccessibilityFramework"), "the reason must reach the message: \(error)")
    }
  }

  func testFusedFrontmostApplicationUnavailableKindThrowsApplicationUnavailable() throws {
    // `application_unavailable` means the same on a frontmost read as on `--pid`; no pid because nothing resolved.
    let data = try failureAnswer("no accessibility server answered the system-wide hit-test at (201.0, 437.0)", kind: "application_unavailable")
    XCTAssertThrowsError(try AXTreeRead(frontmostResponse: data, method: .centerPoint)) { error in
      guard case let AXBridgeError.applicationUnavailable(pid) = error else {
        return XCTFail("expected applicationUnavailable, got: \(error)")
      }
      XCTAssertNil(pid, "a frontmost read that resolved nothing has no pid to name")
    }
  }

  // `frontmostUnresolved` names the strategy the caller selected — the other two may well answer, so which one
  // was asked for is the actionable half.
  func testFusedFrontmostNamesTheStrategyThatCouldNotAnswer() throws {
    let data = try failureAnswer("AXPTranslator unavailable — is AccessibilityPlatformTranslation loaded?", kind: "frontmost_unresolved")
    XCTAssertThrowsError(try AXTreeRead(frontmostResponse: data, method: .windowServer)) { error in
      guard case let AXBridgeError.frontmostUnresolved(method, reason) = error else {
        return XCTFail("expected frontmostUnresolved, got: \(error)")
      }
      XCTAssertEqual(method, .windowServer)
      XCTAssertEqual(reason, "AXPTranslator unavailable — is AccessibilityPlatformTranslation loaded?")
      XCTAssertTrue("\(error)".contains("window-server"), "the message must name the strategy: \(error)")
    }
  }

  func testHitTestRaisesTheGuestsFailureKind() throws {
    // All three parsers classify alike: a tagged hit-test failure is the typed case, not an opaque
    // one, and the pid the guest reported rides with it.
    let data = try failureAnswer("pid 8865 has no accessibility server to hit-test", kind: "application_unavailable", pid: 8865)
    XCTAssertThrowsError(try AXTreeRead(hitTestResponse: data)) { error in
      guard case let AXBridgeError.applicationUnavailable(pid) = error else {
        return XCTFail("expected applicationUnavailable, got: \(error)")
      }
      XCTAssertEqual(pid, 8865, "the guest's reported pid must ride out on the error")
    }
  }

  func testAnApplicationThatDidNotAnswerIsItsOwnCase() throws {
    // A live app that did not answer is distinct from one that is gone — the reason the guest classifies
    // the AX timeout at all — so it must not land in the same bucket as a reader bug.
    let data = try failureAnswer("pid 8865 did not respond to the read of its element tree before it timed out", kind: "application_not_responding", pid: 8865)
    XCTAssertThrowsError(try AXTreeRead(wholeTreeResponse: data, pid: 8865)) { error in
      guard case let AXBridgeError.applicationNotResponding(pid) = error else {
        return XCTFail("expected applicationNotResponding, got: \(error)")
      }
      XCTAssertEqual(pid, 8865)
    }
  }

  // A host only ever reads its own revision's guest, which writes every answer whole, so an answer it could not have
  // written is refused as unparseable rather than read as something else.
  func testAnAnswerThisRevisionsGuestCannotWriteIsRefused() throws {
    let answers = [
      #"{"failure":{"reason":{"error":"gone","error_kind":"application_unavailable","pid":99999999999}}}"#,
      #"{"failure":{"reason":{"error":"something new went wrong","error_kind":"some_future_kind"}}}"#,
      #"{"tree":{"response":{"automation":{"enabled":true},"pid":42,"tree":{},"truncated":false}}}"#,
      #"{"tree":{"response":{"modal":{"elementType":"X","kind":"bogus"},"pid":42,"tree":{},"truncated":false}}}"#,
    ]
    for answer in answers {
      XCTAssertThrowsError(try AXTreeRead(wholeTreeResponse: Data(answer.utf8), pid: 42), answer) { error in
        guard case let AXBridgeError.guestFailure(message) = error else {
          return XCTFail("expected guestFailure, got: \(error)")
        }
        XCTAssertTrue(message.contains("unparseable guest response"), message)
      }
    }
  }

  func testThrowsOnMalformedResponse() {
    let data = Data("this is not json".utf8)
    XCTAssertThrowsError(try AXTreeRead(wholeTreeResponse: data, pid: 1))
  }

  func testThrowsWhenOkButNoTree() throws {
    let data = Data(#"{"tree":{"response":{"pid":1,"truncated":false}}}"#.utf8)
    XCTAssertThrowsError(try AXTreeRead(wholeTreeResponse: data, pid: 1))
  }

  func testThrowsWhenNotOk() throws {
    // A tree that is not wrapped as an answer's response is not an answer, rather than an empty tree.
    let data = Data(#"{"tree":{"XC_kAXXCAttributeLabel":"x"}}"#.utf8)
    XCTAssertThrowsError(try AXTreeRead(wholeTreeResponse: data, pid: 1))
  }

  // MARK: - One error type across backends

  // A caller holding `any UIAutomation` does not statically know its backend, so one catch clause must handle
  // every backend.
  func testOneCatchClauseHandlesEveryBackend() {
    let backends: [UIAutomationBackend] = [.accessibility, .axBridge(persistence: .oneShot, frontmostMethod: .centerPoint, automationMode: true), .axBridge(persistence: .shared, frontmostMethod: .centerPoint, automationMode: true)]
    for backend in backends {
      let thrown: Error = UIAutomationError.elementNotFound(backend: backend, key: "AXLabel", value: "General")
      guard case let UIAutomationError.elementNotFound(caught, key, value) = thrown else {
        return XCTFail("\(backend) did not match the shared case")
      }
      XCTAssertEqual(caught, backend)
      XCTAssertEqual(key, "AXLabel")
      XCTAssertEqual(value, "General")
      let description = (thrown as? LocalizedError)?.errorDescription ?? ""
      XCTAssertTrue(description.contains(backend.displayName), "message should name the backend: \(description)")
      XCTAssertTrue(description.contains("General"), "message should name the marker: \(description)")
    }
  }

  // MARK: - What a read costs is decided by its key set

  // The reachability attributes cost a hit-test per node, so the default set must not contain them.
  func testTheDefaultKeySetAsksForNoReachabilityAttribute() {
    for expensive: AXKeys in [.interactable, .occludedBy] {
      XCTAssertFalse(
        AXKeys.defaultSet.contains(expensive),
        "\(expensive.rawValue) costs a hit-test per node and must stay out of the default set"
      )
    }
  }

  // A default read sends no attribute list, so the guest uses its own default — identical to a request from a host
  // that predates the field.
  func testADefaultReadNamesNoAttributesOnTheWire() {
    XCTAssertNil(
      AXWire.Node.fetchList(for: AXKeys.defaultSet),
      "a default read must leave the attribute list off the wire entirely"
    )
  }

  // A filter chooses which elements to report, not what the read fetches, so `--filter interactable`
  // does not make the application hit-test every node.
  func testTheInteractableFilterDoesNotWidenTheRead() {
    var options = AccessibilityRequestOptions()
    options.filter = .interactable
    XCTAssertFalse(
      options.serializationKeys.contains(.interactable),
      "a filter must not pull the verdict into a key set the caller did not ask for"
    )
    XCTAssertNil(
      AXWire.Node.fetchList(for: options.serializationKeys),
      "so a filtered read still names no attributes on the wire, exactly like an unfiltered one"
    )
  }

  // Asking for the verdict still fetches the attributes it is derived from.
  func testAskingForTheVerdictStillFetchesWhatDerivesIt() {
    var options = AccessibilityRequestOptions()
    options.filter = .interactable
    options.keys = AXKeys.defaultSet.union([.interactable])
    let fetchList = AXWire.Node.fetchList(for: options.serializationKeys)
    for reachability in AXWire.Node.interactableAttributes {
      XCTAssertTrue(
        fetchList?.contains(reachability.rawValue) ?? false,
        "\(reachability.rawValue) is fetched because the caller asked for the verdict, not because a filter did"
      )
    }
  }

  // The traits bitmask comes back in the same round trip as the rest of the node, so a read that reports
  // `traits` fetches it.
  func testAReadReportingTraitsFetchesTheTraitsBitmask() {
    let fetched = AXWire.Node.fetchList(for: AXKeys.defaultSet) ?? AXWire.Node.defaultFetchList
    XCTAssertTrue(fetched.contains("XC_kAXXCAttributeTraits"))
  }

  // Decoding the bitmask costs the application time per node, so a read that does not report `traits` must not
  // pay for it, with or without the reachability attributes.
  func testAReadNotReportingTraitsDoesNotFetchTheBitmask() {
    for keys: Set<AXKeys> in [[.label, .frame], [.label, .frame, .interactable]] {
      let fetched = AXWire.Node.fetchList(for: keys) ?? AXWire.Node.defaultFetchList
      XCTAssertFalse(fetched.contains("XC_kAXXCAttributeTraits"), "\(keys.map(\.rawValue).sorted())")
    }
  }

  // MARK: - Where the accessibility-server remediation is offered

  private static let axBridge = UIAutomationBackend.axBridge(persistence: .oneShot, frontmostMethod: .centerPoint, automationMode: true)

  // Only an application with no accessibility server gets the flag guidance: an empty point is a successful read of
  // blank space, and a marker that never appeared is about the app's state.
  func testOnlyAnUnreadableApplicationOffersTheAccessibilityServerGuidance() {
    let unavailable = UIAutomationError.applicationUnavailable(backend: Self.axBridge, pid: 8865)
    XCTAssertTrue(unavailable.description.contains("ApplicationAccessibilityEnabled"), "got: \(unavailable.description)")
    XCTAssertTrue(unavailable.description.contains("pid 8865"), "the message must name the process: \(unavailable.description)")

    let empty = UIAutomationError.noElementAtPoint(backend: Self.axBridge, x: 2000, y: 2000)
    XCTAssertFalse(empty.description.contains("ApplicationAccessibilityEnabled"), "got: \(empty.description)")
    XCTAssertTrue(empty.description.contains("found no element at (2000.0, 2000.0)"), "an empty point must say so: \(empty.description)")

    let timedOut = UIAutomationError.timedOut(backend: Self.axBridge, key: "AXLabel", value: "General", timeout: 5)
    XCTAssertFalse(timedOut.description.contains("ApplicationAccessibilityEnabled"), "got: \(timedOut.description)")
    XCTAssertTrue(timedOut.description.contains("timed out after 5.0s waiting for an element whose AXLabel contains \"General\""), "a timeout must say what did not happen: \(timedOut.description)")
  }

  // A display-wide read that resolved nothing has no pid, so the message says where it looked instead of
  // printing a zero — and still offers the guidance, the condition being the same one.
  func testAnUnreadableApplicationWithNoResolvedPidSaysWhereItLooked() {
    let error = UIAutomationError.applicationUnavailable(backend: Self.axBridge, pid: nil)
    XCTAssertTrue(error.description.contains("at that point"), "got: \(error.description)")
    XCTAssertFalse(error.description.contains("pid 0"), "a missing pid must not print as zero: \(error.description)")
    XCTAssertTrue(error.description.contains("ApplicationAccessibilityEnabled"), "got: \(error.description)")
  }

  // One message per condition, so a reader can tell the causes apart without asking the backend.
  func testEachFailureModeStatesItsOwnCause() {
    let cases: [(any LocalizedError, String)] = [
      (AXBridgeError.readerUnavailable("XCTAccessibilityFramework unavailable"), "could not bind"),
      (AXBridgeError.frontmostUnresolved(method: .runningBoard, reason: "Client not entitled"), "runningboard strategy"),
      (UIAutomationError.applicationNotResponding(backend: Self.axBridge, pid: 8865), "did not respond to an accessibility request before it timed out"),
      (UIAutomationError.applicationUnavailable(backend: Self.axBridge, pid: 8865), "accessibility server has not started"),
      (UIAutomationError.noElementAtPoint(backend: Self.axBridge, x: 1, y: 2), "found no element at (1.0, 2.0)"),
    ]
    var descriptions: Set<String> = []
    for (error, expected) in cases {
      let description = error.errorDescription ?? ""
      XCTAssertTrue(description.contains(expected), "expected \"\(expected)\" in: \(description)")
      descriptions.insert(description)
    }
    XCTAssertEqual(descriptions.count, cases.count, "no two failure modes may share a message")
  }

  // `frontmostUnresolved` states the guest's own reason; a genuinely missing accessibility server is tagged
  // `application_unavailable` by the guest and arrives as the case that does carry guidance.
  func testTheFailuresThatAreNotAboutTheFlagOfferNoAccessibilityGuidance() {
    let errors: [String: any LocalizedError] = [
      "readerUnavailable": AXBridgeError.readerUnavailable("XCTAccessibilityFramework unavailable"),
      "frontmostUnresolved": AXBridgeError.frontmostUnresolved(method: .windowServer, reason: "AXPTranslator unavailable"),
      "applicationNotResponding": UIAutomationError.applicationNotResponding(backend: Self.axBridge, pid: 8865),
    ]
    for (name, error) in errors {
      XCTAssertFalse(
        (error.errorDescription ?? "").contains("ApplicationAccessibilityEnabled"),
        "\(name) must not offer a remedy that cannot apply to it: \(error.errorDescription ?? "")"
      )
    }
  }

  func testValueMismatchIsSeamCatchableAndNamesTheMismatch() {
    // A `tap` value assertion is a fact about the query, not the transport, so it is the neutral `UIAutomationError`,
    // catchable by a caller holding `any UIAutomation`.
    let thrown: Error = UIAutomationError.valueMismatch(
      backend: .accessibility, key: AXSearchableKey.value.rawValue, expected: "On", actual: "Off"
    )
    guard case let UIAutomationError.valueMismatch(backend, key, expected, actual) = thrown else {
      return XCTFail("value mismatch should match the shared case, got: \(thrown)")
    }
    XCTAssertEqual(backend, .accessibility)
    XCTAssertEqual(key, "AXValue")
    XCTAssertEqual(expected, "On")
    XCTAssertEqual(actual, "Off")
    let description = (thrown as? LocalizedError)?.errorDescription ?? ""
    XCTAssertTrue(description.contains("The accessibility backend"), "message should name the backend: \(description)")
    XCTAssertTrue(description.contains("AXValue"), "message should name the key: \(description)")
    XCTAssertTrue(description.contains("On") && description.contains("Off"), "message should name both values: \(description)")
  }

  // MARK: - What a client can recover from a rendered axbridge failure

  private static let overlongSocketPath = "/tmp/" + String(repeating: "a", count: 115) + ".sock"

  /// Every pre-tree axbridge failure a client can be handed, and exactly what each one reads as.
  ///
  /// `ErrorMapping` renders a thrown error to `errorDescription` and the gRPC status carries that text
  /// and nothing else, so this is the whole of what reaches `idb`'s stderr, and all a consumer has to
  /// work from. The two application conditions appear as `UIAutomationError` because the conformer
  /// re-raises them backend-neutrally, and twice each because a display-wide read resolves no pid.
  private static let renderedAxbridgeFailures: [(name: String, error: any LocalizedError, expected: String)] = [
    (
      "bridgeUnavailable",
      AXBridgeError.bridgeUnavailable,
      "The SimulatorFrameworkBridge guest binary was not found in the companion Resources directory"
    ),
    (
      "readerUnavailable",
      AXBridgeError.readerUnavailable("XCTAccessibilityFramework unavailable"),
      "The axbridge guest reader could not bind the simulator's accessibility runtime: XCTAccessibilityFramework unavailable"
    ),
    (
      "frontmostUnresolved",
      AXBridgeError.frontmostUnresolved(method: .windowServer, reason: "no frontmost application"),
      "axbridge could not resolve the frontmost application using the window-server strategy: no frontmost application"
    ),
    (
      "guestApplicationUnavailable",
      AXBridgeError.applicationUnavailable(pid: 8865),
      "The axbridge guest found no readable application with pid 8865"
    ),
    (
      "guestApplicationUnavailableWithoutPid",
      AXBridgeError.applicationUnavailable(pid: nil),
      "The axbridge guest found no readable application at that point"
    ),
    (
      "guestApplicationNotResponding",
      AXBridgeError.applicationNotResponding(pid: 8865),
      "The application with pid 8865 did not respond to an accessibility request before it timed out"
    ),
    (
      "assertionFailed",
      AXBridgeError.assertionFailed("the element there is not the one named"),
      "The axbridge guest refused the write: the element there is not the one named"
    ),
    (
      "socketPathTooLong",
      AXBridgeError.socketPathTooLong(path: AXBridgeReadsTests.overlongSocketPath, limit: 104),
      "The axbridge serve socket path is 125 bytes, over the 104-byte sockaddr_un limit, so no guest can be reached at it: \(AXBridgeReadsTests.overlongSocketPath)"
    ),
    (
      "guestDiedBeforeBinding",
      AXBridgeError.guestDiedBeforeBinding(pid: 8901, signal: 9, exitCode: nil, path: "/tmp/axbridge.sock"),
      "The axbridge guest (pid 8901) was killed by signal 9 before binding its serve socket at /tmp/axbridge.sock"
    ),
    (
      "guestFailure",
      AXBridgeError.guestFailure("the guest reported a failure with nothing further to say"),
      "The axbridge guest failed: the guest reported a failure with nothing further to say"
    ),
    (
      "applicationUnavailable",
      UIAutomationError.applicationUnavailable(backend: AXBridgeReadsTests.axBridge, pid: 8865),
      "The axbridge backend could not read the application with pid 8865: it is not a running app, or its accessibility server has not started. \(AccessibilityGuidance.accessibilityServer)"
    ),
    (
      "applicationUnavailableWithoutPid",
      UIAutomationError.applicationUnavailable(backend: AXBridgeReadsTests.axBridge, pid: nil),
      "The axbridge backend could not read the application at that point: it is not a running app, or its accessibility server has not started. \(AccessibilityGuidance.accessibilityServer)"
    ),
    (
      "applicationNotResponding",
      UIAutomationError.applicationNotResponding(backend: AXBridgeReadsTests.axBridge, pid: 8865),
      "The application with pid 8865 did not respond to an accessibility request before it timed out"
    ),
    (
      "applicationNotRespondingWithoutPid",
      UIAutomationError.applicationNotResponding(backend: AXBridgeReadsTests.axBridge, pid: nil),
      "The application at that point did not respond to an accessibility request before it timed out"
    ),
    (
      "applicationUnavailableNamed",
      UIAutomationError.applicationUnavailable(backend: AXBridgeReadsTests.axBridge, pid: 8865, bundleID: "com.example.app"),
      "The axbridge backend could not read the application with pid 8865: it is not a running app, or its accessibility server has not started. Pid 8865 is com.example.app. \(AccessibilityGuidance.accessibilityServer)"
    ),
    (
      "applicationNotRespondingNamed",
      UIAutomationError.applicationNotResponding(backend: AXBridgeReadsTests.axBridge, pid: 8865, bundleID: "com.example.app"),
      "The application with pid 8865 did not respond to an accessibility request before it timed out. Pid 8865 is com.example.app."
    ),
    (
      "applicationNotRespondingNamedWithoutPid",
      UIAutomationError.applicationNotResponding(backend: AXBridgeReadsTests.axBridge, pid: nil, bundleID: "com.example.app"),
      "The application at that point did not respond to an accessibility request before it timed out"
    ),
  ]

  /// What a consumer can parse a kind out of a rendered message by: an `axbridge[<kind>]` tag leading
  /// the message, with a `,pid=<n>` clause where the failure named a process. Found by scanning rather
  /// than anchoring, because a client appends its own context to the text it received.
  private static func kindToken(in description: String) -> String? {
    guard let open = description.range(of: "axbridge["),
      let close = description.range(of: "]", range: open.upperBound..<description.endIndex)
    else {
      return nil
    }
    return String(description[open.upperBound..<close.lowerBound])
  }

  func testEachAxbridgeFailureRendersExactlyThis() {
    for failure in Self.renderedAxbridgeFailures {
      XCTAssertEqual(failure.error.errorDescription, failure.expected, "\(failure.name) renders differently")
    }
  }

  // A client is handed one string and nothing else, so a kind it can act on has to be in that string.
  func testTheRenderedAxbridgeFailuresCarryTheseKindTokens() {
    let tokens = Self.renderedAxbridgeFailures.map { Self.kindToken(in: $0.error.errorDescription ?? "") }
    // BUG: no failure renders a machine-readable kind, so a consumer can only pattern-match the prose —
    // flipped in the following commit.
    XCTAssertEqual(tokens, Array(repeating: nil, count: Self.renderedAxbridgeFailures.count))
  }

  // The tag is an axbridge convention. The legacy backend has no guest and no kinds, so its messages
  // must never claim one.
  func testTheLegacyBackendRendersNoAxbridgeKindToken() {
    let errors: [(String, any LocalizedError)] = [
      ("applicationUnavailable", UIAutomationError.applicationUnavailable(backend: .accessibility, pid: 8865)),
      ("applicationNotResponding", UIAutomationError.applicationNotResponding(backend: .accessibility, pid: 8865)),
      ("noElementAtPoint", UIAutomationError.noElementAtPoint(backend: .accessibility, x: 1, y: 2)),
    ]
    for (name, error) in errors {
      let description = error.errorDescription ?? ""
      XCTAssertNil(Self.kindToken(in: description), "\(name) must carry no kind token: \(description)")
    }
  }

  // A query fact is not a guest failure kind: an empty point is a successful read, and a marker that
  // never appeared is about the app. Tagging those would invent vocabulary the guest never reported.
  func testAxbridgeQueryFailuresCarryNoKindToken() {
    let errors: [(String, any LocalizedError)] = [
      ("noElementAtPoint", UIAutomationError.noElementAtPoint(backend: Self.axBridge, x: 1, y: 2)),
      ("elementNotFound", UIAutomationError.elementNotFound(backend: Self.axBridge, key: "AXLabel", value: "General")),
      ("timedOut", UIAutomationError.timedOut(backend: Self.axBridge, key: "AXLabel", value: "General", timeout: 5)),
    ]
    for (name, error) in errors {
      let description = error.errorDescription ?? ""
      XCTAssertNil(Self.kindToken(in: description), "\(name) must carry no kind token: \(description)")
    }
  }

  // MARK: - Automation-mode default

  func testSelectingAxbridgeByResolvedNameAssertsAutomationMode() {
    for name in [UIAutomationBackendName.axBridgeOneShot, .axBridgePersistent] {
      guard case let .axBridge(_, _, automationMode) = UIAutomationBackend(resolvedName: name) else {
        return XCTFail("\(name) did not select an axbridge backend")
      }
      XCTAssertEqual(automationMode, true, "selecting \(name) by name asserts automation mode")
    }
  }

  // The tri-state has to survive the enum, not just the wire. `false` is what reproduces the child-cache
  // fault and what measures the mode's cost, and it must not collapse into "did not ask".
  func testTheAxbridgeBackendCarriesAnExplicitlyDisabledAutomationMode() {
    guard case let .axBridge(_, _, off) = UIAutomationBackend(resolvedName: .axBridgeOneShot, automationMode: false),
      case let .axBridge(_, _, unset) = UIAutomationBackend(resolvedName: .axBridgeOneShot, automationMode: nil)
    else {
      return XCTFail("expected axbridge backends")
    }
    XCTAssertEqual(off, false, "explicitly off is carried, not dropped")
    XCTAssertNil(unset, "and is distinct from observing without asking")
  }

  // MARK: - Profile shape per backend

  private func timings(
    roundTrip: CFAbsoluteTime, decode: CFAbsoluteTime, traverse: CFAbsoluteTime?, machRoundTrips: Int64?,
    responseBytes: Int64 = 1024
  ) -> AXReadTimings {
    AXReadTimings(
      roundTrip: roundTrip, decode: decode, traverse: traverse, machRoundTrips: machRoundTrips,
      responseBytes: responseBytes)
  }

  // On a one-shot read most of the round trip is not the walk; the residual attributes it rather than losing it.
  func testTheResidualIsTheRoundTripLessTheWalk() {
    let t = timings(roundTrip: 0.387, decode: 0.004, traverse: 0.023, machRoundTrips: 134)
    XCTAssertEqual(t.residual, 0.364, accuracy: 0.0001, "387ms round trip less a 23ms walk")
  }

  // A guest that does not report its walk must not make the residual look like the whole read *plus* a
  // phantom walk, nor go negative.
  func testTheResidualDegradesToTheRoundTripWhenTheGuestDidNotReportAWalk() {
    let t = timings(roundTrip: 0.2, decode: 0.001, traverse: nil, machRoundTrips: nil)
    XCTAssertEqual(t.residual, 0.2, accuracy: 0.0001)
  }

  // Clocks are not monotonic across processes, and a guest reporting a walk longer than the host's round
  // trip is possible. A negative duration is worse than a clamped one: it would poison any aggregate.
  func testTheResidualNeverGoesNegative() {
    let t = timings(roundTrip: 0.010, decode: 0.001, traverse: 0.050, machRoundTrips: 10)
    XCTAssertEqual(t.residual, 0, "a walk longer than the round trip clamps rather than going negative")
  }

  // MARK: - Suspect-geometry guidance

  private func summary(total: Int, zeroFrame: Int) -> AccessibilityFrameSummary {
    AccessibilityFrameSummary(total: total, framed: total - zeroFrame, zeroFrame: zeroFrame)
  }

  // A well-formed, untruncated, error-free read whose elements have lost their geometry: nothing else in the
  // response distinguishes it, so this is the one place in the read path allowed a threshold.
  func testMostlyUnframedReadsAreAdvisedAboutAutomationMode() {
    let advice = AccessibilityGuidance.zeroFrameAdvice(summary(total: 190, zeroFrame: 167))
    XCTAssertNotNil(advice)
    XCTAssertTrue(advice?.contains("AutomationEnabled") == true, "got: \(advice ?? "nil")")
  }

  func testFullyFramedReadsAreNotAdvised() {
    XCTAssertNil(AccessibilityGuidance.zeroFrameAdvice(summary(total: 176, zeroFrame: 0)))
  }

  // A handful of unframed elements is ordinary. The advice is about a whole screen having lost its
  // geometry, not about any element that reports none.
  func testASmallReadIsNotJudged() {
    XCTAssertNil(
      AccessibilityGuidance.zeroFrameAdvice(summary(total: 4, zeroFrame: 4)),
      "reads below the size threshold produce no advice, whatever their ratio"
    )
  }

  // Nil rather than zeroes means the read carried no frames at all, which is a caller's choice via
  // `--key`. Advising on it would be answering a question they did not ask.
  func testAReadCarryingNoFramesIsNotAdvised() {
    XCTAssertNil(AccessibilityGuidance.zeroFrameAdvice(nil))
  }

  // MARK: - Which read failures a marker wait polls through

  // An app still launching has no frontmost, no readable tree and no accessibility server, and acquires
  // all three shortly, so a wait is right to keep polling through those.
  func testAWaitPollsThroughTheFailuresAnAppStillLaunchingProduces() {
    let transient: [String: AXBridgeError] = [
      "frontmostUnresolved": .frontmostUnresolved(method: .centerPoint, reason: "found no element"),
      "applicationUnavailable": .applicationUnavailable(pid: 8865),
      "applicationNotResponding": .applicationNotResponding(pid: 8865),
      "guestFailure": .guestFailure("something transient"),
    ]
    for (name, error) in transient {
      XCTAssertTrue(error.isTransientDuringMarkerWait, "\(name) must not end the wait")
    }
  }

  func testEveryRetryVerdictAndReasonHasItsWireValue() {
    let expected: [(UIAutomationRetry, String, String)] = [
      (.nothingWritten, "safe", "nothing_written"),
      (.idempotent, "safe", "idempotent"),
      (.rereadFirst, "safe_after_reread", "nothing_written"),
      (.outcomeUnknown, "unsafe", "outcome_unknown"),
      (.willNotChange, "unsafe", "will_not_change"),
    ]
    for (retry, verdict, reason) in expected {
      XCTAssertEqual(retry.verdict.rawValue, verdict, "\(retry)")
      XCTAssertEqual(retry.reason.rawValue, reason, "\(retry)")
    }
  }

  func testEachUIAutomationFailureSaysWhetherItIsSafeToRetry() {
    let backend = UIAutomationBackend.axBridge(persistence: .shared, frontmostMethod: .centerPoint, automationMode: true)
    let cases: [(UIAutomationError, UIAutomationRetry)] = [
      (.elementNotFound(backend: backend, key: "label", value: "General"), .nothingWritten),
      (.elementNotOnScreen(backend: backend, key: "label", value: "General"), .nothingWritten),
      (.frameUnavailable(backend: backend, query: .frontmost), .nothingWritten),
      (.noElementAtPoint(backend: backend, x: 1, y: 2), .nothingWritten),
      (.timedOut(backend: backend, key: "label", value: "General", timeout: 5), .nothingWritten),
      (.applicationUnavailable(backend: backend, pid: 42), .nothingWritten),
      (.applicationNotResponding(backend: backend, pid: 42), .nothingWritten),
      (.valueMismatch(backend: backend, key: "label", expected: "General", actual: "Wi-Fi"), .rereadFirst),
      (.elementMoved(backend: backend, key: "label", value: "General"), .rereadFirst),
      (.writeUnconfirmed(backend: backend, idempotent: false, underlying: AXBridgeError.guestFailure("x")), .outcomeUnknown),
      (.writeUnconfirmed(backend: backend, idempotent: true, underlying: AXBridgeError.guestFailure("x")), .idempotent),
      (.markerRequired(backend: backend, operation: "Wait"), .willNotChange),
      (.pointOrMarkerRequired(backend: backend, operation: "A tap"), .willNotChange),
      (.invalidPollInterval(backend: backend, pollInterval: -1), .willNotChange),
      (.operationUnsupported(backend: backend, operation: "Quiescence"), .willNotChange),
      (.traversalCannotAnswer(backend: backend, traversal: "single-fetch", keys: ["interactable"]), .willNotChange),
    ]
    for (error, retry) in cases {
      XCTAssertEqual(error.retry, retry, "\(error)")
      XCTAssertEqual(UIAutomationRetry(for: error), retry)
    }
  }

  // A marker wait polls through exactly the bridge failures that are safe to send again as they were.
  func testEachBridgeFailureSaysWhetherItIsSafeToRetry() {
    let cases: [(AXBridgeError, UIAutomationRetry)] = [
      (.frontmostUnresolved(method: .centerPoint, reason: "found no element"), .nothingWritten),
      (.guestFailure("something transient"), .nothingWritten),
      (.applicationUnavailable(pid: 42), .nothingWritten),
      (.applicationNotResponding(pid: 42), .nothingWritten),
      (.assertionFailed("moved"), .rereadFirst),
      (.bridgeUnavailable, .willNotChange),
      (.readerUnavailable("XCTAccessibilityFramework unavailable"), .willNotChange),
      (.socketPathTooLong(path: "/x", limit: 104), .willNotChange),
      (.guestDiedBeforeBinding(pid: 4242, signal: 6, exitCode: nil, path: "/x/y.sock"), .willNotChange),
    ]
    for (error, retry) in cases {
      XCTAssertEqual(error.retry, retry, "\(error)")
      XCTAssertEqual(error.isTransientDuringMarkerWait, retry.verdict == .safe, "\(error)")
    }
  }

  func testAnErrorFromOutsideUIAutomationHasNoVerdict() {
    XCTAssertNil(UIAutomationRetry(for: CancellationError()))
  }

  func testAReadThatTimedOutOrMetARestartingSpringBoardIsSafeToRetry() {
    let errors: [AccessibilityError] = [
      .serviceNotAnswering(.request(kind: "multiple_attribute", timeout: 5), elapsed: 5, behindAbandoned: 0),
      .serviceNotAnswering(.query(timeout: 10), elapsed: 10, behindAbandoned: 0),
      .springBoardRestarting(exitedProcessIdentifier: 42, restartedAgo: 1),
    ]
    for error in errors {
      XCTAssertEqual(UIAutomationRetry(for: error), .nothingWritten, "\(error)")
    }
  }

  // Neither of these changes by being asked again, so both end the wait with what they already know
  // rather than being replaced by a timeout once the deadline passes.
  func testAWaitEndsAtOnceOnAFailureThatCannotResolveItself() {
    XCTAssertFalse(
      AXBridgeError.readerUnavailable("XCTAccessibilityFramework unavailable").isTransientDuringMarkerWait,
      "readerUnavailable is not transient; the wait must end immediately"
    )
    XCTAssertFalse(AXBridgeError.bridgeUnavailable.isTransientDuringMarkerWait)
    // Polling through this one re-spawns a guest that cannot start, once per poll interval, and still
    // ends in a timeout that has thrown away the signal it already had.
    XCTAssertFalse(
      AXBridgeError.guestDiedBeforeBinding(pid: 4242, signal: 6, exitCode: nil, path: "/x/y.sock")
        .isTransientDuringMarkerWait
    )
  }

  /// A legacy provider's sole display, or the inner of two displays with its accessibility identity
  /// already known. `changing` reports a rotated display on every read after the first.
  private func displays(legacy: Bool = false, changing: Bool = false) -> DisplayCommandsDouble {
    func target(_ rotation: SimulatorDisplayRotation) -> SimulatorDisplayTarget {
      let geometry = SimulatorDisplayGeometry(bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: rotation)
      guard !legacy else { return .sole(.legacy(geometry)) }
      return .selected(
        SimulatorDisplay(
          uniqueID: "inner", name: "Inner", activity: .active, isPrimary: false, isIntegrated: true,
          bounds: geometry.bounds, scale: geometry.scale, rotation: geometry.rotation))
    }
    let displays = changing ? DisplayCommandsDouble(target(.clockwise), target(.upright)) : DisplayCommandsDouble(target(.clockwise))
    displays.identities.remember([SimulatorAccessibilityDisplay(uniqueID: "inner", displayID: 82)], verified: [.scopedInteractions, .scopedTrees])
    return displays
  }

  func testDisplayScopedPointReadKeepsInterfaceCoordinatesAndMetadata() async throws {
    for legacy in [false, true] {
      let transport = try StubAXBridgeWaitTransport(responses: [
        hitAnswer([AXWire.Node.label.rawValue: "target"], pid: 42)
      ])
      let reader = AXBridgeUIAutomation(
        simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
        transport: transport, persistence: .exclusive, displays: displays(legacy: legacy))
      let response = try await reader.describe(.point(CGPoint(x: 80, y: 180)), options: AccessibilityRequestOptions())
      let requests = await transport.requests
      XCTAssertEqual(requests.count, 1)
      guard case let .hitTest(x, y, _, _, displayID, _) = requests[0] else { return XCTFail("\(requests[0])") }
      XCTAssertEqual(x, 180)
      XCTAssertEqual(y, 320)
      XCTAssertEqual(displayID, legacy ? nil : 82)
      XCTAssertEqual(response.screen?.width, 400)
      XCTAssertEqual(response.screen?.height, 600)
      XCTAssertEqual(response.screen?.display?.uniqueID, legacy ? nil : "inner")
      XCTAssertEqual(response.screen?.display?.rotation, 90)
    }
  }

  func testSelectingTheActiveDisplayOrItsConfigurationReadsIt() async throws {
    for selection in [DisplaySelection.display(uniqueID: "inner"), .configuration(generation: 1)] {
      let transport = try StubAXBridgeWaitTransport(responses: [
        hitAnswer([AXWire.Node.label.rawValue: "target"], pid: 42)
      ])
      let reader = AXBridgeUIAutomation(
        simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
        transport: transport, persistence: .exclusive, displays: displays(), selection: selection)
      let response = try await reader.describe(.point(CGPoint(x: 80, y: 180)), options: AccessibilityRequestOptions())
      XCTAssertEqual(response.screen?.display?.uniqueID, "inner", "\(selection)")
      let requests = await transport.requests
      XCTAssertEqual(requests.first?.displayID, 82, "\(selection)")
    }
  }

  func testSelectingAnInactiveDisplaySendsNothing() async throws {
    let transport = StubAXBridgeWaitTransport(responses: [])
    let reader = AXBridgeUIAutomation(
      simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
      transport: transport, persistence: .exclusive, displays: displays(), selection: .display(uniqueID: "inner-inactive"))
    do {
      try await reader.tap(.point(CGPoint(x: 80, y: 180)), options: TapOptions())
      XCTFail("Expected an inactive display")
    } catch { guard case SimulatorDisplayInteractionError.inactiveDisplay("inner-inactive") = error else { return XCTFail("\(error)") } }
    let count = await transport.readCount
    XCTAssertEqual(count, 0)
  }

  func testSelectingAStaleConfigurationSendsNothing() async throws {
    let transport = StubAXBridgeWaitTransport(responses: [])
    let reader = AXBridgeUIAutomation(
      simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
      transport: transport, persistence: .exclusive, displays: displays(), selection: .configuration(generation: 2))
    do {
      _ = try await reader.describe(.frontmost, options: AccessibilityRequestOptions())
      XCTFail("Expected a display change")
    } catch { guard case SimulatorDisplayError.changed = error else { return XCTFail("\(error)") } }
    let count = await transport.readCount
    XCTAssertEqual(count, 0)
  }

  func testMarkerWritePinsDisplayAcrossLookupAndWrite() async throws {
    let displays = displays()
    let transport = try StubAXBridgeWaitTransport(responses: [
      treeAnswer(
        [
          AXWire.Node.label.rawValue: "target",
          AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(CGRect(x: 60, y: 160, width: 40, height: 40)) as NSDictionary,
        ], pid: 42),
      writtenAnswer(pid: 42),
    ])
    let reader = AXBridgeUIAutomation(
      simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
      transport: transport, persistence: .exclusive, displays: displays)
    try await reader.tap(.marker(value: "target", key: .label, depth: 10), options: TapOptions())
    // One resolution, then a check before the write and another after the operation.
    XCTAssertEqual(displays.reads, 3)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].displayID, 82)
    guard case let .write(write) = requests[1] else { return XCTFail("\(requests[1])") }
    XCTAssertEqual(write.displayID, 82)
    XCTAssertEqual(write.x, 180)
    XCTAssertEqual(write.y, 320)
    XCTAssertEqual(write.assertion?.value, "target")
    XCTAssertEqual(write.pid, 42)
  }

  func testTreeScreenUsesPinnedGeometryWithoutRewritingElementFrames() async throws {
    for query in [AccessibilityElementQuery.frontmost, .marker(value: "target", key: .label, depth: 10)] {
      let transport = try StubAXBridgeWaitTransport(responses: [
        treeAnswer(
          [
            AXWire.Node.label.rawValue: "target",
            AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(CGRect(x: 0, y: 0, width: 600, height: 400)) as NSDictionary,
          ], pid: 42)
      ])
      let reader = AXBridgeUIAutomation(
        simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
        transport: transport, persistence: .exclusive, displays: displays())
      let response = try await reader.describe(query, options: AccessibilityRequestOptions(keys: [.frameDict]))
      XCTAssertEqual(response.screen?.width, 400)
      XCTAssertEqual(response.screen?.height, 600)
      XCTAssertEqual(response.screen?.display?.uniqueID, "inner")
      let frame = try XCTUnwrap(response.elements.elements.first?.frame ?? nil)
      XCTAssertEqual(frame.width, 600)
      XCTAssertEqual(frame.height, 400)
    }
  }

  func testDisplayChangeBeforeWriteSendsNoAction() async throws {
    let transport = StubAXBridgeWaitTransport(responses: [])
    let reader = AXBridgeUIAutomation(
      simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
      transport: transport, persistence: .exclusive, displays: displays(changing: true))
    do {
      try await reader.tap(.point(CGPoint(x: 80, y: 180)), options: TapOptions())
      XCTFail("Expected display change")
    } catch { guard case SimulatorDisplayError.changed = error else { return XCTFail("\(error)") } }
    let count = await transport.readCount
    XCTAssertEqual(count, 0)
  }

  func testDisplayChangeBeforeDragSendsNoGesture() async throws {
    let reader = AXBridgeUIAutomation(
      simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
      transport: StubAXBridgeWaitTransport(responses: []), persistence: .exclusive, displays: displays(changing: true))
    do {
      try await reader.drag(from: .point(CGPoint(x: 80, y: 180)), to: .point(CGPoint(x: 120, y: 220)), options: DragOptions())
      XCTFail("Expected display change")
    } catch { guard case SimulatorDisplayError.changed = error else { return XCTFail("\(error)") } }
  }

  func testDisplayChangeDuringReadDiscardsResult() async throws {
    let transport = try StubAXBridgeWaitTransport(responses: [waitMatchingEnvelope()])
    let reader = AXBridgeUIAutomation(
      simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
      transport: transport, persistence: .exclusive, displays: displays(changing: true))
    do {
      _ = try await reader.describe(.frontmost, options: AccessibilityRequestOptions())
      XCTFail("Expected display change")
    } catch { guard case SimulatorDisplayError.changed = error else { return XCTFail("\(error)") } }
    let count = await transport.readCount
    XCTAssertEqual(count, 1)
  }

  private func nativeWaitReader(
    responses: [Data], runningApplications: (@Sendable () async throws -> [String: pid_t])? = nil
  ) -> (AXBridgeUIAutomation, StubAXBridgeWaitTransport) {
    let transport = StubAXBridgeWaitTransport(responses: responses)
    let reader = AXBridgeUIAutomation(
      simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
      transport: transport,
      persistence: .exclusive,
      runningApplications: runningApplications
    )
    return (reader, transport)
  }

  private func waitErrorEnvelope(_ kind: String) throws -> Data {
    try failureAnswer("read failed", kind: kind, pid: 42)
  }

  private func waitMatchingEnvelope() throws -> Data {
    try treeAnswer([AXWire.Node.label.rawValue: "ready"], pid: 42)
  }

  private func tapMatchingEnvelope() throws -> Data {
    try treeAnswer(
      [
        AXWire.Node.label.rawValue: "General",
        AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(CGRect(x: 10, y: 100, width: 100, height: 44)),
      ], pid: 42)
  }

  func testMarkerTapRetriesATransientTargetReadTimeout() async throws {
    let (reader, transport) = try nativeWaitReader(responses: [
      waitErrorEnvelope("application_not_responding"), tapMatchingEnvelope(), writtenAnswer(pid: 42),
    ])
    try await reader.tap(.marker(value: "General", key: .label, depth: 10), options: TapOptions())
    let reads = await transport.readCount
    let writes = await transport.writeCount
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(writes, 1)
  }

  // Frontmost resolution can name an app that has since exited, such as one that is being relaunched.
  func testMarkerTapRereadsAFrontmostAppThatHasExited() async throws {
    let (reader, transport) = try nativeWaitReader(responses: [
      waitErrorEnvelope("application_unavailable"), tapMatchingEnvelope(), writtenAnswer(pid: 42),
    ])
    try await reader.tap(.marker(value: "General", key: .label, depth: 10), options: TapOptions())
    let reads = await transport.readCount
    let writes = await transport.writeCount
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(writes, 1)
  }

  func testMarkerTapDoesNotRepeatATimedOutWrite() async throws {
    let (reader, transport) = try nativeWaitReader(responses: [
      tapMatchingEnvelope(), waitErrorEnvelope("application_not_responding"), writtenAnswer(pid: 42),
    ])
    do {
      try await reader.tap(.marker(value: "General", key: .label, depth: 10), options: TapOptions())
      XCTFail("a timed-out press has an unknown outcome")
    } catch let UIAutomationError.writeUnconfirmed(_, idempotent, underlying) {
      XCTAssertFalse(idempotent)
      guard case UIAutomationError.applicationNotResponding? = underlying as? UIAutomationError else {
        return XCTFail("expected the unanswered write underneath, got \(underlying)")
      }
    }
    let reads = await transport.readCount
    let writes = await transport.writeCount
    XCTAssertEqual(reads, 1)
    XCTAssertEqual(writes, 1)
  }

  private func writeFailure(
    _ write: (AXBridgeUIAutomation) async throws -> Void,
    guestFailure: BridgeAXFailure
  ) async throws -> any Error {
    let (reader, _) = try nativeWaitReader(responses: [tapMatchingEnvelope(), answerData(.failure(guestFailure))])
    do {
      try await write(reader)
    } catch {
      return error
    }
    XCTFail("the write must fail")
    return CancellationError()
  }

  private let markerTap: (AXBridgeUIAutomation) async throws -> Void = {
    try await $0.tap(.marker(value: "General", key: .label, depth: 10), options: TapOptions())
  }

  private let markerSetValue: (AXBridgeUIAutomation) async throws -> Void = {
    try await $0.setValue("hello", for: .marker(value: "General", key: .label, depth: 10))
  }

  func testAWriteTheGuestNeverSentKeepsItsErrorAndIsSafeToRetry() async throws {
    for write in [markerTap, markerSetValue] {
      let error = try await writeFailure(
        write,
        guestFailure: BridgeAXFailure(
          message: "pid 42 did not respond to the write before it timed out", kind: .applicationNotResponding, pid: 42, effect: BridgeAXWire.Effect.none))
      guard case UIAutomationError.applicationNotResponding? = error as? UIAutomationError else {
        return XCTFail("expected applicationNotResponding, got \(error)")
      }
      XCTAssertEqual(UIAutomationRetry(for: error), .nothingWritten)
    }
  }

  func testAWriteThatCouldNotReachTheGuestKeepsItsError() async throws {
    for write in [markerTap, markerSetValue] {
      // The stub has no response for the write, so sending it fails as a missing guest binary would.
      let (reader, _) = try nativeWaitReader(responses: [tapMatchingEnvelope()])
      do {
        try await write(reader)
        XCTFail("the write must fail")
      } catch {
        guard case AXBridgeError.bridgeUnavailable? = error as? AXBridgeError else {
          return XCTFail("expected bridgeUnavailable, got \(error)")
        }
        XCTAssertEqual(UIAutomationRetry(for: error), .willNotChange)
      }
    }
  }

  func testAOneshotPointWriteWithNoGuestBinaryKeepsItsError() async throws {
    let transport = AXBridgeOneshotTransport(
      transport: SimulatorFrameworkBridgeOneshotTransport(launcher: MissingGuestLauncher()))
    let reader = AXBridgeUIAutomation(
      simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
      transport: transport,
      persistence: .exclusive
    )
    let point = AccessibilityElementQuery.point(CGPoint(x: 80, y: 180))
    let writes: [(AXBridgeUIAutomation) async throws -> Void] = [
      { try await $0.tap(point, options: TapOptions()) },
      { try await $0.setValue("hello", for: point) },
    ]
    for write in writes {
      do {
        try await write(reader)
        XCTFail("the write must fail")
      } catch {
        guard case AXBridgeError.bridgeUnavailable? = error as? AXBridgeError else {
          return XCTFail("expected bridgeUnavailable, got \(error)")
        }
        XCTAssertEqual(UIAutomationRetry(for: error), .willNotChange)
      }
    }
  }

  func testAnApplicationFailureNamesTheAppTheSimulatorRunsWithItsPid() async throws {
    struct ListingFailed: Error {}
    let lookups: [(name: String, running: @Sendable () async throws -> [String: pid_t], bundleID: String?)] = [
      ("running", { ["com.example.app": 42, "com.example.other": 7] }, "com.example.app"),
      ("notRunning", { ["com.example.other": 7] }, nil),
      ("listingFailed", { throw ListingFailed() }, nil),
    ]
    for kind in ["application_unavailable", "application_not_responding"] {
      for lookup in lookups {
        let reader = try AXBridgeUIAutomation(
          simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
          transport: StubAXBridgeWaitTransport(responses: [waitErrorEnvelope(kind)]), persistence: .exclusive,
          runningApplications: lookup.running)
        do {
          _ = try await reader.describe(.frontmost, options: AccessibilityRequestOptions())
          XCTFail("\(kind) \(lookup.name): expected a failure")
        } catch let UIAutomationError.applicationUnavailable(_, pid, bundleID), let UIAutomationError.applicationNotResponding(_, pid, bundleID) {
          XCTAssertEqual(pid, 42, "\(kind) \(lookup.name)")
          XCTAssertEqual(bundleID, lookup.bundleID, "\(kind) \(lookup.name)")
        }
      }
    }
  }

  func testOnlyAnApplicationFailureThatReachesTheCallerListsTheRunningApps() async throws {
    let listings = RunningApplicationListings()
    let running: @Sendable () async throws -> [String: pid_t] = {
      await listings.record()
      return ["com.example.app": 42]
    }
    let (waiter, _) = try nativeWaitReader(
      responses: [waitErrorEnvelope("application_unavailable"), waitMatchingEnvelope()], runningApplications: running)
    try await waiter.wait(.marker(value: "ready", key: .label, depth: 10), timeout: 5, pollInterval: 0)
    let afterWait = await listings.count
    XCTAssertEqual(afterWait, 0, "a failed poll is read again, so it names no app")

    let (tapper, _) = try nativeWaitReader(
      responses: [waitErrorEnvelope("application_not_responding"), waitErrorEnvelope("application_not_responding")],
      runningApplications: running)
    do {
      try await tapper.tap(.marker(value: "General", key: .label, depth: 10), options: TapOptions())
      XCTFail("an unresolved target must fail")
    } catch let UIAutomationError.applicationNotResponding(_, _, bundleID) {
      XCTAssertEqual(bundleID, "com.example.app")
    }
    let afterTap = await listings.count
    XCTAssertEqual(afterTap, 1, "only the target read that is not repeated names the app")
  }

  func testASlowListingLeavesTheFailureUnnamedWithoutWaitingForIt() async throws {
    let (reader, _) = try nativeWaitReader(
      responses: [waitErrorEnvelope("application_unavailable")],
      runningApplications: {
        // Detached, so the listing ignores the cancellation the deadline sends it.
        await Task.detached { try? await Task.sleep(nanoseconds: 60_000_000_000) }.value
        return ["com.example.app": 42]
      })
    let started = Date()
    do {
      _ = try await reader.describe(.frontmost, options: AccessibilityRequestOptions())
      XCTFail("expected a failure")
    } catch let UIAutomationError.applicationUnavailable(_, pid, bundleID) {
      XCTAssertEqual(pid, 42)
      XCTAssertNil(bundleID)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
  }

  func testASentPressThatWasNotConfirmedIsUnsafeToRetryWithItsMessageUnchanged() async throws {
    let error = try await writeFailure(
      markerTap,
      guestFailure: BridgeAXFailure(message: "pid 42 did not respond to the write before it timed out", kind: .applicationNotResponding, pid: 42, effect: .unknown))
    let retry = try XCTUnwrap(UIAutomationRetry(for: error))
    XCTAssertEqual(retry, .outcomeUnknown)
    XCTAssertEqual(retry.verdict, .unsafe)
    XCTAssertEqual(
      error.localizedDescription,
      "The application with pid 42 did not respond to an accessibility request before it timed out"
    )
  }

  func testASentValueThatWasNotConfirmedIsSafeToRetryBecauseItIsIdempotent() async throws {
    let error = try await writeFailure(
      markerSetValue,
      guestFailure: BridgeAXFailure(
        message: "the accessibility runtime rejected the write with AX error -25200 (kAXErrorFailure)", kind: .runtimeFailed, pid: 42, axError: -25200,
        effect: .unknown))
    XCTAssertEqual(UIAutomationRetry(for: error), .idempotent)
    XCTAssertEqual(error.localizedDescription, "The axbridge guest failed: the accessibility runtime rejected the write with AX error -25200 (kAXErrorFailure)")
  }

  // A failure that names no `effect` can only mean the write may have been sent.
  func testAWriteFailureWithNoEffectIsTreatedAsPossiblySent() async throws {
    let error = try await writeFailure(
      markerTap,
      guestFailure: BridgeAXFailure(message: "pid 42 did not respond to the write before it timed out", kind: .applicationNotResponding, pid: 42))
    XCTAssertEqual(UIAutomationRetry(for: error), .outcomeUnknown)
  }

  func testMarkerTapBoundsTargetReadAttempts() async throws {
    let (reader, transport) = try nativeWaitReader(responses: [
      waitErrorEnvelope("application_not_responding"), waitErrorEnvelope("application_not_responding"), tapMatchingEnvelope(),
    ])
    do {
      try await reader.tap(.marker(value: "General", key: .label, depth: 10), options: TapOptions())
      XCTFail("an unresolved target must fail")
    } catch UIAutomationError.applicationNotResponding {
    }
    let reads = await transport.readCount
    let writes = await transport.writeCount
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(writes, 0)
  }

  func testMarkerTapRetriesAMovedElement() async throws {
    let (reader, transport) = try nativeWaitReader(responses: [
      tapMatchingEnvelope(), waitErrorEnvelope("assertion_failed"),
      tapMatchingEnvelope(), writtenAnswer(pid: 42),
    ])
    try await reader.tap(.marker(value: "General", key: .label, depth: 10), options: TapOptions())
    let reads = await transport.readCount
    let writes = await transport.writeCount
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(writes, 2)
  }

  func testMarkerTapBoundsMovedElementAttempts() async throws {
    let (reader, transport) = try nativeWaitReader(responses: [
      tapMatchingEnvelope(), waitErrorEnvelope("assertion_failed"),
      tapMatchingEnvelope(), waitErrorEnvelope("assertion_failed"),
    ])
    do {
      try await reader.tap(.marker(value: "General", key: .label, depth: 10), options: TapOptions())
      XCTFail("an element that keeps moving must fail")
    } catch UIAutomationError.elementMoved {
    }
    let reads = await transport.readCount
    let writes = await transport.writeCount
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(writes, 2)
  }

  func testMarkerSetValueRetriesAMovedElement() async throws {
    let (reader, transport) = try nativeWaitReader(responses: [
      tapMatchingEnvelope(), waitErrorEnvelope("assertion_failed"),
      tapMatchingEnvelope(), writtenAnswer(pid: 42),
    ])
    try await reader.setValue("hello", for: .marker(value: "General", key: .label, depth: 10))
    let reads = await transport.readCount
    let writes = await transport.writeCount
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(writes, 2)
  }

  private func assertNativeWaitRecovers(from kind: String) async throws {
    let (reader, transport) = try nativeWaitReader(responses: [
      waitErrorEnvelope(kind), waitMatchingEnvelope(),
    ])
    try await reader.wait(.marker(value: "ready", key: .label, depth: 10), timeout: 5, pollInterval: 0)
    let readCount = await transport.readCount
    XCTAssertEqual(readCount, 2, "wait must retry the failed read before finding the marker")
  }

  func testNativeWaitRetriesApplicationUnavailable() async throws {
    try await assertNativeWaitRecovers(from: "application_unavailable")
  }

  func testNativeWaitRetriesApplicationNotResponding() async throws {
    try await assertNativeWaitRecovers(from: "application_not_responding")
  }

  func testNativeWaitApplicationFailuresStillRespectTimeout() async throws {
    for kind in ["application_unavailable", "application_not_responding"] {
      let (reader, transport) = try nativeWaitReader(responses: [waitErrorEnvelope(kind)])
      do {
        try await reader.wait(.marker(value: "ready", key: .label, depth: 10), timeout: 0, pollInterval: 0)
        XCTFail("a failed read cannot satisfy the wait")
      } catch let UIAutomationError.timedOut(backend, key, value, timeout, diagnostics) {
        XCTAssertEqual(backend, reader.backend)
        XCTAssertEqual(key, AXSearchableKey.label.rawValue)
        XCTAssertEqual(value, "ready")
        XCTAssertEqual(timeout, 0)
        XCTAssertEqual(diagnostics?.unmatchedValues, [])
        XCTAssertNotNil(diagnostics?.readError)
      }
      let readCount = await transport.readCount
      XCTAssertEqual(readCount, 1, "an expired wait must not retry \(kind)")
    }
  }

  func testNativeWaitReportsOnlyTheSearchedKeyWithoutAnotherRead() async throws {
    let response = try treeAnswer(
      [
        AXWire.Node.label.rawValue: "unrelated label",
        AXWire.Node.identifier.rawValue: "settings_id",
      ], pid: 42, truncated: true)
    let (reader, transport) = nativeWaitReader(responses: [response])
    do {
      try await reader.wait(.marker(value: "missing", key: .uniqueID, depth: 10), timeout: 0, pollInterval: 0)
      XCTFail("a missing identifier must time out")
    } catch let UIAutomationError.timedOut(_, _, _, _, diagnostics) {
      XCTAssertEqual(diagnostics?.unmatchedValues, ["settings_id"])
      XCTAssertEqual(diagnostics?.truncated, false)
      XCTAssertEqual(diagnostics?.readTruncated, true)
      XCTAssertNil(diagnostics?.readError)
    }
    let readCount = await transport.readCount
    XCTAssertEqual(readCount, 1)
  }

  func testNativeWaitSeparatesSampleBoundsFromTreeReadBounds() async throws {
    for readTruncated in [false, true] {
      for (labels, sampleTruncated, sampleCount) in [
        (["Settings"], false, 1),
        ((0..<51).map { "label \($0)" }, true, 50),
        ([String(repeating: "x", count: 201)], true, 1),
      ] {
        let response = try treeAnswer(
          [AXWire.Node.children.rawValue: labels.map { [AXWire.Node.label.rawValue: $0] }],
          pid: 42, truncated: readTruncated)
        let (reader, transport) = nativeWaitReader(responses: [response])
        do {
          try await reader.wait(.marker(value: "missing", key: .label, depth: 10), timeout: 0, pollInterval: 0)
          XCTFail("a missing label must time out")
        } catch let UIAutomationError.timedOut(_, _, _, _, diagnostics) {
          XCTAssertEqual(diagnostics?.truncated, sampleTruncated)
          XCTAssertEqual(diagnostics?.readTruncated, readTruncated)
          XCTAssertEqual(diagnostics?.unmatchedValues.count, sampleCount)
          XCTAssertNil(diagnostics?.readError)
        }
        let readCount = await transport.readCount
        XCTAssertEqual(readCount, 1, "diagnostics must reuse the final poll's read")
      }
    }
  }

  func testSearchReturnsOnlyVisitedNonmatchingValuesOfTheKey() {
    let elements = AXTreeWalk.describeAllElements(
      fromTree: [
        AXWire.Node.label.rawValue: "root", AXWire.Node.identifier.rawValue: "unrelated_id",
        AXWire.Node.children.rawValue: [
          [AXWire.Node.identifier.rawValue: "missing_label"],
          [AXWire.Node.label.rawValue: "ready"],
          [AXWire.Node.label.rawValue: "unvisited"],
        ],
      ], keys: AXKeys.defaultSet, nestedFormat: false, pid: 42)
    let result = AXTreeWalk.search(inElements: elements, markerValue: "ready", key: .label)
    XCTAssertEqual(result.match?.label ?? nil, "ready")
    XCTAssertEqual(result.diagnostics?.unmatchedValues, ["root"])
    XCTAssertEqual(result.diagnostics?.truncated, false)
    let missing = AXTreeWalk.search(inElements: elements, markerValue: "absent", key: .label)
    XCTAssertNil(missing.match)
    XCTAssertEqual(missing.diagnostics?.unmatchedValues, ["root", "ready", "unvisited"])
    let noValues = AXTreeWalk.search(inElements: elements, markerValue: "absent", key: .help)
    XCTAssertNil(noValues.match)
    XCTAssertEqual(noValues.diagnostics, AccessibilitySearchDiagnostics())
  }

  func testSearchContinuesAfterItsDiagnosticSampleFills() {
    let elements = AXTreeWalk.describeAllElements(
      fromTree: [
        AXWire.Node.label.rawValue: "root",
        AXWire.Node.children.rawValue: (0..<60).map { [AXWire.Node.label.rawValue: "label \($0)"] }
          + [[AXWire.Node.label.rawValue: "ready"]],
      ], keys: AXKeys.defaultSet, nestedFormat: false, pid: 42)
    let result = AXTreeWalk.search(inElements: elements, markerValue: "ready", key: .label)
    XCTAssertEqual(result.match?.label ?? nil, "ready")
    XCTAssertEqual(result.diagnostics?.unmatchedValues.count, 50)
    XCTAssertEqual(result.diagnostics?.truncated, true)
  }

  func testNativeWaitPreservesTerminalReaderFailure() async throws {
    let (reader, transport) = try nativeWaitReader(responses: [
      waitErrorEnvelope("reader_unavailable"), waitMatchingEnvelope(),
    ])
    do {
      try await reader.wait(.marker(value: "ready", key: .label, depth: 10), timeout: 5, pollInterval: 0)
      XCTFail("a terminal failure must end the wait")
    } catch let AXBridgeError.readerUnavailable(reason) {
      XCTAssertEqual(reason, "read failed")
    }
    let readCount = await transport.readCount
    XCTAssertEqual(readCount, 1, "a terminal failure must not be retried")
  }

  // MARK: - Marker matching agrees with the accessibility backend

  // The accessibility backend matches a marker by substring, so the serialized-tree matcher must too, or `--api`
  // silently changes what `tap General` hits (the contract stated on `AccessibilityElementQuery.marker`).
  func testMarkerMatchesBySubstring() throws {
    let elements = AXTreeWalk.describeAllElements(
      fromTree: [
        AXWire.Node.label.rawValue: "root",
        AXWire.Node.children.rawValue: [
          [AXWire.Node.label.rawValue: "General Settings", AXWire.Node.children.rawValue: [[String: Any]]()] as [String: Any]
        ],
      ],
      keys: AXKeys.defaultSet, nestedFormat: false, pid: 1
    )
    let match = AXTreeWalk.matchingElement(inElements: elements, markerValue: "General", key: .label)
    guard let label = match?.label ?? nil else {
      return XCTFail("a substring marker must match, got: \(String(describing: match))")
    }
    XCTAssertEqual(label, "General Settings")
  }

  // An element equal to the marker wins over an earlier one that only contains it.
  func testMarkerPrefersAnExactMatchOverAnEarlierContainingOne() throws {
    let elements = AXTreeWalk.describeAllElements(
      fromTree: [
        AXWire.Node.label.rawValue: "root",
        AXWire.Node.children.rawValue: [
          [AXWire.Node.label.rawValue: "OK nested", AXWire.Node.children.rawValue: [[String: Any]]()] as [String: Any],
          [AXWire.Node.label.rawValue: "OK", AXWire.Node.children.rawValue: [[String: Any]]()] as [String: Any],
        ],
      ],
      keys: AXKeys.defaultSet, nestedFormat: false, pid: 1
    )
    let match = AXTreeWalk.matchingElement(inElements: elements, markerValue: "OK", key: .label)
    XCTAssertEqual(match?.label ?? nil, "OK")
  }

  func testMarkerFrameCentreMatchesBySubstring() throws {
    // `tap`/`wait`/`set-value` resolve through frameCenter, so it must use the same predicate as the
    // describe matcher — otherwise a marker could be describable but not tappable.
    let elements = AXTreeWalk.describeAllElements(
      fromTree: [
        AXWire.Node.label.rawValue: "General Settings",
        AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(CGRect(x: 10, y: 20, width: 100, height: 50)) as NSDictionary,
        AXWire.Node.children.rawValue: [[String: Any]](),
      ],
      keys: AXKeys.defaultSet, nestedFormat: false, pid: 1
    )
    let centre = AXTreeWalk.frameCenter(inElements: elements, markerValue: "General", key: .label)
    XCTAssertEqual(centre?.x, 60)
    XCTAssertEqual(centre?.y, 45)
  }

  // MARK: - Marker case sensitivity is opt-in, and reads only

  private func settingsElements() -> [AccessibilityDocumentElement] {
    AXTreeWalk.describeAllElements(
      fromTree: [
        AXWire.Node.label.rawValue: "General Settings",
        AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(CGRect(x: 10, y: 20, width: 100, height: 50)) as NSDictionary,
        AXWire.Node.children.rawValue: [[String: Any]](),
      ],
      keys: AXKeys.defaultSet, nestedFormat: false, pid: 1
    )
  }

  func testMarkerIsCaseSensitiveUnlessAsked() throws {
    let elements = settingsElements()
    XCTAssertNil(
      AXTreeWalk.matchingElement(inElements: elements, markerValue: "general", key: .label),
      "the default must stay the historical case-sensitive match"
    )
    guard
      let label = AXTreeWalk.matchingElement(
        inElements: elements, markerValue: "general", key: .label, ignoresCase: true
      )?.label ?? nil
    else {
      return XCTFail("--ignore-case must resolve a marker that differs only in case")
    }
    XCTAssertEqual(label, "General Settings")
  }

  func testMarkerWritesStayCaseSensitive() {
    // `resolveMarker` takes no case option: a write that resolved "ok" to a *Cancel* button labelled "OK" would act on
    // an element the caller did not name, and cannot be undone by reading again.
    let elements = settingsElements()
    XCTAssertEqual(
      AXTreeWalk.resolveMarker(inElements: elements, markerValue: "general", key: .label),
      .notFound
    )
    XCTAssertNil(AXTreeWalk.frameCenter(inElements: elements, markerValue: "general", key: .label))
  }

  func testAMarkerWriteWithIgnoreCaseResolvesCaseInsensitively() async throws {
    let target = try await Self.framedReader().writeTarget(
      for: .marker(value: "general", key: .label, depth: 10, ignoresCase: true),
      operation: "A tap"
    )
    XCTAssertEqual(target.point, CGPoint(x: Self.childRect.midX, y: Self.childRect.midY))
    XCTAssertEqual(target.assertion, AXBridgeWriteAssertion(key: .label, value: "General Settings"))
  }

  func testResolveMarkerWithIgnoreCaseMatchesLikeTheDescribeMatcher() throws {
    let elements = settingsElements()
    XCTAssertEqual(
      AXTreeWalk.resolveMarker(inElements: elements, markerValue: "general", key: .label, ignoresCase: true),
      .resolved(x: 60, y: 45)
    )
    XCTAssertEqual(
      AXTreeWalk.frameCenter(inElements: elements, markerValue: "general", key: .label, ignoresCase: true)?.x,
      60
    )
  }

  func testEmptyMarkerKeepsMatchingTheFirstElementCarryingTheKey() {
    // Every value contains the empty string, so an empty marker resolves to the first element carrying the key.
    // `AccessibilityMatch` refuses to represent that; the matcher must not turn the refusal into "no match".
    let label = AXTreeWalk.matchingElement(inElements: settingsElements(), markerValue: "", key: .label)?.label ?? nil
    XCTAssertEqual(label, "General Settings")
  }

  // MARK: - A marker matches by its searched key regardless of the requested key set

  // A marker is matched over the *serialized* element, so every marker call site unions the searched key into the
  // read set — sound only because each searchable key serializes into the field named by its own raw value.
  func testSearchableKeyMapsToItsOwnSerializedField() {
    let searchable: [AXSearchableKey] = [.label, .uniqueID, .value, .title, .role, .roleDescription, .subrole, .help, .placeholder]
    for key in searchable {
      XCTAssertEqual(key.serializationKey.rawValue, key.rawValue, "\(key) must serialize into the field its marker match reads")
    }
  }

  func testMarkerMatchesWhenSearchedKeyIsOutsideTheRequestedKeySet() {
    // The marker union below is what makes a searched key outside the requested set — a restricted key
    // request, or `.placeholder`, which the default set omits — matchable at all.
    let tree: [String: Any] = [
      AXWire.Node.label.rawValue: "General Settings",
      AXWire.Node.children.rawValue: [[String: Any]](),
    ]
    let requested: Set<AXKeys> = [.value]
    let withoutSearchedKey = AXTreeWalk.describeAllElements(fromTree: tree, keys: requested, nestedFormat: false, pid: 1)
    XCTAssertNil(
      AXTreeWalk.matchingElement(inElements: withoutSearchedKey, markerValue: "General", key: .label),
      "a key absent from the serialized set must not resolve a marker"
    )
    let withSearchedKey = AXTreeWalk.describeAllElements(
      fromTree: tree, keys: requested.union([AXSearchableKey.label.serializationKey]), nestedFormat: false, pid: 1
    )
    guard let label = AXTreeWalk.matchingElement(inElements: withSearchedKey, markerValue: "General", key: .label)?.label ?? nil
    else {
      return XCTFail("unioning the searched key must make the marker resolve regardless of the requested keys")
    }
    XCTAssertEqual(label, "General Settings")
  }

  // MARK: - AXTreeRead system-wide hit-test parsing

  func testHitTestParsesHitNodeAndOwningPid() throws {
    // A system-wide hit-test resolves which app owns the point, so the response carries the owning pid
    // the host tags the element with.
    let node: [String: Any] = [AXWire.Node.identifier.rawValue: "com.apple.settings.general"]
    let data = try hitAnswer(node, pid: 8865)
    let parsed = try AXTreeRead(hitTestResponse: data)
    XCTAssertEqual(parsed?.tree.identifier, BridgeAXScalar.string("com.apple.settings.general"))
    XCTAssertEqual(parsed?.pid, 8865)
  }

  func testHitTestReturnsNilForEmptyResult() throws {
    // `{ok:true, empty:true}` is "no element at the point" — a valid empty result, returned as nil,
    // not conflated with a reader failure.
    let data = try emptyHitAnswer()
    XCTAssertNil(try AXTreeRead(hitTestResponse: data))
  }

  func testHitTestThrowsOnFailure() throws {
    // A failure (`ok:false`) is distinct from an empty result and is surfaced with the guest message.
    let data = try failureAnswer("AXUIElementCopyElementAtPosition unavailable")
    XCTAssertThrowsError(try AXTreeRead(hitTestResponse: data)) { error in
      XCTAssertTrue("\(error)".contains("AXUIElementCopyElementAtPosition unavailable"), "unexpected error: \(error)")
    }
  }

  func testHitTestThrowsWhenOkButNoTreeOrEmpty() throws {
    let data = Data(#"{"hitTest":{"response":{}}}"#.utf8)
    XCTAssertThrowsError(try AXTreeRead(hitTestResponse: data))
  }

  func testHitTestThrowsWhenOwningPidMissing() throws {
    // A hit node with no owning pid is a protocol violation — the host cannot tag the element.
    let data = Data(#"{"hitTest":{"response":{"element":{"tree":{"XC_kAXXCAttributeIdentifier":"x"}}}}}"#.utf8)
    XCTAssertThrowsError(try AXTreeRead(hitTestResponse: data)) { error in
      guard case AXBridgeError.guestFailure = error else {
        return XCTFail("a hit-test without an owning pid should be guestFailure, got: \(error)")
      }
    }
  }

  // MARK: - AXTreeRead fused frontmost tree parsing

  func testFrontmostTreeParsesTreeAndResolvedPid() throws {
    // The fused read resolves the frontmost app AND reads its tree in one call, so the response carries
    // the resolved pid the host tags elements with — it did not know the pid in advance.
    let tree: [String: Any] = [AXWire.Node.label.rawValue: "Settings"]
    let data = try treeAnswer(tree, pid: 8865, method: .centerPoint)
    let parsed = try AXTreeRead(frontmostResponse: data, method: .centerPoint)
    XCTAssertEqual(parsed.pid, 8865)
    XCTAssertEqual(parsed.tree.label, BridgeAXScalar.string("Settings"))
    XCTAssertFalse(parsed.truncated)
  }

  func testFrontmostTreeSurfacesTruncation() throws {
    let data = try treeAnswer([AXWire.Node.label.rawValue: "root"], pid: 1, truncated: true)
    XCTAssertTrue(try AXTreeRead(frontmostResponse: data, method: .centerPoint).truncated)
  }

  func testFrontmostTreeThrowsFrontmostUnresolvedOnAnEmptyAnchor() throws {
    // Nothing at the anchor — an app mid-launch, or genuinely empty space. The strategy ran and named
    // nothing, so it is `frontmostUnresolved`, which the read poll retries.
    let data = try failureAnswer("system-wide hit-test at (201.0, 437.0) found no element", kind: "frontmost_unresolved")
    XCTAssertThrowsError(try AXTreeRead(frontmostResponse: data, method: .centerPoint)) { error in
      guard case let AXBridgeError.frontmostUnresolved(method, reason) = error else {
        return XCTFail("a strategy that named nothing should be frontmostUnresolved, got: \(error)")
      }
      XCTAssertEqual(method, .centerPoint)
      XCTAssertEqual(reason, "system-wide hit-test at (201.0, 437.0) found no element")
    }
  }

  // A pid above `Int32.max` must be rejected as a guest failure rather than trapping in the
  // non-failable `Int32` conversion.
  func testAnOutOfRangeResolvedPidIsRejectedRatherThanTrapping() throws {
    let frontmost = Data(#"{"tree":{"response":{"pid":99999999999,"tree":{},"truncated":false}}}"#.utf8)
    XCTAssertThrowsError(try AXTreeRead(frontmostResponse: frontmost, method: .centerPoint)) { error in
      guard case AXBridgeError.guestFailure = error else {
        return XCTFail("expected guestFailure, got: \(error)")
      }
    }

    let hit = Data(#"{"hitTest":{"response":{"element":{"pid":99999999999,"tree":{}}}}}"#.utf8)
    XCTAssertThrowsError(try AXTreeRead(hitTestResponse: hit)) { error in
      guard case AXBridgeError.guestFailure = error else {
        return XCTFail("expected guestFailure, got: \(error)")
      }
    }
  }

  func testFrontmostTreeThrowsWhenResolvedPidMissing() throws {
    // An ok response with a tree but no pid is a protocol violation — the host cannot tag the elements.
    let data = Data(#"{"tree":{"response":{"tree":{"XC_kAXXCAttributeLabel":"x"},"truncated":false}}}"#.utf8)
    XCTAssertThrowsError(try AXTreeRead(frontmostResponse: data, method: .centerPoint)) { error in
      guard case AXBridgeError.guestFailure = error else {
        return XCTFail("a fused response without a pid should be guestFailure, got: \(error)")
      }
    }
  }

  func testFrontmostTreeThrowsWhenTreeMissing() throws {
    let data = Data(#"{"tree":{"response":{"pid":8865,"truncated":false}}}"#.utf8)
    XCTAssertThrowsError(try AXTreeRead(frontmostResponse: data, method: .centerPoint)) { error in
      guard case AXBridgeError.guestFailure = error else {
        return XCTFail("a fused response without a tree should be guestFailure, got: \(error)")
      }
    }
  }

  // MARK: - Fullscreen-modal descriptor parsing + non-serialization

  /// The modal a frontmost read's answer carries beside an otherwise minimal tree.
  private func modal(in modal: BridgeAXModal?) throws -> AccessibilityModalInfo? {
    try AXTreeRead(frontmostResponse: treeAnswer([:], pid: 1, modal: modal), method: .windowServer).modal
  }

  func testModalParsesSystemAlert() throws {
    let modal = try modal(in: BridgeAXModal(kind: .system, elementType: "SBAlertItemWindow", label: "Allow \u{201c}Maps\u{201d} to use your location?"))
    XCTAssertEqual(modal?.kind, .system)
    XCTAssertEqual(modal?.elementType, "SBAlertItemWindow")
    XCTAssertEqual(modal?.label, "Allow \u{201c}Maps\u{201d} to use your location?")
  }

  func testModalParsesAppAlertWithoutLabel() throws {
    let modal = try modal(in: BridgeAXModal(kind: .app, elementType: "_UIAlertControllerView", label: nil))
    XCTAssertEqual(modal?.kind, .app)
    XCTAssertEqual(modal?.elementType, "_UIAlertControllerView")
    XCTAssertNil(modal?.label)
  }

  func testModalAbsentIsNil() throws {
    XCTAssertNil(try modal(in: nil), "no modal -> nil")
  }

  func testFrontmostTreeCarriesModalDescriptor() throws {
    let tree: [String: Any] = [AXWire.Node.label.rawValue: "root"]
    let data = try treeAnswer(tree, pid: 20475, modal: BridgeAXModal(kind: .system, elementType: "SBAlertItemWindow", label: "Allow"))
    let parsed = try AXTreeRead(frontmostResponse: data, method: .centerPoint)
    XCTAssertEqual(parsed.pid, 20475)
    XCTAssertEqual(parsed.modal?.kind, .system)
    XCTAssertEqual(parsed.modal?.elementType, "SBAlertItemWindow")
  }

  func testModalIsNeverSerializedInTheCLIOutput() throws {
    // The modal field enriches the host view but MUST NOT change the emitted CLI/gRPC JSON — a response
    // with a modal must serialize byte-identically to one without.
    let modal = AccessibilityModalInfo(kind: .system, elementType: "SBAlertItemWindow", label: "Allow")
    let withModal = AccessibilityElementsResponse(elements: .tree([]), modal: modal)
    let without = AccessibilityElementsResponse(elements: .tree([]))
    let a = try withModal.legacyJSONData()
    let b = try without.legacyJSONData()
    XCTAssertEqual(a, b, "the modal descriptor must not appear in the serialized output")
  }

  // MARK: - Tree -> shared serializer integration

  func testGuestTreeFeedsSharedSerializerSchema() throws {
    // The child is a Button (automationType 9) with its identifier, proving the guest tree uses the
    // shared serializer rather than a bespoke output shape.
    let tree: [String: Any] = [
      AXWire.Node.label.rawValue: "root",
      AXWire.Node.children.rawValue: [
        [
          AXWire.Node.label.rawValue: "General",
          AXWire.Node.identifier.rawValue: "com.apple.settings.general",
          AXWire.Node.automationType.rawValue: 9,
          AXWire.Node.children.rawValue: [[String: Any]](),
        ] as [String: Any]
      ],
    ]
    let data = try treeAnswer(tree, pid: 99)
    let parsed = try AXTreeRead(wholeTreeResponse: data, pid: 99)

    let elements = AXTreeWalk.describeAllElements(
      fromTree: parsed.tree, keys: AXKeys.defaultSet, nestedFormat: false, pid: 99
    )
    XCTAssertEqual(elements.count, 2, "expected the root plus its one child, flattened")

    let response = AccessibilityElementsResponse(
      elements: .tree(elements)
    )
    let json = try response.legacyJSONData()
    let serialized = String(data: json, encoding: .utf8) ?? ""
    XCTAssertTrue(serialized.contains("com.apple.settings.general"), "missing identifier in \(serialized)")
    // automationType 9 maps to the readable XCUIElementType name via the shared serializer.
    XCTAssertTrue(serialized.contains("\"role\":\"Button\""), "role not mapped in \(serialized)")
  }

  // MARK: - Shared `describeTree` composition

  private static func twoNodeTree() -> [String: Any] {
    [
      AXWire.Node.label.rawValue: "root",
      AXWire.Node.children.rawValue: [
        [
          AXWire.Node.label.rawValue: "General Settings",
          AXWire.Node.children.rawValue: [[String: Any]](),
        ] as [String: Any]
      ],
    ]
  }

  private static func stubRead(truncated: Bool = false, modal: AccessibilityModalInfo? = nil) -> AXTreeRead {
    AXTreeRead(tree: twoNodeTree(), pid: 99, truncated: truncated, modal: modal)
  }

  func testDescribeTreeReturnsAnArrayForWholeTreeQueries() async throws {
    for query in [AccessibilityElementQuery.frontmost, .application(pid: 99)] {
      let reader = StubAXBridgeTreeReader(read: Self.stubRead())
      let response = try await reader.describeTree(query, options: AccessibilityRequestOptions())
      guard case let .tree(elements) = response.elements else {
        return XCTFail("\(query) must serialize to an array, got \(response.elements)")
      }
      XCTAssertEqual(elements.count, 2, "the whole tree is flattened to root plus child")
    }
  }

  // A marker resolves to one element, so the response carries a bare object — the same shape the
  // accessibility backend returns, so a consumer never branches on `--api` here.
  func testDescribeTreeReturnsABareObjectForAMarkerQuery() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead())
    let response = try await reader.describeTree(
      .marker(value: "General", key: .label, depth: 10), options: AccessibilityRequestOptions()
    )
    guard case let .single(element) = response.elements else {
      return XCTFail("a marker must serialize to a single object, got \(response.elements)")
    }
    XCTAssertEqual(element.label, .some("General Settings"))
  }

  func testDescribeTreeReadsAsTheNamedClientAndReportsIt() async throws {
    for query in [AccessibilityElementQuery.frontmost, .marker(value: "General", key: .label, depth: 10)] {
      let named = StubAXBridgeTreeReader(read: Self.stubRead())
      let response = try await named.describeTree(query, options: AccessibilityRequestOptions(traversalStrategy: .semantic, clientType: .xctest))
      XCTAssertEqual(named.clientTypes, [.xctest], "\(query)")
      XCTAssertEqual(response.client, AccessibilityClientReport(clientType: .xctest), "\(query)")

      let unnamed = StubAXBridgeTreeReader(read: Self.stubRead())
      let defaultResponse = try await unnamed.describeTree(query, options: AccessibilityRequestOptions())
      XCTAssertEqual(unnamed.clientTypes, [.noClient], "\(query)")
      XCTAssertNil(defaultResponse.client, "\(query)")
    }
  }

  func testAPointReadSendsTheNamedClientWithTheHitTestAndReportsIt() async throws {
    for clientType in [AXClientType?.none, .voiceOver] {
      let transport = try StubAXBridgeWaitTransport(responses: [
        hitAnswer([AXWire.Node.label.rawValue: "target"], pid: 42)
      ])
      let reader = AXBridgeUIAutomation(
        simulator: SimulatorTestSupport.testableSimulator(withDevice: AXBridgeWaitDevice()),
        transport: transport, persistence: .exclusive, displays: displays())
      let response = try await reader.describe(.point(CGPoint(x: 80, y: 180)), options: AccessibilityRequestOptions(clientType: clientType))
      guard case let .hitTest(_, _, _, sent, _, _) = await transport.requests.first else {
        return XCTFail("a point read must hit-test")
      }
      XCTAssertEqual(sent, clientType ?? .noClient)
      XCTAssertEqual(response.client, clientType.map(AccessibilityClientReport.init))
    }
  }

  func testANamedClientAutoResolvesToTheSemanticWalk() {
    for keys in [AXKeys.defaultSet, [.interactable]] {
      XCTAssertEqual(AXBridgeUIAutomation.resolvedTraversal(for: AccessibilityRequestOptions(keys: keys, clientType: .xctest)), .semantic)
      XCTAssertEqual(AXBridgeUIAutomation.resolvedTraversal(for: AccessibilityRequestOptions(keys: keys, clientType: .noClient)), .semantic)
    }
    XCTAssertEqual(AXBridgeUIAutomation.resolvedTraversal(for: AccessibilityRequestOptions()), .singleFetch)
    XCTAssertEqual(AXBridgeUIAutomation.resolvedTraversal(for: AccessibilityRequestOptions(keys: [.interactable])), .viewHierarchy)
  }

  func testAClientWithAnExplicitXCTestTraversalIsRefusedBeforeReading() async throws {
    for strategy in [AXTraversalStrategy.viewHierarchy, .singleFetch] {
      for query in [AccessibilityElementQuery.frontmost, .marker(value: "General", key: .label, depth: 10)] {
        let reader = StubAXBridgeTreeReader(read: Self.stubRead())
        do {
          _ = try await reader.describeTree(query, options: AccessibilityRequestOptions(traversalStrategy: strategy, clientType: .xctest))
          XCTFail("\(strategy) with a client must be refused")
        } catch let UIAutomationError.clientNeedsTranslatorVocabulary(_, traversal) {
          XCTAssertEqual(traversal, strategy.rawValue)
        }
        XCTAssertEqual(reader.readCount, 0, "\(strategy) \(query)")
      }
    }
  }

  func testDescribeTreeCarriesTheModalDescriptorOutOfTheRead() async throws {
    let modal = AccessibilityModalInfo(kind: .system, elementType: "SBAlertItemWindow", label: "Allow")
    for query in [AccessibilityElementQuery.frontmost, .marker(value: "General", key: .label, depth: 10)] {
      let reader = StubAXBridgeTreeReader(read: Self.stubRead(modal: modal))
      let response = try await reader.describeTree(query, options: AccessibilityRequestOptions())
      XCTAssertEqual(response.modal, modal, "\(query) must surface the read's modal to the host")
    }
  }

  // The truncation warning belongs to a describe, not to a raw read: it fires exactly once per
  // describe so a `.marker` wait poll (which reads without describing) stays silent.
  func testDescribeTreeWarnsOnceWithTheReadsTruncationFlag() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead(truncated: true))
    _ = try await reader.describeTree(.frontmost, options: AccessibilityRequestOptions())
    XCTAssertEqual(reader.truncationWarnings, [true], "one warning carrying the read's flag")
  }

  func testDescribeTreeCarriesTheChosenTraversalToTheRead() async throws {
    for query in [AccessibilityElementQuery.frontmost, .marker(value: "General", key: .label, depth: 10)] {
      let reader = StubAXBridgeTreeReader(read: Self.stubRead())
      _ = try? await reader.describeTree(query, options: AccessibilityRequestOptions(traversalStrategy: .semantic))
      XCTAssertEqual(reader.traversals, [.semantic], "\(query) must carry the caller's choice to the read")
    }
  }

  // The profile must report the traversal that actually ran — inferring it from `mach_round_trips`
  // breaks as soon as two traversals produce the same count.
  func testDescribeTreeReportsTheTraversalItReadWith() async throws {
    for strategy in AXTraversalStrategy.allCases {
      let reader = StubAXBridgeTreeReader(read: Self.stubRead())
      var options = AccessibilityRequestOptions(traversalStrategy: strategy)
      options.enableProfiling = true
      let response = try await reader.describeTree(.frontmost, options: options)
      guard case let .guestBridge(profile)? = response.profilingData else {
        return XCTFail("expected a guest profile, got \(String(describing: response.profilingData))")
      }
      // Against what the read resolved to rather than what was asked for, which is the point of the
      // field: `auto` names no traversal and the profile must still report the one that ran.
      XCTAssertEqual(profile.traversal, StubAXBridgeTreeReader.resolvedTraversal(for: options))
      XCTAssertEqual(reader.traversals, reader.profiledTraversals, "the read and its profile must agree")
    }
  }

  func testTheTraversalIsOnlyReportedWhenProfilingWasAskedFor() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead())
    let response = try await reader.describeTree(
      .frontmost, options: AccessibilityRequestOptions(traversalStrategy: .singleFetch)
    )
    XCTAssertNil(response.profilingData)
    XCTAssertEqual(reader.profiledTraversals, [], "an unprofiled read must not build a profile at all")
  }

  // The walk done in one call, so per-element answers match — reachability is a whole-read refusal in
  // `describeTree`, not a per-element gap, which is why it does not appear here.
  func testTheSingleFetchAnswersEveryKeyTheDefaultWalkDoes() {
    XCTAssertEqual(AXTraversal.singleFetch.unsatisfiableKeys, [])
    XCTAssertEqual(
      AXTraversal.singleFetch.unsatisfiableKeys,
      AXTraversal.viewHierarchy.unsatisfiableKeys
    )
  }

  // An explicit single fetch asking for reachability is refused before any read is attempted: the guest
  // would time out rather than answer, so the combination fails fast with the keys it cannot serve.
  func testAnExplicitSingleFetchAskingForReachabilityIsRefused() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead())
    do {
      _ = try await reader.describeTree(
        .frontmost, options: AccessibilityRequestOptions(keys: [.interactable], traversalStrategy: .singleFetch)
      )
      XCTFail("expected the read to be refused")
    } catch let UIAutomationError.traversalCannotAnswer(_, traversal, keys) {
      XCTAssertEqual(traversal, "single-fetch")
      XCTAssertEqual(keys, ["interactable"])
    }
    XCTAssertEqual(reader.traversals, [], "the refusal must happen before any read is attempted")
  }

  // The warning is what makes an absent field readable as "this traversal could not ask", so it belongs
  // on the describe that actually reports fields — not only on the marker branch.
  func testDescribeTreeWarnsAboutUnsatisfiableKeys() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead())
    _ = try? await reader.describeTree(
      .frontmost, options: AccessibilityRequestOptions(keys: [.type, .label], traversalStrategy: .semantic)
    )
    XCTAssertEqual(reader.unsatisfiableWarnings, [[.type]], "a frontmost describe must warn it cannot type")
  }

  // A view-hierarchy read answers everything, so the warning must carry an empty set rather than be
  // skipped — an absent warning and a warning about nothing are the same thing to a caller.
  func testDescribeTreeWarnsAboutNothingOnASatisfiableTraversal() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead())
    _ = try? await reader.describeTree(
      .frontmost, options: AccessibilityRequestOptions(keys: [.type, .label], traversalStrategy: .viewHierarchy)
    )
    XCTAssertEqual(reader.unsatisfiableWarnings, [[]], "nothing is unsatisfiable on the view hierarchy")
  }

  // A marker is matched over the *serialized* element, so the searched key is unioned into the read key
  // set — otherwise a marker on a key the caller did not request could never resolve.
  func testDescribeTreeUnionsTheSearchedKeyForAMarker() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead())
    let options = AccessibilityRequestOptions(keys: [.value])
    let response = try await reader.describeTree(
      .marker(value: "General", key: .label, depth: 10), options: options
    )
    guard case let .single(element) = response.elements else {
      return XCTFail("expected a single object, got \(response.elements)")
    }
    XCTAssertNotNil(element.label as Any?, "the searched key must be serialized even when unrequested")
  }

  // A marker's match runs over a flattened tree regardless of the caller's format, so a nested request still
  // resolves the element; the match reports empty children because none were walked.
  func testDescribeTreeMatchesAMarkerFlatEvenWhenNestedIsRequested() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead())
    let options = AccessibilityRequestOptions(format: .nested)
    let response = try await reader.describeTree(
      .marker(value: "General", key: .label, depth: 10), options: options
    )
    guard case let .single(element) = response.elements else {
      return XCTFail("expected a single object, got \(response.elements)")
    }
    XCTAssertEqual(element.label, .some("General Settings"))
    XCTAssertEqual(element.children, [], "the match reports children, empty because the search walk was flat")
  }

  func testDescribeTreeHonoursTheRequestedNestedFormatForWholeTreeQueries() async throws {
    let response = try await StubAXBridgeTreeReader(read: Self.stubRead())
      .describeTree(.frontmost, options: AccessibilityRequestOptions(format: .nested))
    guard case let .tree(elements) = response.elements, let root = elements.first else {
      return XCTFail("expected a nested root, got \(response.elements)")
    }
    XCTAssertEqual(elements.count, 1, "nested output carries the child inside the root, not beside it")
    guard let children = root.children, let child = children.first else {
      return XCTFail("expected the child nested under the root, got \(String(describing: root.children))")
    }
    XCTAssertEqual(child.label, .some("General Settings"))
  }

  func testDescribeTreeHonoursTheRequestedFilterForWholeTreeQueries() async throws {
    // The unlabeled root of this tree is dropped by `.interactable`, leaving only the labeled child.
    let tree: [String: Any] = [
      AXWire.Node.children.rawValue: [
        [
          AXWire.Node.label.rawValue: "General Settings",
          AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(CGRect(x: 10, y: 20, width: 100, height: 50)) as NSDictionary,
          AXWire.Node.children.rawValue: [[String: Any]](),
        ] as [String: Any]
      ]
    ]
    let reader = StubAXBridgeTreeReader(read: AXTreeRead(tree: tree, pid: 99, truncated: false, modal: nil))
    let response = try await reader.describeTree(.frontmost, options: AccessibilityRequestOptions(filter: .interactable))
    guard case let .tree(elements) = response.elements else {
      return XCTFail("expected an array, got \(response.elements)")
    }
    XCTAssertEqual(elements.count, 1, "the unlabeled container is filtered out, its labeled child kept")
  }

  // The warning describes the tree, not the caller's view of it, so a filter must not hide it.
  func testAMostlyUnframedTreeIsWarnedAboutUnderTheInteractableFilter() async throws {
    let frame = CGRectCreateDictionaryRepresentation(CGRect(x: 10, y: 20, width: 100, height: 50)) as NSDictionary
    let stale = (0..<3).map { [AXWire.Node.label.rawValue: "Stale \($0)"] as [String: Any] }
    let framed: [String: Any] = [AXWire.Node.label.rawValue: "Framed", AXWire.Node.frame.rawValue: frame]
    let tree: [String: Any] = [AXWire.Node.frame.rawValue: frame, AXWire.Node.children.rawValue: stale + [framed]]
    let reader = StubAXBridgeTreeReader(read: AXTreeRead(tree: tree, pid: 99, truncated: false, modal: nil))
    _ = try await reader.describeTree(.frontmost, options: AccessibilityRequestOptions(filter: .interactable))

    let frames = try XCTUnwrap(reader.geometryWarnings.first ?? nil, "the read tallied its frames")
    XCTAssertEqual(frames.zeroFrame, 3, "the three labeled elements with no frame are counted")
  }

  private static func occlusionIdentity(label: String, frame: CGRect) -> [String: Any] {
    [
      AXWire.Node.label.rawValue: label,
      AXWire.Node.identifier.rawValue: label.lowercased(),
      AXWire.Node.elementType.rawValue: NSNumber(value: 9),
      AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(frame) as NSDictionary,
    ]
  }

  private static func occlusionNode(
    label: String,
    frame: CGRect,
    blockedBy: [String: Any]? = nil,
    children: [[String: Any]] = []
  ) -> [String: Any] {
    let centre = CGPoint(x: frame.midX, y: frame.midY)
    var node = occlusionIdentity(label: label, frame: frame)
    node[AXWire.Node.isVisible.rawValue] = blockedBy == nil
    node[AXWire.Node.visiblePoint.rawValue] =
      CGPointCreateDictionaryRepresentation(
        blockedBy == nil ? centre : CGPoint(x: -1, y: -1)
      ) as NSDictionary
    node[AXWire.Node.centerPoint.rawValue] = CGPointCreateDictionaryRepresentation(centre) as NSDictionary
    node[AXWire.Node.userInteractionEnabled.rawValue] = true
    node[AXWire.Node.children.rawValue] = children
    node[AXWire.Node.explainedBy.rawValue] = blockedBy
    return node
  }

  private static func describedOcclusionTree(_ tree: [String: Any]) async throws -> AccessibilityDocumentElement {
    let reader = StubAXBridgeTreeReader(
      read: AXTreeRead(tree: tree, pid: 99, truncated: false, modal: nil)
    )
    let response = try await reader.describeTree(
      .frontmost,
      options: AccessibilityRequestOptions(format: .nested, keys: [.occludedBy])
    )
    return try XCTUnwrap(response.elements.elements.first)
  }

  private static func elementRef(label: String, frame: CGRect) -> AccessibilityElementRef {
    AccessibilityElementRef(
      type: "Button",
      identifier: label.lowercased(),
      label: label,
      frame: AccessibilityFrame(frame),
      pid: 99
    )
  }

  func testAnAncestorHandlingATouchIsClassifiedAsARelative() async throws {
    let rootFrame = CGRect(x: 0, y: 0, width: 400, height: 800)
    let childFrame = CGRect(x: 20, y: 20, width: 100, height: 40)
    let rootIdentity = Self.occlusionIdentity(label: "Root", frame: rootFrame)
    let tree = Self.occlusionNode(
      label: "Root",
      frame: rootFrame,
      children: [Self.occlusionNode(label: "Child", frame: childFrame, blockedBy: rootIdentity)]
    )

    let root = try await Self.describedOcclusionTree(tree)
    let child = try XCTUnwrap(root.children?.first)
    XCTAssertEqual(
      child.interactable ?? nil,
      .blocked(reasons: [.handledBy(Self.elementRef(label: "Root", frame: rootFrame))])
    )
  }

  func testAGrandchildHandlingATouchIsClassifiedAsARelative() async throws {
    let rootFrame = CGRect(x: 0, y: 0, width: 400, height: 800)
    let childFrame = CGRect(x: 20, y: 20, width: 200, height: 200)
    let grandchildFrame = CGRect(x: 40, y: 40, width: 100, height: 40)
    let grandchildIdentity = Self.occlusionIdentity(label: "Grandchild", frame: grandchildFrame)
    let tree = Self.occlusionNode(
      label: "Root",
      frame: rootFrame,
      blockedBy: grandchildIdentity,
      children: [
        Self.occlusionNode(
          label: "Child",
          frame: childFrame,
          children: [Self.occlusionNode(label: "Grandchild", frame: grandchildFrame)]
        )
      ]
    )

    let root = try await Self.describedOcclusionTree(tree)
    XCTAssertEqual(
      root.interactable ?? nil,
      .blocked(reasons: [.handledBy(Self.elementRef(label: "Grandchild", frame: grandchildFrame))])
    )
  }

  func testASiblingHandlingATouchIsClassifiedAsAnOccluder() async throws {
    let rootFrame = CGRect(x: 0, y: 0, width: 400, height: 800)
    let firstFrame = CGRect(x: 20, y: 20, width: 100, height: 40)
    let secondFrame = CGRect(x: 20, y: 80, width: 100, height: 40)
    let secondIdentity = Self.occlusionIdentity(label: "Second", frame: secondFrame)
    let tree = Self.occlusionNode(
      label: "Root",
      frame: rootFrame,
      children: [
        Self.occlusionNode(label: "First", frame: firstFrame, blockedBy: secondIdentity),
        Self.occlusionNode(label: "Second", frame: secondFrame),
      ]
    )

    let root = try await Self.describedOcclusionTree(tree)
    let first = try XCTUnwrap(root.children?.first)
    XCTAssertEqual(
      first.interactable ?? nil,
      .blocked(reasons: [.occluded(by: Self.elementRef(label: "Second", frame: secondFrame))])
    )
  }

  // MARK: - Frame coverage

  /// A root spanning a 390x844 screen with one child covering its lower half — enough for a coverage
  /// calculation to have both a screen to measure against and an element to measure. The element types
  /// are `XCUIElementType` raw values, which is how the guest reports a role: 2 is Application, 9 is
  /// Button.
  private static func sizedTree() -> [String: Any] {
    [
      AXWire.Node.label.rawValue: "root",
      AXWire.Node.elementType.rawValue: NSNumber(value: 2),
      AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(CGRect(x: 0, y: 0, width: 390, height: 844)) as NSDictionary,
      AXWire.Node.children.rawValue: [
        [
          AXWire.Node.label.rawValue: "Lower Half",
          AXWire.Node.elementType.rawValue: NSNumber(value: 9),
          AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(CGRect(x: 0, y: 422, width: 390, height: 422)) as NSDictionary,
          AXWire.Node.children.rawValue: [[String: Any]](),
        ] as [String: Any]
      ],
    ]
  }

  // `describeTree` is the read path every backend but `ax` funnels through, so it must honour
  // `collectFrameCoverage` for all of them.
  func testDescribeTreeReportsTheRequestedFrameCoverage() async throws {
    let reader = StubAXBridgeTreeReader(read: AXTreeRead(tree: Self.sizedTree(), pid: 99, truncated: false, modal: nil))
    var options = AccessibilityRequestOptions(format: .complete)
    options.collectFrameCoverage = true
    let response = try await reader.describeTree(.frontmost, options: options)

    XCTAssertEqual(
      response.screen, AccessibilityScreenInfo(width: 390, height: 844),
      "the bounds a coverage calculation would measure against are known"
    )
    guard case let .tree(elements) = response.elements, let root = elements.first else {
      return XCTFail("expected a nested root, got \(response.elements)")
    }
    // `complete` is a nested format, so the child rides inside the root rather than beside it.
    let heights = ([root] + (root.children ?? [])).compactMap { element -> Double? in
      guard let frame = element.frame ?? nil else { return nil }
      return frame.height
    }
    XCTAssertEqual(heights, [844, 422], "and every element carries the frame it would be measured by")

    let coverage = try XCTUnwrap(response.coverage, "the guest backends collect coverage too")
    // The child covers the screen's lower half; the application root is excluded.
    XCTAssertEqual(coverage.frame, 0.5, accuracy: 0.01)
    XCTAssertEqual(coverage.walked, 0.5, accuracy: 0.01, "nothing was filtered, so the two ratios agree")
    XCTAssertNil(coverage.additional, "remote-content discovery is accessibility-only")
    XCTAssertEqual(response.document.coverage, coverage, "and the complete document reports it")
  }

  // Coverage stays opt-in: a read that did not ask for it reports none rather than a zero.
  func testDescribeTreeReportsNoCoverageUnlessAsked() async throws {
    let reader = StubAXBridgeTreeReader(read: AXTreeRead(tree: Self.sizedTree(), pid: 99, truncated: false, modal: nil))
    let response = try await reader.describeTree(.frontmost, options: AccessibilityRequestOptions(format: .complete))
    XCTAssertNil(response.coverage)
    XCTAssertNil(response.document.coverage)
  }

  // A read whose root reports no usable frame has no screen to measure against, so it reports no
  // coverage rather than measuring against a zero-sized grid.
  func testDescribeTreeReportsNoCoverageWithoutUsableScreenBounds() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead())
    var options = AccessibilityRequestOptions(format: .complete)
    options.collectFrameCoverage = true
    let response = try await reader.describeTree(.frontmost, options: options)
    XCTAssertNil(response.screen, "the stub tree's root reports no frame")
    XCTAssertNil(response.coverage, "so there is nothing to measure against")
  }

  /// `sizedTree()` with the lower half's label removed, so `.interactable` drops it: element type 1 is
  /// Other, which is not an actionable role.
  private static func sizedTreeWithUnlabeledLowerHalf() -> [String: Any] {
    [
      AXWire.Node.label.rawValue: "root",
      AXWire.Node.elementType.rawValue: NSNumber(value: 2),
      AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(CGRect(x: 0, y: 0, width: 390, height: 844)) as NSDictionary,
      AXWire.Node.children.rawValue: [
        [
          AXWire.Node.elementType.rawValue: NSNumber(value: 1),
          AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(CGRect(x: 0, y: 422, width: 390, height: 422)) as NSDictionary,
          AXWire.Node.children.rawValue: [[String: Any]](),
        ] as [String: Any]
      ],
    ]
  }

  // MARK: - What `content` has to get right

  // Synthetic tree shapes, not captured traces. The container chain is what breaks looser predicates: coverage is
  // a union of areas, so one full-screen container that passes saturates the measure at 1.0.

  private static let syntheticScreen = CGRect(x: 0, y: 0, width: 400, height: 800)

  private static func node(
    _ type: Int, _ frame: CGRect, label: String? = nil, identifier: String? = nil,
    children: [[String: Any]] = []
  ) -> [String: Any] {
    var node: [String: Any] = [
      AXWire.Node.elementType.rawValue: NSNumber(value: type),
      AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(frame) as NSDictionary,
      AXWire.Node.children.rawValue: children,
    ]
    if let label { node[AXWire.Node.label.rawValue] = label }
    if let identifier { node[AXWire.Node.identifier.rawValue] = identifier }
    return node
  }

  /// The guest shape: a named window over an application element over an identified scroll view over a
  /// run of anonymous full-screen layout nodes, with `content` at the bottom. Element types are
  /// `XCUIElementType` raw values — 1 Other, 2 Application, 9 Button, 48 StaticText.
  private static func containerChain(wrapping content: [[String: Any]]) -> [String: Any] {
    let full = syntheticScreen
    var innermost = node(1, full, children: content)
    for _ in 0..<4 {
      innermost = node(1, full, children: [innermost])
    }
    let scrollView = node(1, full, identifier: "scroll-view", children: [innermost])
    let application = node(2, full, identifier: "app-window", children: [scrollView])
    return node(1, full, label: "App Title", children: [application])
  }

  private func contentCoverage(of tree: [String: Any]) async throws -> Double? {
    let reader = StubAXBridgeTreeReader(read: AXTreeRead(tree: tree, pid: 99, truncated: false, modal: nil))
    var options = AccessibilityRequestOptions(format: .complete)
    options.collectFrameCoverage = true
    return try await reader.describeTree(.frontmost, options: options).coverage?.content
  }

  func testContentCoverageIsHighForDenseTextWithAndWithoutAContainerChain() async throws {
    let text = [Self.node(48, CGRect(x: 0, y: 80, width: 400, height: 640), label: "lots of text")]
    let bare = Self.node(2, Self.syntheticScreen, label: "App", children: text)

    let bareMeasured = try await contentCoverage(of: bare)
    let chainedMeasured = try await contentCoverage(of: Self.containerChain(wrapping: text))
    let bareCoverage = try XCTUnwrap(bareMeasured)
    let chainedCoverage = try XCTUnwrap(chainedMeasured)
    XCTAssertEqual(bareCoverage, 0.8, accuracy: 0.02, "the text covers four fifths of the screen")
    XCTAssertEqual(chainedCoverage, bareCoverage, accuracy: 0.001, "wrapping it in containers changes nothing")
  }

  // A full-screen region the app draws but does not describe carries an identifier (a developer automation handle),
  // so any predicate that accepts an identifier calls this screen fully covered.
  func testContentCoverageIsLowForAnUndescribedRegion() async throws {
    let sparse = [
      Self.node(9, CGRect(x: 0, y: 0, width: 400, height: 60), label: "Nav"),
      Self.node(1, CGRect(x: 0, y: 60, width: 400, height: 740), identifier: "webview"),
    ]
    let bare = Self.node(2, Self.syntheticScreen, label: "App", children: sparse)

    let bareMeasured = try await contentCoverage(of: bare)
    let chainedMeasured = try await contentCoverage(of: Self.containerChain(wrapping: sparse))
    let bareCoverage = try XCTUnwrap(bareMeasured)
    let chainedCoverage = try XCTUnwrap(chainedMeasured)
    XCTAssertLessThan(bareCoverage, 0.1, "only the nav bar is described")
    XCTAssertEqual(chainedCoverage, bareCoverage, accuracy: 0.001, "and the chain does not describe it either")
  }

  // An app icon is a labelled button wrapping an unlabelled image. What disowns a label is a *labelled* descendant,
  // so the button counts and its image does not; requiring childlessness would measure a screen of icons as zero.
  func testContentCoverageCountsALabelledElementWrappingUnlabelledDecoration() async throws {
    let icons = [
      Self.node(
        9, CGRect(x: 0, y: 0, width: 100, height: 100), label: "Maps",
        children: [Self.node(1, CGRect(x: 0, y: 0, width: 100, height: 100))]
      ),
      Self.node(
        9, CGRect(x: 100, y: 0, width: 100, height: 100), label: "Photos",
        children: [Self.node(1, CGRect(x: 100, y: 0, width: 100, height: 100))]
      ),
    ]
    let measured = try await contentCoverage(of: Self.containerChain(wrapping: icons))
    let coverage = try XCTUnwrap(measured)
    XCTAssertEqual(coverage, 0.07, accuracy: 0.02, "the two icons, counted once each rather than not at all")
  }

  // A handful of small labelled widgets on an otherwise empty screen is low coverage, not the `1.0` the
  // enclosing named window would report on its own.
  func testContentCoverageIsLowForSparseWidgetsInAContainerChain() async throws {
    let widgets = [
      Self.node(9, CGRect(x: 0, y: 0, width: 200, height: 100), label: "A"),
      Self.node(9, CGRect(x: 0, y: 700, width: 400, height: 100), label: "B"),
    ]
    let measured = try await contentCoverage(of: Self.containerChain(wrapping: widgets))
    let coverage = try XCTUnwrap(measured)
    XCTAssertEqual(coverage, 0.19, accuracy: 0.02, "the two widgets, and none of the containers holding them")
  }

  // The two ratios diverge on the guest backends the same way they do on the accessibility one — the
  // calculation is shared, so the gap cannot come to mean different things per backend.
  func testDescribeTreeReportsWalkedCoverageAboveReportedWhenFiltering() async throws {
    let reader = StubAXBridgeTreeReader(
      read: AXTreeRead(tree: Self.sizedTreeWithUnlabeledLowerHalf(), pid: 99, truncated: false, modal: nil)
    )
    var options = AccessibilityRequestOptions(format: .complete)
    options.collectFrameCoverage = true
    options.filter = .interactable
    let response = try await reader.describeTree(.frontmost, options: options)

    let coverage = try XCTUnwrap(response.coverage)
    XCTAssertEqual(coverage.walked, 0.5, accuracy: 0.01, "the walk saw the unlabeled element covering the lower half")
    XCTAssertEqual(coverage.frame, 0, accuracy: 0.01, "the filter dropped it, so the report covers nothing")
  }
  func testDescribeTreeThrowsWhenNoElementMatchesTheMarker() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead())
    do {
      _ = try await reader.describeTree(
        .marker(value: "Nothing", key: .label, depth: 10), options: AccessibilityRequestOptions()
      )
      XCTFail("an unmatched marker must throw")
    } catch let error as UIAutomationError {
      guard case .elementNotFound = error else {
        return XCTFail("expected elementNotFound, got \(error)")
      }
    }
  }

  // A point delegates to the backend's hit-test and turns its "no element" (nil) into a throw, which is what makes
  // `describe(.point:)` throwing while `hitTest` stays optional.
  func testDescribeTreeDelegatesAPointToHitTestWithoutReadingATree() async throws {
    let hit = AccessibilityElementsResponse(
      elements: .single(
        {
          var e = AccessibilityDocumentElement()
          e.label = .some("hit")
          return e
        }()))
    let reader = StubAXBridgeTreeReader(read: Self.stubRead(), hitTestResult: hit)
    let response = try await reader.describeTree(.point(CGPoint(x: 3, y: 4)), options: AccessibilityRequestOptions())
    XCTAssertEqual(reader.hitTestPoints, [CGPoint(x: 3, y: 4)])
    XCTAssertEqual(reader.readCount, 0, "a point must not read a whole tree")
    XCTAssertTrue(reader.truncationWarnings.isEmpty, "a point read has no tree to warn about")
    guard case let .single(element) = response.elements else {
      return XCTFail("expected the hit-test's element, got \(response.elements)")
    }
    XCTAssertEqual(element.label, .some("hit"))
  }

  // MARK: - Provenance stamping

  // The backend and the query are known here, not by the front-end that asked for a format, so
  // `describeTree` stamps them on the way out. These fields feed the `complete` document only.
  func testDescribeTreeStampsBackendAndTargetForEveryQueryKind() async throws {
    let hit = AccessibilityElementsResponse(elements: .single(AccessibilityDocumentElement()))
    let cases: [(AccessibilityElementQuery, AccessibilityTargetDescriptor.Kind)] = [
      (.frontmost, .frontmost),
      (.application(pid: 99), .application),
      (.marker(value: "General", key: .label, depth: 10), .marker),
      (.point(CGPoint(x: 3, y: 4)), .point),
    ]
    for (query, kind) in cases {
      let reader = StubAXBridgeTreeReader(read: Self.stubRead(), hitTestResult: hit)
      let response = try await reader.describeTree(query, options: AccessibilityRequestOptions())
      XCTAssertEqual(response.backend, .axBridgeOneShot, "\(query) must record which backend answered")
      XCTAssertEqual(response.target?.kind, kind, "\(query) must record what was asked for")
    }
  }

  func testDescribeTreeStampsTruncationAndScreenForTreeReads() async throws {
    // The stub tree's root reports no frame, so the screen is unknown rather than zero-sized.
    let reader = StubAXBridgeTreeReader(read: Self.stubRead(truncated: true))
    let response = try await reader.describeTree(.frontmost, options: AccessibilityRequestOptions())
    XCTAssertTrue(response.truncated, "a partial walk must be reported as partial")
    XCTAssertNil(response.screen, "a root with no frame yields no screen bounds")

    let sized: [String: Any] = [
      AXWire.Node.label.rawValue: "root",
      AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(CGRect(x: 0, y: 0, width: 390, height: 844)) as NSDictionary,
      AXWire.Node.children.rawValue: [[String: Any]](),
    ]
    let sizedReader = StubAXBridgeTreeReader(read: AXTreeRead(tree: sized, pid: 99, truncated: false, modal: nil))
    let sizedResponse = try await sizedReader.describeTree(.frontmost, options: AccessibilityRequestOptions())
    XCTAssertEqual(sizedResponse.screen, AccessibilityScreenInfo(width: 390, height: 844))
    XCTAssertFalse(sizedResponse.truncated)
  }

  // A hit-test resolves one element with no tree behind it, so there is nothing to say about the
  // screen or truncation — but which backend answered and what was asked for are still known.
  func testDescribeTreeStampsAPointWithoutScreenOrTruncation() async throws {
    let hit = AccessibilityElementsResponse(elements: .single(AccessibilityDocumentElement()))
    let reader = StubAXBridgeTreeReader(read: Self.stubRead(truncated: true), hitTestResult: hit)
    let response = try await reader.describeTree(.point(CGPoint(x: 3, y: 4)), options: AccessibilityRequestOptions())
    XCTAssertEqual(response.target, .point(CGPoint(x: 3, y: 4)))
    XCTAssertNil(response.screen)
    XCTAssertFalse(response.truncated, "the unread tree's truncation must not leak onto a hit-test")
  }

  // Stamping is provenance only: it must not disturb the elements or the legacy envelope's bytes.
  func testProvenanceDoesNotChangeTheLegacyEnvelope() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead())
    let response = try await reader.describeTree(.frontmost, options: AccessibilityRequestOptions())
    let stamped = try response.legacyJSONData()
    let bare = try AccessibilityElementsResponse(elements: response.elements).legacyJSONData()
    XCTAssertEqual(stamped, bare, "provenance must stay out of the legacy envelope")
  }

  func testReplacingScreenCanClearBoundsAndKeepsEverythingElse() throws {
    let hit = AccessibilityElementsResponse(
      elements: .single(AccessibilityDocumentElement()),
      truncated: true,
      screen: AccessibilityScreenInfo(width: 370, height: 52),
      backend: .ax,
      target: .marker(value: "General", matchKey: "AXLabel")
    )
    XCTAssertNotNil(hit.screen, "the fixture starts with the misleading element-sized bounds")

    let stripped = hit.replacingScreen(nil)
    XCTAssertNil(stripped.screen, "the element's own frame is not the screen")
    XCTAssertEqual(stripped.elements, hit.elements)
    XCTAssertEqual(stripped.truncated, hit.truncated)
    XCTAssertEqual(stripped.backend, hit.backend)
    XCTAssertEqual(stripped.target, hit.target)
  }

  // Clear-then-stamp is the sequence the `ax` backend performs; the clear is what makes it safe when the root's frame
  // does not describe a screen, since `withProvenance` falls back to whatever the response already carries.
  func testMarkerReportsTheRootBoundsAndNeverTheMatchs() throws {
    let root = try XCTUnwrap(AccessibilityScreenInfo(width: 402, height: 874))
    let matchSized = AccessibilityElementsResponse(
      elements: .single(AccessibilityDocumentElement()),
      screen: AccessibilityScreenInfo(width: 370, height: 52),
      backend: .ax
    )

    let restamped = matchSized.replacingScreen(root)
    XCTAssertEqual(restamped.screen, root, "a marker read reports the root's bounds, not the match's")
    XCTAssertEqual(restamped.backend, .ax, "clearing the screen does not disturb the rest of the provenance")

    XCTAssertNil(
      matchSized.replacingScreen(nil).screen,
      "with no usable root bounds a marker reports none, rather than falling back to the match's frame"
    )
  }

  func testBackendNameIsATotalBijection() {
    // Total over allCases: a backend added without teaching both directions fails here, not at a
    // consumer that silently cannot name (or select) it.
    for name in UIAutomationBackendName.allCases {
      XCTAssertEqual(
        UIAutomationBackend(resolvedName: name).name, name,
        "\(name.rawValue) must round-trip through the backend it selects"
      )
    }
    XCTAssertEqual(
      UIAutomationBackend.axBridge(persistence: .shared, frontmostMethod: .centerPoint, automationMode: true).name,
      .axBridgePersistent,
      "the persistent transport is a distinct backend to a consumer reading timings"
    )
    XCTAssertEqual(
      UIAutomationBackend(resolvedName: .axBridgePersistent, frontmostMethod: .windowServer).name,
      .axBridgePersistent,
      "the frontmost method rides the axbridge case without disturbing its name"
    )
  }

  func testDescribeTreeThrowsForAnEmptyPoint() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead(), hitTestResult: nil)
    do {
      _ = try await reader.describeTree(.point(CGPoint(x: 1, y: 2)), options: AccessibilityRequestOptions())
      XCTFail("an empty point must throw from describe")
    } catch let error as UIAutomationError {
      guard case .noElementAtPoint = error else {
        return XCTFail("expected noElementAtPoint, got \(error)")
      }
    }
  }

  // MARK: - Shared `frameFromTree` composition

  // `frame` over a tree-reading backend is `describeTree` narrowed to the geometry key, so what it has
  // to get right is which element of the response answers each query shape, and what happens when that
  // element reports no rectangle.

  private static let rootRect = CGRect(x: 0, y: 0, width: 390, height: 844)
  private static let childRect = CGRect(x: 16, y: 100, width: 358, height: 44)

  private static func framedReader(child: CGRect? = childRect) -> StubAXBridgeTreeReader {
    func node(_ label: String, _ rect: CGRect?, children: [[String: Any]]) -> [String: Any] {
      var node: [String: Any] = [
        AXWire.Node.label.rawValue: label,
        AXWire.Node.children.rawValue: children,
      ]
      if let rect {
        node[AXWire.Node.frame.rawValue] = CGRectCreateDictionaryRepresentation(rect) as NSDictionary
      }
      return node
    }
    let tree = node("root", rootRect, children: [node("General Settings", child, children: [])])
    return StubAXBridgeTreeReader(read: AXTreeRead(tree: tree, pid: 99, truncated: false, modal: nil))
  }

  // A whole-tree query has no element in mind, so it answers with the root's — the application's own
  // rectangle, which is what the accessibility backend reports for the same query.
  func testFrameFromTreeAnswersWithTheRootRectangleForWholeTreeQueries() async throws {
    for query in [AccessibilityElementQuery.frontmost, .application(pid: 99)] {
      let frame = try await Self.framedReader().frameFromTree(query)
      XCTAssertEqual(frame, Self.rootRect, "\(query) must answer with the application root's frame")
    }
  }

  // The narrowed key set is the part most likely to break a marker: the searched key is unioned in by
  // `describeTree`, so asking for geometry alone still resolves the element rather than matching nothing.
  func testFrameFromTreeAnswersWithTheMatchedElementsRectangleForAMarker() async throws {
    let frame = try await Self.framedReader().frameFromTree(.marker(value: "General", key: .label, depth: 10))
    XCTAssertEqual(frame, Self.childRect, "a marker must answer with the matched element's frame, not the root's")
  }

  func testFrameFromTreeAnswersWithTheHitElementsRectangleForAPoint() async throws {
    var hit = AccessibilityDocumentElement()
    hit.frame = .some(AccessibilityFrame(Self.childRect))
    let reader = StubAXBridgeTreeReader(read: Self.stubRead(), hitTestResult: AccessibilityElementsResponse(elements: .single(hit)))
    let frame = try await reader.frameFromTree(.point(CGPoint(x: 20, y: 110)))
    XCTAssertEqual(frame, Self.childRect)
    XCTAssertEqual(reader.readCount, 0, "a point reads no tree to answer about its own frame")
  }

  // An absent frame key parses to .zero, so frame answers .zero rather than throwing.
  func testFrameFromTreeReportsAZeroRectangleForAnElementWithNoFrameOnTheWire() async throws {
    let frame = try await Self.framedReader(child: nil).frameFromTree(.marker(value: "General", key: .label, depth: 10))
    XCTAssertEqual(frame, .zero)
  }

  // A backend cannot reach this — `frameFromTree` requests the frame key — but the response type permits it, and a
  // zero rect is not an answer a caller could tell apart from the origin.
  func testFrameFromTreeThrowsWhenTheReadCarriesNoFrame() async throws {
    let query = AccessibilityElementQuery.point(CGPoint(x: 20, y: 110))
    let frameless = AccessibilityElementsResponse(elements: .single(AccessibilityDocumentElement()))
    do {
      _ = try await StubAXBridgeTreeReader(read: Self.stubRead(), hitTestResult: frameless).frameFromTree(query)
      XCTFail("a read carrying no frame must throw rather than answer with the origin")
    } catch let error as UIAutomationError {
      guard case let .frameUnavailable(backend, thrownQuery) = error else {
        return XCTFail("expected frameUnavailable, got \(error)")
      }
      XCTAssertEqual(backend, .axBridge(persistence: .oneShot, frontmostMethod: .centerPoint, automationMode: true))
      XCTAssertEqual(thrownQuery, query, "the error must name the target that was asked about")
    }
  }

  // Every query shape can be asked for a frame, so the error names whichever was asked — unlike
  // `elementNotOnScreen`, which can only speak about a marker.
  func testFrameUnavailableNamesEveryTargetShape() {
    let backend = UIAutomationBackend.axBridge(persistence: .oneShot, frontmostMethod: .centerPoint, automationMode: true)
    let expectations: [(AccessibilityElementQuery, String)] = [
      (.frontmost, "the frontmost application"),
      (.application(pid: 99), "pid 99"),
      (.marker(value: "General", key: .label, depth: 10), "AXLabel"),
      (.point(CGPoint(x: 3, y: 4)), "(3.0, 4.0)"),
    ]
    for (query, expected) in expectations {
      let description = UIAutomationError.frameUnavailable(backend: backend, query: query).description
      XCTAssertTrue(description.contains(expected), "\(query) should be named by \"\(expected)\": \(description)")
      XCTAssertTrue(description.contains(backend.displayName), "message should name the backend: \(description)")
    }
  }

  // MARK: - Shared `writeTarget` resolution

  // A write is point-addressed, so everything that decides *which* point — and what the guest must still
  // find there — happens before the request is built. That resolution is what these cover; the request
  // it turns into is pinned in `AXWireContractTests`.

  private static let marker = AccessibilityElementQuery.marker(value: "General", key: .label, depth: 10)

  // A coordinate names no element, so it is sent exactly as given: nothing to look up, nothing to assert
  // about, and no tree read to pay for.
  func testAPointWriteTargetsTheCoordinateItself() async throws {
    let reader = Self.framedReader()
    let target = try await reader.writeTarget(for: .point(CGPoint(x: 12, y: 34)), operation: "A tap")
    XCTAssertEqual(target, AXWriteTarget(point: CGPoint(x: 12, y: 34), pid: nil, assertion: nil))
    XCTAssertEqual(reader.readCount, 0, "a point write must not read a tree to find a point it was given")
  }

  // A marker resolves to the centre of the element it matched, scoped to the application the read
  // resolved so the guest hit-tests inside it rather than display-wide.
  func testAMarkerWriteTargetsTheMatchedElementsCentre() async throws {
    let target = try await Self.framedReader().writeTarget(for: Self.marker, operation: "A tap")
    XCTAssertEqual(target.point, CGPoint(x: Self.childRect.midX, y: Self.childRect.midY))
    XCTAssertEqual(target.pid, 99)
  }

  // Markers match by substring, so sending the marker text would refuse every marker that is a prefix of the label
  // it matched — "General" would never equal "General Settings".
  func testAMarkerAssertionCarriesTheMatchedValueRatherThanTheMarkerText() async throws {
    let target = try await Self.framedReader().writeTarget(for: Self.marker, operation: "A tap")
    XCTAssertEqual(target.assertion, AXBridgeWriteAssertion(key: .label, value: "General Settings"))
  }

  private static let suggestionRect = CGRect(x: 16, y: 200, width: 358, height: 44)

  private static func reader(children: [[String: Any]]) -> StubAXBridgeTreeReader {
    let tree: [String: Any] = [
      AXWire.Node.label.rawValue: "root",
      AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(rootRect) as NSDictionary,
      AXWire.Node.children.rawValue: children,
    ]
    return StubAXBridgeTreeReader(read: AXTreeRead(tree: tree, pid: 99, truncated: false, modal: nil))
  }

  private static func leaf(_ key: AXWire.Node, _ value: String, _ rect: CGRect?) -> [String: Any] {
    var node: [String: Any] = [key.rawValue: value, AXWire.Node.children.rawValue: [[String: Any]]()]
    if let rect {
      node[AXWire.Node.frame.rawValue] = CGRectCreateDictionaryRepresentation(rect) as NSDictionary
    }
    return node
  }

  // Safari's address field is identified exactly `URL`, and while it is being typed into, a suggestion
  // identified `SearchSuggestion?destination=URL` comes before it in the tree.
  private static let addressBarChildren = [
    leaf(.identifier, "SearchSuggestion?destination=URL", suggestionRect),
    leaf(.identifier, "URL", childRect),
  ]

  func testAMarkerDescribesTheElementEqualToItOverOneContainingIt() async throws {
    let response = try await Self.reader(children: Self.addressBarChildren).describeTree(
      .marker(value: "URL", key: .uniqueID, depth: 10), options: AccessibilityRequestOptions()
    )
    guard case let .single(element) = response.elements else {
      return XCTFail("a marker read must answer with one element, got \(response.elements)")
    }
    XCTAssertEqual(element.searchableValue(for: .uniqueID), "URL")
  }

  func testAMarkerWriteTargetsTheElementEqualToItOverOneContainingIt() async throws {
    let target = try await Self.reader(children: Self.addressBarChildren).writeTarget(
      for: .marker(value: "URL", key: .uniqueID, depth: 10), operation: "A tap"
    )
    XCTAssertEqual(target.point, CGPoint(x: Self.childRect.midX, y: Self.childRect.midY))
    XCTAssertEqual(target.assertion, AXBridgeWriteAssertion(key: .identifier, value: "URL"))
  }

  // The first match has no frame to tap, so the write goes to the next match that has one.
  func testAMarkerWriteAssertsOnTheMatchItTargets() async throws {
    let reader = Self.reader(children: [
      Self.leaf(.label, "General Settings", nil),
      Self.leaf(.label, "General Sounds", Self.childRect),
    ])
    let target = try await reader.writeTarget(for: Self.marker, operation: "A tap")
    XCTAssertEqual(target.point, CGPoint(x: Self.childRect.midX, y: Self.childRect.midY))
    XCTAssertEqual(target.assertion, AXBridgeWriteAssertion(key: .label, value: "General Sounds"))
  }

  // Only the attributes this wire carries can be asserted on; a marker searched on a host-side
  // derivation still writes, unasserted, rather than not at all.
  func testAMarkerOnANonAssertableKeyStillResolvesWithoutAnAssertion() async throws {
    let tree: [String: Any] = [
      AXWire.Node.elementType.rawValue: "Button",
      AXWire.Node.frame.rawValue: CGRectCreateDictionaryRepresentation(Self.childRect) as NSDictionary,
      AXWire.Node.children.rawValue: [[String: Any]](),
    ]
    let reader = StubAXBridgeTreeReader(read: AXTreeRead(tree: tree, pid: 99, truncated: false, modal: nil))
    let target = try await reader.writeTarget(
      for: .marker(value: "Button", key: .role, depth: 10), operation: "A tap"
    )
    XCTAssertEqual(target.point, CGPoint(x: Self.childRect.midX, y: Self.childRect.midY))
    XCTAssertNil(target.assertion, "a key this wire does not carry must not become an assertion the guest cannot check")
  }

  // Only keys whose value comes straight off the wire map; the rest are host-side derivations (`role` normalizes an
  // element type; the others are answered nil over this wire), so asserting on them would never match.
  func testOnlyWireBackedSearchKeysAreAssertable() {
    let expected: [AXSearchableKey: AXWire.Node?] = [
      .label: .label,
      .value: .value,
      .uniqueID: .identifier,
      .title: nil,
      .role: nil,
      .roleDescription: nil,
      .subrole: nil,
      .help: nil,
      .placeholder: nil,
    ]
    for (key, node) in expected {
      XCTAssertEqual(AXWire.Node(assertableSearchKey: key), node, "\(key)")
    }
  }

  // A point-addressed write acts on the deepest element under the point, so a whole-tree query would
  // silently become "whatever is in the middle of the screen" rather than the thing the caller named.
  func testWholeTreeQueriesAreRefusedForWrites() async throws {
    for query in [AccessibilityElementQuery.frontmost, .application(pid: 99)] {
      do {
        _ = try await Self.framedReader().writeTarget(for: query, operation: "A tap")
        XCTFail("\(query) must not resolve to a point to write to")
      } catch let error as UIAutomationError {
        guard case let .pointOrMarkerRequired(_, operation) = error else {
          return XCTFail("expected pointOrMarkerRequired, got \(error)")
        }
        XCTAssertEqual(operation, "A tap", "the error must name the verb that was refused")
      }
    }
  }

  func testAMarkerThatMatchesNothingIsNotFound() async throws {
    do {
      _ = try await Self.framedReader().writeTarget(
        for: .marker(value: "Wi-Fi", key: .label, depth: 10), operation: "A tap"
      )
      XCTFail("a marker matching nothing must not resolve a point")
    } catch let error as UIAutomationError {
      guard case let .elementNotFound(_, key, value) = error else {
        return XCTFail("expected elementNotFound, got \(error)")
      }
      XCTAssertEqual(key, "AXLabel")
      XCTAssertEqual(value, "Wi-Fi")
    }
  }

  // An element with no frame on the wire is normalized to a zero rectangle, so a write would resolve it to the
  // origin — a point the caller never named and something is usually drawn at.
  func testAMarkerWithNoFrameIsRefusedRatherThanResolvedToTheOrigin() async throws {
    do {
      _ = try await Self.framedReader(child: nil).writeTarget(for: Self.marker, operation: "A tap")
      XCTFail("an element with no usable frame must not resolve a point to write to")
    } catch let error as UIAutomationError {
      guard case let .elementNotOnScreen(_, key, value) = error else {
        return XCTFail("expected elementNotOnScreen, got \(error)")
      }
      XCTAssertEqual(key, "AXLabel")
      XCTAssertEqual(value, "General")
    }
  }

  // MARK: - The caller's own pre-write assertion

  func testACallerAssertionThatMatchesLetsAMarkerWriteThrough() async throws {
    let target = try await Self.framedReader().writeTarget(
      for: Self.marker,
      operation: "A tap",
      callerAssertion: TapOptions.Assertion(key: .label, value: "General Settings")
    )
    XCTAssertEqual(target.point, CGPoint(x: Self.childRect.midX, y: Self.childRect.midY))
  }

  // The caller's assertion is an equality check on the value they named, and it is reported with both
  // sides — unlike the derived one, the host holds the actual value here and can say what it found.
  func testACallerAssertionThatDoesNotMatchRefusesTheWrite() async throws {
    do {
      _ = try await Self.framedReader().writeTarget(
        for: Self.marker,
        operation: "A tap",
        callerAssertion: TapOptions.Assertion(key: .label, value: "General")
      )
      XCTFail("a caller assertion that does not match must refuse the write")
    } catch let error as UIAutomationError {
      guard case let .valueMismatch(_, key, expected, actual) = error else {
        return XCTFail("expected valueMismatch, got \(error)")
      }
      XCTAssertEqual(key, "AXLabel")
      XCTAssertEqual(expected, "General")
      XCTAssertEqual(actual, "General Settings", "a substring is not a match for an equality assertion")
    }
  }

  // A coordinate carries no value, so a caller assertion on a point costs a hit-test a bare point write does not.
  func testACallerAssertionOnAPointReadsTheElementFirst() async throws {
    var hit = AccessibilityDocumentElement()
    hit.label = .some("Wi-Fi")
    let reader = StubAXBridgeTreeReader(
      read: Self.stubRead(), hitTestResult: AccessibilityElementsResponse(elements: .single(hit))
    )
    do {
      _ = try await reader.writeTarget(
        for: .point(CGPoint(x: 5, y: 6)),
        operation: "A tap",
        callerAssertion: TapOptions.Assertion(key: .label, value: "General")
      )
      XCTFail("a caller assertion on a point must be checked against the element there")
    } catch let error as UIAutomationError {
      guard case let .valueMismatch(_, _, expected, actual) = error else {
        return XCTFail("expected valueMismatch, got \(error)")
      }
      XCTAssertEqual(expected, "General")
      XCTAssertEqual(actual, "Wi-Fi")
    }
    XCTAssertEqual(reader.hitTestPoints, [CGPoint(x: 5, y: 6)], "the assertion must be read at the point being written to")
  }

  func testACallerAssertionOnAnEmptyPointReportsTheEmptyPoint() async throws {
    let reader = StubAXBridgeTreeReader(read: Self.stubRead(), hitTestResult: nil)
    do {
      _ = try await reader.writeTarget(
        for: .point(CGPoint(x: 5, y: 6)),
        operation: "A tap",
        callerAssertion: TapOptions.Assertion(key: .label, value: "General")
      )
      XCTFail("expected noElementAtPoint to be thrown")
    } catch let error as UIAutomationError {
      guard case .noElementAtPoint = error else {
        return XCTFail("expected noElementAtPoint, got \(error)")
      }
    }
  }

  // MARK: - An unoccupied write target

  // The guest answers an unoccupied point the same way whichever query sent the write there, so the
  // error has to be chosen from what the caller named rather than from what the guest was sent.

  // A marker write reports its element as moved — the same error as the guest finding a *different* element under
  // the point; both are the screen changing between the read and the write.
  func testAnEmptyTargetIsReportedAsAMovedElementForAMarker() {
    let error = Self.framedReader().emptyWriteTargetError(for: Self.marker, at: CGPoint(x: 195, y: 122))
    guard case let .elementMoved(_, key, value) = error else {
      return XCTFail("expected elementMoved, got \(error)")
    }
    XCTAssertEqual(key, "AXLabel")
    XCTAssertEqual(value, "General")
    XCTAssertFalse(error.description.contains("195"), "a marker caller never chose a coordinate: \(error.description)")
  }

  // Only a caller who named a coordinate is told about a coordinate.
  func testAnEmptyTargetIsReportedAsAnEmptyPointForAPoint() {
    let error = Self.framedReader().emptyWriteTargetError(
      for: .point(CGPoint(x: 12, y: 34)), at: CGPoint(x: 12, y: 34)
    )
    guard case let .noElementAtPoint(_, x, y) = error else {
      return XCTFail("expected noElementAtPoint, got \(error)")
    }
    XCTAssertEqual(x, 12)
    XCTAssertEqual(y, 34)
  }

  // MARK: - Write envelope parsing

  func testAWriteEnvelopeReportsWhetherItLanded() throws {
    XCTAssertTrue(try AXTreeRead.writeLanded(fromResponse: writtenAnswer(pid: 4321)))
    XCTAssertFalse(
      try AXTreeRead.writeLanded(fromResponse: emptyWriteAnswer()),
      "writeLanded is false for an ok response carrying empty"
    )
  }

  // The guest knows what it found under the point and only the host knows which marker sent the write there, so the
  // two are joined at the backend rather than collapsing into an opaque failure here.
  func testARefusedAssertionParsesAsItsOwnFailure() throws {
    do {
      _ = try AXTreeRead.writeLanded(
        fromResponse: failureAnswer("the element at (1.0, 2.0) has XC_kAXXCAttributeLabel Wi-Fi, expected General", kind: "assertion_failed")
      )
      XCTFail("a refused write must throw")
    } catch let error as AXBridgeError {
      guard case let .assertionFailed(message) = error else {
        return XCTFail("expected assertionFailed, got \(error)")
      }
      XCTAssertTrue(message.contains("expected General"), message)
    }
  }

  func testAWriteClassifiesApplicationFailuresLikeARead() throws {
    let cases: [(String, (AXBridgeError) -> Bool)] = [
      ("application_unavailable", { if case .applicationUnavailable = $0 { true } else { false } }),
      ("application_not_responding", { if case .applicationNotResponding = $0 { true } else { false } }),
      ("bad_request", { if case .guestFailure = $0 { true } else { false } }),
      ("reader_unavailable", { if case .readerUnavailable = $0 { true } else { false } }),
    ]
    for (kind, matches) in cases {
      do {
        _ = try AXTreeRead.writeLanded(
          fromResponse: failureAnswer("no", kind: kind, pid: 4321)
        )
        XCTFail("\(kind) must throw")
      } catch let error as AXBridgeError {
        XCTAssertTrue(matches(error), "\(kind) classified as \(error)")
      }
    }
  }

  func testAnUnparseableWriteEnvelopeIsAGuestFailure() throws {
    XCTAssertThrowsError(try AXTreeRead.writeLanded(fromResponse: Data("not json".utf8)))
  }

  // Every other message opens with the backend's name, so `displayName` is capitalised and ends in
  // "backend"; this one names it part-way through a sentence, where both of those read as a stutter.
  func testAnUnsupportedOperationNamesTheBackendOnceAndInLowerCase() {
    let backends: [UIAutomationBackend] = [
      .accessibility, .axBridge(persistence: .oneShot, frontmostMethod: .centerPoint, automationMode: true),
    ]
    for backend in backends {
      let description = UIAutomationError.operationUnsupported(backend: backend, operation: "Scroll").description
      XCTAssertFalse(description.contains("the The"), description)
      XCTAssertFalse(description.contains("backend backend"), description)
      XCTAssertTrue(description.hasSuffix(backend.inlineName), description)
    }
    XCTAssertEqual(
      UIAutomationError.operationUnsupported(
        backend: .axBridge(persistence: .oneShot, frontmostMethod: .centerPoint, automationMode: true), operation: "Scroll"
      ).description,
      "Scroll is not supported over the axbridge backend"
    )
  }

}

/// Choosing a traversal per read.
final class AXTraversalStrategyTests: XCTestCase {

  // A caller who names no traversal is asking the backend to choose, so `auto` must name no traversal
  // of its own. What each backend chooses is asserted in `AXAutoTraversalTests`.
  func testARequestThatNamesNoTraversalLeavesTheChoiceToTheBackend() {
    XCTAssertEqual(AccessibilityRequestOptions().traversalStrategy, .auto)
    XCTAssertNil(AXTraversalStrategy.auto.traversal, "`auto` must name no traversal of its own")
  }

  // The other three name a traversal outright, and the resolution has to hand back the one named rather
  // than a backend's preference — otherwise `--traversal` would be advisory.
  func testANamedStrategyResolvesToItself() {
    for traversal in AXTraversal.allCases {
      XCTAssertEqual(AXTraversalStrategy(rawValue: traversal.rawValue)?.traversal, traversal)
    }
  }

  // The structural traversal answers everything; nothing a caller asks for is unsatisfiable on its
  // account, so it must never produce a warning.
  func testTheViewHierarchyCanAnswerEveryKey() {
    XCTAssertTrue(AXTraversal.viewHierarchy.unsatisfiableKeys.isEmpty)
    let options = AccessibilityRequestOptions(keys: Set(AXKeys.allCases), traversalStrategy: .viewHierarchy)
    XCTAssertTrue(options.unsatisfiableKeys(for: .viewHierarchy).isEmpty)
  }

  // The semantic traversal answers `type` from the translator's role numbering, which maps only the roles identified
  // so far; the key stays listed because a caller must be able to tell "the app set none" from "this read could not ask".
  func testSemanticCannotTypeEveryElement() {
    XCTAssertEqual(AXTraversal.semantic.unsatisfiableKeys, [.type])
  }

  // Only keys the read actually asked for are reported. A caller that never wanted the type should not
  // be warned about it.
  func testOnlyRequestedKeysAreReportedUnsatisfiable() {
    let asking = AccessibilityRequestOptions(keys: [.type, .label], traversalStrategy: .semantic)
    XCTAssertEqual(asking.unsatisfiableKeys(for: .semantic), [.type])

    let notAsking = AccessibilityRequestOptions(keys: [.label], traversalStrategy: .semantic)
    XCTAssertTrue(
      notAsking.unsatisfiableKeys(for: .semantic).isEmpty,
      "a caller that did not ask for the type must not be warned about it, "
        + "got \(notAsking.unsatisfiableKeys(for: .semantic))"
    )
  }

}

/// What each backend reads when the caller named no traversal.
///
/// Asserted against the real backend rather than `StubAXBridgeTreeReader`: these pins catch a change to the
/// backend's own default without requiring a simulator.
final class AXAutoTraversalTests: XCTestCase {

  // The whole tree in one fetch for a read that named nothing; the per-node walk for one asking about reachability,
  // the only key set the application has to hit-test.
  func testAxbridgeReadsInOneFetchWhenTheCallerNamesNothing() {
    XCTAssertEqual(AXBridgeUIAutomation.autoTraversal(for: AccessibilityRequestOptions()), .singleFetch)
    XCTAssertEqual(
      AXBridgeUIAutomation.autoTraversal(for: AccessibilityRequestOptions(keys: [.interactable, .occludedBy])),
      .viewHierarchy
    )
  }

  // The guest reads one request whichever transport carried it, so a default that snapshots over argv but walks over
  // the socket would be a read whose cost depends on how the host happened to connect.
  func testADefaultGuestReadAsksTheGuestForASnapshot() throws {
    let traversal = AXBridgeUIAutomation.autoTraversal(for: AccessibilityRequestOptions())
    let request = Self.readRequest(traversal: traversal)
    XCTAssertTrue(try wireAction(request).contains(#""traversal":"single-fetch""#))
  }

  // The same wire pin for a reachability read: it resolves to the walk, and says so.
  func testAReachabilityReadAsksTheGuestForNoSnapshot() throws {
    let traversal = AXBridgeUIAutomation.autoTraversal(for: AccessibilityRequestOptions(keys: [.interactable]))
    let request = Self.readRequest(traversal: traversal)
    XCTAssertTrue(try wireAction(request).contains(#""traversal":"view-hierarchy""#))
  }

  // Pinned in its own right, not only as the current default.
  func testTheSingleFetchAsksTheGuestForASnapshot() throws {
    let request = Self.readRequest(traversal: .singleFetch)
    XCTAssertTrue(try wireAction(request).contains(#""traversal":"single-fetch""#))
  }

  func testANamedTraversalOverridesTheBackendDefault() {
    for traversal in AXTraversal.allCases {
      guard let strategy = AXTraversalStrategy(rawValue: traversal.rawValue) else {
        return XCTFail("no strategy names \(traversal)")
      }
      let options = AccessibilityRequestOptions(traversalStrategy: strategy)
      XCTAssertEqual(AXBridgeUIAutomation.resolvedTraversal(for: options), traversal)
    }
  }

  func testANilClientTypeResolvesToNone() {
    XCTAssertNil(AccessibilityRequestOptions().clientType)
    XCTAssertEqual(AccessibilityRequestOptions().resolvedClientType, .noClient)
    for clientType in AXClientType.allCases {
      XCTAssertEqual(AccessibilityRequestOptions(clientType: clientType).resolvedClientType, clientType)
    }
  }

  func testTheDefaultOptionsDescriptionNamesNoClientType() {
    XCTAssertFalse(String(describing: AccessibilityRequestOptions()).contains("clientType"))
    XCTAssertTrue(String(describing: AccessibilityRequestOptions(clientType: .xctest)).contains("clientType=xctest"))
  }

  private static func readRequest(traversal: AXTraversal) -> AXBridgeRequest {
    .read(
      pid: 1,
      options: AXBridgeReadRequest(
        maxDepth: AXReadLimits.maxReadDepth,
        maxNodes: AXReadLimits.maxReadNodes,
        attributes: nil,
        explainUnreachable: false,
        traversal: traversal,
        automationMode: nil, clientType: .noClient
      )
    )
  }
}

/// The message a caller gets when the in-guest reader disappears mid-request.
final class AXBridgeGuestDeathTests: XCTestCase {

  // The motivating case: a guest killed by the system. The signal points at the environment rather
  // than at whatever change the caller happens to be testing.
  func testAKilledGuestIsReportedWithItsSignal() {
    let message = SimulatorFrameworkBridgeConnection.socketClosedMessage(pid: 4321, signal: 9, exitCode: nil)
    XCTAssertTrue(message.contains("killed by signal 9"), message)
    XCTAssertTrue(message.contains("pid 4321"), message)
  }

  func testAGuestThatExitedIsReportedWithItsCode() {
    let message = SimulatorFrameworkBridgeConnection.socketClosedMessage(pid: 4321, signal: nil, exitCode: 3)
    XCTAssertTrue(message.contains("exited with code 3"), message)
  }

  // A signalled exit wins over an exit code, because it names something outside the reader as the cause
  // and that is the more actionable of the two.
  func testASignalTakesPrecedenceOverAnExitCode() {
    let message = SimulatorFrameworkBridgeConnection.socketClosedMessage(pid: 4321, signal: 9, exitCode: 0)
    XCTAssertTrue(message.contains("killed by signal 9"), message)
    XCTAssertFalse(message.contains("exited with code"), message)
  }

  // A clean exit is a different problem from a kill, and the guest is gone either way.
  func testACleanExitIsStillReported() {
    XCTAssertTrue(
      SimulatorFrameworkBridgeConnection.socketClosedMessage(pid: 4321, signal: 0, exitCode: 0).contains("exited with code 0")
    )
  }

  // Nothing to consult, nothing added: a caller is told what is true and no more.
  func testSocketClosedMessageOmitsDetailWhenPidAndStatusUnknown() {
    XCTAssertEqual(
      SimulatorFrameworkBridgeConnection.socketClosedMessage(pid: nil, signal: nil, exitCode: nil),
      "serve socket closed by peer"
    )
    XCTAssertEqual(SimulatorFrameworkBridgeConnection.socketClosedMessage(process: nil), "serve socket closed by peer")
  }

  // A process whose exit status never resolved is still named, rather than the message pretending it
  // knows or the read stalling to find out.
  func testAGuestWithNoRecordedStatusIsStillNamed() {
    let message = SimulatorFrameworkBridgeConnection.socketClosedMessage(pid: 4321, signal: nil, exitCode: nil)
    XCTAssertTrue(message.contains("no exit status recorded"), message)
    XCTAssertTrue(message.contains("pid 4321"), message)
  }
}

/// A minimal `AXBridgeTreeReader` serving a canned read, so the shared `describeTree` composition can be
/// observed without a simulator. `readRawTree`, `warnIfTruncated`, `warnIfMostElementsUnframed` and `hitTest`
/// are the seams
/// `describeTree` drives; every other `UIAutomation` verb is an unused conformance stub.
private final class StubAXBridgeTreeReader: AXBridgeTreeReader, @unchecked Sendable {

  let backend: UIAutomationBackend = .axBridge(persistence: .oneShot, frontmostMethod: .centerPoint, automationMode: true)

  private let read: AXTreeRead
  private let hitTestResult: AccessibilityElementsResponse?

  private(set) var readCount = 0
  /// The attribute list each read was asked for — how a test asserts that requesting a key put its
  /// attributes on the wire, and that not requesting it left them off.
  private(set) var readAttributes: [[String]?] = []
  /// Whether each read asked the guest to explain its unreachable elements — how a test asserts that the
  /// cost is only incurred when the key that needs it was requested.
  private(set) var explainRequests: [Bool] = []
  private(set) var truncationWarnings: [Bool] = []
  /// The traversal each read was performed with — how a test asserts a caller's choice reached the wire,
  /// and what an unchosen one resolved to.
  private(set) var traversals: [AXTraversal] = []
  private(set) var clientTypes: [AXClientType] = []
  /// The traversal each profile was built for, so a test can assert the profile is told the same thing
  /// the read was rather than working it out for itself.
  private(set) var profiledTraversals: [AXTraversal] = []
  private(set) var unsatisfiableWarnings: [Set<AXKeys>] = []
  private(set) var hitTestPoints: [CGPoint] = []

  init(read: AXTreeRead, hitTestResult: AccessibilityElementsResponse? = nil) {
    self.read = read
    self.hitTestResult = hitTestResult
  }

  func readRawTree(
    for query: AccessibilityElementQuery,
    attributes: [String]?,
    explainUnreachable: Bool,
    traversal: AXTraversal,
    clientType: AXClientType,
    queryTimeout: TimeInterval?
  ) async throws -> AXTreeRead {
    readCount += 1
    clientTypes.append(clientType)
    readAttributes.append(attributes)
    explainRequests.append(explainUnreachable)
    traversals.append(traversal)
    return read
  }

  static func autoTraversal(for options: AccessibilityRequestOptions) -> AXTraversal {
    .viewHierarchy
  }

  func warnIfUnsatisfiable(_ keys: Set<AXKeys>, traversal: AXTraversal) async {
    unsatisfiableWarnings.append(keys)
  }

  func profile(
    for read: AXTreeRead, elementCount: Int, serializeDuration: CFAbsoluteTime,
    traversal: AXTraversal
  ) -> AccessibilityProfile? {
    profiledTraversals.append(traversal)
    return .guestBridge(
      AXBridgeProfile(
        elementCount: Int64(elementCount), totalDuration: 0, acquireDuration: 0, readDuration: 0,
        serializeDuration: serializeDuration, traversal: traversal
      ))
  }

  /// Records the key set of any read that would have warned about per-node hit-testing.
  private(set) var reachabilityWarnings: [Set<AXKeys>] = []

  func warnIfReachabilityAcrossTree(_ keys: Set<AXKeys>) async {
    if keys.contains(.interactable) || keys.contains(.occludedBy) {
      reachabilityWarnings.append(keys)
    }
  }

  func warnIfTruncated(_ truncated: Bool) async {
    truncationWarnings.append(truncated)
  }

  private(set) var geometryWarnings: [AccessibilityFrameSummary?] = []

  func warnIfMostElementsUnframed(_ frames: AccessibilityFrameSummary?) async {
    geometryWarnings.append(frames)
  }

  func hitTest(at point: CGPoint, options: AccessibilityRequestOptions) async throws -> AccessibilityElementsResponse? {
    hitTestPoints.append(point)
    return hitTestResult
  }

  func describe(_ query: AccessibilityElementQuery, options: AccessibilityRequestOptions) async throws -> AccessibilityElementsResponse {
    try await describeTree(query, options: options)
  }

  func tap(_ query: AccessibilityElementQuery, options: TapOptions) async throws {}

  func setValue(_ value: String, for query: AccessibilityElementQuery) async throws {}

  func wait(_ query: AccessibilityElementQuery, timeout: TimeInterval, pollInterval: TimeInterval) async throws {}

  func scroll(_ query: AccessibilityElementQuery, direction: AccessibilityScrollDirection) async throws {}

  func frame(_ query: AccessibilityElementQuery) async throws -> CGRect { .zero }

  func drag(
    from source: AccessibilityElementQuery, to destination: AccessibilityElementQuery, options: DragOptions
  ) async throws {}

  func quiescence(
    _ query: AccessibilityElementQuery, parameters: QuiescenceParameters
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
}

/// The composition of the key vocabulary's derived sets.
final class AXKeySetTests: XCTestCase {

  // Derived from `allCases`, so a new key joins `everything` automatically.
  func testEverythingIsEveryKey() {
    XCTAssertEqual(AXKeys.everything, Set(AXKeys.allCases))
    XCTAssertTrue(AXKeys.everything.isSuperset(of: AXKeys.defaultSet))
  }

  // The expensive keys are included deliberately: a caller asking for everything is asking for the
  // fields that cost extra guest work.
  func testEverythingIncludesTheKeysThatCostExtraGuestWork() {
    XCTAssertTrue(AXKeys.everything.contains(.interactable))
    XCTAssertTrue(AXKeys.everything.contains(.occludedBy))
  }
}

@objc private final class AXBridgeWaitDevice: NSObject {
  @objc let UDID = NSUUID()
  @objc var deviceType: NSObject? { nil }
}

private actor StubAXBridgeWaitTransport: AXBridgeTransport {
  private var responses: [Data]
  private(set) var readCount = 0
  private(set) var writeCount = 0
  private(set) var requests: [AXBridgeRequest] = []

  init(responses: [Data]) {
    self.responses = responses
  }

  func send(_ request: AXBridgeRequest) async throws -> AXBridgeReply {
    if case .write = request {
      writeCount += 1
    } else {
      readCount += 1
    }
    requests.append(request)
    guard !responses.isEmpty else {
      throw AXBridgeError.bridgeUnavailable
    }
    return try AXBridgeReply(answer: responses.removeFirst(), for: request)
  }
}

/// A simulator with no guest binary to launch.
private struct MissingGuestLauncher: BridgeGuestLauncher {
  func launch(_ arguments: [String]) async throws -> InSimulatorToolOutput {
    throw SimulatorFrameworkBridgeError.binaryMissing
  }
}

private actor RunningApplicationListings {
  private(set) var count = 0

  func record() {
    count += 1
  }
}
