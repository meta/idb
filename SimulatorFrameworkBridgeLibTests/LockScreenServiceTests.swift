/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
@testable import SimulatorFrameworkBridgeSupport
import Testing

// The service compares nothing itself; the tests compare what it answers.
extension LockScreenStatus: @retroactive Equatable {
  public static func == (lhs: LockScreenStatus, rhs: LockScreenStatus) -> Bool {
    lhs.locked == rhs.locked && lhs.passcodeEnabled == rhs.passcodeEnabled
  }
}

extension LockScreenError: @retroactive Equatable {
  public static func == (lhs: LockScreenError, rhs: LockScreenError) -> Bool {
    lhs.localizedDescription == rhs.localizedDescription
  }
}

/// SpringBoard as the service sees it: a lock state that a completed request moves.
private final class FakeLockScreen: LockScreenRuntime {
  var current: LockScreenStatus?
  var outcome: LockScreenRequestOutcome = .completed
  /// Whether a completed request actually moves the state, as SpringBoard normally does.
  var completionMovesState = true
  /// Whether the read after a change fails, as a momentary MIG failure would.
  var readAfterChangeFails = false
  /// Whether SpringBoard unlocks while the service first waits, as it does for the host's Home button press.
  var unlocksForHomePress = false
  /// Whether the read while waiting for the Home button press fails.
  var readWhileWaitingForHomeFails = false
  private(set) var requests: [String] = []
  private(set) var reads = 0
  private(set) var waits: [TimeInterval] = []

  init(_ current: LockScreenStatus?) {
    self.current = current
  }

  func status() -> LockScreenStatus? {
    reads += 1
    return current
  }

  func status(afterWaitingForLocked locked: Bool, timeout: TimeInterval) -> LockScreenStatus? {
    reads += 1
    waits.append(timeout)
    if requests.isEmpty {
      if readWhileWaitingForHomeFails {
        return nil
      }
      if unlocksForHomePress, let current {
        self.current = LockScreenStatus(locked: false, passcodeEnabled: current.passcodeEnabled)
      }
      return current
    }
    return readAfterChangeFails ? nil : current
  }

  func lock(timeout: TimeInterval) -> LockScreenRequestOutcome {
    request("lock", locked: true)
  }

  func unlock() -> LockScreenRequestOutcome {
    request("unlock", locked: false)
  }

  func request(_ name: String, locked: Bool) -> LockScreenRequestOutcome {
    requests.append(name)
    if case .completed = outcome, completionMovesState, let current {
      self.current = LockScreenStatus(locked: locked, passcodeEnabled: current.passcodeEnabled)
    }
    return outcome
  }
}

private let unlocked = LockScreenStatus(locked: false, passcodeEnabled: false)
private let locked = LockScreenStatus(locked: true, passcodeEnabled: false)

enum LockScreenTestAction: CaseIterable {
  case state, lock, unlock
}

private func run(_ action: LockScreenTestAction, on springBoard: FakeLockScreen) -> Result<LockScreenStatus, LockScreenError> {
  switch action {
  case .state: LockScreenService.state(runtime: springBoard)
  case .lock: LockScreenService.lock(runtime: springBoard)
  case .unlock: LockScreenService.unlock(runtime: springBoard)
  }
}

@Suite("Lock screen service")
struct LockScreenServiceTests {
  @Test("State reports what SpringBoard reports without changing it")
  func stateReportsTheLockState() {
    let springBoard = FakeLockScreen(unlocked)

    #expect(run(.state, on: springBoard) == .success(unlocked))
    #expect(springBoard.requests.isEmpty)
  }

  @Test("Lock locks an unlocked device and reports it locked")
  func lockLocksAnUnlockedDevice() {
    let springBoard = FakeLockScreen(unlocked)

    #expect(run(.lock, on: springBoard) == .success(locked))
    #expect(springBoard.requests == ["lock"])
  }

  @Test("Unlock asks SpringBoard to unlock a device the Home button press did not, and reports it unlocked")
  func unlockUnlocksALockedDevice() {
    let springBoard = FakeLockScreen(locked)

    #expect(run(.unlock, on: springBoard) == .success(unlocked))
    #expect(springBoard.requests == ["unlock"])
    #expect(springBoard.waits == [LockScreenService.homePressTimeout, LockScreenService.settleTimeout])
  }

  @Test("Unlock sends nothing once SpringBoard unlocks for the Home button press")
  func unlockLeavesAHomePressAlone() {
    let springBoard = FakeLockScreen(locked)
    springBoard.unlocksForHomePress = true

    #expect(run(.unlock, on: springBoard) == .success(unlocked))
    #expect(springBoard.requests.isEmpty)
    #expect(springBoard.waits == [LockScreenService.homePressTimeout])
  }

  @Test("A failed read while waiting for the Home button press is reported, and nothing is sent")
  func failedReadWhileWaitingForHomeIsReported() {
    let springBoard = FakeLockScreen(locked)
    springBoard.readWhileWaitingForHomeFails = true

    #expect(run(.unlock, on: springBoard) == .failure(.unreadableAfter(verb: "unlock")))
    #expect(springBoard.requests.isEmpty)
  }

  @Test("Lock does not wait for a Home button press")
  func lockDoesNotWaitForHome() {
    let springBoard = FakeLockScreen(unlocked)

    #expect(run(.lock, on: springBoard) == .success(locked))
    #expect(springBoard.waits == [LockScreenService.settleTimeout])
  }

  @Test(
    "Lock and unlock leave a device already in that state alone",
    arguments: [(LockScreenTestAction.lock, true), (LockScreenTestAction.unlock, false)])
  func changesAreIdempotent(_ action: LockScreenTestAction, isLocked: Bool) {
    let springBoard = FakeLockScreen(isLocked ? locked : unlocked)

    let first = run(action, on: springBoard)
    let second = run(action, on: springBoard)

    #expect(first == .success(isLocked ? locked : unlocked))
    #expect(second == first)
    #expect(springBoard.requests.isEmpty)
  }

  @Test("Unlock refuses a device with a passcode without asking SpringBoard")
  func unlockRefusesAPasscode() {
    let springBoard = FakeLockScreen(LockScreenStatus(locked: true, passcodeEnabled: true))

    let result = run(.unlock, on: springBoard)

    #expect(result == .failure(.passcodeEnabled))
    #expect(LockScreenError.passcodeEnabled.localizedDescription == "The device has a passcode, which an unlock cannot enter")
    #expect(springBoard.requests.isEmpty)
  }

  @Test(
    "A change SpringBoard acknowledges without acting on fails",
    arguments: [(LockScreenTestAction.lock, false), (LockScreenTestAction.unlock, true)])
  func acknowledgedButUnchangedFails(_ action: LockScreenTestAction, startsLocked: Bool) {
    let springBoard = FakeLockScreen(startsLocked ? locked : unlocked)
    springBoard.completionMovesState = false

    let result = run(action, on: springBoard)

    let verb = action == .lock ? "lock" : "unlock"
    #expect(result == .failure(.notApplied(verb: verb, stillLocked: startsLocked)))
    #expect(
      LockScreenError.notApplied(verb: verb, stillLocked: startsLocked).localizedDescription
        == "SpringBoard did not \(verb) the device: it still reports it \(startsLocked ? "locked" : "unlocked")")
  }

  @Test(
    "A lock SpringBoard does not complete fails with what happened",
    arguments: [
      (LockScreenRequestOutcome.timedOut, "SpringBoard did not answer the lock request within 10 seconds"),
      (LockScreenRequestOutcome.unavailable, "SpringBoard cannot be asked to lock the device"),
    ])
  func incompleteLocksFail(_ outcome: LockScreenRequestOutcome, message: String) throws {
    let springBoard = FakeLockScreen(unlocked)
    springBoard.outcome = outcome

    let result = run(.lock, on: springBoard)

    guard case let .failure(error) = result else {
      Issue.record("expected a failure, got \(result)")
      return
    }
    #expect(error.localizedDescription == message)
    #expect(springBoard.current == unlocked)
  }

  @Test(
    "A failed read after a change is reported at once, not retried",
    arguments: [(LockScreenTestAction.lock, false), (LockScreenTestAction.unlock, true)])
  func failedReadAfterChangeIsReported(_ action: LockScreenTestAction, startsLocked: Bool) {
    let springBoard = FakeLockScreen(startsLocked ? locked : unlocked)
    springBoard.readAfterChangeFails = true

    let result = run(action, on: springBoard)

    let verb = action == .lock ? "lock" : "unlock"
    #expect(result == .failure(.unreadableAfter(verb: verb)))
    #expect(
      LockScreenError.unreadableAfter(verb: verb).localizedDescription == "Could not read the lock state from SpringBoard after the \(verb)")
    // SpringBoard did move the state; the service does not read again to find out. An unlock also read once
    // while it waited for the Home button press.
    #expect(springBoard.current == (startsLocked ? unlocked : locked))
    #expect(springBoard.reads == (action == .unlock ? 3 : 2))
    #expect(springBoard.requests == [verb])
  }

  @Test("An unreadable lock state fails before anything is sent", arguments: LockScreenTestAction.allCases)
  func unreadableStateFails(_ action: LockScreenTestAction) {
    let springBoard = FakeLockScreen(nil)

    #expect(run(action, on: springBoard) == .failure(.unreadable))
    #expect(LockScreenError.unreadable.localizedDescription == "Could not read the lock state from SpringBoard")
    #expect(springBoard.requests.isEmpty)
  }
}
