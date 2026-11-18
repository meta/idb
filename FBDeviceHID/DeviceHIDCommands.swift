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
    var orientationSetAdmitted = false

    func checkAdmission(_ id: UUID) throws {
      guard !uncertain else { throw DeviceHIDError.uncertainState }
      guard operationID == id, !cancelled else { throw CancellationError() }
    }
  }

  private let state: Atomic<State>
  private let prepare: @Sendable (String, Double, Double, TimeInterval?) async throws -> DeviceHIDPreparedTap
  private let checkRuntime: @Sendable () async throws -> Void
  private let makeTransport: @Sendable (UUID) -> DeviceHIDTransport
  private let prepareTouch: @Sendable (String, DeviceHIDTouchSequence) async throws -> DeviceHIDPreparedTouch
  private let prepareButton: @Sendable (String, DeviceHIDButton, TimeInterval?) async throws -> DeviceHIDPreparedButton
  private let makeButtonTransport: @Sendable (UUID) -> DeviceHIDTransport
  private let orientationTool: DeviceOrientationTool

  init(
    device: Device,
    prepare: @escaping @Sendable (String, Double, Double, TimeInterval?) async throws -> DeviceHIDPreparedTap = {
      try await DeviceHIDPreparation.prepare(udid: $0, x: $1, y: $2, duration: $3)
    },
    checkRuntime: @escaping @Sendable () async throws -> Void = { try await DeviceHIDRuntime.checkAsync() },
    makeTransport: @escaping @Sendable (UUID) -> DeviceHIDTransport = { DeviceHIDTransport(deviceIdentifier: $0) },
    prepareTouch: @escaping @Sendable (String, DeviceHIDTouchSequence) async throws -> DeviceHIDPreparedTouch = { try await DeviceHIDPreparation.prepare(udid: $0, sequence: $1) },
    prepareButton: @escaping @Sendable (String, DeviceHIDButton, TimeInterval?) async throws -> DeviceHIDPreparedButton = { try await DeviceHIDPreparation.prepare(udid: $0, button: $1, duration: $2) },
    makeButtonTransport: @escaping @Sendable (UUID) -> DeviceHIDTransport = { DeviceHIDTransport(deviceIdentifier: $0, kind: .button) },
    orientationTool: DeviceOrientationTool = DeviceOrientationTool()
  ) {
    state = Atomic(wrappedValue: State(device: device))
    self.prepare = prepare
    self.checkRuntime = checkRuntime
    self.makeTransport = makeTransport
    self.prepareTouch = prepareTouch
    self.prepareButton = prepareButton
    self.makeButtonTransport = makeButtonTransport
    self.orientationTool = orientationTool
  }

  /// Coordinates are display points. A nil or zero duration adds no intentional hold.
  /// Success reports local native returns, not a remote delivery acknowledgment.
  public func tap(x: Double, y: Double, duration: TimeInterval?) async throws {
    guard x.isFinite, y.isFinite, x >= 0, y >= 0,
      duration.map({ $0.isFinite && $0 >= 0 }) ?? true
    else { throw DeviceHIDError.preparationFailed("Coordinates and duration must be finite and nonnegative") }
    try await perform { udid in
      .touch(DeviceHIDPreparedTouch(start: try await self.prepare(udid, x, y, duration), positions: []))
    }
  }

  /// Sends a complete, bounded down/move/up recipe; it never leaves a contact held for a later call.
  public func touch(_ sequence: DeviceHIDTouchSequence) async throws {
    try await perform { udid in .touch(try await self.prepareTouch(udid, sequence)) }
  }

  /// Sends one down/optional-hold/up button press, not an idempotent system action.
  public func button(_ button: DeviceHIDButton, duration: TimeInterval? = nil) async throws {
    guard duration.map({ $0.isFinite && $0 >= 0 && $0 < 5 }) ?? true else {
      throw DeviceHIDError.preparationFailed("Button hold must be finite, nonnegative, and less than five seconds")
    }
    try await perform { udid in .button(try await self.prepareButton(udid, button, duration)) }
  }

  func orientation(_ setting: DeviceOrientation?) async throws -> DeviceOrientation {
    let (id, udid) = try admit()
    defer { retire(id) }
    return try await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        let result = try await orientationTool.perform(udid: udid, setting: setting) {
          try Task.checkCancellation()
          try self.state.sync { state in
            try state.checkAdmission(id)
            state.orientationSetAdmitted = true
          }
        }
        try Task.checkCancellation()
        try state.sync { try $0.checkAdmission(id) }
        return result
      } catch {
        let uncertain = state.sync { state in
          guard state.operationID == id, state.orientationSetAdmitted else { return false }
          state.uncertain = true
          return true
        }
        if uncertain { throw DeviceHIDError.orientationMayHaveApplied(error.localizedDescription) }
        throw error
      }
    } onCancel: {
      self.cancel(id)
    }
  }

  private func admit() throws -> (UUID, String) {
    let id = UUID()
    let device = try state.sync { state -> Device in
      guard !state.uncertain else { throw DeviceHIDError.uncertainState }
      guard state.operationID == nil else { throw DeviceHIDError.busy }
      guard let device = state.device else { throw DeviceHIDError.deviceUnavailable }
      state.operationID = id
      state.cancelled = false
      state.orientationSetAdmitted = false
      return device
    }
    return (id, device.udid)
  }

  private func retire(_ id: UUID) {
    let retired = state.sync { state -> DeviceHIDOperation? in
      guard state.operationID == id else { return nil }
      let retired = state.operation
      state.operation = nil
      state.operationID = nil
      state.cancelled = false
      state.orientationSetAdmitted = false
      return retired
    }
    withExtendedLifetime(retired) {}
  }

  private func cancel(_ id: UUID) {
    let operation = state.sync { state -> DeviceHIDOperation? in
      guard state.operationID == id else { return nil }
      state.cancelled = true
      return state.operation
    }
    operation?.cancel()
  }

  private func perform(_ prepare: @Sendable (String) async throws -> DeviceHIDPreparedInput) async throws {
    let (id, udid) = try admit()
    defer { retire(id) }
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let prepared = try await prepare(udid)
      try state.sync { try $0.checkAdmission(id) }
      try await checkRuntime()
      try Task.checkCancellation()
      try state.sync { try $0.checkAdmission(id) }
      let transport: DeviceHIDTransport
      switch prepared {
      case .touch: transport = makeTransport(prepared.deviceIdentifier)
      case .button: transport = makeButtonTransport(prepared.deviceIdentifier)
      }
      let operation = DeviceHIDOperation(
        transport: transport,
        input: prepared,
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
      self.cancel(id)
    }
  }
}
