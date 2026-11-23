/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@unsafe @preconcurrency import CoreSimulator
import FBControlCore
import Foundation

package enum SimulatorDarwinNotificationObserver {
  package typealias Cancel = @Sendable () -> Void
  package typealias Subscription = (changes: AsyncThrowingStream<Void, any Error>, cancel: Cancel, failure: @Sendable () -> (any Error)?)
  package typealias Register =
    @Sendable (
      @escaping @Sendable () -> Void, @escaping @Sendable (Result<Cancel, any Error>) -> Void,
      @escaping @Sendable (any Error) -> Void
    ) -> Void

  package static func subscribe(on simulator: Simulator, name: String) async throws -> Subscription {
    guard simulator.device.responds(to: NSSelectorFromString("observeDarwinNotification:onQueue:handler:completionHandler:")) else {
      throw SimulatorNotificationObservationError.unsupported
    }
    guard simulator.state == .booted else { throw SimulatorNotificationObservationError.notBooted }
    let queue = DispatchQueue(label: "com.facebook.fbsimulatorcontrol.settings")
    return try await subscribe { changed, registered, failed in
      let notifier = simulator.device as any SimDeviceNotifier
      let handle = notifier.registerNotificationHandler(on: queue) { info in
        if info?["notification"] as? String == "device_state",
          let state = info?["new_state"] as? NSNumber, TargetState(rawValue: state.uintValue) != .booted
        {
          failed(SimulatorNotificationObservationError.notBooted)
        }
      }
      let unregisterState: Cancel = { _ = unsafe notifier.unregisterNotificationHandler(handle, error: nil) }
      simulator.device.observeDarwinNotification(name, on: queue, handler: { _ in changed() }) { token, error in
        if let error {
          token?.invalidate()
          unregisterState()
          registered(.failure(error))
        } else if let token {
          registered(
            .success {
              token.invalidate()
              unregisterState()
            })
        } else {
          unregisterState()
          registered(.failure(SimulatorNotificationObservationError.missingToken))
        }
      }
    }
  }

  static func subscribe(register: Register) async throws -> Subscription {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let observation = SimulatorNotificationObservation(continuation: continuation)
    continuation.onTermination = { _ in observation.finish(throwing: nil) }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { ready in
        guard observation.park(ready) else { return }
        register({ continuation.yield(()) }, { observation.registered($0) }, { observation.finish(throwing: $0) })
      }
    } onCancel: {
      observation.finish(throwing: nil)
    }
    return (stream, { observation.finish(throwing: nil) }, { observation.sourceFailure() })
  }

  package static func values<Value: Sendable>(
    subscription: Subscription, read: @escaping @Sendable (Bool) async throws -> Value
  ) -> AsyncThrowingStream<Value, any Error> {
    let readValue: @Sendable (Bool) async throws -> Value = { initial in
      try Task.checkCancellation()
      if let error = subscription.failure() { throw error }
      let value = try await read(initial)
      try Task.checkCancellation()
      if let error = subscription.failure() { throw error }
      return value
    }
    return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let follow = Task {
        do {
          continuation.yield(try await readValue(true))
          for try await _ in subscription.changes {
            continuation.yield(try await readValue(false))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: Task.isCancelled ? nil : subscription.failure() ?? error)
        }
      }
      continuation.onTermination = { _ in
        follow.cancel()
        subscription.cancel()
      }
    }
  }

  static func state(on simulator: Simulator, name: String) throws -> UInt64 {
    guard simulator.device.responds(to: NSSelectorFromString("darwinNotificationGetState:name:error:")) else {
      throw SimulatorNotificationObservationError.unsupported
    }
    var value: UInt64 = 0
    unsafe try simulator.device.darwinNotificationGetState(&value, name: name)
    return value
  }
}

// SAFETY: `lock` guards registration, cancellation and ownership of the native token.
private final class SimulatorNotificationObservation: @unchecked Sendable {
  private let lock = NSLock()
  private let continuation: AsyncThrowingStream<Void, any Error>.Continuation
  private var ready: CheckedContinuation<Void, any Error>?
  private var unregister: SimulatorDarwinNotificationObserver.Cancel?
  private var cancelled = false
  private var terminalError: (any Error)?

  init(continuation: AsyncThrowingStream<Void, any Error>.Continuation) {
    self.continuation = continuation
  }

  func park(_ ready: CheckedContinuation<Void, any Error>) -> Bool {
    lock.lock()
    if cancelled {
      lock.unlock()
      ready.resume(throwing: CancellationError())
      return false
    }
    self.ready = ready
    lock.unlock()
    return true
  }

  func registered(_ result: Result<SimulatorDarwinNotificationObserver.Cancel, any Error>) {
    lock.lock()
    let ready = self.ready
    self.ready = nil
    if case let .success(unregister) = result, !cancelled { self.unregister = unregister }
    let cancelled = self.cancelled
    lock.unlock()
    if cancelled, case let .success(unregister) = result { unregister() }
    switch result {
    case .success: ready?.resume()
    case let .failure(error):
      ready?.resume(throwing: error)
      continuation.finish(throwing: error)
    }
  }

  func sourceFailure() -> (any Error)? {
    lock.withLock { terminalError }
  }

  func finish(throwing error: (any Error)?) {
    lock.lock()
    guard !cancelled else {
      lock.unlock()
      return
    }
    cancelled = true
    terminalError = error
    let ready = self.ready
    let unregister = self.unregister
    self.ready = nil
    self.unregister = nil
    lock.unlock()
    unregister?()
    ready?.resume(throwing: error ?? CancellationError())
    continuation.finish(throwing: error)
  }
}

enum SimulatorNotificationObservationError: Error, LocalizedError, SimulatorFailureClassifying {
  case unsupported
  case notBooted
  case missingToken

  var errorDescription: String? {
    switch self {
    case .unsupported: "CoreSimulator does not support Darwin notification observation"
    case .notBooted: "The simulator must be booted to observe Darwin notifications"
    case .missingToken: "CoreSimulator returned no notification registration token"
    }
  }

  var failureKind: SimulatorFailureKind {
    switch self {
    case .unsupported: .unsupported(capability: "Darwin notification observation")
    case .notBooted: .notReady
    case .missingToken: .failed
    }
  }
}
