/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBSimulatorControl
import Foundation
import Testing

@Suite
struct DisplayCommandsTests {
  private func display(_ id: String, width: Double = 1200, activity: SimulatorDisplayActivity = .active) -> SimulatorDisplay {
    SimulatorDisplay(
      uniqueID: id, name: id, activity: activity, isPrimary: false, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: width, height: 800), scale: 2, rotation: .upright)
  }

  private let inventory = [
    SimulatorAccessibilityDisplay(uniqueID: "cover", displayID: 2),
    SimulatorAccessibilityDisplay(uniqueID: "inner", displayID: 3),
  ]

  @Test
  func soleDisplayResolvesWithoutNamingIt() async throws {
    let displays = DisplayCommandsDouble(.sole(.identified(display("lcd"))))
    let resolved = try await displays.resolveDisplay()
    #expect(resolved == .target(.sole(.identified(display("lcd")))))
    #expect(displays.reads == 1)
  }

  @Test
  func selectedDisplayIdentityIsLookedUpOnceAndConfirmed() async throws {
    let displays = DisplayCommandsDouble(.selected(display("inner")))
    let transport = InventoryTransport(inventory)
    let first = try await displays.accessibilityID(for: display("inner"), transport: transport, receiveTimeout: 5)
    #expect(first == 3)
    #expect(displays.reads == 1)
    let second = try await displays.accessibilityID(for: display("inner"), transport: transport, receiveTimeout: 5)
    #expect(second == first)
    #expect(displays.reads == 1)
    let sends = await transport.sends
    #expect(sends == 1)
  }

  @Test
  func aDisplayLookupIsBoundedByTheCallersTimeout() async throws {
    let displays = DisplayCommandsDouble(.selected(display("inner")))
    let transport = InventoryTransport(inventory)
    _ = try await displays.accessibilityID(for: display("inner"), transport: transport, receiveTimeout: 5)
    let receiveTimeouts = await transport.receiveTimeouts
    #expect(receiveTimeouts == [5])
  }

  @Test
  func newlySelectedDisplayRefreshesTheCache() async throws {
    let displays = DisplayCommandsDouble(.selected(display("inner")), .selected(display("cover")))
    let transport = InventoryTransport(inventory)
    let inner = try await displays.accessibilityID(for: display("inner"), transport: transport, receiveTimeout: 5)
    let cover = try await displays.accessibilityID(for: display("cover"), transport: transport, receiveTimeout: 5)
    #expect(inner == 3)
    #expect(cover == 2)
    let sends = await transport.sends
    #expect(sends == 1)
  }

  @Test
  func unlistedDisplayHasNoMapping() async throws {
    let displays = DisplayCommandsDouble(.selected(display("rear")))
    do {
      _ = try await displays.accessibilityID(for: display("rear"), transport: InventoryTransport(inventory), receiveTimeout: 5)
      Issue.record("Expected a missing mapping")
    } catch SimulatorDisplayInteractionError.missingMapping("rear") {}
    #expect(displays.identities.accessibilityID(for: "inner") == nil)
  }

  @Test
  func displayChangeDuringLookupFails() async throws {
    let displays = DisplayCommandsDouble(.selected(display("cover")))
    do {
      _ = try await displays.accessibilityID(for: display("inner"), transport: InventoryTransport(inventory), receiveTimeout: 5)
      Issue.record("Expected a display change")
    } catch SimulatorDisplayError.changed {}
    #expect(displays.identities.accessibilityID(for: "inner") == nil)
  }

  @Test
  func runtimeWithoutDisplayReportsFallsBack() async throws {
    let displays = DisplayCommandsDouble([.success(.failed(.unsupported("displayinfo")))])
    let resolved = try await displays.resolveDisplay()
    #expect(resolved == .fallback(.unreadable(.unsupported("displayinfo"))))
  }

  @Test
  func runtimeThatCannotSayWhichDisplayIsTargetedFallsBack() async throws {
    let geometry = SimulatorDisplayGeometry(bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: .upright)
    let unknown = display("lcd", activity: .unknown)
    let cases: [(SimulatorDisplayReport, SimulatorDisplayFallback)] = [
      (.failed(.unavailable("displayinfo")), .unreadable(.unavailable("displayinfo"))),
      (.failed(.timedOut), .unreadable(.timedOut)),
      (.failed(.malformed("Unknown backlight state")), .unreadable(.malformed("Unknown backlight state"))),
      (.displays([unknown]), .unknownActivity),
      (.legacy(integrated: []), .legacyIntegratedDisplays(count: 0)),
      (.legacy(integrated: [geometry, geometry]), .legacyIntegratedDisplays(count: 2)),
    ]
    for (report, fallback) in cases {
      let resolved = try await DisplayCommandsDouble([.success(report)]).resolveDisplay()
      #expect(resolved == .fallback(fallback))
    }
  }

  @Test
  func aRuntimeWithOnlyATVOutputFallsBackWithoutWaiting() async throws {
    // An Apple TV renders only on its TV output: no integrated display is going to become active.
    let tvOut = SimulatorDisplay(
      uniqueID: "F774281A-0000-0000-0000-000000000000", name: "TVOut", activity: .active, isPrimary: true, isIntegrated: false,
      bounds: CGRect(x: 0, y: 0, width: 3840, height: 2160), scale: 2, rotation: .upright)
    let displays = DisplayCommandsDouble([.success(.displays([tvOut]))])
    let resolved = try await displays.resolveDisplay()
    #expect(resolved == .fallback(.noIntegratedDisplay))
    #expect(displays.reads == 1)
  }

  @Test
  func resolvingWhileNoDisplayIsActiveWaitsForOne() async throws {
    let displays = DisplayCommandsDouble([
      .success(.displays([display("cover", activity: .inactive), display("inner", activity: .inactive)])),
      .success(.reporting(.selected(display("inner")))),
    ])
    let resolved = await outcome { try await displays.resolveDisplay() }
    #expect(try resolved.get() == .target(.selected(display("inner"))))
    #expect(displays.reads == 2)
  }

  @Test
  func resolvingWhileSeveralDisplaysStayActiveFails() async throws {
    let displays = DisplayCommandsDouble([.success(.displays([display("cover"), display("inner")]))])
    let resolved = await outcome { try await displays.resolveDisplay() }
    guard case let .failure(SimulatorDisplayError.ambiguousActiveDisplays(identities)) = resolved else {
      Issue.record("\(resolved)")
      return
    }
    #expect(identities == ["cover", "inner"])
    #expect(displays.reads > 1)
  }

  @Test
  func fallbackIsAChangeFromAReportedDisplay() async throws {
    let displays = DisplayCommandsDouble([.success(.failed(.unsupported("displayinfo")))])
    do {
      try await displays.validate(.identified(display("lcd")))
      Issue.record("Expected a display change")
    } catch SimulatorDisplayError.changed {}
  }

  @Test
  func requiredCapabilityIsCheckedOfTheGuest() async throws {
    let selected = DisplayCommandsDouble(.selected(display("inner")))
    selected.identities.remember(inventory)
    let oldGuest = InventoryTransport(inventory)
    do {
      _ = try await selected.accessibilityID(for: display("inner"), transport: oldGuest, requiring: .scopedInteractions, receiveTimeout: 5)
      Issue.record("Expected the guest to lack scoped interactions")
    } catch SimulatorDisplayInteractionError.unsupportedCapability {}
    let oldGuestSends = await oldGuest.sends
    #expect(oldGuestSends == 1)

    let currentGuest = InventoryTransport(inventory, scopedInteractions: true)
    for _ in 0..<2 {
      let resolved = try await selected.accessibilityID(for: display("inner"), transport: currentGuest, requiring: .scopedInteractions, receiveTimeout: 5)
      #expect(resolved == 3)
    }
    let currentGuestSends = await currentGuest.sends
    #expect(currentGuestSends == 1)
  }

  @Test
  func lookupDuringADisplayTransitionSettlesOnTheNextReport() async throws {
    let settled = Result<SimulatorDisplayReport, any Error>.success(.reporting(.selected(display("inner"))))
    let touchscreens = [SimulatorTouchscreen(displayUniqueID: "inner", digitizerTarget: 29)]
    let accessibility = DisplayCommandsDouble([transition, settled])
    let hid = DisplayCommandsDouble([transition, settled], touchscreens: touchscreens)
    let transport = InventoryTransport(inventory)
    let accessibilityID = await outcome { try await accessibility.accessibilityID(for: selected(accessibility), transport: transport, receiveTimeout: 5) }
    let digitizerTarget = await outcome { try await hid.digitizerTarget(for: selected(hid)) }
    #expect(try accessibilityID.get() == 3)
    #expect(try digitizerTarget.get() == 29)
    #expect([accessibility.reads, hid.reads] == [3, 3] as [Int])
  }

  @Test
  func lookupFailsWhenADisplayTransitionDoesNotSettle() async throws {
    let displays = DisplayCommandsDouble([transition])
    let resolved = try await displays.resolveDisplay()
    #expect(resolved == .transitioning)
    #expect(displays.reads > 1)
    let hid = DisplayCommandsDouble([transition], touchscreens: [SimulatorTouchscreen(displayUniqueID: "inner", digitizerTarget: 29)])
    assertTransitioning(await outcome { try await hid.digitizerTarget(for: display("inner")) })
  }

  private func selected(_ displays: DisplayCommandsDouble) async throws -> SimulatorDisplay {
    guard case let .target(.selected(display)) = try await displays.resolveDisplay() else {
      throw SimulatorDisplayInteractionError.unsupportedCapability("a selected display")
    }
    return display
  }

  private let transition = Result<SimulatorDisplayReport, any Error>.success(.transitioning(incoming: nil))

  private func outcome<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
  }

  private func assertTransitioning<T>(_ result: Result<T, any Error>, sourceLocation: SourceLocation = #_sourceLocation) {
    guard case let .failure(error) = result, case SimulatorDisplayError.transitioning = error else {
      Issue.record("\(result)", sourceLocation: sourceLocation)
      return
    }
  }

  @Test
  func validateComparesConfiguration() async throws {
    let displays = DisplayCommandsDouble(.selected(display("inner")))
    try await displays.validate(.identified(display("inner")))
    do {
      try await displays.validate(.identified(display("inner", width: 800)))
      Issue.record("Expected a display change")
    } catch SimulatorDisplayError.changed {}
  }

  @Test
  func describingNamesIdentifiedDisplaysAndNoLegacyOnes() async throws {
    let geometry = display("lcd").geometry
    guard case let .read(displays) = try await DisplayCommandsDouble([.success(.displays([display("cover"), display("inner")]))]).describedDisplays()
    else {
      Issue.record("identified displays are read")
      return
    }
    #expect(displays.map(\.uniqueID) == ["cover", "inner"])
    guard case let .read(legacy) = try await DisplayCommandsDouble([.success(.legacy(integrated: [geometry]))]).describedDisplays() else {
      Issue.record("a legacy runtime is read")
      return
    }
    #expect(legacy.isEmpty)
    guard case .failed = try await DisplayCommandsDouble([.success(.failed(.malformed("unreadable")))]).describedDisplays() else {
      Issue.record("an unreadable report fails")
      return
    }
  }

  @Test
  func describingDuringADisplayTransitionSettlesOnTheNextReport() async throws {
    let displays = DisplayCommandsDouble([.success(.transitioning(incoming: nil)), .success(.displays([display("inner")]))])

    guard case let .read(described) = try await displays.describedDisplays() else {
      Issue.record("the settled displays are read")
      return
    }

    #expect(described.map(\.uniqueID) == ["inner"])
    #expect(displays.reads == 2)
  }

  @Test
  func describingFailsWhenADisplayTransitionDoesNotSettle() async throws {
    guard case let .failed(error) = try await DisplayCommandsDouble([.success(.transitioning(incoming: nil))]).describedDisplays(),
      case SimulatorDisplayError.transitioning = error
    else {
      Issue.record("an unsettled transition fails")
      return
    }
  }

  @Test
  func aDisplayIsDescribedInItsCurrentOrientation() {
    let display = SimulatorDisplay(
      uniqueID: "FA9C9507-0D45-4189-A7D6-A3335032D47B", name: "LCD-1", activity: .active, isPrimary: false, isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: 2008, height: 2854), scale: 3, rotation: .clockwise)

    #expect(
      String(reflecting: TargetDisplayDescription(display))
        == String(
          reflecting: TargetDisplayDescription(
            uniqueID: "FA9C9507-0D45-4189-A7D6-A3335032D47B", name: "LCD-1", isActive: true, isIntegrated: true, widthPixels: 2854,
            heightPixels: 2008, scale: 3)))
  }

  @Test
  func anInactiveExternalDisplayIsDescribedAsSuch() {
    let display = SimulatorDisplay(
      uniqueID: "F774281A-0000-0000-0000-000000000000", name: "TVOut", activity: .inactive, isPrimary: false, isIntegrated: false,
      bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1, rotation: .upright)

    let described = TargetDisplayDescription(display)

    #expect(!described.isActive)
    #expect(!described.isIntegrated)
    #expect(described.widthPixels == 1920)
    #expect(described.heightPixels == 1080)
  }

  @Test
  func aDisplayWithoutAUsableSizeIsDescribedWithNone() {
    let display = SimulatorDisplay(
      uniqueID: "F774281A-0000-0000-0000-000000000000", name: "TVOut", activity: .inactive, isPrimary: false, isIntegrated: false,
      bounds: CGRect(x: 0, y: 0, width: CGFloat.nan, height: -1), scale: 1, rotation: .upright)

    let described = TargetDisplayDescription(display)

    #expect(described.widthPixels == 0)
    #expect(described.heightPixels == 0)
  }

  @Test
  func theSelectedDisplayIsTheActiveOneOnceATransitionSettles() async throws {
    for selection in [DisplaySelection.display(uniqueID: "inner"), .configuration(generation: 1)] {
      let displays = DisplayCommandsDouble([.success(.transitioning(incoming: nil)), .success(.reporting(.selected(display("inner"))))])
      let selected = try await displays.activeDisplay(selectedBy: selection, within: .seconds(1))
      #expect(selected == display("inner"), "\(selection)")
      #expect(displays.reads == 2, "\(selection)")
    }
  }

  @Test
  func aSelectionThatIsNotTheActiveDisplayFails() async {
    let selections: [(DisplaySelection, (any Error) -> Bool)] = [
      (.display(uniqueID: "cover"), { if case SimulatorDisplayInteractionError.inactiveDisplay("cover") = $0 { true } else { false } }),
      (.configuration(generation: 2), { if case SimulatorDisplayError.changed = $0 { true } else { false } }),
    ]
    for (selection, matches) in selections {
      do {
        _ = try await DisplayCommandsDouble(.selected(display("inner"))).activeDisplay(selectedBy: selection, within: .zero)
        Issue.record("Expected \(selection) to fail")
      } catch { #expect(matches(error), "\(selection): \(error)") }
    }
  }

  @Test
  func noDisplayIsSelectedMidTransition() async {
    do {
      _ = try await DisplayCommandsDouble([.success(.transitioning(incoming: nil))]).activeDisplay(selectedBy: .display(uniqueID: "inner"), within: .zero)
      Issue.record("Expected a transition")
    } catch {
      guard case SimulatorDisplayError.transitioning = error else {
        Issue.record("\(error)")
        return
      }
    }
  }
}
