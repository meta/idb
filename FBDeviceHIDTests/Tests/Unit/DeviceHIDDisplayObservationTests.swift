/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Dispatch
@testable import FBDeviceHID
import Foundation
import IDBConcurrency
import Testing

@Suite("Selected-device live display observation")
struct DeviceHIDDisplayObservationTests {
  private static var baseline: DeviceHIDDisplaySnapshot {
    DeviceHIDDisplaySnapshot(
      displays: [.init(identifier: 1, primary: true, integrated: true, bounds: CGRect(x: 0, y: 0, width: 400, height: 800), nativeSize: CGSize(width: 400, height: 800), pointScale: 2, nativeOrientation: "rot0", currentOrientation: "rot0")],
      orientation: .portrait, nonFlatOrientation: .portrait)
  }

  private static func prepared(_ fixture: LiveHIDFixture, snapshot: DeviceHIDDisplaySnapshot = baseline) -> DeviceHIDLivePreparation {
    fixture.preparation(snapshot: snapshot) { CGPoint(x: $0.x / 200, y: $0.y / 400) }
  }

  private static var inventory: (prepared: DeviceHIDDisplaySnapshot, native: DeviceHIDDisplaySnapshot) {
    var prepared = baseline
    var secondary = prepared.displays[0]
    secondary.identifier = 3
    secondary.primary = false
    secondary.integrated = false
    prepared.displays.append(secondary)
    var native = prepared
    for identifier in [2, 4, 5, 6, 7] as [UInt32] {
      var empty = secondary
      empty.identifier = identifier
      empty.bounds = .zero
      empty.nativeSize = .zero
      empty.pointScale = 1
      native.displays.append(empty)
    }
    return (prepared, native)
  }

  @Test func sourceWaitsForInitialFrameStartupReturnAndFactory() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let native = DeviceHIDFixture(lateFactory: true)
    let fixture = LiveHIDFixture(native: native, initial: nil, held: ["displayStartup"])
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport },
      prepareLive: { _ in Self.prepared(fixture) })
    let samples = LiveSamples(events: [.down(x: 100, y: 200), .up(x: 100, y: 200)])
    let run = fixture.task("public") { try await command.liveTouch(events: samples) }
    try await fixture.withTask(run) {
      try await fixture.events.waitFor("gate.displayStartup")
      #expect(samples.pulls.wrappedValue == 0)
      fixture.emit(Self.baseline)
      #expect(samples.pulls.wrappedValue == 0)
      #expect(fixture.events.count("factory") == 0)
      fixture.open("displayStartup")
      try await fixture.events.waitFor("factoryPending")
      #expect(samples.pulls.wrappedValue == 0)
      #expect(fixture.events.count("start") == 0)
      native.completeFactory()
      try await run.value
      #expect(samples.pulls.wrappedValue == 2)
      #expect(native.state.wrappedValue.points == [.init(x: 0.5, y: 0.5), .init(x: 0.5, y: 0.5)])
      await fixture.expectRetired()
    }
  }

  @Test func dispatchedStartupTimeoutCannotInvalidateAReadyOperation() async throws {
    let fixture = LiveHIDFixture(initial: Self.baseline)
    let operation = fixture.operation(prepared: Self.prepared(fixture))
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      fixture.clock.advance(1000)
      operation.advance()
      fixture.emit(Self.baseline)
      #expect(fixture.events.count("operationReturned") == 0)
      #expect(fixture.events.count("start") == 0)
      try await operation.sendLive(.down(x: 100, y: 200))
      try await operation.sendLive(.up(x: 100, y: 200))
      #expect((await run.value).error == nil)
      await fixture.expectRetired()
    }
  }

  @Test func delayedFirstValueCannotBeatAStarvedStartupTimer() async throws {
    let timerQueue = DispatchQueue(label: "live-test.suspended-timer")
    timerQueue.suspend()
    defer { timerQueue.resume() }
    let fixture = LiveHIDFixture(initial: nil, held: ["displayCompletion"])
    let operation = fixture.operation(prepared: Self.prepared(fixture), timerQueue: timerQueue)
    try await fixture.withOperation(operation) { run in
      try await fixture.events.waitFor("displayStartupReturned")
      fixture.clock.advance(11)
      fixture.emit(Self.baseline)
      try await fixture.events.waitFor("gate.displayCompletion")
      #expect(fixture.events.count("operationReturned") == 0)
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      fixture.clock.advance(1000)
      fixture.open("displayCompletion")
      let outcome = await run.value
      guard case .deadlineExceeded? = outcome.error as? DeviceHIDError else {
        Issue.record("A late first frame bypassed setup expiry")
        return
      }
      #expect(!outcome.uncertain)
      await fixture.expectRetired()
    }
  }

  @Test func firstFrameMustMatchPreparationRatherThanReplaceIt() async throws {
    var changed = Self.baseline
    changed.displays[0].pointScale = 4
    let fixture = LiveHIDFixture(initial: changed)
    let prepared = Self.prepared(fixture)
    let operation = fixture.operation(prepared: prepared)
    try await fixture.withOperation(operation) { run in
      let outcome = await run.value
      guard case .preparationFailed? = outcome.error as? DeviceHIDError else {
        Issue.record("A different initial basis was accepted")
        return
      }
      let normalized = try prepared.normalize(CGPoint(x: 100, y: 200))
      #expect(normalized == CGPoint(x: 0.5, y: 0.5))
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      #expect(!outcome.uncertain)
      await fixture.expectRetired()
    }
  }

  @Test(arguments: [false, true])
  func changeAwayAndBackIsStickyBeforeAndAfterInput(_ contact: Bool) async throws {
    let fixture = LiveHIDFixture(initial: Self.baseline)
    let operation = fixture.operation(prepared: Self.prepared(fixture))
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      if contact { try await operation.sendLive(.down(x: 100, y: 200)) }
      var changed = Self.baseline
      changed.displays[0].pointScale = 4
      fixture.emit(changed)
      fixture.emit(Self.baseline)
      await #expect(throws: DeviceHIDError.self) {
        try await operation.sendLive(contact ? .move(x: 110, y: 210) : .down(x: 100, y: 200))
      }
      let outcome = await run.value
      if contact {
        guard case .displayObservationFailed? = outcome.error as? DeviceHIDError else {
          Issue.record("Lost post-input failure")
          return
        }
      } else {
        guard case .preparationFailed? = outcome.error as? DeviceHIDError else {
          Issue.record("Lost pre-input failure")
          return
        }
      }
      #expect(fixture.events.count("position") == 0)
      #expect(fixture.events.count("end") == (contact ? 1 : 0))
      #expect(!outcome.uncertain)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      await fixture.expectRetired()
    }
  }

  @Test(arguments: ["id", "scale", "size", "selection", "display-set", "display-rotation", "native-rotation", "orientation", "non-flat"])
  func everyUsedBasisChangeInvalidates(_ field: String) async throws {
    let fixture = LiveHIDFixture(initial: Self.baseline)
    let operation = fixture.operation(prepared: Self.prepared(fixture))
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 100, y: 200))
      var next = Self.baseline
      switch field {
      case "id": next.displays[0].identifier = 2
      case "scale": next.displays[0].pointScale = 4
      case "size":
        next.displays[0].bounds.size.width = 402
        next.displays[0].nativeSize.width = 402
      case "selection": next.displays[0].primary = false
      case "display-set":
        var extra = next.displays[0]
        extra.identifier = 2
        extra.primary = false
        next.displays.append(extra)
      case "display-rotation": next.displays[0].currentOrientation = "rot90"
      case "native-rotation": next.displays[0].nativeOrientation = "rot90"
      case "orientation": next.orientation = .unsupported
      case "non-flat": next.nonFlatOrientation = .unsupported
      default: Issue.record("Unknown test field")
      }
      fixture.emit(next)
      let outcome = await run.value
      guard case .displayObservationFailed? = outcome.error as? DeviceHIDError else {
        Issue.record("Changed basis was not a typed observation failure")
        return
      }
      #expect(!outcome.uncertain)
      #expect(fixture.native.state.wrappedValue.points == [.init(x: 0.5, y: 0.5), .init(x: 0.5, y: 0.5)])
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      await fixture.expectRetired()
    }
  }

  @Test(arguments: ["empty", "duplicate", "external", "origin", "negative-size", "zero-scale", "negative-scale", "native-size", "orientation", "non-flat", "missing-orientation", "missing-non-flat"])
  func invalidInitialMetadataFailsClosed(_ field: String) async throws {
    var frame = Self.baseline
    switch field {
    case "empty": frame.displays = []
    case "duplicate": frame.displays.append(frame.displays[0])
    case "external": frame.displays[0].integrated = false
    case "origin": frame.displays[0].bounds.origin.x = 1
    case "negative-size": frame.displays[0].bounds.size.width = -400
    case "zero-scale": frame.displays[0].pointScale = 0
    case "negative-scale": frame.displays[0].pointScale = -1
    case "native-size": frame.displays[0].nativeSize.width = 401
    case "orientation": frame.orientation = .unsupported
    case "non-flat": frame.nonFlatOrientation = .unsupported
    case "missing-orientation": frame.orientation = nil
    case "missing-non-flat": frame.nonFlatOrientation = nil
    default: Issue.record("Unknown test field")
    }
    let fixture = LiveHIDFixture(initial: frame)
    let operation = fixture.operation(prepared: Self.prepared(fixture))
    try await fixture.withOperation(operation) { run in
      let outcome = await run.value
      guard case .preparationFailed? = outcome.error as? DeviceHIDError else {
        Issue.record("Invalid initial metadata did not fail preparation")
        return
      }
      #expect(fixture.events.count("start") == 0)
      #expect(!outcome.uncertain)
      await fixture.expectRetired()
    }
  }

  @Test(arguments: ["unchanged", "empty-add", "empty-remove", "empty-field", "nonempty"])
  func projectedFirstFramePinsTheFullLiveInventory(_ change: String) async throws {
    let inventory = Self.inventory
    #expect(inventory.prepared.displays.count == 2)
    #expect(inventory.native.displays.count == 7)
    let fixture = LiveHIDFixture(initial: inventory.native)
    let prepared = Self.prepared(fixture, snapshot: inventory.prepared)
    let operation = fixture.operation(prepared: prepared)
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 100, y: 200))
      var faceUp = inventory.native
      faceUp.orientation = .faceUp
      faceUp.displays.reverse()
      fixture.emit(faceUp)
      fixture.emit(inventory.native)
      fixture.emit(inventory.native)
      #expect(fixture.events.count("end") == 0)
      var next = inventory.native
      switch change {
      case "empty-add":
        var extra = next.displays[2]
        extra.identifier = 8
        next.displays.append(extra)
      case "empty-remove": next.displays.removeLast()
      case "empty-field": next.displays[2].pointScale = 2
      case "nonempty":
        next.displays[2].bounds.size = CGSize(width: 1, height: 1)
        next.displays[2].nativeSize = CGSize(width: 1, height: 1)
      default: break
      }
      fixture.emit(next)
      fixture.emit(inventory.native)
      if change == "unchanged" { try await operation.sendLive(.up(x: 100, y: 200)) }
      let outcome = await run.value
      if change == "unchanged" {
        #expect(outcome.error == nil)
      } else {
        guard case .displayObservationFailed? = outcome.error as? DeviceHIDError else {
          Issue.record("The full inventory was not pinned")
          return
        }
      }
      let normalized = try prepared.normalize(CGPoint(x: 100, y: 200))
      #expect(normalized == CGPoint(x: 0.5, y: 0.5))
      #expect(fixture.native.state.wrappedValue.points == [.init(x: 0.5, y: 0.5), .init(x: 0.5, y: 0.5)])
      #expect(!outcome.uncertain)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      await fixture.expectRetired()
    }
  }

  @Test(arguments: [64, 65])
  func projectionEnforcesTheFullDisplayCountBound(_ count: Int) async throws {
    var snapshot = Self.baseline
    let primary = snapshot.displays[0]
    snapshot.displays = (1...count).map { index in
      var display = primary
      display.identifier = UInt32(index)
      display.primary = index == 1
      if index != 1 {
        display.integrated = false
        display.bounds = .zero
        display.nativeSize = .zero
      }
      return display
    }
    let fixture = LiveHIDFixture(initial: snapshot)
    let operation = fixture.operation(prepared: Self.prepared(fixture))
    try await fixture.withOperation(operation) { run in
      if count == 64 {
        try await operation.waitUntilReady()
        try await operation.sendLive(.down(x: 100, y: 200))
        try await operation.sendLive(.up(x: 100, y: 200))
        #expect((await run.value).error == nil)
      } else {
        guard case .preparationFailed? = (await run.value).error as? DeviceHIDError else {
          Issue.record("Projection hid an oversized full inventory")
          return
        }
        #expect(fixture.events.count("start") == 0)
      }
      await fixture.expectRetired()
    }
  }

  @Test(arguments: [false, true])
  func acceptsFaceUpOnlyWithPortraitNonFlatBasis(_ portrait: Bool) async throws {
    var frame = Self.baseline
    frame.orientation = .faceUp
    if !portrait { frame.nonFlatOrientation = .unsupported }
    let fixture = LiveHIDFixture(initial: frame)
    let operation = fixture.operation(prepared: Self.prepared(fixture))
    try await fixture.withOperation(operation) { run in
      if portrait {
        try await operation.waitUntilReady()
        try await operation.sendLive(.down(x: 100, y: 200))
        try await operation.sendLive(.up(x: 100, y: 200))
        #expect((await run.value).error == nil)
      } else {
        guard case .preparationFailed? = (await run.value).error as? DeviceHIDError else {
          Issue.record("Unsupported flat basis was accepted")
          return
        }
      }
    }
  }

  @Test(arguments: [false, true], [false, true])
  func terminalEventsInvalidateWhileInputIsIdle(_ failed: Bool, _ contact: Bool) async throws {
    let fixture = LiveHIDFixture(initial: Self.baseline)
    let operation = fixture.operation(prepared: Self.prepared(fixture))
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      if contact { try await operation.sendLive(.down(x: 100, y: 200)) }
      fixture.finish(failed ? .failure(DeviceHIDTestError.nativeFailure) : .success(()))
      let outcome = await run.value
      if contact {
        guard case .displayObservationFailed? = outcome.error as? DeviceHIDError else {
          Issue.record("Lost idle-contact stream failure")
          return
        }
      } else if failed {
        guard case .nativeFailure(let operation, _, _, _)? = outcome.error as? DeviceHIDError else {
          Issue.record("Lost pre-input native stream error")
          return
        }
        #expect(operation == "display observation")
      } else {
        guard case .preparationFailed? = outcome.error as? DeviceHIDError else {
          Issue.record("Lost pre-input stream failure")
          return
        }
      }
      #expect(fixture.events.count("end") == (contact ? 1 : 0))
      #expect(!outcome.uncertain)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      await fixture.expectRetired()
    }
  }

  @Test func emptyStreamCannotSynthesizeABaseline() async throws {
    let fixture = LiveHIDFixture(initial: nil)
    let operation = fixture.operation(prepared: Self.prepared(fixture))
    try await fixture.withOperation(operation) { run in
      try await fixture.events.waitFor("displayStarted")
      fixture.finish()
      guard case .preparationFailed? = (await run.value).error as? DeviceHIDError else {
        Issue.record("An empty stream synthesized readiness")
        return
      }
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      await fixture.expectRetired()
    }
  }

  @Test(arguments: [false, true])
  func cancellationBeforeFirstValueJoinsBothObserverScopes(_ completionFirst: Bool) async throws {
    let fixture = LiveHIDFixture(initial: nil, held: ["displayCompletion", "displayCancelReturn"])
    let operation = fixture.operation(prepared: Self.prepared(fixture))
    try await fixture.withOperation(operation) { run in
      try await fixture.events.waitFor("displayStartupReturned")
      operation.cancel()
      try await fixture.events.waitFor("gate.displayCompletion")
      try await fixture.events.waitFor("gate.displayCancelReturn")
      fixture.clock.advance(1000)
      operation.advance()
      let first = completionFirst ? "displayCompletion" : "displayCancelReturn"
      fixture.open(first)
      try await fixture.events.waitFor(completionFirst ? "consumerReturned" : "displayCancelReturned")
      #expect(fixture.events.count("operationReturned") == 0)
      #expect(fixture.events.count("release") == 0)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      fixture.open(completionFirst ? "displayCancelReturn" : "displayCompletion")
      let outcome = await run.value
      #expect(outcome.error is CancellationError)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("start") == 0)
      await fixture.expectRetired()
    }
  }

  @Test func stalledStartupStopsAdmissionButJoinsLateStartupAndCompletion() async throws {
    let fixture = LiveHIDFixture(initial: nil, held: ["displayStartup", "displayCompletion"])
    let operation = fixture.operation(prepared: Self.prepared(fixture))
    try await fixture.withOperation(operation) { run in
      try await fixture.events.waitFor("gate.displayStartup")
      fixture.clock.advance(11)
      operation.advance()
      fixture.emit(Self.baseline)
      fixture.clock.advance(1000)
      operation.advance()
      #expect(fixture.events.count("operationReturned") == 0)
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      fixture.open("displayStartup")
      try await fixture.events.waitFor("gate.displayCompletion")
      #expect(fixture.events.count("operationReturned") == 0)
      #expect(fixture.events.count("release") == 0)
      fixture.open("displayCompletion")
      let outcome = await run.value
      guard case .deadlineExceeded? = outcome.error as? DeviceHIDError else {
        Issue.record("Stalled startup lost its deadline")
        return
      }
      #expect(!outcome.uncertain)
      await fixture.expectRetired()
    }
  }

  @Test func cancellationThenOwnedCompletionFailurePreservesBothCauses() async throws {
    let fixture = LiveHIDFixture(initial: Self.baseline, completionResult: .failure(DeviceHIDTestError.nativeFailure))
    let operation = fixture.operation(prepared: Self.prepared(fixture))
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 100, y: 200))
      operation.cancel()
      let outcome = await run.value
      guard case .cleanupFailed(let cause, let failures)? = outcome.error as? DeviceHIDError else {
        Issue.record("Observer failure hid cancellation")
        return
      }
      #expect(cause is CancellationError)
      #expect(failures.count == 1)
      guard case .displayObservationFailed? = failures.first as? DeviceHIDError else {
        Issue.record("Lost concrete observation cleanup failure")
        return
      }
      #expect(!outcome.uncertain)
      #expect(outcome.uncertaintyCause == nil)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      await fixture.expectRetired()
    }
  }

  @Test func displayConsumptionDoesNotWaitForABlockedNativeMove() async throws {
    let fixture = LiveHIDFixture(initial: Self.baseline, held: ["position"])
    let operation = fixture.operation(prepared: Self.prepared(fixture))
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 100, y: 200))
      let move = fixture.task("move") { try await operation.sendLive(.move(x: 110, y: 210)) }
      try await fixture.events.waitFor("gate.position")
      var changed = Self.baseline
      changed.displays[0].pointScale = 4
      fixture.emit(changed)
      fixture.emit(Self.baseline)
      #expect(fixture.events.count("end") == 0)
      #expect(fixture.events.count("operationReturned") == 0)
      #expect(fixture.events.count("moveReturned") == 0)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      fixture.open("position")
      _ = await move.result
      let outcome = await run.value
      guard case .displayObservationFailed? = outcome.error as? DeviceHIDError else {
        Issue.record("Blocked MOVE hid geometry invalidation")
        return
      }
      #expect(!outcome.uncertain)
      #expect(fixture.native.state.wrappedValue.points.last == CGPoint(x: 0.55, y: 0.525))
      #expect(fixture.events.count("end") == 1)
      await fixture.expectRetired()
    }
  }

  @Test func concurrentInitialLiveFramesCannotReplaceThePinnedBaseline() async throws {
    let inventory = Self.inventory
    var second = inventory.native
    second.displays[2].pointScale = 2
    let other = second
    let fixture = LiveHIDFixture(initial: nil, held: ["displayStartup"])
    let operation = fixture.operation(prepared: Self.prepared(fixture, snapshot: inventory.prepared))
    try await fixture.withOperation(operation) { run in
      try await fixture.events.waitFor("gate.displayStartup")
      try await fixture.race([{ fixture.emit(inventory.native) }, { fixture.emit(other) }])
      fixture.open("displayStartup")
      let outcome = await run.value
      guard case .preparationFailed? = outcome.error as? DeviceHIDError else {
        Issue.record("Concurrent projected frames replaced the full baseline")
        return
      }
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      #expect(!outcome.uncertain)
      await fixture.expectRetired()
    }
  }

  @Test func fullInventoryChangeRacingCancellationJoinsOneMatchingUp() async throws {
    let inventory = Self.inventory
    var changed = inventory.native
    changed.displays.removeLast()
    let mismatch = changed
    let fixture = LiveHIDFixture(initial: inventory.native)
    let operation = fixture.operation(prepared: Self.prepared(fixture, snapshot: inventory.prepared))
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 100, y: 200))
      try await fixture.race([{ fixture.emit(mismatch) }, { operation.cancel() }])
      let outcome = await run.value
      if !(outcome.error is CancellationError) {
        guard case .displayObservationFailed? = outcome.error as? DeviceHIDError else {
          Issue.record("Race replaced its primary cause")
          return
        }
      }
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(fixture.native.state.wrappedValue.points == [.init(x: 0.5, y: 0.5), .init(x: 0.5, y: 0.5)])
      await fixture.expectRetired()
    }
  }

  @Test(arguments: [1.5, 2.0, 3.0], ["portrait", "faceUp"])
  func liveAndBoundedPreparationUseTheSameImmutableNormalization(_ scale: Double, _ orientation: String) throws {
    let (details, displays) = try Self.metadata(scale: scale, orientation: orientation)
    let live = try DeviceHIDPreparation.decodeLive(details: details, displays: displays, udid: "test-phone")
    let bounded = try DeviceHIDPreparation.decodeTouch(details: details, displays: displays, udid: "test-phone", sequence: .tap(x: 100, y: 200))
    #expect(live.deviceIdentifier == bounded.start.deviceIdentifier)
    #expect(live.displaySnapshot.displays == bounded.start.displaySnapshot.displays)
    #expect(try live.normalize(CGPoint(x: 100, y: 200)) == bounded.start.point)
    for point in [CGPoint(x: -1, y: 0), CGPoint(x: 400 / scale, y: 0), CGPoint(x: 0, y: 800 / scale), CGPoint(x: Double.nan, y: 0)] {
      #expect { try live.normalize(point) } throws: { error in
        if case DeviceHIDError.liveProtocol = error { return true }
        return false
      }
    }
  }

  @Test(arguments: ["udid", "uuid", "schema", "query"])
  func identityAndMetadataMustSucceedBeforeThePrivateConsumerStarts(_ fault: String) async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let fixture = LiveHIDFixture()
    let calls = Atomic(wrappedValue: [String]())
    let command = DeviceHIDCommands(
      device: device, checkRuntime: { calls.sync { $0.append("runtime") } },
      makeTransport: { _ in
        calls.sync { $0.append("private") }
        return fixture.transport
      },
      prepareLive: { udid in
        calls.sync { $0.append("identity") }
        let (details, displays) = try Self.metadata(udid: udid, fault: fault)
        return try DeviceHIDPreparation.decodeLive(details: details, displays: displays, udid: udid)
      })
    let samples = LiveSamples(events: [.down(x: 100, y: 200)])
    await #expect(throws: (any Error).self) { try await command.liveTouch(events: samples) }
    #expect(calls.wrappedValue == ["runtime", "identity"])
    #expect(samples.pulls.wrappedValue == 0)
    #expect(fixture.events.count("displayStarted") == 0)
    #expect(fixture.events.count("acquire") == 0)
  }

  private static func metadata(udid: String = "test-phone", scale: Double = 2, orientation: String = "portrait", fault: String? = nil) throws -> (Data, Data) {
    func info(_ operation: String) -> [String: Any] {
      ["arguments": ["--device", udid], "commandType": "devicectl.device.info.\(operation)", "jsonVersion": fault == "schema" ? 4 : 5, "outcome": fault == "query" ? "failure" : "success", "version": "651.13.5"]
    }
    let details: [String: Any] = [
      "info": info("details"),
      "result": ["identifier": fault == "uuid" ? "not-a-uuid" : "00000000-0000-0000-0000-000000000001", "properties": ["hardware": ["udid": fault == "udid" ? "wrong-phone" : udid, "reality": "physical", "deviceType": "iPhone", "platform": "iOS"]]],
    ]
    let displays: [String: Any] = [
      "info": info("displays"),
      "result": [
        "displays": [["displayId": 1, "primary": true, "type": ["integrated": [String: String]()], "bounds": [[0, 0], [400, 800]], "nativeSize": [400, 800], "pointScale": scale, "currentOrientation": "rot0", "nativeOrientation": "rot0"]],
        "orientation": ["currentDeviceOrientation": orientation, "currentDeviceNonFlatOrientation": "portrait"],
      ],
    ]
    return (try JSONSerialization.data(withJSONObject: details), try JSONSerialization.data(withJSONObject: displays))
  }
}
