/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
@_implementationOnly import ShimulatorIdleSyncCore
@_implementationOnly import ShimulatorProtocol
import Synchronization
import Testing

private final class ScriptedProbe: IdleSyncProbe, Sendable {
  private struct State {
    var samples: [IdleSyncSample] = []
    var thresholds: [UInt32?] = []
  }

  private let state = Mutex(State())

  var thresholds: [UInt32?] { state.withLock { $0.thresholds } }

  func next(_ reasons: [IdleSyncReason], idleSince: UInt64 = 0, at: UInt64) {
    state.withLock { $0.samples.append(IdleSyncSample(reasons: reasons, idleSince: idleSince, at: at)) }
  }

  func sample() -> IdleSyncSample {
    state.withLock { $0.samples.removeFirst() }
  }

  func setBusyThreshold(milliseconds: UInt32?) {
    state.withLock { $0.thresholds.append(milliseconds) }
  }
}

@Suite("Idle sync controller")
struct IdleSyncControllerTests {
  private func state(_ update: ShimulatorMethodUpdate?) throws -> IdleSyncState {
    let update = try #require(update)
    #expect(update.state == .accepted)
    return try JSONDecoder().decode(IdleSyncState.self, from: #require(update.payload))
  }

  @Test("An idle state carries when the trackers recorded the idle period beginning, and a busy one none")
  func idlePeriods() throws {
    let probe = ScriptedProbe()
    let controller = IdleSyncController(probe: probe)
    let admission = try controller.start(IdleSyncParameters())

    probe.next([.main, .animation], at: 10)
    #expect(try state(controller.poll(admission)) == IdleSyncState(idleSince: nil, reasons: ["main", "animation"]))
    probe.next([], idleSince: 15, at: 20)
    #expect(try state(controller.poll(admission)) == IdleSyncState(idleSince: 15, reasons: []))
    probe.next([.animation], idleSince: 15, at: 40)
    #expect(try state(controller.poll(admission)) == IdleSyncState(idleSince: nil, reasons: ["animation"]))
    probe.next([], idleSince: 45, at: 50)
    #expect(try state(controller.poll(admission)) == IdleSyncState(idleSince: 45, reasons: []), "a new period")
  }

  @Test("An idle period that began before the host connected, or before an earlier host left, is dated from its start")
  func idleBeforeConnecting() throws {
    let probe = ScriptedProbe()
    let controller = IdleSyncController(probe: probe)
    let first = try controller.start(IdleSyncParameters())
    probe.next([], idleSince: 5, at: 20)
    #expect(try state(controller.poll(first)) == IdleSyncState(idleSince: 5, reasons: []))
    controller.stop(first)
    let second = try controller.start(IdleSyncParameters())
    probe.next([], idleSince: 5, at: 90)
    #expect(try state(controller.poll(second)) == IdleSyncState(idleSince: 5, reasons: []))
  }

  @Test("After the busy threshold changes, no idle period is dated before the first report under the new one")
  func thresholdChangeDropsHistory() throws {
    let probe = ScriptedProbe()
    let controller = IdleSyncController(probe: probe)
    let admission = try controller.start(IdleSyncParameters(busyThresholdMs: 2))
    probe.next([], idleSince: 5, at: 20)
    #expect(try state(controller.poll(admission)) == IdleSyncState(idleSince: 20, reasons: []))
    probe.next([], idleSince: 5, at: 30)
    #expect(try state(controller.poll(admission)) == IdleSyncState(idleSince: 20, reasons: []), "still the period from 20")
    probe.next([.main], idleSince: 5, at: 40)
    #expect(try state(controller.poll(admission)) == IdleSyncState(idleSince: nil, reasons: ["main"]))
    probe.next([], idleSince: 45, at: 50)
    #expect(try state(controller.poll(admission)) == IdleSyncState(idleSince: 45, reasons: []), "recorded under the new one")

    // Leaving restores the trackers' own threshold, which the next host's first report starts from too.
    controller.stop(admission)
    let next = try controller.start(IdleSyncParameters())
    probe.next([], idleSince: 45, at: 90)
    #expect(try state(controller.poll(next)) == IdleSyncState(idleSince: 90, reasons: []))
  }

  @Test("An idle period dated after the sample is reported from the sample")
  func idleSinceAhead() throws {
    let probe = ScriptedProbe()
    let controller = IdleSyncController(probe: probe)
    let admission = try controller.start(IdleSyncParameters())
    probe.next([], idleSince: .max, at: 20)
    #expect(try state(controller.poll(admission)) == IdleSyncState(idleSince: 20, reasons: []))
  }

  @Test("Equal states are equal updates, so the client sends each state once")
  func equalStatesAreEqualUpdates() throws {
    let probe = ScriptedProbe()
    let controller = IdleSyncController(probe: probe)
    let admission = try controller.start(IdleSyncParameters())
    probe.next([], idleSince: 15, at: 20)
    probe.next([], idleSince: 15, at: 30)
    #expect(controller.poll(admission) == controller.poll(admission))
  }

  @Test("The host's busy threshold applies while it is connected, and the trackers' own once it leaves")
  func busyThreshold() throws {
    let probe = ScriptedProbe()
    let controller = IdleSyncController(probe: probe)
    controller.stop(try controller.start(IdleSyncParameters(busyThresholdMs: 32)))
    _ = try controller.start(IdleSyncParameters())
    #expect(probe.thresholds == [32, nil, nil])
  }

  @Test("The parameters a host sends decode, including from a host that sets none")
  func parametersWireFormat() throws {
    let none = try ShimulatorRequest<IdleSyncParameters>.decode(Data(#"{"version":1,"parameters":{}}"#.utf8))
    #expect(none.parameters == IdleSyncParameters())
    let threshold = try ShimulatorRequest<IdleSyncParameters>.decode(
      Data(#"{"version":1,"parameters":{"busyThresholdMs":32}}"#.utf8))
    #expect(threshold.parameters == IdleSyncParameters(busyThresholdMs: 32))
  }
}
