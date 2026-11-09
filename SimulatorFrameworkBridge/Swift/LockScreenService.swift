/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

#if canImport(SimulatorFrameworkBridgeRuntime)
@_implementationOnly import SimulatorFrameworkBridgeRuntime
#endif

#if !os(tvOS) && !os(watchOS)

/// SpringBoard's lock state.
struct LockScreenStatus: Sendable {
  let locked: Bool
  let passcodeEnabled: Bool
}

/// What became of a lock or unlock request.
enum LockScreenRequestOutcome: Sendable {
  case completed
  case timedOut
  case unavailable
}

/// Why a lock screen request failed.
enum LockScreenError: Error, Sendable {
  case unreadable
  case unreadableAfter(verb: String)
  case passcodeEnabled
  case timedOut(verb: String, seconds: Int)
  case unavailable(verb: String)
  case notApplied(verb: String, stillLocked: Bool)
}

extension LockScreenError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .unreadable:
      "Could not read the lock state from SpringBoard"
    case let .unreadableAfter(verb):
      "Could not read the lock state from SpringBoard after the \(verb)"
    case .passcodeEnabled:
      "The device has a passcode, which an unlock cannot enter"
    case let .timedOut(verb, seconds):
      "SpringBoard did not answer the \(verb) request within \(seconds) seconds"
    case let .unavailable(verb):
      "SpringBoard cannot be asked to \(verb) the device"
    case let .notApplied(verb, stillLocked):
      "SpringBoard did not \(verb) the device: it still reports it \(stillLocked ? "locked" : "unlocked")"
    }
  }
}

/// The SpringBoard calls the service makes, so tests can stand in for SpringBoard.
protocol LockScreenRuntime {
  func status() -> LockScreenStatus?
  /// The state SpringBoard reports once it reports `locked`, or when `timeout` passes first; nil as soon as a
  /// read fails.
  func status(afterWaitingForLocked locked: Bool, timeout: TimeInterval) -> LockScreenStatus?
  func lock(timeout: TimeInterval) -> LockScreenRequestOutcome
  func unlock() -> LockScreenRequestOutcome
}

struct SpringBoardLockScreen: LockScreenRuntime {
  func status() -> LockScreenStatus? {
    FBLockScreenClient.currentStatus().map(LockScreenStatus.init)
  }

  func status(afterWaitingForLocked locked: Bool, timeout: TimeInterval) -> LockScreenStatus? {
    FBLockScreenClient.statusAfterWaiting(forLocked: locked, timeout: timeout).map(LockScreenStatus.init)
  }

  func lock(timeout: TimeInterval) -> LockScreenRequestOutcome {
    LockScreenRequestOutcome(FBLockScreenClient.lock(withTimeout: timeout))
  }

  func unlock() -> LockScreenRequestOutcome {
    LockScreenRequestOutcome(FBLockScreenClient.requestUnlock())
  }
}

private extension LockScreenRequestOutcome {
  init(_ outcome: FBLockScreenRequestOutcome) {
    switch outcome {
    case .completed: self = .completed
    case .timedOut: self = .timedOut
    case .unavailable: self = .unavailable
    @unknown default: self = .unavailable
    }
  }
}

private extension LockScreenStatus {
  init(_ status: FBLockScreenStatus) {
    self.init(locked: status.locked, passcodeEnabled: status.passcodeEnabled)
  }
}

/// Reports SpringBoard's lock state, and locks and unlocks the device through SpringBoard.
///
/// A lock goes through SpringBoard's lock screen service. The host unlocks a device without a passcode by
/// pressing the Home button before it asks for an unlock, which SpringBoard honours on every runtime, so an
/// unlock first gives SpringBoard `homePressTimeout` to act on that press. Only if the device is still locked
/// does it go through SpringBoard's accessibility server, the request Switch Control uses, which SpringBoard
/// honours before iOS 27 and ignores from it; waiting first keeps the two from both acting. Either way
/// SpringBoard unlocks its UI and returns to the app that was in front before the lock. A device with a
/// passcode cannot be unlocked this way, so it is refused.
///
/// Both are idempotent: a device already in the requested state is reported as it is, with nothing sent
/// to SpringBoard. A change succeeds only once SpringBoard reports the new state, so a request it does
/// not act on is a failure. Each success carries the state SpringBoard reports afterwards.
///
/// The guest answers one request at a time, synchronously, on its main thread, and uses no Swift
/// concurrency, so waiting for SpringBoard here holds no cooperative thread; the waits keep the main run
/// loop turning, which is where SpringBoard's services deliver their completions.
enum LockScreenService {
  static let requestTimeout: TimeInterval = 10
  static let settleTimeout: TimeInterval = 5
  static let homePressTimeout: TimeInterval = 2

  static func state(runtime: LockScreenRuntime = SpringBoardLockScreen()) -> Result<LockScreenStatus, LockScreenError> {
    runtime.status().map { .success($0) } ?? .failure(.unreadable)
  }

  static func lock(runtime: LockScreenRuntime = SpringBoardLockScreen()) -> Result<LockScreenStatus, LockScreenError> {
    change(toLocked: true, runtime: runtime)
  }

  static func unlock(runtime: LockScreenRuntime = SpringBoardLockScreen()) -> Result<LockScreenStatus, LockScreenError> {
    change(toLocked: false, runtime: runtime)
  }

  private static func change(toLocked wantLocked: Bool, runtime: LockScreenRuntime) -> Result<LockScreenStatus, LockScreenError> {
    guard let before = runtime.status() else {
      return .failure(.unreadable)
    }
    if before.locked == wantLocked {
      return .success(before)
    }
    if !wantLocked, before.passcodeEnabled {
      return .failure(.passcodeEnabled)
    }
    let verb = wantLocked ? "lock" : "unlock"
    if !wantLocked {
      guard let unlockedByHome = runtime.status(afterWaitingForLocked: false, timeout: homePressTimeout) else {
        return .failure(.unreadableAfter(verb: verb))
      }
      if !unlockedByHome.locked {
        return .success(unlockedByHome)
      }
    }
    switch wantLocked ? runtime.lock(timeout: requestTimeout) : runtime.unlock() {
    case .completed:
      break
    case .timedOut:
      return .failure(.timedOut(verb: verb, seconds: Int(requestTimeout)))
    case .unavailable:
      return .failure(.unavailable(verb: verb))
    }
    // A failed read is reported, not retried: lock and unlock are idempotent, so the caller can retry the call.
    guard let after = runtime.status(afterWaitingForLocked: wantLocked, timeout: settleTimeout) else {
      return .failure(.unreadableAfter(verb: verb))
    }
    guard after.locked == wantLocked else {
      return .failure(.notApplied(verb: verb, stillLocked: after.locked))
    }
    return .success(after)
  }
}

#endif
