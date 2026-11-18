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
  nonisolated static func makeInertDevice(udid: String = UUID().uuidString) -> Device {
    let logger = ControlCoreGlobalConfiguration.defaultLogger
    let mobile = MobileDevice(
      allValues: ["UniqueDeviceID": udid],
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
      try await command?.touch(.tap(x: 1, y: 1, duration: nil))
      Issue.record("A released device was accepted")
    } catch DeviceHIDError.deviceUnavailable {
    } catch { Issue.record("Unexpected error: \(error)") }
  }

  @Test func rawInvalidInputDoesNotReachPreparation() async {
    let device = Self.makeInertDevice()
    let prepared = Atomic(wrappedValue: 0)
    let command = DeviceHIDCommands(
      device: device,
      prepareTouch: { _, _ in
        prepared.sync { $0 += 1 }
        return DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(), positions: [])
      })
    for (x, y, duration) in [
      (Double.nan, 1.0, nil), (1, Double.infinity, nil), (-1, 1, nil),
      (1, 1, -1), (1, 1, Double.nan), (1, 1, Double.infinity),
      (1, 1, 5), (1, 1, 10), (1, 1, Double.greatestFiniteMagnitude),
    ] as [(Double, Double, Double?)] {
      do {
        try await command.touch(.tap(x: x, y: y, duration: duration))
        Issue.record("Invalid tap input was accepted")
      } catch DeviceHIDError.preparationFailed {
      } catch { Issue.record("Unexpected error: \(error)") }
    }
    #expect(prepared.wrappedValue == 0)
  }

  @Test(arguments: [nil, 0.0, 0.15] as [Double?])
  func tapUsesValidatedTouchPreparation(duration: Double?) async throws {
    let device = Self.makeInertDevice()
    let fixture = DeviceHIDFixture()
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport },
      prepareTouch: { _, sequence in
        #expect(sequence.contacts.count == 1)
        #expect(sequence.contacts[0].positions.count == 1)
        #expect(sequence.contacts[0].positions[0].point == CGPoint(x: 100, y: 200))
        #expect(sequence.contacts[0].positions[0].delay == (duration ?? 0))
        #expect(sequence.duration == (duration ?? 0))
        return DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(duration: sequence.duration), positions: [])
      })
    try await command.touch(.tap(x: 100, y: 200, duration: duration))
    #expect(fixture.state.sync { $0.points } == [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.25, y: 0.5)])
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("end") == 1)
    #expect(fixture.events.count("barrier") == 1)
  }

  @Test func failedPreparationNeverReachesTheRuntimeGate() async {
    let device = Self.makeInertDevice()
    let runtimeChecks = Atomic(wrappedValue: 0)
    let command = DeviceHIDCommands(
      device: device,
      checkRuntime: { runtimeChecks.sync { $0 += 1 } },
      prepareTouch: { _, _ in throw DeviceHIDError.preparationFailed("test producer failure") })
    do {
      try await command.touch(.tap(x: 1, y: 1, duration: nil))
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
      checkRuntime: { throw DeviceHIDError.unsupportedRuntime("test mismatch") },
      makeTransport: { _ in
        constructions.sync { $0 += 1 }
        return fixture.transport
      },
      prepareTouch: { _, sequence in
        DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(duration: sequence.duration), positions: [])
      })
    do {
      try await command.touch(.tap(x: 1, y: 1, duration: nil))
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
        checkRuntime: {},
        makeTransport: { _ in fixture.transport },
        prepareTouch: { _, sequence in
          DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(duration: sequence.duration), positions: [])
        })
    }
    #expect(device.hid === command)
    let first = Task { try await command.touch(.tap(x: 1, y: 1, duration: nil)) }
    try await fixture.events.waitFor("start")
    do {
      try await device.hid.touch(.tap(x: 2, y: 2, duration: nil))
      Issue.record("Concurrent input was accepted")
    } catch DeviceHIDError.busy {
    } catch { Issue.record("Unexpected error: \(error)") }
    fixture.gate.open()
    do {
      try await first.value
      Issue.record("A failed end was reported as success")
    } catch DeviceHIDError.liveUncertain(let cause, _) {
      guard case DeviceHIDError.nativeFailure(let operation, _, _, _) = cause else {
        Issue.record("Lost native end failure: \(cause)")
        return
      }
      #expect(operation == "end")
    } catch { Issue.record("Unexpected error: \(error)") }
    do {
      try await device.hid.touch(.tap(x: 3, y: 3, duration: nil))
      Issue.record("An uncertain command accepted another tap")
    } catch DeviceHIDError.uncertainState {
    } catch { Issue.record("Unexpected error: \(error)") }
    #expect(fixture.events.count("acquire") == 1)
    #expect(fixture.events.count("start") == 1)
    #expect(fixture.events.count("end") == 1)
  }

  @Test func buttonUsesTheSameAdmissionAndQuarantine() async throws {
    let device = Self.makeInertDevice()
    let fixture = DeviceHIDFixture(block: "start", fail: "end")
    defer { fixture.gate.open() }
    let unexpectedPreparations = Atomic(wrappedValue: 0)
    let command = DeviceHIDCommands(
      device: device,
      checkRuntime: {},
      makeTransport: { _ in
        Issue.record("Rejected touch input constructed a transport")
        return fixture.transport
      },
      prepareTouch: { _, _ in
        unexpectedPreparations.sync { $0 += 1 }
        throw DeviceHIDError.preparationFailed("Touch preparation must not run during rejection")
      },
      prepareButton: { _, button, duration in
        DeviceHIDPreparedButton(deviceIdentifier: UUID(), button: button, duration: duration)
      },
      makeButtonTransport: { _ in fixture.transport })
    let sequence = try DeviceHIDTouchSequence([.down(x: 1, y: 1), .up(x: 1, y: 1)])
    let task = Task { try await command.button(.home) }
    try await fixture.events.waitFor("start")
    for kind in 0...2 {
      do {
        switch kind {
        case 0: try await command.button(.volumeUp)
        case 1: try await command.touch(.tap(x: 1, y: 1, duration: nil))
        default: try await command.touch(sequence)
        }
        Issue.record("Overlapping input accepted")
      } catch DeviceHIDError.busy {
      } catch { Issue.record("Unexpected error: \(error)") }
    }
    fixture.gate.open()
    await #expect(throws: (any Error).self) { try await task.value }
    for kind in 0...2 {
      do {
        switch kind {
        case 0: try await command.button(.volumeDown)
        case 1: try await command.touch(.tap(x: 1, y: 1, duration: nil))
        default: try await command.touch(sequence)
        }
        Issue.record("Quarantined input accepted")
      } catch DeviceHIDError.uncertainState {
      } catch { Issue.record("Unexpected error: \(error)") }
    }
    #expect(unexpectedPreparations.wrappedValue == 0)
    #expect(fixture.state.sync { $0.buttons } == [.home, .home])
    #expect(fixture.events.count("acquire") == 1)
  }

  @Test func buttonCannotConstructPrivateTransportBeforePreflight() async {
    let device = Self.makeInertDevice()
    let constructions = Atomic(wrappedValue: 0)
    let command = DeviceHIDCommands(
      device: device,
      checkRuntime: { throw DeviceHIDError.unsupportedRuntime("test mismatch") },
      prepareButton: { _, button, duration in
        DeviceHIDPreparedButton(deviceIdentifier: UUID(), button: button, duration: duration)
      },
      makeButtonTransport: { _ in
        constructions.sync { $0 += 1 }
        return DeviceHIDFixture().transport
      })
    do {
      try await command.button(.home)
      Issue.record("Failed runtime preflight was ignored")
    } catch DeviceHIDError.unsupportedRuntime {
    } catch { Issue.record("Unexpected error: \(error)") }
    #expect(constructions.wrappedValue == 0)
  }

  @Test func touchSharesTapAdmissionAndQuarantine() async throws {
    let device = Self.makeInertDevice()
    let fixture = DeviceHIDFixture(block: "position", fail: "end")
    defer { fixture.gate.open() }
    let sequence = try DeviceHIDTouchSequence([.down(x: 1, y: 1), .move(x: 2, y: 2), .up(x: 2, y: 2)])
    let command = DeviceHIDCommands(
      device: device,
      checkRuntime: {},
      makeTransport: { _ in fixture.transport },
      prepareTouch: { _, _ in
        DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(), positions: [DeviceHIDPosition(point: CGPoint(x: 0.5, y: 0.5), delay: 0)])
      })
    let task = Task { try await command.touch(sequence) }
    try await fixture.events.waitFor("position")
    for touch in [false, true] {
      do {
        if touch { try await command.touch(sequence) } else { try await command.touch(.tap(x: 1, y: 1, duration: nil)) }
        Issue.record("Overlapping input was accepted")
      } catch DeviceHIDError.busy {
      } catch { Issue.record("Unexpected error: \(error)") }
    }
    fixture.gate.open()
    await #expect(throws: (any Error).self) { try await task.value }
    for touch in [false, true] {
      do {
        if touch { try await command.touch(sequence) } else { try await command.touch(.tap(x: 1, y: 1, duration: nil)) }
        Issue.record("Quarantined input was accepted")
      } catch DeviceHIDError.uncertainState {
      } catch { Issue.record("Unexpected error: \(error)") }
    }
    #expect(fixture.events.count("acquire") == 1)
    #expect(fixture.events.count("position") == 1)
    #expect(fixture.events.count("end") == 1)
  }

  @Test(arguments: ["start", "factory"])
  func stalledNativeWorkReturnsButKeepsAdmissionAndQuarantine(_ phase: String) async throws {
    let device = Self.makeInertDevice()
    let replacement = Self.makeInertDevice(udid: device.udid)
    let fixture = DeviceHIDFixture(block: phase == "start" ? "start" : nil, lateFactory: phase == "factory")
    defer {
      fixture.gate.open()
      fixture.completeFactory()
    }
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport },
      prepareTouch: { _, _ in DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(), positions: []) })
    let other = DeviceHIDCommands(
      device: replacement, checkRuntime: {},
      prepareButton: { _, _, _ in
        Issue.record("A replacement Device bypassed retained ownership")
        throw DeviceHIDError.unexpectedCompletion
      })
    let first = Task {
      defer { fixture.events.record("callerReturned") }
      try await command.touch(.tap(x: 1, y: 1, duration: nil))
    }
    try await fixture.events.waitFor(phase == "start" ? "start" : "factoryPending")
    await #expect { try await other.button(.home) } throws: { error in
      if case DeviceHIDError.busy = error { return true }
      return false
    }
    first.cancel()
    try await fixture.events.waitFor("callerReturned", timeout: 8)
    await #expect { try await first.value } throws: { error in
      guard case DeviceHIDError.liveUncertain(let cause, let uncertainty) = error,
        case DeviceHIDError.deadlineExceeded? = uncertainty as? DeviceHIDError
      else { return false }
      return cause is CancellationError
    }
    for candidate in [command, other, DeviceHIDCommands(device: replacement)] {
      await #expect { try await candidate.button(.home) } throws: { error in
        if case DeviceHIDError.uncertainState = error { return true }
        return false
      }
    }
    #expect(fixture.events.count("release") == 0)
    #expect(fixture.events.count("end") == 0)
    #expect(fixture.events.count("discard") == 0)
    #expect(fixture.events.count("transportRetired") == 0)
    fixture.gate.open()
    fixture.completeFactory()
    try await fixture.events.waitFor("transportRetired")
    #expect(fixture.events.count("end") == (phase == "start" ? 1 : 0))
    #expect(fixture.events.count("barrier") == (phase == "start" ? 1 : 0))
    #expect(fixture.events.count("releaseReturned") == 1)
    await #expect { try await other.button(.home) } throws: { error in
      if case DeviceHIDError.uncertainState = error { return true }
      return false
    }
    withExtendedLifetime((device, replacement)) {}
  }

  @Test(arguments: [false, true])
  func lateQuarantineRevokesTheNextInputWhileItIsPreparing(_ button: Bool) async throws {
    let device = Self.makeInertDevice()
    let firstFixture = DeviceHIDFixture(retainAcquisition: true)
    let secondFixture = DeviceHIDFixture()
    let preparationCount = Atomic(wrappedValue: 0)
    let constructions = Atomic(wrappedValue: 0)
    let buttonConstructions = Atomic(wrappedValue: 0)
    let entered = AsyncStream<Void>.makeStream()
    let resume = AsyncStream<Void>.makeStream()
    let prepare: @Sendable (TimeInterval?) async -> DeviceHIDPreparedTap = { duration in
      let index = preparationCount.sync { count in
        count += 1
        return count
      }
      if index == 2 {
        entered.continuation.yield(())
        for await _ in resume.stream { break }
      }
      return DeviceHIDFixture.prepared(duration: duration)
    }
    let command = device.commandCache.resolve {
      DeviceHIDCommands(
        device: device,
        checkRuntime: {},
        makeTransport: { _ in
          let index = constructions.sync { count in
            count += 1
            return count
          }
          return index == 1 ? firstFixture.transport : secondFixture.transport
        },
        prepareTouch: { _, sequence in
          DeviceHIDPreparedTouch(start: await prepare(sequence.duration), positions: [])
        },
        prepareButton: { _, button, duration in
          let prepared = await prepare(duration)
          return DeviceHIDPreparedButton(deviceIdentifier: prepared.deviceIdentifier, button: button, duration: duration)
        },
        makeButtonTransport: { _ in
          buttonConstructions.sync { $0 += 1 }
          return secondFixture.transport
        })
    }
    try await command.touch(.tap(x: 1, y: 1, duration: nil))
    let second = Task {
      if button { try await command.button(.home) } else { try await command.touch(.tap(x: 2, y: 2, duration: nil)) }
    }
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
    #expect(buttonConstructions.wrappedValue == 0)
    #expect(firstFixture.events.count("start") == 1)
    #expect(firstFixture.events.count("release") == 1)
    #expect(secondFixture.events.count("acquire") == 0)
    #expect(secondFixture.events.count("start") == 0)
  }
}
