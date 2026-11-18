/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Dispatch
@testable import FBDeviceControl
@testable import FBDeviceHID
import Foundation
import IDBConcurrency
import Testing

// MARK: - Existing bounded-input test adapters

extension DeviceHIDFixture {
  static var displaySnapshot: DeviceHIDDisplaySnapshot {
    DeviceHIDDisplaySnapshot(
      displays: [
        .init(
          identifier: 1, primary: true, integrated: true,
          bounds: CGRect(x: 0, y: 0, width: 1000, height: 2000),
          nativeSize: CGSize(width: 1000, height: 2000), pointScale: 2,
          nativeOrientation: "rot0", currentOrientation: "rot0")
      ],
      orientation: .portrait, nonFlatOrientation: .portrait)
  }
}

extension DeviceHIDTransport {
  convenience init(
    acquire: @escaping @Sendable (@escaping @Sendable (Result<DeviceHIDAssertion, any Error>) -> Void) throws -> DeviceHIDCancellation,
    makeCapability: @escaping @Sendable (@escaping @Sendable (Result<Void, any Error>) -> Void) throws -> DeviceHIDCancellation,
    send: @escaping @Sendable (DeviceHIDContactPhase, DeviceHIDContact) throws -> Void,
    barrier: @escaping @Sendable () throws -> Void,
    discard: @escaping @Sendable () -> Void
  ) {
    self.init(
      acquire: acquire, makeCapability: makeCapability,
      observeDisplays: { receive, completion in
        receive(DeviceHIDFixture.displaySnapshot)
        return { completion(.success(())) }
      },
      send: send, barrier: barrier, discard: discard)
  }
}

// MARK: - Independently controlled display producer

private final class DeviceHIDDisplayFixture: Sendable {
  private struct State {
    var receive: (@Sendable (DeviceHIDDisplaySnapshot) -> Void)?
    var completion: (@Sendable (Result<Void, any Error>) -> Void)?
    var finished = false
  }

  let native: DeviceHIDFixture
  let startupGate = DeviceHIDTestGate()
  let cancellationGate = DeviceHIDTestGate()
  private let state = Atomic(wrappedValue: State())
  private let initial: DeviceHIDDisplaySnapshot?
  private let blockStartup: Bool
  private let blockCancellation: Bool
  private let completeOnCancel: Bool
  private let cancellationResult: Result<Void, any Error>

  var events: DeviceHIDTestRecorder { native.events }

  init(
    native: DeviceHIDFixture = DeviceHIDFixture(),
    initial: DeviceHIDDisplaySnapshot? = DeviceHIDFixture.displaySnapshot,
    blockStartup: Bool = false, blockCancellation: Bool = false,
    completeOnCancel: Bool = true, cancellationResult: Result<Void, any Error> = .success(())
  ) {
    self.native = native
    self.initial = initial
    self.blockStartup = blockStartup
    self.blockCancellation = blockCancellation
    self.completeOnCancel = completeOnCancel
    self.cancellationResult = cancellationResult
  }

  var transport: DeviceHIDTransport {
    let base = native.transport
    return DeviceHIDTransport(
      acquire: base.acquire, makeCapability: base.makeCapability,
      observeDisplays: { receive, completion in
        let closed = self.state.sync { state in
          guard !state.finished else { return true }
          state.receive = receive
          state.completion = completion
          return false
        }
        self.events.record("displayStarted")
        if closed {
          completion(.success(()))
        } else if let initial = self.initial {
          self.emit(initial)
        }
        if self.blockStartup { self.startupGate.wait() }
        self.events.record("displayStartupReturned")
        return {
          self.events.record("displayCancel")
          if self.completeOnCancel { self.finish(self.cancellationResult) }
          if self.blockCancellation { self.cancellationGate.wait() }
          self.events.record("displayCancelReturned")
        }
      },
      send: base.send, barrier: base.barrier, discard: base.discard)
  }

  func emit(_ frame: DeviceHIDDisplaySnapshot) {
    state.sync { $0.receive }?(frame)
    events.record("displayFrameReturned")
  }

  func race(_ actions: [@Sendable () -> Void]) async throws {
    let gate = DeviceHIDTestGate()
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "device-hid-display-test.callbacks", attributes: .concurrent)
    for (index, action) in actions.enumerated() {
      group.enter()
      queue.async {
        self.events.record("callbackReady\(index)")
        gate.wait()
        action()
        self.events.record("callbackReturned\(index)")
        group.leave()
      }
    }
    let result: Result<Void, any Error>
    do {
      for index in actions.indices { try await events.waitFor("callbackReady\(index)") }
      result = .success(())
    } catch {
      result = .failure(error)
    }
    gate.open()
    await withCheckedContinuation { continuation in
      group.notify(queue: .global()) { continuation.resume() }
    }
    try result.get()
  }

  func finish(_ result: Result<Void, any Error> = .success(())) {
    let retired = state.sync { state in
      let retired = (state.receive, state.completion)
      state.finished = true
      state.receive = nil
      state.completion = nil
      return retired
    }
    if let completion = retired.1 {
      events.record("displayCompleting")
      completion(result)
      events.record("displayCompletionReturned")
    }
    withExtendedLifetime(retired) {}
  }

  func unblock() {
    startupGate.open()
    cancellationGate.open()
    native.gate.open()
    finish()
  }

  func operation(
    snapshot: DeviceHIDDisplaySnapshot = DeviceHIDFixture.displaySnapshot,
    duration: TimeInterval = 0, secondPoint: CGPoint? = nil,
    positions: [DeviceHIDPosition] = [], pause: TimeInterval = 0, subsequent: [DeviceHIDContactPlan] = [],
    operationSeconds: TimeInterval = 10, timerQueue: DispatchQueue = .global()
  ) -> DeviceHIDOperation {
    let prepared = DeviceHIDPreparedTap(
      deviceIdentifier: UUID(), point: CGPoint(x: 0.25, y: 0.5), duration: duration,
      secondPoint: secondPoint, displaySnapshot: snapshot)
    return DeviceHIDOperation(
      transport: transport,
      input: .touch(DeviceHIDPreparedTouch(start: prepared, positions: positions, pause: pause, subsequent: subsequent)),
      operationSeconds: operationSeconds, cleanupReserve: 0, timerQueue: timerQueue,
      quarantine: { self.native.state.sync { $0.quarantined = true } })
  }

  func withOperation(
    _ operation: DeviceHIDOperation,
    _ body: (Task<DeviceHIDOutcome, Never>) async throws -> Void
  ) async throws {
    let task = Task {
      let outcome = await operation.run()
      self.events.record("callerFinished")
      return outcome
    }
    let result: Result<Void, any Error>
    do {
      try await body(task)
      result = .success(())
    } catch {
      result = .failure(error)
    }
    operation.cancel()
    unblock()
    _ = await task.value
    try result.get()
  }
}

@Suite("Bounded physical HID display monitoring")
struct DeviceHIDDisplayTests {
  @Test(arguments: ["primary", "integrated", "bounds", "nativeSize", "pointScale", "nativeOrientation", "currentOrientation"])
  func mismatchDiagnosticNamesTheFirstFieldAndBothValues(_ field: String) throws {
    var prepared = DeviceHIDFixture.displaySnapshot
    var secondary = prepared.displays[0]
    secondary.identifier = 3
    secondary.primary = false
    secondary.pointScale = 1
    prepared.displays.append(secondary)
    var observed = prepared
    let detail: String
    switch field {
    case "primary":
      observed.displays[0].primary = false
      observed.displays[1].primary = true
      detail = "display 1 primary expected=true, observed=false"
    case "integrated":
      observed.displays[1].integrated = false
      detail = "display 3 integrated expected=true, observed=false"
    case "bounds":
      observed.displays[1].bounds.size.width = 1001
      detail = "display 3 bounds expected=(x=0.0,y=0.0,width=1000.0,height=2000.0), observed=(x=0.0,y=0.0,width=1001.0,height=2000.0)"
    case "nativeSize":
      observed.displays[1].nativeSize.width = 1001
      detail = "display 3 nativeSize expected=(width=1000.0,height=2000.0), observed=(width=1001.0,height=2000.0)"
    case "pointScale":
      observed.displays[1].pointScale = 2
      observed.displays[1].currentOrientation = "rot90"
      detail = "display 3 pointScale expected=1.0, observed=2.0"
    case "nativeOrientation":
      observed.displays[1].nativeOrientation = "rot90"
      detail = "display 3 nativeOrientation expected=rot0, observed=rot90"
    default:
      observed.displays[1].currentOrientation = "rot180"
      detail = "display 3 currentOrientation expected=rot0, observed=rot180"
    }
    observed.displays.reverse()
    do {
      try observed.validate(against: prepared)
      Issue.record("Unequal display inventory was accepted")
    } catch DeviceHIDError.preparationFailed(let message) {
      #expect(message == "The selected-device display basis changed after touch preparation: \(detail)")
    }
  }

  @Test func inventoryDiagnosticReportsMissingAndAddedDisplayIDs() throws {
    var prepared = DeviceHIDFixture.displaySnapshot
    var secondary = prepared.displays[0]
    secondary.identifier = 3
    secondary.primary = false
    prepared.displays.append(secondary)
    var observed = prepared
    observed.displays[1].identifier = 4
    do {
      try observed.validate(against: prepared)
      Issue.record("Changed display identity was accepted")
    } catch DeviceHIDError.preparationFailed(let message) {
      #expect(message.contains("inventory expected.count=2, observed.count=2, missing=[3] (count=1), added=[4] (count=1)"))
    }
  }

  @Test func inventoryDiagnosticIsBounded() throws {
    var prepared = DeviceHIDFixture.displaySnapshot
    let primary = prepared.displays[0]
    prepared.displays += (2...64).map { identifier in
      var display = primary
      display.identifier = UInt32(identifier)
      display.primary = false
      return display
    }
    do {
      try DeviceHIDFixture.displaySnapshot.validate(against: prepared)
      Issue.record("Missing displays were accepted")
    } catch DeviceHIDError.preparationFailed(let message) {
      #expect(message.contains("missing=[2,3,4,5,6,7,8,9,...] (count=63)"))
      #expect(message.utf8.count < 256)
    }
  }

  @Test func mismatchDiagnosticDoesNotExposeUnknownRotationText() throws {
    var prepared = DeviceHIDFixture.displaySnapshot
    var secondary = prepared.displays[0]
    secondary.identifier = 3
    secondary.primary = false
    prepared.displays.append(secondary)
    var observed = prepared
    let unknown = String(repeating: "private-token\n", count: 100)
    observed.displays[1].currentOrientation = unknown
    do {
      try observed.validate(against: prepared)
      Issue.record("Unknown changed rotation was accepted")
    } catch DeviceHIDError.preparationFailed(let message) {
      #expect(message.contains("display 3 currentOrientation expected=rot0, observed=<unrecognized rotation; \(unknown.utf8.count) bytes>"))
      #expect(!message.contains("private-token"))
      #expect(!message.contains("\n"))
      #expect(message.utf8.count < 256)
    }
  }

  @Test func preparationRetainsTheCompleteBasisUsedForNormalization() throws {
    let details = Data(
      #"{"info":{"arguments":["--device","test-phone"],"commandType":"devicectl.device.info.details","jsonVersion":5,"outcome":"success","version":"651.13.5"},"result":{"identifier":"00000000-0000-0000-0000-000000000001","properties":{"hardware":{"udid":"test-phone","reality":"physical","deviceType":"iPhone","platform":"iOS"}}}}"#.utf8)
    let displays = Data(
      #"{"info":{"arguments":["--device","test-phone"],"commandType":"devicectl.device.info.displays","jsonVersion":5,"outcome":"success","version":"651.13.5"},"result":{"displays":[{"displayId":1,"primary":true,"type":{"integrated":{}},"bounds":[[0,0],[1000,2000]],"nativeSize":[1000,2000],"pointScale":2,"nativeOrientation":"rot0","currentOrientation":"rot0"},{"displayId":2,"primary":false,"type":{"external":{}},"bounds":[[10,20],[600,800]],"nativeSize":[600,800],"pointScale":1.5,"nativeOrientation":"rot90","currentOrientation":"rot180"}],"orientation":{"currentDeviceOrientation":"faceUp","currentDeviceNonFlatOrientation":"portrait"}}}"#.utf8)
    let prepared = try DeviceHIDPreparation.decodeTouch(
      details: details, displays: displays, udid: "test-phone", sequence: .tap(x: 125, y: 500))
    #expect(prepared.start.point == CGPoint(x: 0.25, y: 0.5))
    var observed = DeviceHIDFixture.displaySnapshot
    observed.displays.append(
      .init(
        identifier: 2, primary: false, integrated: false,
        bounds: CGRect(x: 10, y: 20, width: 600, height: 800), nativeSize: CGSize(width: 600, height: 800),
        pointScale: 1.5, nativeOrientation: "rot90", currentOrientation: "rot180"))
    try observed.validate(against: prepared.start.displaySnapshot)
    observed.displays[1].pointScale = 2
    #expect(throws: DeviceHIDError.self) { try observed.validate(against: prepared.start.displaySnapshot) }
  }

  @Test(arguments: ["id", "scale", "size", "origin", "native-size", "primary", "integrated", "display-rotation", "native-rotation", "inventory"])
  func firstObservedBasisMustMatchPreparedGeometry(_ field: String) async throws {
    let fixture = DeviceHIDDisplayFixture(initial: changed(field))
    try await fixture.withOperation(fixture.operation()) { task in
      let outcome = await task.value
      guard case .preparationFailed? = outcome.error as? DeviceHIDError else {
        Issue.record("A first-frame mismatch before input lost its preparation classification")
        return
      }
      #expect(!outcome.uncertain)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      #expect(fixture.events.count("end") == 0)
      #expect(fixture.events.count("barrier") == 0)
      #expect(fixture.events.count("displayCancel") == 1)
      #expect(fixture.events.count("releaseReturned") == 1)
      #expect(fixture.events.count("discard") == 1)
    }
  }

  @Test(arguments: ["empty", "duplicate", "too-many", "zero-id", "zero-scale", "nan-scale", "fractional-size", "orientation", "non-flat", "missing-orientation", "missing-non-flat"])
  func invalidObservedMetadataFailsClosed(_ field: String) throws {
    var frame = DeviceHIDFixture.displaySnapshot
    switch field {
    case "empty": frame.displays = []
    case "duplicate": frame.displays.append(frame.displays[0])
    case "too-many":
      let display = frame.displays[0]
      frame.displays = (1...65).map { id in
        var next = display
        next.identifier = UInt32(id)
        next.primary = id == 1
        return next
      }
    case "zero-id": frame.displays[0].identifier = 0
    case "zero-scale": frame.displays[0].pointScale = 0
    case "nan-scale": frame.displays[0].pointScale = .nan
    case "fractional-size":
      frame.displays[0].bounds.size.width = 1000.5
      frame.displays[0].nativeSize.width = 1000.5
    case "orientation": frame.orientation = .unsupported
    case "non-flat": frame.nonFlatOrientation = .unsupported
    case "missing-orientation": frame.orientation = nil
    case "missing-non-flat": frame.nonFlatOrientation = nil
    default: Issue.record("Unknown metadata mutation")
    }
    #expect(throws: DeviceHIDError.self) { try frame.primaryDisplay() }
    #expect(throws: DeviceHIDError.self) { try frame.validate(against: DeviceHIDFixture.displaySnapshot) }
  }

  @Test func duplicatePostureAndDisplayOrderChangesKeepThePreparedBasis() async throws {
    var prepared = DeviceHIDFixture.displaySnapshot
    var secondary = prepared.displays[0]
    secondary.identifier = 2
    secondary.primary = false
    secondary.integrated = false
    prepared.displays.append(secondary)
    let native = DeviceHIDFixture(block: "start")
    let fixture = DeviceHIDDisplayFixture(native: native, initial: prepared)
    let baseline = prepared
    try await fixture.withOperation(fixture.operation(snapshot: baseline)) { task in
      try await fixture.events.waitFor("start")
      fixture.emit(baseline)
      var flat = baseline
      flat.orientation = .faceUp
      flat.displays.reverse()
      fixture.emit(flat)
      fixture.emit(baseline)
      native.gate.open()
      let outcome = await task.value
      #expect(outcome.error == nil)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("start") == 1)
      #expect(fixture.events.count("end") == 1)
      #expect(native.state.wrappedValue.points == [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.25, y: 0.5)])
    }
  }

  @Test func factoryWaitsForAMatchingFrameAndObserverStartupReturn() async throws {
    let fixture = DeviceHIDDisplayFixture(initial: nil, blockStartup: true)
    try await fixture.withOperation(fixture.operation()) { task in
      try await fixture.events.waitFor("displayStarted")
      #expect(fixture.events.count("factory") == 0)
      fixture.emit(DeviceHIDFixture.displaySnapshot)
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      fixture.startupGate.open()
      #expect((await task.value).error == nil)
      #expect(try #require(fixture.events.time("observeReturned")) <= #require(fixture.events.time("displayStarted")))
      #expect(try #require(fixture.events.time("displayStartupReturned")) <= #require(fixture.events.time("factory")))
    }
  }

  @Test func changeAwayAndBackWhileFactoryIsBlockedCannotReopenDown() async throws {
    let native = DeviceHIDFixture(block: "factory")
    let fixture = DeviceHIDDisplayFixture(native: native)
    try await fixture.withOperation(fixture.operation()) { task in
      try await fixture.events.waitFor("factory")
      fixture.emit(changed("scale"))
      fixture.emit(DeviceHIDFixture.displaySnapshot)
      native.gate.open()
      let outcome = await task.value
      #expect(outcome.error != nil)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("start") == 0)
      #expect(fixture.events.count("end") == 0)
      #expect(fixture.events.count("releaseReturned") == 1)
    }
  }

  @Test func absentFirstFrameUsesTheOperationDeadlineAndJoins() async throws {
    let fixture = DeviceHIDDisplayFixture(initial: nil, completeOnCancel: false)
    try await fixture.withOperation(fixture.operation(operationSeconds: 1)) { task in
      try await fixture.events.waitFor("displayCancel")
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      #expect(fixture.events.count("release") == 0)
      #expect(fixture.events.count("callerFinished") == 0)
      fixture.finish()
      let outcome = await task.value
      guard case .deadlineExceeded? = outcome.error as? DeviceHIDError else {
        Issue.record("Silent display startup lost the execution deadline")
        return
      }
      #expect(!outcome.uncertain)
    }
  }

  @Test func lateMatchingFirstFrameCannotBeatAStarvedTimer() async throws {
    let timers = DispatchQueue(label: "device-hid-display-test.timers")
    timers.suspend()
    defer { timers.resume() }
    let fixture = DeviceHIDDisplayFixture(initial: nil)
    try await fixture.withOperation(fixture.operation(operationSeconds: 1, timerQueue: timers)) { task in
      try await fixture.events.waitFor("displayStarted")
      let started = try #require(fixture.events.time("displayStarted"))
      fixture.events.onDeadline(started.advanced(by: .milliseconds(1200)), signal: "lateFirstFrame") {
        fixture.emit(DeviceHIDFixture.displaySnapshot)
      }
      let outcome = await task.value
      guard case .deadlineExceeded? = outcome.error as? DeviceHIDError else {
        Issue.record("A first frame after the deadline admitted input")
        return
      }
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      #expect(fixture.events.count("releaseReturned") == 1)
    }
  }

  @Test func cancellationDuringStartupJoinsTheLateCancellationHandle() async throws {
    let fixture = DeviceHIDDisplayFixture(initial: nil, blockStartup: true)
    let operation = fixture.operation()
    try await fixture.withOperation(operation) { task in
      try await fixture.events.waitFor("displayStarted")
      operation.cancel()
      fixture.emit(DeviceHIDFixture.displaySnapshot)
      #expect(fixture.events.count("release") == 0)
      #expect(fixture.events.count("callerFinished") == 0)
      fixture.startupGate.open()
      let outcome = await task.value
      #expect(outcome.error is CancellationError)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("displayCancel") == 1)
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      #expect(fixture.events.count("releaseReturned") == 1)
    }
  }

  @Test(arguments: [false, true])
  func unsolicitedStreamCompletionFailsBeforeInput(_ failed: Bool) async throws {
    let fixture = DeviceHIDDisplayFixture(initial: nil)
    try await fixture.withOperation(fixture.operation()) { task in
      try await fixture.events.waitFor("displayStarted")
      fixture.finish(failed ? .failure(DeviceHIDTestError.nativeFailure) : .success(()))
      let outcome = await task.value
      #expect(outcome.error != nil)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("start") == 0)
      #expect(fixture.events.count("releaseReturned") == 1)
    }
  }

  @Test func throwingObserverStartupCannotReachTheFactory() async throws {
    let fixture = DeviceHIDDisplayFixture()
    let base = fixture.native.transport
    let transport = DeviceHIDTransport(
      acquire: base.acquire, makeCapability: base.makeCapability,
      observeDisplays: { _, _ in throw DeviceHIDTestError.nativeFailure },
      send: base.send, barrier: base.barrier, discard: base.discard)
    let operation = DeviceHIDOperation(transport: transport, prepared: DeviceHIDFixture.prepared(), quarantine: {})
    try await fixture.withOperation(operation) { task in
      let outcome = await task.value
      #expect(outcome.error != nil)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      #expect(fixture.events.count("releaseReturned") == 1)
    }
  }

  @Test(arguments: ["start", "end", "barrier"], [false, true])
  func unsolicitedCompletionAfterDownStopsAndDrainsWithoutQuarantine(_ phase: String, _ failed: Bool) async throws {
    let native = DeviceHIDFixture(block: phase)
    let fixture = DeviceHIDDisplayFixture(native: native)
    try await fixture.withOperation(fixture.operation()) { task in
      try await fixture.events.waitFor(phase)
      fixture.finish(failed ? .failure(DeviceHIDTestError.nativeFailure) : .success(()))
      #expect(!native.state.wrappedValue.quarantined)
      #expect(fixture.events.count("release") == 0)
      native.gate.open()
      let outcome = await task.value
      guard case .displayObservationFailed(let reason)? = outcome.error as? DeviceHIDError else {
        Issue.record("Post-input stream termination was not classified as an observation failure")
        return
      }
      #expect(!reason.isEmpty)
      if !failed { #expect(reason.contains("display stream ended")) }
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("start") == 1)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(fixture.events.count("releaseReturned") == 1)
    }
  }

  @Test func observerCleanupFailurePreservesCallerCancellation() async throws {
    let native = DeviceHIDFixture(block: "start")
    let fixture = DeviceHIDDisplayFixture(native: native, cancellationResult: .failure(DeviceHIDTestError.nativeFailure))
    let operation = fixture.operation()
    try await fixture.withOperation(operation) { task in
      try await fixture.events.waitFor("start")
      operation.cancel()
      try await fixture.events.waitFor("displayCompletionReturned")
      native.gate.open()
      let outcome = await task.value
      let error = try #require(outcome.error as? DeviceHIDError)
      guard case .cleanupFailed(let cause, let failures) = error else {
        Issue.record("Observer cleanup replaced the primary cancellation")
        return
      }
      #expect(cause is CancellationError)
      #expect(failures.count == 1)
      #expect(!outcome.uncertain)
      #expect(!native.state.wrappedValue.quarantined)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(fixture.events.count("releaseReturned") == 1)
    }
  }

  @Test(arguments: [false, true])
  func ownedShutdownCompletionDoesNotTurnSuccessIntoFailure(_ cancelled: Bool) async throws {
    let fixture = DeviceHIDDisplayFixture(cancellationResult: cancelled ? .failure(CancellationError()) : .success(()))
    try await fixture.withOperation(fixture.operation()) { task in
      let outcome = await task.value
      #expect(outcome.error == nil)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("displayCancel") == 1)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      let drained = try #require(fixture.events.time("barrierReturned"))
      let cancelledAt = try #require(fixture.events.time("displayCancel"))
      #expect(drained <= cancelledAt)
    }
  }

  @Test(arguments: ["start", "position"])
  func geometryFailureDuringBlockedSendKeepsTheLastAdmittedPinchPoints(_ phase: String) async throws {
    let native = DeviceHIDFixture(block: phase)
    let fixture = DeviceHIDDisplayFixture(native: native)
    let second = CGPoint(x: 0.75, y: 0.5)
    let moved = CGPoint(x: 0.3, y: 0.6)
    let movedSecond = CGPoint(x: 0.7, y: 0.6)
    let operation = fixture.operation(
      secondPoint: second, positions: [DeviceHIDPosition(point: moved, delay: 0, secondPoint: movedSecond)])
    try await fixture.withOperation(operation) { task in
      try await fixture.events.waitFor(phase)
      fixture.emit(changed("scale"))
      fixture.emit(DeviceHIDFixture.displaySnapshot)
      #expect(!native.state.wrappedValue.quarantined)
      #expect(fixture.events.count("end") == 0)
      #expect(fixture.events.count("release") == 0)
      native.gate.open()
      let outcome = await task.value
      guard case .displayObservationFailed(let reason)? = outcome.error as? DeviceHIDError else {
        Issue.record("A display change after admitted \(phase) was misclassified as preparation")
        return
      }
      #expect(reason.contains("display basis changed"))
      #expect(!reason.contains("preparation failed"))
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(native.state.wrappedValue.points.last == (phase == "start" ? CGPoint(x: 0.25, y: 0.5) : moved))
      let lastSecond = try #require(native.state.wrappedValue.secondPoints.last)
      let releasedSecond = try #require(lastSecond)
      #expect(releasedSecond == (phase == "start" ? second : movedSecond))
      #expect(try #require(fixture.events.time(phase + "Returned")) <= #require(fixture.events.time("end")))
    }
  }

  @Test(arguments: [false, true])
  func observationFailureAfterAnEarlierCompletedContactIsNotPreparation(_ eof: Bool) async throws {
    let fixture = DeviceHIDDisplayFixture()
    let later = DeviceHIDContactPlan(contact: .touch(CGPoint(x: 0.6, y: 0.7)), duration: 0, positions: [])
    let operation = fixture.operation(pause: 1, subsequent: [later])
    try await fixture.withOperation(operation) { task in
      try await fixture.events.waitFor("endReturned")
      if eof { fixture.finish() } else { fixture.emit(changed("scale")) }
      let outcome = await task.value
      guard case .displayObservationFailed(let reason)? = outcome.error as? DeviceHIDError else {
        Issue.record("Failure after an earlier completed contact was classified as preparation")
        return
      }
      #expect(!reason.isEmpty)
      #expect(!reason.contains("preparation failed"))
      #expect(!outcome.uncertain)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      #expect(fixture.events.count("start") == 1)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(fixture.events.count("releaseReturned") == 1)
    }
  }

  @Test(arguments: ["start", "end", "barrier"], [false, true])
  func observerJoinAndNativeCleanupAreIndependent(_ phase: String, _ observerFirst: Bool) async throws {
    let native = DeviceHIDFixture(block: phase)
    let fixture = DeviceHIDDisplayFixture(native: native, completeOnCancel: false)
    let operation = fixture.operation()
    try await fixture.withOperation(operation) { task in
      try await fixture.events.waitFor(phase)
      operation.cancel()
      try await fixture.events.waitFor("displayCancelReturned")
      #expect(fixture.events.count("release") == 0)
      #expect(fixture.events.count("callerFinished") == 0)
      if observerFirst {
        fixture.finish()
        #expect(fixture.events.count("release") == 0)
        native.gate.open()
      } else {
        native.gate.open()
        try await fixture.events.waitFor("barrierReturned")
        #expect(fixture.events.count("release") == 0)
        #expect(fixture.events.count("callerFinished") == 0)
        fixture.finish()
      }
      let outcome = await task.value
      #expect(outcome.error is CancellationError)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(fixture.events.count("releaseReturned") == 1)
      let release = try #require(fixture.events.time("release"))
      #expect(try #require(fixture.events.time("displayCompleting")) <= release)
      #expect(try #require(fixture.events.time("barrierReturned")) <= release)
    }
  }

  @Test func observerCompletionDoesNotSubstituteForCancellationReturn() async throws {
    let fixture = DeviceHIDDisplayFixture(blockCancellation: true)
    try await fixture.withOperation(fixture.operation()) { task in
      try await fixture.events.waitFor("displayCompletionReturned")
      #expect(fixture.events.count("release") == 0)
      #expect(fixture.events.count("discard") == 0)
      #expect(fixture.events.count("callerFinished") == 0)
      fixture.cancellationGate.open()
      #expect((await task.value).error == nil)
      #expect(try #require(fixture.events.time("displayCancelReturned")) <= #require(fixture.events.time("release")))
    }
  }

  @Test func normalCompletionWaitsForObserverAndIgnoresShutdownFrames() async throws {
    let fixture = DeviceHIDDisplayFixture(completeOnCancel: false)
    try await fixture.withOperation(fixture.operation()) { task in
      try await fixture.events.waitFor("displayCancelReturned")
      #expect(fixture.events.count("barrierReturned") == 1)
      #expect(fixture.events.count("release") == 0)
      #expect(fixture.events.count("callerFinished") == 0)
      fixture.emit(changed("scale"))
      fixture.finish()
      let outcome = await task.value
      #expect(outcome.error == nil)
      #expect(!outcome.uncertain)
      #expect(fixture.events.count("releaseReturned") == 1)
      #expect(fixture.events.count("discard") == 1)
    }
  }

  @Test func competingFailuresClaimOnlyOneUpAndStopLaterContacts() async throws {
    let native = DeviceHIDFixture(block: "start")
    let fixture = DeviceHIDDisplayFixture(native: native)
    let later = DeviceHIDContactPlan(contact: .touch(CGPoint(x: 0.6, y: 0.7)), duration: 0, positions: [])
    let operation = fixture.operation(subsequent: [later])
    try await fixture.withOperation(operation) { task in
      try await fixture.events.waitFor("start")
      await withTaskGroup(of: Void.self) { group in
        group.addTask { operation.cancel() }
        group.addTask { fixture.emit(changed("scale")) }
        group.addTask { native.state.sync { $0.invalidated }?() }
      }
      native.gate.open()
      let outcome = await task.value
      #expect(outcome.error != nil)
      #expect(outcome.uncertain)
      #expect(fixture.events.count("start") == 1)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(fixture.events.count("release") == 1)
    }
  }

  @Test func commandAdmissionWaitsForObserverJoin() async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let fixture = DeviceHIDDisplayFixture(completeOnCancel: false)
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {}, makeTransport: { _ in fixture.transport },
      prepareTouch: { _, _ in DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(), positions: []) })
    let first = Task { try await command.touch(.tap(x: 1, y: 2)) }
    let result: Result<Void, any Error>
    do {
      try await fixture.events.waitFor("displayCancelReturned")
      for button in [false, true] {
        await #expect {
          if button { try await command.button(.home) } else { try await command.touch(.tap(x: 1, y: 2)) }
        } throws: { error in
          if case DeviceHIDError.busy = error { return true }
          return false
        }
      }
      #expect(fixture.events.count("release") == 0)
      fixture.finish()
      try await first.value
      #expect(fixture.events.count("releaseReturned") == 1)
      result = .success(())
    } catch {
      result = .failure(error)
    }
    first.cancel()
    fixture.unblock()
    _ = await first.result
    withExtendedLifetime(device) {}
    try result.get()
  }

  @Test(arguments: ["geometry", "eof", "error"])
  func cleanMonitoringFailureAllowsAnotherCommand(_ failure: String) async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let native = DeviceHIDFixture(block: "start")
    let fixture = DeviceHIDDisplayFixture(native: native, completeOnCancel: false)
    let recovery = DeviceHIDFixture()
    let constructions = Atomic(wrappedValue: 0)
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {},
      makeTransport: { _ in
        let first = constructions.sync { count in
          count += 1
          return count == 1
        }
        return first ? fixture.transport : recovery.transport
      },
      prepareTouch: { _, _ in DeviceHIDPreparedTouch(start: DeviceHIDFixture.prepared(), positions: []) })
    let first = Task { try await command.touch(.tap(x: 1, y: 2)) }
    let result: Result<Void, any Error>
    do {
      try await fixture.events.waitFor("start")
      switch failure {
      case "geometry":
        fixture.emit(changed("scale"))
        try await fixture.events.waitFor("displayCancelReturned")
      case "eof": fixture.finish()
      default: fixture.finish(.failure(DeviceHIDTestError.nativeFailure))
      }
      await #expect { try await command.touch(.tap(x: 1, y: 2)) } throws: { error in
        if case DeviceHIDError.busy = error { return true }
        return false
      }
      native.gate.open()
      if failure == "geometry" {
        try await fixture.events.waitFor("barrierReturned")
        #expect(fixture.events.count("release") == 0)
        fixture.finish()
      }
      await #expect(throws: DeviceHIDError.self) { try await first.value }
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("releaseReturned") == 1)
      try await command.touch(.tap(x: 3, y: 4))
      #expect(constructions.wrappedValue == 2)
      #expect(recovery.events.count("start") == 1)
      #expect(recovery.events.count("end") == 1)
      #expect(recovery.events.count("releaseReturned") == 1)
      result = .success(())
    } catch {
      result = .failure(error)
    }
    first.cancel()
    fixture.unblock()
    _ = await first.result
    withExtendedLifetime(device) {}
    try result.get()
  }

  @Test func buttonsNeverStartDisplayObservation() async throws {
    let fixture = DeviceHIDDisplayFixture(initial: nil)
    let input = DeviceHIDPreparedButton(deviceIdentifier: UUID(), button: .home, duration: nil)
    let operation = DeviceHIDOperation(transport: fixture.transport, input: .button(input), quarantine: {})
    try await fixture.withOperation(operation) { task in
      #expect((await task.value).error == nil)
      #expect(fixture.events.count("displayStarted") == 0)
      #expect(fixture.events.count("displayCancel") == 0)
      #expect(fixture.events.count("start") == 1)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.native.state.wrappedValue.buttons == [.home, .home])
    }
  }

  @Test func preparationProjectionAcceptsTwoPreparedAndSevenNativeDisplays() throws {
    let prepared = Self.projectedPreparation
    let observed = Self.fullNativeSnapshot
    #expect(prepared.displays.map(\.identifier) == [1, 3])
    #expect(observed.displays.map(\.identifier) == [1, 3, 2, 4, 5, 6, 7])
    try observed.validatePreparation(against: prepared)
    #expect(throws: DeviceHIDError.self) { try observed.validate(against: prepared) }
    try observed.validate(against: observed)
  }

  @Test func preparationProjectionDoesNotAlsoFilterThePreparedInventory() {
    let prepared = Self.fullNativeSnapshot
    #expect(throws: DeviceHIDError.self) { try prepared.validatePreparation(against: prepared) }
  }

  @Test(arguments: ["zero", "zero-width", "zero-height", "offset-empty", "negative-width", "negative-height", "negative-both", "null", "infinite", "tiny", "ordinary"])
  func preparationProjectionUsesCGRectEmptiness(_ shape: String) throws {
    let bounds: CGRect
    switch shape {
    case "zero": bounds = .zero
    case "zero-width": bounds = CGRect(x: 0, y: 0, width: 0, height: 20)
    case "zero-height": bounds = CGRect(x: 0, y: 0, width: 20, height: 0)
    case "offset-empty": bounds = CGRect(x: 17, y: -9, width: 0, height: 20)
    case "negative-width": bounds = CGRect(x: 0, y: 0, width: -10, height: 20)
    case "negative-height": bounds = CGRect(x: 0, y: 0, width: 10, height: -20)
    case "negative-both": bounds = CGRect(x: 0, y: 0, width: -10, height: -20)
    case "null": bounds = .null
    case "infinite": bounds = .infinite
    case "tiny": bounds = CGRect(x: 0, y: 0, width: 0.001, height: 0.001)
    default: bounds = CGRect(x: 0, y: 0, width: 10, height: 20)
    }
    var observed = Self.projectedPreparation
    var extra = Self.emptyDisplay(2)
    extra.bounds = bounds
    observed.displays.append(extra)
    if bounds.isEmpty {
      try observed.validatePreparation(against: Self.projectedPreparation)
    } else {
      #expect(throws: DeviceHIDError.self) { try observed.validatePreparation(against: Self.projectedPreparation) }
    }
  }

  @Test(arguments: ["add", "missing", "primary-scale", "secondary-scale", "secondary-bounds", "secondary-native-size", "secondary-primary", "secondary-integrated", "secondary-native-rotation", "secondary-current-rotation"])
  func firstProjectionRejectsNonemptyInventoryAndCommonFieldChanges(_ change: String) async throws {
    var observed = Self.fullNativeSnapshot
    switch change {
    case "add":
      var extra = observed.displays[1]
      extra.identifier = 8
      observed.displays.append(extra)
    case "missing": observed.displays.remove(at: 1)
    case "primary-scale": observed.displays[0].pointScale = 4
    case "secondary-scale": observed.displays[1].pointScale = 2
    case "secondary-bounds": observed.displays[1].bounds.origin.x = 1
    case "secondary-native-size": observed.displays[1].nativeSize.width += 1
    case "secondary-primary": observed.displays[1].primary = true
    case "secondary-integrated": observed.displays[1].integrated = true
    case "secondary-native-rotation": observed.displays[1].nativeOrientation = "rot90"
    default: observed.displays[1].currentOrientation = "rot180"
    }
    #expect(throws: DeviceHIDError.self) { try observed.validatePreparation(against: Self.projectedPreparation) }
    let fixture = DeviceHIDDisplayFixture(initial: observed)
    try await fixture.withOperation(fixture.operation(snapshot: Self.projectedPreparation)) { task in
      let outcome = await task.value
      guard case .preparationFailed? = outcome.error as? DeviceHIDError else {
        Issue.record("A projected first-frame mismatch was not a preparation failure")
        return
      }
      #expect(!outcome.uncertain)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      #expect(fixture.events.count("end") == 0)
      #expect(fixture.events.count("barrier") == 0)
      #expect(fixture.events.count("releaseReturned") == 1)
    }
  }

  @Test(arguments: ["duplicate-empty", "duplicate-visible", "too-many-empty", "extra-empty-primary", "empty-primary", "missing-primary", "nonintegrated-primary", "zero-primary-id", "primary-origin", "primary-native-size", "primary-scale", "primary-rotation", "unsupported-orientation"])
  func projectionCannotHideInvalidFullMetadata(_ change: String) throws {
    var observed = Self.fullNativeSnapshot
    switch change {
    case "duplicate-empty": observed.displays.append(observed.displays[2])
    case "duplicate-visible": observed.displays[2].identifier = 3
    case "too-many-empty":
      observed.displays = Self.projectedPreparation.displays + (10...72).map { Self.emptyDisplay(UInt32($0)) }
    case "extra-empty-primary": observed.displays[2].primary = true
    case "empty-primary":
      observed.displays[0].bounds = .zero
      observed.displays[0].nativeSize = .zero
    case "missing-primary": observed.displays[0].primary = false
    case "nonintegrated-primary": observed.displays[0].integrated = false
    case "zero-primary-id": observed.displays[0].identifier = 0
    case "primary-origin": observed.displays[0].bounds.origin.x = 1
    case "primary-native-size": observed.displays[0].nativeSize.height += 1
    case "primary-scale": observed.displays[0].pointScale = .nan
    case "primary-rotation": observed.displays[0].currentOrientation = "rot90"
    default: observed.orientation = .unsupported
    }
    #expect(throws: DeviceHIDError.self) { try observed.primaryDisplay() }
    #expect(throws: DeviceHIDError.self) { try observed.validatePreparation(against: Self.projectedPreparation) }
  }

  @Test func projectedFirstFramePinsFullInventoryWithoutRenormalizingTheContact() async throws {
    let native = DeviceHIDFixture(block: "start")
    let fixture = DeviceHIDDisplayFixture(native: native, initial: nil, blockStartup: true)
    let baseline = Self.fullNativeSnapshot
    let second = CGPoint(x: 0.75, y: 0.5)
    try await fixture.withOperation(fixture.operation(snapshot: Self.projectedPreparation, secondPoint: second)) { task in
      try await fixture.events.waitFor("displayStarted")
      fixture.emit(baseline)
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      fixture.startupGate.open()
      try await fixture.events.waitFor("start")
      var repeated = baseline
      repeated.displays.reverse()
      repeated.orientation = .faceUp
      fixture.emit(repeated)
      fixture.emit(baseline)
      native.gate.open()
      let outcome = await task.value
      #expect(outcome.error == nil)
      #expect(!outcome.uncertain)
      #expect(native.state.wrappedValue.points == [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.25, y: 0.5)])
      #expect(native.state.wrappedValue.secondPoints == [second, second])
      #expect(fixture.events.count("start") == 1)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("releaseReturned") == 1)
    }
  }

  @Test(
    arguments: ["add", "remove", "id", "origin", "empty-shape", "native-size", "scale", "integrated", "primary", "native-rotation", "current-rotation", "becomes-nonempty"],
    ["factory", "start", "position", "end", "barrier"])
  func laterFramesCompareTheFullPinnedInventory(_ change: String, _ phase: String) async throws {
    let baseline = Self.fullNativeSnapshot
    let changed = Self.changedEmptyInventory(change, baseline: baseline)
    #expect(throws: DeviceHIDError.self) { try changed.validate(against: baseline) }
    if change != "primary", change != "becomes-nonempty" {
      try changed.validatePreparation(against: Self.projectedPreparation)
    }
    let native = DeviceHIDFixture(block: phase)
    let fixture = DeviceHIDDisplayFixture(native: native, initial: baseline)
    let moved = CGPoint(x: 0.3, y: 0.6)
    let second = CGPoint(x: 0.75, y: 0.5)
    let movedSecond = CGPoint(x: 0.7, y: 0.6)
    let operation = fixture.operation(
      snapshot: Self.projectedPreparation, secondPoint: second,
      positions: [DeviceHIDPosition(point: moved, delay: 0, secondPoint: movedSecond)])
    try await fixture.withOperation(operation) { task in
      try await fixture.events.waitFor(phase)
      fixture.emit(changed)
      fixture.emit(baseline)
      #expect(fixture.events.count("release") == 0)
      #expect(fixture.events.count("callerFinished") == 0)
      native.gate.open()
      let outcome = await task.value
      if phase == "factory" {
        guard case .preparationFailed? = outcome.error as? DeviceHIDError else {
          Issue.record("A full-baseline change before DOWN lost its preparation classification")
          return
        }
        #expect(native.state.wrappedValue.points.isEmpty)
        #expect(fixture.events.count("start") == 0)
        #expect(fixture.events.count("end") == 0)
        #expect(fixture.events.count("barrier") == 0)
      } else {
        guard case .displayObservationFailed? = outcome.error as? DeviceHIDError else {
          Issue.record("A full-baseline change after DOWN lost its observation classification")
          return
        }
        #expect(fixture.events.count("start") == 1)
        #expect(fixture.events.count("end") == 1)
        #expect(fixture.events.count("barrier") == 1)
        #expect(native.state.wrappedValue.points.last == (phase == "start" ? CGPoint(x: 0.25, y: 0.5) : moved))
        let lastSecond = try #require(native.state.wrappedValue.secondPoints.last)
        let releasedSecond = try #require(lastSecond)
        #expect(releasedSecond == (phase == "start" ? second : movedSecond))
        if phase == "start" { #expect(fixture.events.count("position") == 0) }
      }
      #expect(!outcome.uncertain)
      #expect(!native.state.wrappedValue.quarantined)
      #expect(fixture.events.count("releaseReturned") == 1)
      #expect(fixture.events.count("discard") == 1)
    }
  }

  @Test func projectionKeepsTheFullInventoryCountLimit() throws {
    var observed = Self.projectedPreparation
    observed.displays += (10...71).map { Self.emptyDisplay(UInt32($0)) }
    try observed.validatePreparation(against: Self.projectedPreparation)
    observed.displays.append(Self.emptyDisplay(72))
    #expect(throws: DeviceHIDError.self) { try observed.validatePreparation(against: Self.projectedPreparation) }
  }

  @Test func fullBaselineChangeRacingCancellationJoinsOneMatchingUp() async throws {
    let baseline = Self.fullNativeSnapshot
    let changed = Self.changedEmptyInventory("add", baseline: baseline)
    let native = DeviceHIDFixture(block: "position")
    let fixture = DeviceHIDDisplayFixture(native: native, initial: baseline)
    let moved = CGPoint(x: 0.3, y: 0.6)
    let operation = fixture.operation(
      snapshot: Self.projectedPreparation, positions: [DeviceHIDPosition(point: moved, delay: 0)])
    try await fixture.withOperation(operation) { task in
      try await fixture.events.waitFor("position")
      try await fixture.race([
        { fixture.emit(changed) },
        { fixture.emit(baseline) },
        { operation.cancel() },
      ])
      #expect(fixture.events.count("end") == 0)
      #expect(fixture.events.count("release") == 0)
      native.gate.open()
      let outcome = await task.value
      if !(outcome.error is CancellationError) {
        guard case .displayObservationFailed? = outcome.error as? DeviceHIDError else {
          Issue.record("Cancellation and full-baseline failure lost both typed causes")
          return
        }
      }
      #expect(!outcome.uncertain)
      #expect(!native.state.wrappedValue.quarantined)
      #expect(native.state.wrappedValue.points == [CGPoint(x: 0.25, y: 0.5), moved, moved])
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("barrier") == 1)
      #expect(fixture.events.count("releaseReturned") == 1)
      #expect(fixture.events.count("discard") == 1)
    }
  }

  @Test(arguments: ["same", "different-id", "different-count"], [false, true])
  func concurrentInitialFramesCannotReplaceTheFullBaseline(_ difference: String, _ cancel: Bool) async throws {
    let first = Self.fullNativeSnapshot
    var candidate = first
    if difference == "different-id" { candidate.displays[2].identifier = 8 }
    if difference == "different-count" { candidate.displays.removeLast() }
    let second = candidate
    try first.validatePreparation(against: Self.projectedPreparation)
    try second.validatePreparation(against: Self.projectedPreparation)
    let fixture = DeviceHIDDisplayFixture(initial: nil, blockStartup: true)
    let operation = fixture.operation(snapshot: Self.projectedPreparation)
    try await fixture.withOperation(operation) { task in
      try await fixture.events.waitFor("displayStarted")
      var callbacks: [@Sendable () -> Void] = [
        { fixture.emit(first) },
        { fixture.emit(second) },
      ]
      if cancel { callbacks.append { operation.cancel() } }
      try await fixture.race(callbacks)
      #expect(fixture.events.count("callbackReturned0") == 1)
      #expect(fixture.events.count("callbackReturned1") == 1)
      #expect(fixture.events.count("factory") == 0)
      #expect(fixture.events.count("start") == 0)
      fixture.startupGate.open()
      let outcome = await task.value
      if cancel {
        if difference == "same" {
          #expect(outcome.error is CancellationError)
        } else if !(outcome.error is CancellationError) {
          guard case .preparationFailed? = outcome.error as? DeviceHIDError else {
            Issue.record("Concurrent cancellation and display mismatch lost both typed causes")
            return
          }
        }
      } else if difference == "same" {
        #expect(outcome.error == nil)
      } else {
        guard case .preparationFailed? = outcome.error as? DeviceHIDError else {
          Issue.record("Concurrent first frames were both accepted against the unbound projection")
          return
        }
      }
      #expect(!outcome.uncertain)
      #expect(!fixture.native.state.wrappedValue.quarantined)
      let contacts = !cancel && difference == "same" ? 1 : 0
      #expect(fixture.events.count("start") == contacts)
      #expect(fixture.events.count("end") == contacts)
      #expect(fixture.events.count("barrier") == contacts)
      #expect(fixture.events.count("releaseReturned") == 1)
      #expect(fixture.events.count("discard") == 1)
    }
  }

  @Test(arguments: ["add", "remove", "scale"])
  func cleanFullBaselineFailureAllowsAChangedInventoryOnTheNextCommand(_ change: String) async throws {
    let device = DeviceHIDRetentionTests.makeInertDevice()
    let baseline = Self.fullNativeSnapshot
    let changed = Self.changedEmptyInventory(change, baseline: baseline)
    let native = DeviceHIDFixture(block: "start")
    let fixture = DeviceHIDDisplayFixture(native: native, initial: baseline, completeOnCancel: false)
    let recovery = DeviceHIDDisplayFixture(initial: changed)
    let constructions = Atomic(wrappedValue: 0)
    let prepared = DeviceHIDPreparedTouch(
      start: DeviceHIDPreparedTap(
        deviceIdentifier: UUID(), point: CGPoint(x: 0.25, y: 0.5), duration: 0,
        displaySnapshot: Self.projectedPreparation), positions: [])
    let command = DeviceHIDCommands(
      device: device, checkRuntime: {},
      makeTransport: { _ in
        let first = constructions.sync { count in
          count += 1
          return count == 1
        }
        return first ? fixture.transport : recovery.transport
      }, prepareTouch: { _, _ in prepared })
    let first = Task { try await command.touch(.tap(x: 1, y: 2)) }
    let result: Result<Void, any Error>
    do {
      try await fixture.events.waitFor("start")
      fixture.emit(changed)
      try await fixture.events.waitFor("displayCancelReturned")
      await #expect { try await command.touch(.tap(x: 3, y: 4)) } throws: { error in
        if case DeviceHIDError.busy = error { return true }
        return false
      }
      native.gate.open()
      try await fixture.events.waitFor("barrierReturned")
      #expect(fixture.events.count("release") == 0)
      fixture.finish()
      await #expect { try await first.value } throws: { error in
        if case DeviceHIDError.inputMayHaveApplied(let cause) = error,
          case DeviceHIDError.displayObservationFailed = cause
        {
          return true
        }
        return false
      }
      #expect(!native.state.wrappedValue.quarantined)
      #expect(fixture.events.count("end") == 1)
      #expect(fixture.events.count("releaseReturned") == 1)
      try await command.touch(.tap(x: 3, y: 4))
      #expect(constructions.wrappedValue == 2)
      #expect(recovery.events.count("start") == 1)
      #expect(recovery.events.count("end") == 1)
      #expect(recovery.events.count("releaseReturned") == 1)
      result = .success(())
    } catch {
      result = .failure(error)
    }
    first.cancel()
    fixture.unblock()
    recovery.unblock()
    _ = await first.result
    withExtendedLifetime(device) {}
    try result.get()
  }

  private static var projectedPreparation: DeviceHIDDisplaySnapshot {
    DeviceHIDDisplaySnapshot(
      displays: [
        .init(
          identifier: 1, primary: true, integrated: true,
          bounds: CGRect(x: 0, y: 0, width: 1179, height: 2556), nativeSize: CGSize(width: 1179, height: 2556),
          pointScale: 3, nativeOrientation: "rot0", currentOrientation: "rot0"),
        .init(
          identifier: 3, primary: false, integrated: false,
          bounds: CGRect(x: 0, y: 0, width: 1184, height: 2560), nativeSize: CGSize(width: 1184, height: 2560),
          pointScale: 1, nativeOrientation: "rot0", currentOrientation: "rot0"),
      ], orientation: .portrait, nonFlatOrientation: .portrait)
  }

  private static var fullNativeSnapshot: DeviceHIDDisplaySnapshot {
    var snapshot = projectedPreparation
    snapshot.displays += [UInt32(2), 4, 5, 6, 7].map(emptyDisplay)
    return snapshot
  }

  private static func emptyDisplay(_ identifier: UInt32) -> DeviceHIDDisplaySnapshot.Display {
    .init(
      identifier: identifier, primary: false, integrated: false,
      bounds: .zero, nativeSize: .zero, pointScale: 1,
      nativeOrientation: "rot0", currentOrientation: "rot0")
  }

  private static func changedEmptyInventory(_ field: String, baseline: DeviceHIDDisplaySnapshot) -> DeviceHIDDisplaySnapshot {
    var frame = baseline
    switch field {
    case "add": frame.displays.append(emptyDisplay(8))
    case "remove": frame.displays.remove(at: 2)
    case "id": frame.displays[2].identifier = 8
    case "origin": frame.displays[2].bounds.origin = CGPoint(x: 5, y: 6)
    case "empty-shape": frame.displays[2].bounds.size.height = 20
    case "native-size": frame.displays[2].nativeSize = CGSize(width: 10, height: 20)
    case "scale": frame.displays[2].pointScale = 2
    case "integrated": frame.displays[2].integrated = true
    case "primary": frame.displays[2].primary = true
    case "native-rotation": frame.displays[2].nativeOrientation = "rot90"
    case "current-rotation": frame.displays[2].currentOrientation = "rot180"
    case "becomes-nonempty":
      frame.displays[2].bounds.size = CGSize(width: 10, height: 20)
      frame.displays[2].nativeSize = frame.displays[2].bounds.size
    default: Issue.record("Unknown empty-inventory mutation")
    }
    return frame
  }

  private func changed(_ field: String) -> DeviceHIDDisplaySnapshot {
    var frame = DeviceHIDFixture.displaySnapshot
    switch field {
    case "id": frame.displays[0].identifier = 2
    case "scale": frame.displays[0].pointScale = 4
    case "size":
      frame.displays[0].bounds.size.width = 1002
      frame.displays[0].nativeSize.width = 1002
    case "origin": frame.displays[0].bounds.origin.x = 1
    case "native-size": frame.displays[0].nativeSize.width = 1002
    case "primary": frame.displays[0].primary = false
    case "integrated": frame.displays[0].integrated = false
    case "display-rotation": frame.displays[0].currentOrientation = "rot90"
    case "native-rotation": frame.displays[0].nativeOrientation = "rot90"
    case "inventory":
      var extra = frame.displays[0]
      extra.identifier = 2
      extra.primary = false
      frame.displays.append(extra)
    default: Issue.record("Unknown basis mutation")
    }
    return frame
  }
}
