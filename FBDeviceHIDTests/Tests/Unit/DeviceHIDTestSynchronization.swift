/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Dispatch
import Foundation
import IDBConcurrency

/// Blocks a dedicated native-work queue until opened; opening is permanent.
final class DeviceHIDTestGate: Sendable {
  private let condition = NSConditionLock(condition: 0)

  func wait() {
    condition.lock(whenCondition: 1)
    condition.unlock()
  }

  func open() {
    condition.lock()
    condition.unlock(withCondition: 1)
  }
}

final class DeviceHIDTestRecorder: Sendable {
  private enum WaitError: Error { case timedOut }

  private struct Waiter {
    let name: String
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var waiters: [UUID: Waiter] = [:]
    var calls: [String] = []
    var times: [String: ContinuousClock.Instant] = [:]
  }

  private let state = Atomic(wrappedValue: State())

  func record(_ name: String) {
    let ready = state.sync { state -> [CheckedContinuation<Void, any Error>] in
      state.calls.append(name)
      state.times[name] = .now
      let identifiers = state.waiters.filter { $0.value.name == name }.map { $0.key }
      return identifiers.compactMap { state.waiters.removeValue(forKey: $0)?.continuation }
    }
    for continuation in ready { continuation.resume() }
  }

  func count(_ name: String) -> Int { state.sync { $0.calls.filter { $0 == name }.count } }

  func time(_ name: String) -> ContinuousClock.Instant? { state.sync { $0.times[name] } }

  func waitFor(_ name: String) async throws {
    let id = UUID()
    try await withCheckedThrowingContinuation { continuation in
      let observed = state.sync { state -> Bool in
        if state.calls.contains(name) { return true }
        state.waiters[id] = Waiter(name: name, continuation: continuation)
        return false
      }
      if observed {
        continuation.resume()
        return
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        let expired = self.state.sync { $0.waiters.removeValue(forKey: id) }
        expired?.continuation.resume(throwing: WaitError.timedOut)
      }
    }
  }

  func onDeadline(_ deadline: ContinuousClock.Instant, signal name: String, perform action: @escaping @Sendable () -> Void) {
    let remaining = ContinuousClock.now.duration(to: deadline).components
    let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
    DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds)) {
      self.record(name)
      action()
    }
  }
}
