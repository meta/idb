/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBDeviceHID
import Foundation
import Testing

@Suite("Physical HID caller completion and native retirement")
struct DeviceHIDRetirementTests {
  @Test func shutdownWaitIncludesAdmittedPreparationBeforeNativeInstallation() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let replacement = DeviceHIDRetentionTests.makeInertDevice(udid: device.udid)
    let fixture = LiveHIDFixture()
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {},
      prepareLive: { _ in
        fixture.events.record("preparing")
        try await fixture.events.waitFor("finishPreparation")
        fixture.events.record("preparationReturned")
        throw DeviceHIDError.preparationFailed("injected failure")
      })
    let other = DeviceHIDCommands(device: replacement)
    let run = fixture.task("public") { try await command.liveTouch(events: LiveSamples(events: [])) }
    try await fixture.withTask(run) {
      defer { fixture.events.record("finishPreparation") }
      try await fixture.events.waitFor("preparing")
      let waiter = fixture.task("waiter") {
        fixture.events.record("waitEntered")
        await other.waitForRetirement()
      }
      try await fixture.events.waitFor("waitEntered")
      #expect(fixture.events.count("waiterReturned") == 0)
      fixture.events.record("finishPreparation")
      await #expect(throws: DeviceHIDError.self) { try await run.value }
      try await waiter.value
      #expect(try #require(fixture.events.time("preparationReturned")) <= #require(fixture.events.time("waiterReturned")))
      #expect(fixture.events.count("acquire") == 0)
      await other.waitForRetirement()
    }
    withExtendedLifetime((device, replacement)) {}
  }

  @Test func shutdownWaitIgnoresCancellationWithoutCancellingHealthyOwner() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let replacement = DeviceHIDRetentionTests.makeInertDevice(udid: device.udid)
    let fixture = LiveHIDFixture()
    let command = DeviceHIDCommands(device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport }, prepareLive: { _ in fixture.preparation() })
    let other = DeviceHIDCommands(device: replacement)
    await other.waitForRetirement()
    let (stream, writer) = AsyncThrowingStream<DeviceHIDLiveEvent, any Error>.makeStream()
    defer { writer.finish() }
    let source = ObservedLiveStream(stream: stream, events: fixture.events)
    let run = fixture.task("public") { try await command.liveTouch(events: source) }
    try await fixture.withTask(run) {
      writer.yield(.down(x: 0.25, y: 0.5))
      try await fixture.events.waitFor("sourcePull2")
      let waiter = fixture.task("waiter") {
        try await fixture.events.waitFor("enterWait")
        #expect(Task.isCancelled)
        fixture.events.record("waitEntered")
        await other.waitForRetirement()
      }
      waiter.cancel()
      fixture.events.record("enterWait")
      try await fixture.events.waitFor("waitEntered")
      writer.yield(.move(x: 0.4, y: 0.5))
      try await fixture.events.waitFor("sourcePull3")
      #expect(fixture.events.count("waiterReturned") == 0)
      #expect(fixture.events.count("end") == 0)
      writer.yield(.up(x: 0.4, y: 0.5))
      try await run.value
      try await waiter.value
      #expect(try #require(fixture.events.time("discard")) <= #require(fixture.events.time("waiterReturned")))
      await other.waitForRetirement()
    }
    withExtendedLifetime((device, replacement)) {}
  }

  @Test(arguments: [false, true], ["start", "displayCancelReturn"])
  func shutdownWaitJoinsRetirementRatherThanCallerPublication(_ cancelWaiter: Bool, _ blocker: String) async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let replacement = DeviceHIDRetentionTests.makeInertDevice(udid: device.udid)
    let fixture = LiveHIDFixture(held: [blocker, "discard"])
    let command = DeviceHIDCommands(device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport }, prepareLive: { _ in fixture.preparation() })
    let other = DeviceHIDCommands(device: replacement)
    let run = fixture.task("public") {
      try await command.liveTouch(events: LiveSamples(events: [.down(x: 0.25, y: 0.5), .up(x: 0.25, y: 0.5)]))
    }
    try await fixture.withTask(run) {
      try await fixture.events.waitFor("gate.\(blocker)")
      if blocker == "start" { run.cancel() }
      try await fixture.events.waitFor("publicReturned", timeout: 8)
      if blocker == "displayCancelReturn" {
        try await fixture.events.waitFor("completionCallbackReturned")
        #expect(fixture.events.count("displayCancelReturned") == 0)
        #expect(fixture.events.count("release") == 0)
      }
      let waiter = fixture.task("waiter") {
        fixture.events.record("waitEntered")
        await other.waitForRetirement()
      }
      if cancelWaiter { waiter.cancel() }
      try await fixture.events.waitFor("waitEntered")
      fixture.open(blocker)
      try await fixture.events.waitFor("gate.discard")
      #expect(fixture.events.count("waiterReturned") == 0)
      #expect(fixture.events.count("end") == 1)
      fixture.open("discard")
      try await waiter.value
      #expect(try #require(fixture.events.time("discard")) <= #require(fixture.events.time("waiterReturned")))
      await other.waitForRetirement()
      await #expect { try await other.button(.home) } throws: { error in
        if case DeviceHIDError.uncertainState = error { return true }
        return false
      }
    }
    withExtendedLifetime((device, replacement)) {}
  }

  @Test func shutdownRegistrationRacingRetirementDoesNotLoseWaiters() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let replacement = DeviceHIDRetentionTests.makeInertDevice(udid: device.udid)
    let fixture = LiveHIDFixture(held: ["discard"])
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport },
      prepareTouch: { _, _ in DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(), positions: []) })
    let other = DeviceHIDCommands(device: replacement)
    let run = fixture.task("public") { try await command.touch(.tap(x: 1, y: 2)) }
    try await fixture.withTask(run) {
      try await fixture.events.waitFor("gate.discard")
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<32 {
          group.addTask {
            await other.waitForRetirement()
            fixture.events.record("joined")
            #expect(fixture.events.count("discard") == 1)
          }
        }
        group.addTask { fixture.open("discard") }
      }
      try await run.value
      #expect(fixture.events.count("joined") == 32)
      await command.waitForRetirement()
      await other.waitForRetirement()
    }
    withExtendedLifetime((device, replacement)) {}
  }

  @Test func cancellationCaptureRetirementCannotHoldTheCallerOrLoseOwnership() async throws {
    let fixture = LiveHIDFixture()
    let gate = DeviceHIDTestGate()
    fixture.onCancellationRetirement.set {
      fixture.events.record("captureRetiring")
      gate.wait()
    }
    defer {
      gate.open()
      fixture.onCancellationRetirement.set(nil)
    }
    let operation = DeviceHIDOperation(
      transport: fixture.transport, mode: .live(fixture.preparation()),
      clock: { fixture.clock.now() }, retired: { fixture.events.record("nativeRetired") },
      quarantine: { fixture.native.state.sync { $0.quarantined = true } })
    try await fixture.withOperation(operation) { run in
      try await operation.waitUntilReady()
      try await operation.sendLive(.down(x: 0.25, y: 0.5))
      _ = fixture.task("up") { try await operation.sendLive(.up(x: 0.25, y: 0.5)) }
      try await fixture.events.waitFor("captureRetiring")
      fixture.clock.advance(6)
      operation.advance()
      try await fixture.events.waitFor("operationReturned")
      #expect((await run.value).uncertain)
      #expect(fixture.events.count("nativeRetired") == 0)
      #expect(fixture.events.count("displayCancellationRetired") == 0)
      gate.open()
      try await fixture.events.waitFor("nativeRetired")
      #expect(fixture.events.count("displayCancellationRetired") == 1)
    }
  }

  @Test(arguments: [false, true], ["acquisition", "observation", "factory", "displayStartup", "cancellation"])
  func expiredSetupReturnsBeforeItsLateOwnedWork(_ live: Bool, _ stage: String) async throws {
    let native = DeviceHIDFixture(
      block: stage == "observation" ? "observe" : nil,
      lateAcquisition: stage == "acquisition", lateFactory: stage == "factory" || stage == "cancellation")
    let fixture = LiveHIDFixture(
      native: native,
      held: stage == "displayStartup" ? ["displayStartup"] : (stage == "cancellation" ? ["factoryCancelReturn"] : []))
    let operation = DeviceHIDOperation(
      transport: fixture.transport,
      mode: live ? .live(fixture.preparation()) : .bounded(.touch(DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(), positions: []))),
      clock: { fixture.clock.now() }, retired: { fixture.events.record("nativeRetired") },
      quarantine: { native.state.sync { $0.quarantined = true } })
    try await fixture.withOperation(operation) { run in
      let entered: String
      switch stage {
      case "acquisition": entered = "acquisitionPending"
      case "observation": entered = "observe"
      case "displayStartup": entered = "gate.displayStartup"
      default: entered = "factoryPending"
      }
      try await fixture.events.waitFor(entered)
      fixture.clock.advance(11)
      operation.advance()
      if stage == "cancellation" {
        try await fixture.events.waitFor("gate.factoryCancelReturn")
        native.completeFactory()
      }
      fixture.clock.advance(6)
      operation.advance()
      try await fixture.events.waitFor("operationReturned")
      let outcome = await run.value
      #expect(outcome.uncertain)
      #expect(!outcome.inputAdmitted)
      #expect(fixture.events.count("start") == 0)
      #expect(fixture.events.count("release") == 0)
      #expect(fixture.events.count("discard") == 0)
      #expect(fixture.events.count("nativeRetired") == 0)
      fixture.unblock()
      try await fixture.events.waitFor("nativeRetired")
      #expect(fixture.events.count("start") == 0)
      #expect(fixture.events.count("releaseReturned") == 1)
      #expect(fixture.events.count("discard") == 1)
    }
  }

  @Test(arguments: [false, true], [false, true])
  func cleanCancellationPreservesRetrySafetyAndAllowsFreshDeviceReuse(_ live: Bool, _ afterInput: Bool) async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let replacement = DeviceHIDRetentionTests.makeInertDevice(udid: device.udid)
    let native = DeviceHIDFixture(block: afterInput ? "start" : nil, lateFactory: !afterInput)
    let fixture = LiveHIDFixture(native: native)
    let recovery = DeviceHIDFixture()
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport },
      prepareTouch: { _, _ in DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(), positions: []) },
      prepareLive: { _ in fixture.preparation() })
    let other = DeviceHIDCommands(
      device: replacement, checkRuntime: {},
      prepareButton: { _, button, duration in DeviceHIDPreparedButton(deviceIdentifier: recovery.identifier, button: button, duration: duration) },
      makeButtonTransport: { _ in recovery.transport })
    let run = fixture.task("public") {
      if live { try await command.liveTouch(events: LiveSamples(events: [.down(x: 0.25, y: 0.5), .up(x: 0.25, y: 0.5)])) } else { try await command.touch(.tap(x: 1, y: 2)) }
    }
    try await fixture.withTask(run) {
      try await fixture.events.waitFor(afterInput ? "start" : "factoryPending")
      run.cancel()
      fixture.unblock()
      await #expect { try await run.value } throws: { error in
        if afterInput {
          guard case DeviceHIDError.inputMayHaveApplied(let cause) = error else { return false }
          return cause is CancellationError
        }
        return error is CancellationError
      }
      try await other.button(.home)
      #expect(recovery.events.count("start") == 1)
      #expect(native.events.count("end") == (afterInput ? 1 : 0))
    }
    withExtendedLifetime((device, replacement)) {}
  }

  @Test(arguments: ["start", "displayCompletion"])
  func publicLiveCallerReturnsWhileSameUDIDOwnershipRemains(_ stage: String) async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let replacement = DeviceHIDRetentionTests.makeInertDevice(udid: device.udid)
    let fixture = LiveHIDFixture(held: [stage])
    let command = DeviceHIDCommands(device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport }, prepareLive: { _ in fixture.preparation() })
    let other = DeviceHIDCommands(
      device: replacement, checkRuntime: {},
      prepareButton: { _, _, _ in
        Issue.record("A fresh Device escaped retained live ownership")
        throw DeviceHIDError.unexpectedCompletion
      })
    let run = fixture.task("public") {
      try await command.liveTouch(events: LiveSamples(events: [.down(x: 0.25, y: 0.5), .up(x: 0.25, y: 0.5)]))
    }
    try await fixture.withTask(run) {
      try await fixture.events.waitFor("gate.\(stage)")
      if stage == "start" { run.cancel() }
      try await fixture.events.waitFor("publicReturned", timeout: 8)
      await #expect { try await run.value } throws: { error in
        if case DeviceHIDError.liveUncertain = error { return true }
        return false
      }
      #expect(fixture.events.count("transportRetired") == 0)
      #expect(fixture.events.count("release") == 0)
      await #expect { try await other.button(.home) } throws: { error in
        if case DeviceHIDError.uncertainState = error { return true }
        return false
      }
      fixture.unblock()
      try await fixture.events.waitFor("transportRetired")
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(fixture.events.count("releaseReturned") == 1)
    }
    withExtendedLifetime((device, replacement)) {}
  }

  // Regression for the follow-up to published 7a7abeea71a3: caller completion is not native retirement.
  @Test(arguments: [false, true], ["start", "position", "end", "barrier", "displayCompletion", "displayCancelReturn", "release", "discard"])
  func stalledRetirementReturnsWithoutAbandoningNativeOwnership(_ live: Bool, _ stage: String) async throws {
    let fixture = LiveHIDFixture(held: [stage])
    let input = DeviceHIDPreparedTouch(
      start: DeviceHIDFixture.prepared(),
      positions: [DeviceHIDPosition(point: CGPoint(x: 0.4, y: 0.5), delay: 0)])
    let operation = DeviceHIDOperation(
      transport: fixture.transport, mode: live ? .live(fixture.preparation()) : .bounded(.touch(input)),
      clock: { fixture.clock.now() }, quarantine: { fixture.native.state.sync { $0.quarantined = true } })
    try await fixture.withOperation(operation) { run in
      if live {
        _ = fixture.task("samples") {
          try await operation.waitUntilReady()
          try await operation.sendLive(.down(x: 0.25, y: 0.5))
          try await operation.sendLive(.move(x: 0.4, y: 0.5))
          try await operation.sendLive(.up(x: 0.4, y: 0.5))
        }
      }
      try await fixture.events.waitFor("gate.\(stage)")
      if ["start", "position"].contains(stage) { operation.cancel() }
      fixture.clock.advance(6)
      operation.advance()
      try await fixture.events.waitFor("operationReturned")
      let outcome = await run.value
      #expect(outcome.uncertain)
      #expect(fixture.native.state.wrappedValue.quarantined)
      #expect(outcome.uncertaintyCause != nil)
      if ["start", "position", "end", "barrier", "displayCompletion", "displayCancelReturn"].contains(stage) {
        #expect(fixture.events.count("release") == 0)
        #expect(fixture.events.count("discard") == 0)
      }
      if stage == "start" || stage == "position" { #expect(fixture.events.count("end") == 0) }
      #expect(fixture.events.count("transportRetired") == 0)
      fixture.unblock()
      try await fixture.events.waitFor("releaseReturned")
      try await fixture.events.waitFor("discard")
      try await fixture.events.waitFor("displayCancellationRetired")
      #expect(fixture.events.count("start") == 1)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(fixture.events.count("release") == 1)
      #expect(fixture.native.state.wrappedValue.points.last == (stage == "start" ? CGPoint(x: 0.25, y: 0.5) : CGPoint(x: 0.4, y: 0.5)))
      #expect(try #require(fixture.events.time("endReturned")) <= #require(fixture.events.time("barrier")))
      #expect(try #require(fixture.events.time("barrierReturned")) <= #require(fixture.events.time("release")))
      #expect(fixture.events.count("operationReturned") == 1)
    }
  }

  @Test(arguments: [false, true])
  func noncooperativeObserverReturnsUncertaintyWithoutDiscard(_ live: Bool) async throws {
    let fixture = LiveHIDFixture(completeOnCancel: false)
    let operation = DeviceHIDOperation(
      transport: fixture.transport,
      mode: live ? .live(fixture.preparation()) : .bounded(.touch(DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(), positions: []))),
      clock: { fixture.clock.now() }, quarantine: { fixture.native.state.sync { $0.quarantined = true } })
    try await fixture.withOperation(operation) { run in
      if live {
        _ = fixture.task("samples") {
          try await operation.waitUntilReady()
          try await operation.sendLive(.down(x: 0.25, y: 0.5))
          try await operation.sendLive(.up(x: 0.25, y: 0.5))
        }
      }
      try await fixture.events.waitFor("displayCancelReturned")
      fixture.clock.advance(6)
      operation.advance()
      try await fixture.events.waitFor("operationReturned")
      #expect((await run.value).uncertain)
      #expect(fixture.events.count("consumerReturned") == 0)
      #expect(fixture.events.count("release") == 0)
      #expect(fixture.events.count("discard") == 0)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      fixture.finish()
      try await fixture.events.waitFor("displayCancellationRetired")
      await fixture.expectRetired()
    }
  }
}
