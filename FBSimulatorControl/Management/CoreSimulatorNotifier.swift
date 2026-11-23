/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
import Foundation

/// Arbitrates the single hand-off between the notification block, task cancellation and the
/// continuation, any of which can arrive first, and owns unregistering the handler exactly once.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
private final class StateChangeWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var notifier: CoreSimulatorNotifier?
  private var finished = false

  /// Returns false when cancellation beat the continuation, in which case it is resumed here and
  /// the caller must not register a handler.
  func park(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
    lock.lock()
    if finished {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return false
    }
    self.continuation = continuation
    lock.unlock()
    return true
  }

  /// Takes ownership of the handler's registration. The notification block runs as soon as it is
  /// registered, so the wait can already be over by the time the notifier is handed over.
  func attach(_ notifier: CoreSimulatorNotifier) {
    lock.lock()
    if finished {
      lock.unlock()
      notifier.terminate()
      return
    }
    self.notifier = notifier
    lock.unlock()
  }

  func finish(throwing error: (any Error)?) {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    let continuation = self.continuation
    let notifier = self.notifier
    self.continuation = nil
    self.notifier = nil
    lock.unlock()

    notifier?.terminate()
    if let error {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
  }
}

public final class CoreSimulatorNotifier {

  private let handle: UInt64
  private let notifier: (any SimDeviceNotifier)? // nil in test doubles

  /// Calls `block` on `queue` with each notification `simDevice` posts, until terminated.
  public convenience init(device simDevice: SimDevice, queue: DispatchQueue, block: @escaping @Sendable ([String: Any]) -> Void) {
    self.init(notifier: simDevice.notificationManager as AnyObject?, queue: queue, block: block)
  }

  /// Suspends until `device` reports a state other than `state`. The CoreSimulator notification
  /// handler is unregistered whether the state change arrives or the calling task is cancelled.
  public static func resolveLeavesState(_ state: TargetState, for device: SimDevice) async throws {
    let waiter = StateChangeWaiter()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        guard waiter.park(continuation) else {
          return
        }
        let queue = DispatchQueue(label: "com.facebook.fbsimulatorcontrol.resolve_state")
        let notifier = CoreSimulatorNotifier(device: device, queue: queue) { info in
          guard let notification = info["notification"] as? String, notification == "device_state" else {
            return
          }
          guard let newStateNumber = info["new_state"] as? NSNumber else {
            return
          }
          let newState = TargetState(rawValue: newStateNumber.uintValue)
          if newState == state {
            return
          }
          waiter.finish(throwing: nil)
        }
        waiter.attach(notifier)
      }
    } onCancel: {
      waiter.finish(throwing: CancellationError())
    }
  }

  public func terminate() {
    notifier?.unregisterNotificationHandler(handle, error: nil)
  }

  /// Calls `block` on `queue` with each notification `set`'s device set posts, until terminated.
  convenience init(set: SimulatorSet, queue: DispatchQueue, block: @escaping @Sendable ([String: Any]) -> Void) {
    // notificationManager may be nil in test doubles (ObjC nil messaging returns nil).
    self.init(notifier: (set.deviceSet as AnyObject).notificationManager as AnyObject?, queue: queue, block: block)
  }

  private init(notifier: AnyObject?, queue: DispatchQueue, block: @escaping @Sendable ([String: Any]) -> Void) {
    // nil for test doubles; mirror ObjC nil-messaging with a 0 handle.
    guard let notifier = notifier as? any SimDeviceNotifier else {
      self.notifier = nil
      self.handle = 0
      return
    }
    self.notifier = notifier
    self.handle = notifier.registerNotificationHandler(on: queue) { info in
      block((info as? [String: Any]) ?? [:])
    }
  }
}
