/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBDeviceControl
import Foundation
internal import IDBConcurrency

/// Owns local operation admission, not a reusable CoreDevice connection.
public final class DeviceHIDCommands: Sendable {
  private struct State {
    weak var device: Device?
    var operationID: UUID?
    var operation: DeviceHIDOperation?
    var cancelled = false
    var uncertain = false

    func checkAdmission(_ id: UUID) throws {
      guard !uncertain else { throw DeviceHIDError.uncertainState }
      guard operationID == id, !cancelled else { throw CancellationError() }
    }
  }

  private let state: Atomic<State>
  private let prepare: @Sendable (String, Double, Double, TimeInterval?) async throws -> DeviceHIDPreparedTap
  private let checkRuntime: @Sendable () async throws -> Void
  private let makeTransport: @Sendable (UUID) -> DeviceDigitizerHIDTransport
  private let prepareTouch: @Sendable (String, DeviceHIDTouchSequence) async throws -> DeviceHIDPreparedTouch

  init(
    device: Device,
    prepare: @escaping @Sendable (String, Double, Double, TimeInterval?) async throws -> DeviceHIDPreparedTap = {
      try await DeviceHIDPreparation.prepare(udid: $0, x: $1, y: $2, duration: $3)
    },
    checkRuntime: @escaping @Sendable () async throws -> Void = { try await DeviceHIDRuntime.checkAsync() },
    makeTransport: @escaping @Sendable (UUID) -> DeviceDigitizerHIDTransport = { DeviceDigitizerHIDTransport(deviceIdentifier: $0) },
    prepareTouch: @escaping @Sendable (String, DeviceHIDTouchSequence) async throws -> DeviceHIDPreparedTouch = { try await DeviceHIDPreparation.prepare(udid: $0, sequence: $1) }
  ) {
    state = Atomic(wrappedValue: State(device: device))
    self.prepare = prepare
    self.checkRuntime = checkRuntime
    self.makeTransport = makeTransport
    self.prepareTouch = prepareTouch
  }

  /// Coordinates are display points. A nil or zero duration adds no intentional hold.
  /// Success reports local native returns, not a remote delivery acknowledgment.
  public func tap(x: Double, y: Double, duration: TimeInterval?) async throws {
    guard x.isFinite, y.isFinite, x >= 0, y >= 0,
      duration.map({ $0.isFinite && $0 >= 0 }) ?? true
    else { throw DeviceHIDError.preparationFailed("Coordinates and duration must be finite and nonnegative") }
    try await perform { udid in
      DeviceHIDPreparedTouch(start: try await self.prepare(udid, x, y, duration), positions: [])
    }
  }

  /// Sends a complete, bounded down/move/up recipe; it never leaves a contact held for a later call.
  public func touch(_ sequence: DeviceHIDTouchSequence) async throws {
    try await perform { udid in try await self.prepareTouch(udid, sequence) }
  }

  private func perform(_ prepare: @Sendable (String) async throws -> DeviceHIDPreparedTouch) async throws {
    let id = UUID()
    let udid: String = try {
      let device = try state.sync { state -> Device in
        guard !state.uncertain else { throw DeviceHIDError.uncertainState }
        guard state.operationID == nil else { throw DeviceHIDError.busy }
        guard let device = state.device else { throw DeviceHIDError.deviceUnavailable }
        state.operationID = id
        state.cancelled = false
        return device
      }
      return device.udid
    }()
    defer {
      let retired = state.sync { state -> DeviceHIDOperation? in
        guard state.operationID == id else { return nil }
        let retired = state.operation
        state.operation = nil
        state.operationID = nil
        state.cancelled = false
        return retired
      }
      withExtendedLifetime(retired) {}
    }
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let prepared = try await prepare(udid)
      try state.sync { try $0.checkAdmission(id) }
      try await checkRuntime()
      try Task.checkCancellation()
      try state.sync { try $0.checkAdmission(id) }
      let operation = DeviceHIDOperation(
        transport: makeTransport(prepared.start.deviceIdentifier),
        prepared: prepared.start,
        positions: prepared.positions,
        quarantine: { [weak self] in
          let active = self?.state.sync { state in
            state.uncertain = true
            if state.operationID != nil { state.cancelled = true }
            return state.operation
          }
          active?.cancel()
        })
      try withExtendedLifetime(operation) {
        try state.sync { state in
          try state.checkAdmission(id)
          state.operation = operation
        }
      }
      let outcome = await operation.run()
      if let error = outcome.error { throw error }
    } onCancel: {
      let operation = self.state.sync { state -> DeviceHIDOperation? in
        guard state.operationID == id else { return nil }
        state.cancelled = true
        return state.operation
      }
      operation?.cancel()
    }
  }
}
