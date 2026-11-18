/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
@testable import FBDeviceControl
@testable import FBDeviceHID
import Foundation
import IDBConcurrency
import MobileDeviceAPI
import Testing

@MainActor
@Suite("Physical HID command retention and admission", .serialized)
struct DeviceHIDRetentionTests {
  /// The native reference must remain nil: no MobileDevice call-table entry is populated.
  private nonisolated static func makeInertDevice() -> Device {
    let logger = ControlCoreGlobalConfiguration.defaultLogger
    let mobile = MobileDevice(
      allValues: ["UniqueDeviceID": "inert-hid-retention"],
      calls: CreateZeroedAMDCalls(),
      connectionReuseTimeout: nil,
      serviceReuseTimeout: nil,
      work: .main,
      asyncQueue: .main,
      logger: logger)
    return Device(amDevice: mobile, restorableDevice: nil, logger: logger)
  }

  @Test nonisolated func absentNativeReferenceFailsBeforeCallingTheZeroedTable() async {
    let device = Self.makeInertDevice()
    let entered = Atomic(wrappedValue: false)
    #expect(device.amDeviceRef == nil)
    do {
      try await device.withConnectedDevice(purpose: "inert fixture guard") { _ in
        entered.set(true)
      }
      Issue.record("An inert device opened a native session")
    } catch AMDeviceServiceError.deviceNotConnected(let service) {
      #expect(service == "connect")
    } catch { Issue.record("Unexpected error: \(error)") }
    #expect(!entered.wrappedValue)
  }

  @Test func cachedAccessorDoesNotRetainItsDevice() {
    weak var weakDevice: Device?
    var command: DeviceHIDCommands?
    autoreleasepool {
      let device = Self.makeInertDevice()
      weakDevice = device
      command = device.hid
      #expect(command === device.hid)
    }
    #expect(weakDevice == nil)
    #expect(command != nil)
  }

  @Test func releasedDeviceFailsWithoutRuntimeWork() async {
    var command: DeviceHIDCommands?
    autoreleasepool {
      let device = Self.makeInertDevice()
      command = device.hid
    }
    do {
      try await command?.tap(x: 1, y: 1, duration: nil)
      Issue.record("A released device was accepted")
    } catch DeviceHIDError.deviceUnavailable {
    } catch { Issue.record("Unexpected error: \(error)") }
  }

  @Test func rawInvalidInputDoesNotReachPreparation() async {
    let device = Self.makeInertDevice()
    let prepared = Atomic(wrappedValue: 0)
    let command = DeviceHIDCommands(
      device: device,
      prepare: { _, _, _, _ in
        prepared.sync { $0 += 1 }
        return DeviceHIDFixture.prepared()
      })
    do {
      try await command.tap(x: .nan, y: 1, duration: nil)
      Issue.record("Nonfinite input was accepted")
    } catch DeviceHIDError.preparationFailed {
    } catch { Issue.record("Unexpected error: \(error)") }
    #expect(prepared.wrappedValue == 0)
  }

  @Test func failedPreparationNeverReachesTheRuntimeGate() async {
    let device = Self.makeInertDevice()
    let runtimeChecks = Atomic(wrappedValue: 0)
    let command = DeviceHIDCommands(
      device: device,
      prepare: { _, _, _, _ in throw DeviceHIDError.preparationFailed("test producer failure") },
      checkRuntime: { runtimeChecks.sync { $0 += 1 } })
    do {
      try await command.tap(x: 1, y: 1, duration: nil)
      Issue.record("Preparation failure was ignored")
    } catch DeviceHIDError.preparationFailed {
    } catch { Issue.record("Unexpected error: \(error)") }
    #expect(runtimeChecks.wrappedValue == 0)
  }

  @Test func failedRuntimeGateNeverConstructsTheTransport() async {
    let device = Self.makeInertDevice()
    let constructions = Atomic(wrappedValue: 0)
    let fixture = DeviceHIDFixture()
    let command = DeviceHIDCommands(
      device: device,
      prepare: { _, _, _, duration in DeviceHIDFixture.prepared(duration: duration) },
      checkRuntime: { throw DeviceHIDError.unsupportedRuntime("test mismatch") },
      makeTransport: { _ in
        constructions.sync { $0 += 1 }
        return fixture.transport
      })
    do {
      try await command.tap(x: 1, y: 1, duration: nil)
      Issue.record("Runtime failure was ignored")
    } catch DeviceHIDError.unsupportedRuntime {
    } catch { Issue.record("Unexpected error: \(error)") }
    #expect(constructions.wrappedValue == 0)
    #expect(fixture.events.count("acquire") == 0)
  }

  @Test func cachedCommandRejectsOverlapAndQuarantinesAnUncertainEnd() async throws {
    let device = Self.makeInertDevice()
    let fixture = DeviceHIDFixture(block: "start", fail: "end")
    defer { fixture.gate.open() }
    let command = device.commandCache.resolve {
      DeviceHIDCommands(
        device: device,
        prepare: { _, _, _, duration in DeviceHIDFixture.prepared(duration: duration) },
        checkRuntime: {},
        makeTransport: { _ in fixture.transport })
    }
    #expect(device.hid === command)
    let first = Task { try await command.tap(x: 1, y: 1, duration: nil) }
    try await fixture.events.waitFor("start")
    do {
      try await device.hid.tap(x: 2, y: 2, duration: nil)
      Issue.record("Concurrent input was accepted")
    } catch DeviceHIDError.busy {
    } catch { Issue.record("Unexpected error: \(error)") }
    fixture.gate.open()
    do {
      try await first.value
      Issue.record("A failed end was reported as success")
    } catch DeviceHIDError.nativeFailure {
    } catch { Issue.record("Unexpected error: \(error)") }
    do {
      try await device.hid.tap(x: 3, y: 3, duration: nil)
      Issue.record("An uncertain command accepted another tap")
    } catch DeviceHIDError.uncertainState {
    } catch { Issue.record("Unexpected error: \(error)") }
    #expect(fixture.events.count("acquire") == 1)
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("end") == 1)
  }

  @Test func touchSharesTapAdmissionAndQuarantine() async throws {
    let device = Self.makeInertDevice()
    let fixture = DeviceHIDFixture(block: "position", fail: "end")
    defer { fixture.gate.open() }
    let sequence = try DeviceHIDTouchSequence([.down(x: 1, y: 1), .move(x: 2, y: 2), .up(x: 2, y: 2)])
    let command = DeviceHIDCommands(
      device: device,
      prepare: { _, _, _, duration in DeviceHIDFixture.prepared(duration: duration) },
      checkRuntime: {},
      makeTransport: { _ in fixture.transport },
      prepareTouch: { _, _ in
        DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(), positions: [DeviceHIDPosition(point: CGPoint(x: 0.5, y: 0.5), delay: 0)])
      })
    let task = Task { try await command.touch(sequence) }
    try await fixture.events.waitFor("position")
    for touch in [false, true] {
      do {
        if touch { try await command.touch(sequence) } else { try await command.tap(x: 1, y: 1, duration: nil) }
        Issue.record("Overlapping input was accepted")
      } catch DeviceHIDError.busy {
      } catch { Issue.record("Unexpected error: \(error)") }
    }
    fixture.gate.open()
    await #expect(throws: (any Error).self) { try await task.value }
    for touch in [false, true] {
      do {
        if touch { try await command.touch(sequence) } else { try await command.tap(x: 1, y: 1, duration: nil) }
        Issue.record("Quarantined input was accepted")
      } catch DeviceHIDError.uncertainState {
      } catch { Issue.record("Unexpected error: \(error)") }
    }
    #expect(fixture.events.count("acquire") == 1)
    #expect(fixture.events.count("position") == 1)
    #expect(fixture.events.count("end") == 1)
  }

  @Test(arguments: ["start", "factory"])
  func cancelledNativeWorkKeepsAdmissionUntilRetirement(_ phase: String) async throws {
    let device = Self.makeInertDevice()
    let fixture = DeviceHIDFixture(block: phase == "start" ? "start" : nil, lateFactory: phase == "factory")
    let recovery = DeviceHIDFixture()
    let constructions = Atomic(wrappedValue: 0)
    defer {
      fixture.gate.open()
      fixture.completeFactory()
    }
    let command = DeviceHIDCommands(
      device: device,
      prepare: { _, _, _, duration in DeviceHIDFixture.prepared(duration: duration) },
      checkRuntime: {},
      makeTransport: { _ in
        let first = constructions.sync { count in
          count += 1
          return count == 1
        }
        return first ? fixture.transport : recovery.transport
      })
    let first = Task { try await command.tap(x: 1, y: 1, duration: nil) }
    try await fixture.events.waitFor(phase == "start" ? "start" : "factoryPending")
    first.cancel()
    let formerDrainDeadline = ContinuousClock.now.advanced(by: .milliseconds(5100))
    fixture.events.onDeadline(formerDrainDeadline, signal: "pastFormerDrain") {}
    try await fixture.events.waitFor("pastFormerDrain", timeout: 8)
    #expect(try #require(fixture.events.time("pastFormerDrain")) >= formerDrainDeadline)
    await #expect { try await command.tap(x: 2, y: 2, duration: nil) } throws: { error in
      if case DeviceHIDError.busy = error { return true }
      return false
    }
    #expect(fixture.events.count("release") == 0)
    #expect(fixture.events.count("end") == 0)
    #expect(fixture.events.count("discard") == 0)
    #expect(constructions.wrappedValue == 1)
    fixture.gate.open()
    fixture.completeFactory()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(fixture.events.count("end") == (phase == "start" ? 1 : 0))
    #expect(fixture.events.count("barrier") == (phase == "start" ? 1 : 0))
    #expect(fixture.events.count("releaseReturned") == 1)
    try await command.tap(x: 3, y: 3, duration: nil)
    #expect(recovery.events.count("start") == 1)
    #expect(recovery.events.count("end") == 1)
    withExtendedLifetime(device) {}
  }

  @Test func lateQuarantineRevokesTheNextTapWhileItIsPreparing() async throws {
    let device = Self.makeInertDevice()
    let firstFixture = DeviceHIDFixture(retainAcquisition: true)
    let secondFixture = DeviceHIDFixture()
    let preparationCount = Atomic(wrappedValue: 0)
    let constructions = Atomic(wrappedValue: 0)
    let entered = AsyncStream<Void>.makeStream()
    let resume = AsyncStream<Void>.makeStream()
    let command = device.commandCache.resolve {
      DeviceHIDCommands(
        device: device,
        prepare: { _, _, _, duration in
          let index = preparationCount.sync { count in
            count += 1
            return count
          }
          if index == 2 {
            entered.continuation.yield(())
            for await _ in resume.stream { break }
          }
          return DeviceHIDFixture.prepared(duration: duration)
        },
        checkRuntime: {},
        makeTransport: { _ in
          let index = constructions.sync { count in
            count += 1
            return count
          }
          return index == 1 ? firstFixture.transport : secondFixture.transport
        })
    }
    try await command.tap(x: 1, y: 1, duration: nil)
    let second = Task { try await command.tap(x: 2, y: 2, duration: nil) }
    for await _ in entered.stream { break }
    firstFixture.completeAcquisition()
    resume.continuation.finish()
    entered.continuation.finish()
    do {
      try await second.value
      Issue.record("A pending request survived quarantine")
    } catch DeviceHIDError.uncertainState {
    } catch { Issue.record("Unexpected error: \(error)") }
    #expect(constructions.wrappedValue == 1)
    #expect(firstFixture.events.count("start") == 1)
    #expect(firstFixture.events.count("release") == 1)
    #expect(secondFixture.events.count("acquire") == 0)
    #expect(secondFixture.events.count("start") == 0)
  }
}
