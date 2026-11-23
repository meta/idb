/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import Darwin
import FBControlCore
import FBControlCoreObjC
import Foundation

/// Informal protocol for messaging the runtime-only `SimDeviceLegacyHIDClient`. The class has moved
/// between frameworks across Xcodes and is dlopened on demand, so it is never referenced as a Swift
/// type: that would emit a link-time `_OBJC_CLASS_$_` symbol pinned to one framework. It is looked up
/// by name, allocated via `ObjCRuntimeClass`, and messaged via `unsafeBitCast` to this protocol.
///
/// Every send through this protocol has to be guarded with `FBObjCExceptionGuard`. It lands in
/// CoreSimulator code that asserts on state this process does not own — a device that has been
/// shut down, a `SimDeviceIO` connection that has gone away — and an `NSException` unwinding
/// through a Swift frame reaches `libc++abi` and aborts the companion.
@objc private protocol SimDeviceLegacyHIDClientMessaging {
  @objc(initWithDevice:error:)
  func initWithDevice(_ device: Any, error: AutoreleasingUnsafeMutablePointer<AnyObject?>?) -> AnyObject?

  @objc(sendWithMessage:freeWhenDone:completionQueue:completion:)
  func send(
    withMessage message: UnsafeMutableRawPointer,
    freeWhenDone: Bool,
    completionQueue: DispatchQueue,
    completion: @escaping @Sendable ((any Error)?) -> Void)
}

/**
 Owns the runtime-only SimulatorKit `SimDeviceLegacyHIDClient` and delivers Indigo message bytes to
 it (the IndigoHIDRegistrationPort transport). The concrete class is looked up by name and messaged
 via `unsafeBitCast` — it has relocated across Xcodes, so no link-time class reference is emitted.

 Message sends are serialized onto the private `queue`, so the type is `@unchecked Sendable`.

 A send returns once its message is handed to the client, without waiting for the acknowledgement:
 the wait would otherwise become hold time in the guest, where a key-down left waiting on its
 acknowledgement repeats. `acknowledged()` waits for them instead.
 */
final class SimulatorIndigoHIDClient: @unchecked Sendable {

  private static let clientClassName = "SimulatorKit.SimDeviceLegacyHIDClient"

  /// The queue on which messages are sent to the HID server.
  private let queue: DispatchQueue
  // Untyped on purpose: the concrete `SimDeviceLegacyHIDClient` is a runtime-only class (see
  // SimDeviceLegacyHIDClientMessaging). Messaged via unsafeBitCast to that protocol.
  private var client: AnyObject?
  // Accessed only on `queue`, which is also where the client delivers acknowledgements.
  private var pendingAcknowledgements = 0
  private var firstDeliveryFailure: (any Error)?
  private var acknowledgementWaiters: [CheckedContinuation<Void, any Error>] = []

  /// Resolves the runtime-only `SimDeviceLegacyHIDClient` class, dlopening the Xcode frameworks that
  /// vend it first — `FBSimulatorControl` itself loads only the essential set (CoreSimulator), so
  /// otherwise there is nothing for the lookup to find. Mirrors `SimulatorIndigoHID.init()`.
  static func resolveClientClass(
    loader: any FrameworkLoading = SimulatorControlFrameworkLoader.xcodeFrameworks
  ) throws -> ObjCRuntimeClass {
    try loader.loadPrivateFrameworks(nil)
    guard let clientClass = ObjCRuntimeClass(name: clientClassName) else {
      throw SimulatorHIDError.clientClassUnavailable(className: clientClassName)
    }
    return clientClass
  }

  /// Looks up, allocates and initializes the runtime-only HID client for the provided device.
  convenience init(for device: SimDevice) throws {
    try self.init(device: device, clientClass: Self.resolveClientClass())
  }

  /// Allocates and initializes `clientClass` for `device`.
  convenience init(device: Any, clientClass: ObjCRuntimeClass) throws {
    var clientError: AnyObject?
    let client: AnyObject
    do {
      client = try clientClass.instantiate(as: (any SimDeviceLegacyHIDClientMessaging).self) {
        unsafe $0.initWithDevice(device, error: &clientError)
      }
    } catch {
      // `clientError` first: when the client declines by contract it says why, and that is more
      // specific than "the initializer returned nil".
      throw SimulatorHIDError.clientCreationFailed(
        clientClass: clientClass.name, underlying: (clientError as? any Error) ?? error)
    }
    self.init(
      client: client, queue: DispatchQueue(label: "com.facebook.fbsimulatorcontrol.hid"))
  }

  private init(client: AnyObject, queue: DispatchQueue) {
    self.client = client
    self.queue = queue
  }

  /// Disconnects from the remote HID by releasing the client.
  func disconnect() {
    client = nil
  }

  /// Sends the message bytes, returning once the client has taken them. A failed delivery is reported
  /// by `acknowledged()`.
  ///
  /// The send is made on `queue`, which serializes it against the `disconnect()` that can arrive
  /// from any thread.
  func send(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        // The event is delivered asynchronously. Copy the message and let the client manage its lifecycle:
        // the free of the buffer is performed by the client (freeWhenDone) and the Data frees when out of scope.
        let size = data.count
        guard let raw = unsafe malloc(size) else {
          fatalError("Failed to allocate \(size) bytes for an Indigo message")
        }
        unsafe data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
          guard let base = buffer.baseAddress else { return }
          unsafe raw.copyMemory(from: base, byteCount: size)
        }
        guard let client else {
          unsafe free(raw)
          continuation.resume(throwing: SimulatorHIDError.clientDisposed)
          return
        }
        // Counted before sending, as the client may acknowledge before `send` returns.
        pendingAcknowledgements += 1
        do {
          try FBObjCExceptionGuard.run {
            unsafe unsafeBitCast(client, to: (any SimDeviceLegacyHIDClientMessaging).self)
              .send(withMessage: raw, freeWhenDone: true, completionQueue: queue) { [self] error in
                settleAcknowledgement(error)
              }
          }
          continuation.resume()
        } catch {
          // `raw` is deliberately not freed. Ownership passes to the client with `freeWhenDone`, and a
          // raise leaves no way to tell whether it got that far; one leaked message beats a double free.
          //
          // Uncounting here assumes the client cannot have already completed before raising — true of
          // every observed raise, which come from `-[SimDeviceIOClient ioPorts]` on the way in.
          pendingAcknowledgements -= 1
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Returns once the client has acknowledged every message sent so far, throwing the first delivery
  /// failure among the messages acknowledged since the last call.
  func acknowledged() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        acknowledgementWaiters.append(continuation)
        if pendingAcknowledgements == 0 {
          resumeAcknowledgementWaiters()
        }
      }
    }
  }

  private func settleAcknowledgement(_ error: (any Error)?) {
    dispatchPrecondition(condition: .onQueue(queue))
    if let error, firstDeliveryFailure == nil {
      firstDeliveryFailure = error
    }
    pendingAcknowledgements -= 1
    if pendingAcknowledgements == 0 {
      resumeAcknowledgementWaiters()
    }
  }

  private func resumeAcknowledgementWaiters() {
    // With nobody waiting, a failure is kept for the next `acknowledged()` to report.
    guard !acknowledgementWaiters.isEmpty else {
      return
    }
    let failure = firstDeliveryFailure
    let waiters = acknowledgementWaiters
    firstDeliveryFailure = nil
    acknowledgementWaiters = []
    for waiter in waiters {
      if let failure {
        waiter.resume(throwing: failure)
      } else {
        waiter.resume()
      }
    }
  }
}
