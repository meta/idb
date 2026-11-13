/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import Foundation
import Testing
@preconcurrency import XPC

private func displayValue(id: String, active: Bool, primary: Bool = false, rotation: String = "rot0") -> xpc_object_t {
  let dictionary = SimulatorCoreDevice.dictionary
  let array = SimulatorCoreDevice.array
  return dictionary([
    "uniqueId": xpc_string_create(id), "name": xpc_string_create(id),
    "active": xpc_bool_create(active), "primary": xpc_bool_create(primary),
    "bounds": array([array([xpc_double_create(0), xpc_double_create(0)]), array([xpc_double_create(2007), xpc_double_create(2853)])]),
    "pointScale": xpc_int64_create(3), "currentOrientation": xpc_string_create(rotation),
    "type": dictionary(["integrated": dictionary([:])]),
  ])
}

private func displayReply(_ values: [xpc_object_t], current: Bool = true) -> xpc_object_t {
  SimulatorCoreDevice.dictionary([
    "CoreDevice.output": SimulatorCoreDevice.dictionary([
      "current": xpc_bool_create(current), "displays": SimulatorCoreDevice.array(values),
    ])
  ])
}

private func report(_ values: [xpc_object_t], current: Bool = true) -> SimulatorDisplayReport {
  SimulatorDisplayProtocol.report(displayReply(values, current: current))
}

private struct NotIdentifiedDisplays: Error {
  let report: SimulatorDisplayReport
}

private func displays(_ values: [xpc_object_t]) throws -> [SimulatorDisplay] {
  let report = report(values)
  guard case let .displays(displays) = report else { throw NotIdentifiedDisplays(report: report) }
  return displays
}

private func resolution(_ values: [xpc_object_t]) -> SimulatorDisplayResolution {
  SimulatorDisplayResolution(report(values))
}

private struct Untargeted: Error {
  let resolution: SimulatorDisplayResolution
}

private func target(_ values: [xpc_object_t]) throws -> SimulatorDisplayTarget {
  let resolution = resolution(values)
  guard case let .target(target) = resolution else { throw Untargeted(resolution: resolution) }
  return target
}

private func selected(_ values: [xpc_object_t]) throws -> SimulatorDisplay {
  guard case let .selected(display) = try target(values) else { throw Untargeted(resolution: resolution(values)) }
  return display
}

private func assertFallback(_ resolution: SimulatorDisplayResolution, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
  guard case .fallback = resolution else {
    Issue.record("Expected a fallback, got \(resolution) \(message)", sourceLocation: sourceLocation)
    return
  }
}

private func assertFailed(_ report: SimulatorDisplayReport, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
  guard case .failed = report else {
    Issue.record("Expected a failed read, got \(report) \(message)", sourceLocation: sourceLocation)
    return
  }
}

private func assertLegacy(_ report: SimulatorDisplayReport, sourceLocation: SourceLocation = #_sourceLocation) {
  guard case .legacy = report else {
    Issue.record("Expected a legacy report, got \(report)", sourceLocation: sourceLocation)
    return
  }
}

@Suite
struct SimulatorDisplayReadTests {
  @Test
  func legacyGeometryRetainsInterfaceRotationWithoutInventingIdentity() throws {
    let value = displayValue(id: "legacy", active: true, rotation: "rot90")
    xpc_dictionary_set_value(value, "active", nil)
    xpc_dictionary_set_value(value, "uniqueId", nil)
    guard case let .legacy(geometry) = try target([value]).display else {
      Issue.record("Expected legacy geometry")
      return
    }
    #expect(geometry.pointSize == CGSize(width: 951, height: 669))
    #expect(geometry.unrotatedPointSize == CGSize(width: 669, height: 951))
    #expect(try geometry.unrotatedPoint(from: CGPoint(x: 787, y: 570)) == CGPoint(x: 570, y: 164))
    #expect(resolution([value, value]) == .fallback(.legacyIntegratedDisplays(count: 2)))
    #expect(report([value], current: false) == .failed(.malformed("Report is not current")))
  }

  /// Xcode 27.0 identifies its sole LCD but reports neither layout activity nor backlight state.
  @Test
  func identityWithoutActivityIsALegacyProvider() throws {
    let lcd = displayValue(id: "529D03D7-B58D-4DAA-88ED-807969A20EBC", active: true)
    xpc_dictionary_set_value(lcd, "active", nil)
    assertLegacy(report([lcd]))
    guard case .sole(.legacy) = try target([lcd]) else {
      Issue.record("Expected the sole legacy display")
      return
    }
    #expect(resolution([lcd, lcd]) == .fallback(.legacyIntegratedDisplays(count: 2)))
  }

  /// Xcode 27.1 driving an iOS 26 runtime identifies no display and reports every backlight, the LCD's
  /// included, as `unknown`.
  @Test
  func unknownBacklightOnEveryDisplayWithoutIdentity() throws {
    let lcd = displayValue(id: "LCD", active: true, primary: true)
    let externals = ["TVOut", "Wireless"].map { displayValue(id: $0, active: false) }
    let zero = SimulatorCoreDevice.array([xpc_double_create(0), xpc_double_create(0)])
    for value in externals {
      xpc_dictionary_set_value(value, "type", SimulatorCoreDevice.dictionary(["external": SimulatorCoreDevice.dictionary([:])]))
      xpc_dictionary_set_value(value, "bounds", SimulatorCoreDevice.array([zero, zero]))
    }
    for value in [lcd] + externals {
      xpc_dictionary_set_value(value, "active", nil)
      xpc_dictionary_set_value(value, "uniqueId", nil)
      xpc_dictionary_set_string(value, "backlightState", "unknown")
    }
    guard case let .legacy(integrated) = report([lcd] + externals) else {
      Issue.record("Expected a legacy report")
      return
    }
    #expect(integrated.count == 1)
    guard case let .sole(.legacy(geometry)) = try target([lcd] + externals) else {
      Issue.record("Expected the sole legacy display")
      return
    }
    #expect(geometry.pointSize == CGSize(width: 669, height: 951))
  }

  @Test
  func identifiedGeometryUsesActiveDisplayInsteadOfPrimary() throws {
    let selected = try target([
      displayValue(id: "cover", active: false, primary: true),
      displayValue(id: "inner", active: true, rotation: "rot90"),
    ]).display
    guard case let .identified(display) = selected else {
      Issue.record("Expected identified display")
      return
    }
    #expect(display.uniqueID == "inner")
    #expect(selected.geometry.pointSize == CGSize(width: 951, height: 669))
  }

  @Test
  func onlySeveralIntegratedDisplaysSelectOneByName() throws {
    let sole = try target([displayValue(id: "lcd", active: true)])
    guard case let .sole(.identified(lcd)) = sole else {
      Issue.record("Expected the sole identified display")
      return
    }
    #expect(lcd.uniqueID == "lcd")

    let selected = try target([displayValue(id: "cover", active: false), displayValue(id: "inner", active: true)])
    guard case let .selected(inner) = selected else {
      Issue.record("Expected a selected display")
      return
    }
    #expect(inner.uniqueID == "inner")

    let legacy = displayValue(id: "legacy", active: true)
    xpc_dictionary_set_value(legacy, "active", nil)
    xpc_dictionary_set_value(legacy, "uniqueId", nil)
    guard case .sole(.legacy) = try target([legacy]) else {
      Issue.record("Expected the sole legacy display")
      return
    }
  }

  /// A locked iPhone reports its only integrated display as inactive, by layout activity or by backlight.
  @Test
  func soleIntegratedDisplayIsTargetedWhileInactive() throws {
    let layout = displayValue(id: "lcd", active: false)
    let backlight = displayValue(id: "lcd", active: false)
    xpc_dictionary_set_value(backlight, "active", nil)
    xpc_dictionary_set_string(backlight, "backlightState", "off")
    for value in [layout, backlight] {
      guard case let .sole(.identified(lcd)) = try target([value]) else {
        Issue.record("Expected the sole display")
        return
      }
      #expect(lcd.uniqueID == "lcd")
      #expect(!lcd.isActive)
    }
  }

  @Test
  func interfacePointConversionPreservesAllFourRotations() throws {
    let cases: [(SimulatorDisplayRotation, CGPoint, CGPoint)] = [
      (.upright, CGPoint(x: 80, y: 120), CGPoint(x: 80, y: 120)),
      (.clockwise, CGPoint(x: 80, y: 120), CGPoint(x: 120, y: 320)),
      (.upsideDown, CGPoint(x: 80, y: 120), CGPoint(x: 520, y: 280)),
      (.counterclockwise, CGPoint(x: 80, y: 120), CGPoint(x: 480, y: 80)),
    ]
    for (rotation, point, expected) in cases {
      let geometry = SimulatorDisplayGeometry(bounds: CGRect(x: 30, y: 40, width: 1200, height: 800), scale: 2, rotation: rotation)
      #expect(try geometry.unrotatedPoint(from: point) == expected)
      for invalid in [CGPoint(x: -1, y: 0), CGPoint(x: 1000, y: 0), CGPoint(x: Double.nan, y: 0)] {
        #expect(throws: (any Error).self) { try geometry.unrotatedPoint(from: invalid) }
      }
    }
  }

  @Test
  func legacyReportWithoutIdentityOrActivityDeclinesCaptureCapability() throws {
    let value = displayValue(id: "legacy", active: true)
    xpc_dictionary_set_value(value, "active", nil)
    xpc_dictionary_set_value(value, "uniqueId", nil)
    assertLegacy(report([value]))
    assertFailed(report([value], current: false))
    // A legacy record is still held to the rest of the shape.
    xpc_dictionary_set_int64(value, "pointScale", 0)
    assertFailed(report([value]))
  }

  @Test
  func partialOrMalformedCaptureCapabilityDoesNotFallBack() {
    assertFailed(report([SimulatorCoreDevice.dictionary([:])]))
    let partial = displayValue(id: "inner", active: true)
    xpc_dictionary_set_value(partial, "active", nil)
    assertFailed(report([displayValue(id: "cover", active: false), partial]))
    let malformed = displayValue(id: "inner", active: true)
    xpc_dictionary_set_string(malformed, "active", "true")
    assertFailed(report([malformed]))
    let legacy = displayValue(id: "legacy", active: true)
    xpc_dictionary_set_value(legacy, "active", nil)
    xpc_dictionary_set_value(legacy, "uniqueId", nil)
    assertFailed(report([displayValue(id: "inner", active: true), legacy]))
  }

  @Test
  func emptyCurrentReportDoesNotFallBack() throws {
    guard case let .displays(displays) = report([]) else {
      Issue.record("An empty current report is not a legacy provider")
      return
    }
    #expect(displays == [])
    #expect(resolution([]) == .fallback(.noActiveIntegratedDisplay))
  }

  /// The shape tvOS reports: its only display is an external TVOut with backlight state but no layout activity.
  @Test
  func reportWithOnlyAnExternalDisplayHasNoIntegratedDisplay() throws {
    let fallbacks: [String: SimulatorDisplayFallback] = [
      "off": .noIntegratedDisplay, "unknown": .legacyIntegratedDisplays(count: 0),
    ]
    for (state, fallback) in fallbacks {
      let tvOut = displayValue(id: "TVOut", active: false, primary: true)
      xpc_dictionary_set_value(tvOut, "active", nil)
      xpc_dictionary_set_string(tvOut, "backlightState", state)
      xpc_dictionary_set_value(tvOut, "type", SimulatorCoreDevice.dictionary(["external": SimulatorCoreDevice.dictionary([:])]))
      #expect(resolution([tvOut]) == .fallback(fallback), "\(state)")
    }
  }

  /// Reports that cannot select exactly one active integrated display, for any reason in their display records.
  @Test
  func reportThatCannotSelectADisplay() {
    let identityOnly = displayValue(id: "lcd", active: true)
    xpc_dictionary_set_value(identityOnly, "active", nil)
    let partialLayout = displayValue(id: "inner", active: true)
    xpc_dictionary_set_value(partialLayout, "active", nil)
    let unknownBacklight = displayValue(id: "lcd", active: true)
    xpc_dictionary_set_value(unknownBacklight, "active", nil)
    xpc_dictionary_set_string(unknownBacklight, "backlightState", "unknown")
    let unscaled = displayValue(id: "lcd", active: true)
    xpc_dictionary_set_int64(unscaled, "pointScale", 0)
    // Without activity evidence the listing cannot say which display is active; interaction still
    // resolves the sole integrated display (testIdentityWithoutActivityIsALegacyProvider).
    for values in [[identityOnly], [unknownBacklight]] {
      assertLegacy(report(values))
      guard case .sole(.legacy) = try? target(values) else {
        Issue.record("Expected the sole legacy display")
        return
      }
    }
    let reports: [String: [xpc_object_t]] = [
      "partial layout activity": [displayValue(id: "cover", active: false, primary: true), partialLayout],
      "no active display": [displayValue(id: "cover", active: false), displayValue(id: "inner", active: false)],
      "several active displays": [displayValue(id: "cover", active: true), displayValue(id: "inner", active: true)],
      "invalid record": [unscaled],
    ]
    for (shape, values) in reports {
      assertFallback(resolution(values), shape)
    }
  }

  @Test
  func activityEvidenceSourceCanChangeWithoutChangingTheDisplay() throws {
    let value = displayValue(id: "inner", active: true, rotation: "rot90")
    xpc_dictionary_set_string(value, "backlightState", "activeOn")
    let layout = try target([value]).display
    xpc_dictionary_set_value(value, "active", nil)
    let backlight = try target([value]).display
    #expect(layout == backlight)
    xpc_dictionary_set_string(value, "currentOrientation", "rot180")
    #expect(!(layout.hasSameConfiguration(as: try target([value]).display)))
  }

  @Test
  func completeBacklightEvidenceSelectsIlluminatedDisplay() throws {
    for state in ["activeOn", "activeDimmed"] {
      let cover = displayValue(id: "cover", active: false, primary: true)
      let inner = displayValue(id: "inner", active: true)
      for value in [cover, inner] { xpc_dictionary_set_value(value, "active", nil) }
      xpc_dictionary_set_string(cover, "backlightState", "off")
      xpc_dictionary_set_string(inner, "backlightState", state)
      let selected = try selected([cover, inner])
      #expect(selected.uniqueID == "inner")
    }
  }

  @Test
  func backlightActivitySelectsStableIdentityAcrossNamesCountsAndOrder() throws {
    let ids = ["panel-b", "panel-c", "panel-a"]
    for count in 1...ids.count {
      let activeID = ids[count - 1]
      let values = ids.prefix(count).map { id in
        let value = displayValue(id: id, active: false)
        xpc_dictionary_set_string(value, "name", "not-a-device-label")
        xpc_dictionary_set_value(value, "active", nil)
        xpc_dictionary_set_string(value, "backlightState", id == activeID ? "activeOn" : "off")
        return value
      }
      let reported = Array(values.reversed())
      let parsed = try displays(reported)
      #expect(parsed.map(\.uniqueID) == ids.prefix(count).sorted())
      #expect(parsed.filter(\.isActive).map(\.uniqueID) == [activeID])
      #expect(try target(reported).display.uniqueID == activeID)
    }
  }

  @Test
  func backlightSelectionRejectsUncertaintyAmbiguityAndPartialLayoutActivity() throws {
    let cover = displayValue(id: "cover", active: false, primary: true)
    let inner = displayValue(id: "inner", active: true)
    for value in [cover, inner] { xpc_dictionary_set_value(value, "active", nil) }
    for (first, second) in [("off", "off"), ("inactiveOn", "off"), ("unknown", "activeOn"), ("activeOn", "activeDimmed"), ("off", "futureState")] {
      xpc_dictionary_set_string(cover, "backlightState", first)
      xpc_dictionary_set_string(inner, "backlightState", second)
      assertFallback(resolution([cover, inner]), "\(first), \(second)")
    }
    xpc_dictionary_set_string(cover, "backlightState", "off")
    xpc_dictionary_set_string(inner, "backlightState", "activeOn")
    xpc_dictionary_set_bool(cover, "active", false)
    assertFailed(report([cover, inner]))
    xpc_dictionary_set_bool(inner, "active", false)
    #expect(report([cover, inner]) == .transitioning(incoming: nil))
    #expect(resolution([cover, inner]) == .transitioning)
    #expect(SimulatorDisplayError.transitioning.localizedDescription == "Simulator display is still changing: layout has moved to a display that is not lit yet")
    xpc_dictionary_set_bool(inner, "active", true)
    #expect(try selected([cover, inner]).uniqueID == "inner")
  }

  @Test
  func aTransitioningReportNamesTheDisplayTheLayoutMovedTo() throws {
    let cover = displayValue(id: "cover", active: true, primary: true)
    let inner = displayValue(id: "inner", active: false)
    xpc_dictionary_set_string(cover, "backlightState", "off")
    xpc_dictionary_set_string(inner, "backlightState", "activeOn")
    guard case let .transitioning(incoming) = report([cover, inner]) else {
      Issue.record("Expected a transition")
      return
    }
    let display = try #require(incoming)
    #expect(display.uniqueID == "cover")
    #expect(display.activity == .active)
    #expect(display.isIntegrated)
    #expect(display.geometry.unrotatedPointSize == CGSize(width: 669, height: 951))
    #expect(display.geometry.surfacePixelSize == CGSize(width: 2007, height: 2853))
    #expect(resolution([cover, inner]) == .transitioning)
  }

  @Test
  func aTransitioningReportWithoutOneLaidOutIntegratedDisplayNamesNone() {
    let external = displayValue(id: "external", active: true)
    xpc_dictionary_set_value(external, "type", SimulatorCoreDevice.dictionary(["external": SimulatorCoreDevice.dictionary([:])]))
    let inner = displayValue(id: "inner", active: false)
    xpc_dictionary_set_string(external, "backlightState", "activeOn")
    xpc_dictionary_set_string(inner, "backlightState", "activeOn")
    #expect(report([external, inner]) == .transitioning(incoming: nil))
  }

  @Test
  func displayStringsAreBounded() {
    let long = String(repeating: "x", count: 1025)
    for key in ["uniqueId", "name"] {
      let value = displayValue(id: "inner", active: true)
      xpc_dictionary_set_string(value, key, long)
      assertFailed(report([value]), key)
    }
    assertFailed(report([displayValue(id: "", active: true)]))
  }

  @Test
  func explicitActivitySelectsInnerDespiteNonemptyPrimaryBounds() throws {
    let selected = try selected([
      displayValue(id: "cover", active: false, primary: true),
      displayValue(id: "inner", active: true, rotation: "rot90"),
    ])
    #expect(selected.uniqueID == "inner")
    #expect(selected.size == CGSize(width: 2853, height: 2007))
    #expect(selected.scale == 3)
  }

  @Test
  func activityCannotBeInferredFromMissingFieldOrStaleReport() {
    let value = displayValue(id: "cover", active: true, primary: true)
    assertFailed(report([value], current: false))
    xpc_dictionary_set_value(value, "active", nil)
    #expect(throws: (any Error).self) { try displays([value]) }
  }

  @Test
  func ambiguousAndMissingActiveIntegratedDisplaysFail() throws {
    let values = [displayValue(id: "cover", active: true), displayValue(id: "inner", active: true)]
    #expect(resolution(values) == .fallback(.ambiguousActiveDisplays(["cover", "inner"])))
    assertFailed(report([values[0], values[0]]))
  }

  @Test
  func rotationAndScaleMustBeRecognized() {
    assertFailed(report([displayValue(id: "inner", active: true, rotation: "unknown")]))
    let value = displayValue(id: "inner", active: true)
    xpc_dictionary_set_int64(value, "pointScale", 0)
    assertFailed(report([value]))
  }

  @Test
  func activeBoundsMustBeNonemptyAndFinite() {
    for width in [0, -1, Double.nan, Double.infinity] {
      let value = displayValue(id: "inner", active: true)
      xpc_dictionary_set_value(
        value, "bounds",
        SimulatorCoreDevice.array([
          SimulatorCoreDevice.array([xpc_double_create(0), xpc_double_create(0)]),
          SimulatorCoreDevice.array([xpc_double_create(width), xpc_double_create(2007)]),
        ]))
      assertFailed(report([value]))
    }
  }

  private func readDisplays(from services: SyntheticXPCServices, timeout: DispatchTimeInterval = .seconds(5)) async throws -> SimulatorDisplayReport {
    let channel = try services.channel(to: SimulatorDisplayProtocol.service)
    return try await CoreDeviceSession<SimulatorDisplayReport>(channel: channel, timeout: timeout)
      .read(SimulatorCoreDevice.dictionary([:]), decode: SimulatorDisplayProtocol.report)
  }

  @Test
  func snapshotCompletesAndClosesTheConnection() async throws {
    let services = SyntheticXPCServices()
    let peer = services.register(
      SimulatorDisplayProtocol.service, respond: SyntheticXPCPeer.replying(displayReply([displayValue(id: "inner", active: true)])))
    guard case let .displays(result) = try await readDisplays(from: services) else {
      Issue.record("Expected displays")
      return
    }
    #expect(result.map(\.uniqueID) == ["inner"])
    #expect(peer.received.count == 1)
    let closed = await peer.closed(atLeast: 1)
    #expect(closed == 1)
  }

  @Test
  func timeoutDoesNotProduceEmptySuccess() async {
    let services = SyntheticXPCServices()
    let peer = services.register(SimulatorDisplayProtocol.service, respond: SyntheticXPCPeer.silent)
    do {
      _ = try await readDisplays(from: services, timeout: .milliseconds(500))
      Issue.record("Expected a failed snapshot")
    } catch {
      guard case SimulatorCoreDeviceError.timedOut = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
    let closed = await peer.closed(atLeast: 1)
    #expect(closed == 1)
  }

  @Test
  func peerLossDoesNotProduceEmptySuccess() async {
    let services = SyntheticXPCServices()
    services.register(SimulatorDisplayProtocol.service) { $0.interrupt() }
    do {
      _ = try await readDisplays(from: services)
      Issue.record("Expected a failed snapshot")
    } catch {
      guard case SimulatorCoreDeviceError.unavailable = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
  }

  @Test
  func providerErrorIsPropagated() async throws {
    let services = SyntheticXPCServices()
    let peer = services.register(
      SimulatorDisplayProtocol.service,
      respond: SyntheticXPCPeer.replying(
        SimulatorCoreDevice.dictionary([
          "CoreDevice.error": SimulatorCoreDevice.dictionary([
            "domain": xpc_string_create("provider"), "code": xpc_int64_create(42),
          ])
        ])))
    let result = try await readDisplays(from: services)
    #expect(result == .failed(.unavailable("provider (42)")))
    let closed = await peer.closed(atLeast: 1)
    #expect(closed == 1)
  }

  @Test
  func cancellationClosesOutstandingSnapshot() async {
    let services = SyntheticXPCServices()
    let peer = services.register(SimulatorDisplayProtocol.service, respond: SyntheticXPCPeer.silent)
    let task = Task { try await readDisplays(from: services) }
    _ = await peer.received(atLeast: 1)
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    let closed = await peer.closed(atLeast: 1)
    #expect(closed == 1)
  }
}
