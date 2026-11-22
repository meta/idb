/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBSimulatorBridgeProtocol
@testable import FBSimulatorControl
import Foundation
import Testing

@Suite
struct SimulatorDisplayInteractionTests {
  private func display(
    id: String = "inner", active: Bool = true, rotation: SimulatorDisplayRotation = .upright, scale: Double = 2
  ) -> SimulatorDisplay {
    SimulatorDisplay(
      uniqueID: id, name: id, activity: active ? .active : .inactive, isPrimary: false, isIntegrated: true,
      bounds: CGRect(x: 50, y: 60, width: 1200, height: 800), scale: scale, rotation: rotation)
  }

  @Test
  func hidBindingNeedsOnlyTheMatchingTouchscreenIdentity() async throws {
    let selected = display()
    let displays = DisplayCommandsDouble(
      .selected(selected),
      touchscreens: [
        SimulatorTouchscreen(displayUniqueID: "cover", digitizerTarget: 29),
        SimulatorTouchscreen(displayUniqueID: "inner", digitizerTarget: 82),
      ])
    let target = try await displays.digitizerTarget(for: selected)
    #expect(target == 82)
    let cached = try await displays.digitizerTarget(for: selected)
    #expect(cached == target)
    #expect(displays.touchscreenReads == 1)

    let binding = SimulatorHIDDisplay.selected(selected, id: target)
    let identified = SimulatorHIDDisplay.sole(.identified(selected))
    let legacy = SimulatorHIDDisplay.sole(.legacy(selected.geometry))
    #expect(binding.digitizerTarget == 82)
    #expect(binding.geometry == selected.geometry)
    #expect(identified.digitizerTarget == 0)
    #expect(legacy.digitizerTarget == 0)
    #expect(!binding.hasSameConfiguration(as: identified))
    #expect(!identified.hasSameConfiguration(as: legacy))
  }

  @Test
  func hidBindingRejectsAmbiguousAndMissingTargets() async {
    let selected = display()
    let target = SimulatorTouchscreen(displayUniqueID: "inner", digitizerTarget: 82)
    for targets in [[], [target, target], [SimulatorTouchscreen(displayUniqueID: "cover", digitizerTarget: 82)]] {
      do {
        _ = try await DisplayCommandsDouble(.selected(selected), touchscreens: targets).digitizerTarget(for: selected)
        Issue.record("Expected a unique target requirement")
      } catch {
        guard case SimulatorDisplayInteractionError.unsupportedCapability = error else {
          Issue.record("Unexpected mapping error: \(error)")
          return
        }
      }
    }
  }

  @Test
  func hidBindingIsNotCachedWhenTheDisplayChangesDuringLookup() async {
    let displays = DisplayCommandsDouble(
      .selected(display(id: "cover")),
      touchscreens: [SimulatorTouchscreen(displayUniqueID: "inner", digitizerTarget: 82)])
    do {
      _ = try await displays.digitizerTarget(for: display())
      Issue.record("Expected a display change")
    } catch {
      guard case SimulatorDisplayError.changed = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
    #expect(displays.identities.digitizerTarget(for: "inner") == nil)
  }

  @Test
  func hidGeometryRotatesPointsAndEdgesTogether() throws {
    let cases: [(SimulatorDisplayRotation, CGPoint, SimulatorHIDEdge)] = [
      (.upright, CGPoint(x: 0.2, y: 0.3), .top),
      (.clockwise, CGPoint(x: 0.3, y: 0.8), .left),
      (.upsideDown, CGPoint(x: 0.8, y: 0.7), .bottom),
      (.counterclockwise, CGPoint(x: 0.7, y: 0.2), .right),
    ]
    for (rotation, expected, edge) in cases {
      let geometry = display(rotation: rotation, scale: 3).geometry
      let size = geometry.pointSize
      let point = try geometry.normalizedPoint(CGPoint(x: size.width * 0.2, y: size.height * 0.3))
      #expect(abs(point.x - expected.x) <= 0.000001)
      #expect(abs(point.y - expected.y) <= 0.000001)
      #expect(geometry.unrotatedEdge(.top) == edge)
      #expect(geometry.unrotatedEdge(.none) == .none)
      #expect(throws: (any Error).self) { try geometry.normalizedPoint(CGPoint(x: size.width + 1, y: 0)) }
    }
    let first = SimulatorHIDDisplay.selected(display(), id: 82)
    #expect(!first.hasSameConfiguration(as: .selected(display(), id: 29)))
    #expect(!first.hasSameConfiguration(as: .selected(display(rotation: .clockwise), id: 82)))
  }

  @Test
  func theSurfacePixelSizeIsThePanelsWhateverTheRotation() {
    for rotation in [SimulatorDisplayRotation.upright, .clockwise, .upsideDown, .counterclockwise] {
      #expect(display(rotation: rotation, scale: 3).geometry.surfacePixelSize == CGSize(width: 1200, height: 800), "\(rotation)")
    }
    let fractional = SimulatorDisplayGeometry(bounds: CGRect(x: 0, y: 0, width: 2007.4, height: 2852.6), scale: 3, rotation: .upright)
    #expect(fractional.surfacePixelSize == CGSize(width: 2007, height: 2853))
  }

  @Test
  func invalidPointDescriptionsNameTheProblem() {
    #expect(SimulatorDisplayInteractionError.invalidPoint(CGPoint(x: 401, y: 0), bounds: CGSize(width: 400, height: 300)).localizedDescription == "Touch point (401.0, 0.0) is outside the display's point bounds (400.0 x 300.0)")
    #expect(SimulatorDisplayInteractionError.invalidPoint(CGPoint(x: Double.nan, y: 0), bounds: CGSize(width: 400, height: 300)).localizedDescription == "Touch point (nan, 0.0) is not a real position (x is NaN) within the display's point bounds (400.0 x 300.0)")
    #expect(SimulatorDisplayInteractionError.invalidPoint(CGPoint(x: 0, y: -Double.infinity), bounds: CGSize(width: 400, height: 300)).localizedDescription == "Touch point (0.0, -inf) is not a real position (y is infinite) within the display's point bounds (400.0 x 300.0)")
  }

  @Test
  func inventoryRejectsInvalidIDsAndPreservesUnsupportedFailure() throws {
    let valid = Data(#"{"displays":{"inventory":{"displayScopedInteractions":false,"displayScopedQuiescence":false,"displayScopedTrees":false,"displays":[{"uniqueID":"inner","displayID":82}]}}}"#.utf8)
    #expect(try AXBridgeDisplayInventory.decode(valid) == [SimulatorAccessibilityDisplay(uniqueID: "inner", displayID: 82)])
    for id in ["0", "-1", "4294967296", "true", "1.5", #""82""#] {
      let data = Data("{\"displays\":{\"inventory\":{\"displayScopedInteractions\":false,\"displayScopedQuiescence\":false,\"displayScopedTrees\":false,\"displays\":[{\"uniqueID\":\"inner\",\"displayID\":\(id)}]}}}".utf8)
      #expect(throws: (any Error).self) { try AXBridgeDisplayInventory.decode(data) }
    }
    for json in [
      #"{"displays":{"inventory":{}}}"#,
      #"{"displays":{"inventory":{"displayScopedInteractions":false,"displayScopedQuiescence":false,"displayScopedTrees":false,"displays":[{"uniqueID":"","displayID":82}]}}}"#,
      #"{"displays":{"inventory":{"displayScopedInteractions":false,"displayScopedQuiescence":false,"displayScopedTrees":false,"displays":[{"uniqueID":"a","displayID":82},{"uniqueID":"b","displayID":82}]}}}"#,
      #"{"displays":{"inventory":{"displayScopedInteractions":false,"displayScopedQuiescence":false,"displayScopedTrees":false,"displays":[{"uniqueID":"a","displayID":82},{"uniqueID":"a","displayID":29}]}}}"#,
    ] {
      #expect(throws: (any Error).self) { try AXBridgeDisplayInventory.decode(Data(json.utf8)) }
    }
    let unsupported = try #require(
      #expect(throws: (any Error).self) {
        try AXBridgeDisplayInventory.decode(Data(#"{"failure":{"reason":{"error_kind":"capability_unavailable"}}}"#.utf8))
      })
    if case SimulatorDisplayInteractionError.unsupportedCapability = unsupported {} else { Issue.record("\(unsupported)") }
    let unavailable = try #require(
      #expect(throws: (any Error).self) {
        try AXBridgeDisplayInventory.decode(Data(#"{"failure":{"reason":{"error_kind":"reader_unavailable","error":"failed"}}}"#.utf8))
      })
    if case AXBridgeError.readerUnavailable = unavailable {} else { Issue.record("\(unavailable)") }
    #expect(AXBridgeRequest.displays.command == .accessibility(.displays))
    #expect(try wireAction(.displays) == #"{"displays":{}}"#)
    #expect(AXBridgeRequest.displays.mayRetry)
  }

  @Test
  func scopedInteractionsRequireGuestAdvertisement() throws {
    let unadvertising = Data(#"{"displays":{"inventory":{"displayScopedInteractions":false,"displayScopedQuiescence":false,"displayScopedTrees":false,"displays":[{"uniqueID":"inner","displayID":82}]}}}"#.utf8)
    #expect(try AXBridgeDisplayInventory.decode(unadvertising).count == 1)
    let unadvertised = try #require(
      #expect(throws: (any Error).self) {
        try AXBridgeDisplayInventory.decode(unadvertising, requiring: .scopedInteractions)
      })
    if case SimulatorDisplayInteractionError.unsupportedCapability = unadvertised {} else { Issue.record("\(unadvertised)") }
    let currentGuest = Data(#"{"displays":{"inventory":{"displayScopedInteractions":true,"displayScopedQuiescence":false,"displayScopedTrees":false,"displays":[{"uniqueID":"inner","displayID":82}]}}}"#.utf8)
    #expect(try AXBridgeDisplayInventory.decode(currentGuest, requiring: .scopedInteractions).count == 1)
    #expect(throws: (any Error).self) { try AXBridgeDisplayInventory.decode(currentGuest, requiring: .scopedTrees) }
    let scopedGuest = Data(#"{"displays":{"inventory":{"displayScopedInteractions":false,"displayScopedQuiescence":false,"displayScopedTrees":true,"displays":[{"uniqueID":"inner","displayID":82}]}}}"#.utf8)
    #expect(try AXBridgeDisplayInventory.decode(scopedGuest, requiring: .scopedTrees).count == 1)
  }
}

// The inventory tests spell the guest's answer as the envelope it writes; this decodes it as the transport does.
extension AXBridgeDisplayInventory {
  fileprivate static func decode(_ data: Data, requiring capabilities: AXBridgeDisplayCapabilities = []) throws -> [SimulatorAccessibilityDisplay] {
    try decode(AXBridgeReply(answer: data, for: .displays).answer, requiring: capabilities)
  }
}
