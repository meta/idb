/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Dispatch
internal import FBControlCore
internal import FBControlCoreObjC
import Foundation
internal import IDBConcurrency

#if arch(arm64)
@_weakLinked internal import CoreDevice
#endif

/// The operation supplies the thread, concrete payload, and contact ordering.
final class DeviceHIDTransport: Sendable {
  enum Kind: Sendable { case digitizer, button }

  let acquire: @Sendable (@escaping @Sendable (Result<DeviceHIDAssertion, any Error>) -> Void) throws -> DeviceHIDCancellation
  let makeCapability: @Sendable (@escaping @Sendable (Result<Void, any Error>) -> Void) throws -> DeviceHIDCancellation
  let send: @Sendable (DeviceHIDContactPhase, DeviceHIDContact) throws -> Void
  let barrier: @Sendable () throws -> Void
  let discard: @Sendable () -> Void

  #if arch(arm64)
  private struct Assertion {
    let value: DeviceUsageAssertion
    var released = false
  }

  private struct State {
    var device: RemoteDevice?
    var digitizer: (any HIDDigitizer)?
    var button: (any HIDButton)?
    var assertions: [UUID: Assertion] = [:]
    var assertionKeys: [ObjectIdentifier: UUID] = [:]
    var retired = false
  }

  // Specialization must not replace C.ProtocolType with a caller-assumed HID
  // existential or remove the dynamic check at this private ABI boundary.
  @_optimize(none)
  @inline(never)
  private static func checkedImplementation<C: DeviceCapability, Implementation>(
    for capability: CapabilityStaticMember<C>,
    on device: RemoteDevice,
    as implementationType: Implementation.Type
  ) async throws -> Implementation {
    let value: C.ProtocolType = try await device.getImplementation(for: capability)
    guard let implementation = value as? Implementation else {
      throw DeviceHIDError.unsupportedRuntime("CoreDevice returned an unexpected HID implementation")
    }
    return implementation
  }

  /// Called only after DeviceHIDRuntime.check has returned successfully.
  convenience init(deviceIdentifier: UUID, kind: Kind = .digitizer) {
    let state = Atomic(wrappedValue: State())
    self.init(
      acquire: { completion in
        let device = try FBObjCExceptionGuard.guarded {
          let matches = DeviceManager.shared.allDevices().filter { $0.id == deviceIdentifier }
          guard matches.count == 1, let device = matches.first else {
            throw DeviceHIDError.deviceMatchFailed(identifier: deviceIdentifier, count: matches.count)
          }
          return device
        }
        try withExtendedLifetime(device) {
          try state.sync { state in
            guard !state.retired else { throw CancellationError() }
            state.device = device
          }
        }
        let progress = try FBObjCExceptionGuard.guarded {
          device.acquireDeviceUsageAssertion(
            withReason: "idb physical input",
            requirements: UsageAssertionRequirements(deviceStates: [], capabilities: []),
            invokingCompletionHandlerOn: .global()
          ) { result in
            switch result {
            case .failure(let error):
              completion(.failure(error))
            case .success(let assertion):
              // Keys identify retained caller-owned objects, not a device/session ownership registry.
              let id = state.sync { state -> UUID in
                let object = ObjectIdentifier(assertion)
                if let id = state.assertionKeys[object] { return id }
                let id = UUID()
                state.assertionKeys[object] = id
                state.assertions[id] = Assertion(value: assertion)
                return id
              }
              completion(
                .success(
                  DeviceHIDAssertion(
                    identifier: id,
                    release: {
                      let assertion = state.sync { state -> DeviceUsageAssertion? in
                        guard var assertion = state.assertions[id], !assertion.released else { return nil }
                        assertion.released = true
                        state.assertions[id] = assertion
                        return assertion.value
                      }
                      if let assertion { try FBObjCExceptionGuard.guarded { assertion.releaseAssertion() } }
                    },
                    observe: { invalidated in
                      let assertion = try state.sync { state -> DeviceUsageAssertion in
                        guard let assertion = state.assertions[id], !assertion.released else { throw CancellationError() }
                        return assertion.value
                      }
                      try FBObjCExceptionGuard.guarded {
                        assertion.registerInvalidationHandler(invokingOnQueue: .global()) { _ in invalidated() }
                      }
                    })))
            }
          }
        }
        return { try FBObjCExceptionGuard.guarded { progress.cancel() } }
      },
      makeCapability: { completion in
        let task = Task.detached {
          do {
            let device = try state.sync { state -> RemoteDevice in
              guard !state.retired, let device = state.device else { throw CancellationError() }
              return device
            }
            // A synchronous Objective-C exception guard cannot span this async Swift call.
            switch kind {
            case .digitizer:
              let digitizer = try await Self.checkedImplementation(for: CapabilityStaticMember<DigitizerHIDCapability>(), on: device, as: (any HIDDigitizer).self)
              try withExtendedLifetime(digitizer) {
                try state.sync { state in
                  guard !state.retired else { throw CancellationError() }
                  state.digitizer = digitizer
                }
              }
            case .button:
              let button = try await Self.checkedImplementation(for: CapabilityStaticMember<ButtonHIDCapability>(), on: device, as: (any HIDButton).self)
              try withExtendedLifetime(button) {
                try state.sync { state in
                  guard !state.retired else { throw CancellationError() }
                  state.button = button
                }
              }
            }
            completion(.success(()))
          } catch { completion(.failure(error)) }
        }
        return { task.cancel() }
      },
      send: { phase, contact in
        switch contact {
        case let .touch(point, secondPoint):
          let digitizer = try state.sync { state -> any HIDDigitizer in
            guard !state.retired, let digitizer = state.digitizer else { throw CancellationError() }
            return digitizer
          }
          try FBObjCExceptionGuard.guarded {
            let event: DigitizerEventType
            switch phase {
            case .start: event = .start
            case .position: event = .position
            case .end: event = .end
            }
            try digitizer.send(pointOne: point, pointTwo: secondPoint, eventType: event, edge: .none, target: .mainScreen)
          }
        case let .button(selected):
          let button = try state.sync { state -> any HIDButton in
            guard !state.retired, let button = state.button else { throw CancellationError() }
            return button
          }
          try FBObjCExceptionGuard.guarded {
            let code: HIDUsageCode<ConsumerPage>
            switch selected {
            case .home: code = .home
            case .volumeUp: code = .volumeIncrement
            case .volumeDown: code = .volumeDecrement
            }
            let buttonState: HIDButtonState
            switch phase {
            case .start: buttonState = .down
            case .end: buttonState = .up
            case .position: throw DeviceHIDError.preparationFailed("A button contact cannot move")
            }
            try button.sendButton(page: .consumer, code: code, state: buttonState)
          }
        }
      },
      barrier: {
        switch kind {
        case .digitizer:
          let digitizer = try state.sync { state -> any HIDDigitizer in
            guard !state.retired, let digitizer = state.digitizer else { throw CancellationError() }
            return digitizer
          }
          try FBObjCExceptionGuard.guarded { digitizer.sendBarrier() }
        case .button:
          let button = try state.sync { state -> any HIDButton in
            guard !state.retired, let button = state.button else { throw CancellationError() }
            return button
          }
          try FBObjCExceptionGuard.guarded { button.sendBarrier() }
        }
      },
      discard: {
        let retired = state.sync { state in
          let retired = (state.digitizer, state.button, state.device)
          state.retired = true
          state.digitizer = nil
          state.button = nil
          state.device = nil
          return retired
        }
        withExtendedLifetime(retired) {}
      })
  }
  #else
  convenience init(deviceIdentifier: UUID, kind: Kind = .digitizer) {
    self.init(
      acquire: { _ in throw DeviceHIDError.unsupportedRuntime("Native arm64 is required") },
      makeCapability: { _ in throw DeviceHIDError.unsupportedRuntime("Native arm64 is required") },
      send: { _, _ in throw DeviceHIDError.unsupportedRuntime("Native arm64 is required") },
      barrier: { throw DeviceHIDError.unsupportedRuntime("Native arm64 is required") },
      discard: {})
  }
  #endif

  init(
    acquire: @escaping @Sendable (@escaping @Sendable (Result<DeviceHIDAssertion, any Error>) -> Void) throws -> DeviceHIDCancellation,
    makeCapability: @escaping @Sendable (@escaping @Sendable (Result<Void, any Error>) -> Void) throws -> DeviceHIDCancellation,
    send: @escaping @Sendable (DeviceHIDContactPhase, DeviceHIDContact) throws -> Void,
    barrier: @escaping @Sendable () throws -> Void,
    discard: @escaping @Sendable () -> Void
  ) {
    self.acquire = acquire
    self.makeCapability = makeCapability
    self.send = send
    self.barrier = barrier
    self.discard = discard
  }
}
