/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorBridgeProtocol
import Foundation

public enum SimulatorSettingsReading: Equatable, Sendable {
  case available(Bool)
  case unavailable(SimulatorSettingsAvailability)
}

/// The settings whose current values are published by a simulator settings source.
public struct SimulatorSettingsSnapshot: Equatable, Sendable {
  public let reduceMotionEnabled: Bool
  public let reduceTransparency: SimulatorSettingsReading
  public let buttonShapes: SimulatorSettingsReading
  public let increaseContrast: SimulatorSettingsReading

  public init(
    reduceMotionEnabled: Bool,
    reduceTransparency: SimulatorSettingsReading = .unavailable(.unsupported(reason: "Source does not publish Reduce Transparency")),
    buttonShapes: SimulatorSettingsReading = .unavailable(.unsupported(reason: "Source does not publish Button Shapes")),
    increaseContrast: SimulatorSettingsReading = .unavailable(.unsupported(reason: "Source does not publish Increase Contrast"))
  ) {
    self.reduceMotionEnabled = reduceMotionEnabled
    self.reduceTransparency = reduceTransparency
    self.buttonShapes = buttonShapes
    self.increaseContrast = increaseContrast
  }
}

/// Why a simulator settings source could not publish values.
public enum SimulatorSettingsAvailability: Equatable, Sendable {
  /// The runtime, guest, or protocol does not provide the source.
  case unsupported(reason: String)
  /// The simulator may provide the source once its services are ready.
  case notReady(reason: String)
  /// The source failed without saying it can become ready or is permanently absent.
  case failed(reason: String)
}

/// Current simulator settings and the lifecycle of the source that publishes them.
///
/// This is latest-event transport, not history: a terminal event can replace a buffered snapshot.
/// A consumer can retain only the values it observed, and none is authoritative after unavailability.
public enum SimulatorSettingsEvent: Equatable, Sendable {
  case snapshot(SimulatorSettingsSnapshot)
  case unavailable(SimulatorSettingsAvailability)
  /// The guest ended a source that had not already reported unavailability.
  case sourceEnded
}

package struct SimulatorSettingsPublisher: Sendable {
  package typealias Source = @Sendable () async throws -> AsyncThrowingStream<BridgeAXAnswer, any Error>

  private let source: Source

  package init(source: @escaping Source) {
    self.source = source
  }

  package func events() -> AsyncStream<SimulatorSettingsEvent> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        var lastSnapshot: SimulatorSettingsSnapshot?
        var reportedTerminalState = false
        do {
          let frames = try await source()
          for try await answer in frames {
            guard !Task.isCancelled else { break }
            guard let event = try Self.event(from: answer) else { continue }
            switch event {
            case let .snapshot(snapshot):
              guard snapshot != lastSnapshot else { continue }
              lastSnapshot = snapshot
              continuation.yield(event)
            case .unavailable:
              reportedTerminalState = true
              continuation.yield(event)
            case .sourceEnded:
              continue
            }
            if reportedTerminalState { break }
          }
          if !Task.isCancelled && !reportedTerminalState {
            continuation.yield(.sourceEnded)
          }
        } catch {
          if !Task.isCancelled {
            continuation.yield(.unavailable(Self.availability(for: error)))
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  static func event(from answer: BridgeAXAnswer) throws -> SimulatorSettingsEvent? {
    let snapshot: BridgeAXSettingSnapshot
    switch try AXBridgeResponse.outcome(answer, as: BridgeAXSettingSnapshot.self, context: "simulator settings") {
    case let .success(answer):
      snapshot = answer
    case let .failure(failure):
      return .unavailable(Self.availability(errorKind: failure.kind?.rawValue, message: failure.message ?? "the guest reported no detail"))
    }
    guard !snapshot.setting.isEmpty else {
      throw AXBridgeError.guestFailure("simulator settings response was not a settings snapshot")
    }
    guard snapshot.setting == "reduce-motion" || snapshot.setting == "state-settings" else { return nil }
    guard let enabled = snapshot.enabled else {
      throw AXBridgeError.guestFailure("simulator settings response was not a Reduce Motion snapshot")
    }
    guard snapshot.setting == "state-settings" else {
      return .snapshot(SimulatorSettingsSnapshot(reduceMotionEnabled: enabled))
    }
    return .snapshot(
      SimulatorSettingsSnapshot(
        reduceMotionEnabled: enabled,
        reduceTransparency: try reading(snapshot.otherSettings["reduce-transparency"]),
        buttonShapes: try reading(snapshot.otherSettings["button-shapes"]),
        increaseContrast: try reading(snapshot.otherSettings["increase-contrast"])))
  }

  private static func reading(_ outcome: BridgeAXOutcome<BridgeAXSettingResponse>?) throws -> SimulatorSettingsReading {
    switch outcome {
    case nil:
      throw AXBridgeError.guestFailure("simulator settings response omitted an observed setting")
    case let .success(setting)?:
      return .available(setting.enabled)
    case let .failure(failure)?:
      return .unavailable(availability(errorKind: failure.kind?.rawValue, message: failure.message ?? "Setting read failed"))
    }
  }

  static func availability(errorKind: String?, message: String) -> SimulatorSettingsAvailability {
    guard let errorKind else { return .failed(reason: message) }
    switch errorKind {
    case BridgeAXWire.ErrorKind.capabilityUnavailable.rawValue, BridgeAXWire.ErrorKind.badRequest.rawValue:
      return .unsupported(reason: message)
    case BridgeAXWire.ErrorKind.applicationUnavailable.rawValue,
      BridgeAXWire.ErrorKind.applicationNotResponding.rawValue,
      BridgeAXWire.ErrorKind.frontmostUnresolved.rawValue:
      return .notReady(reason: message)
    case BridgeAXWire.ErrorKind.readerUnavailable.rawValue,
      BridgeAXWire.ErrorKind.assertionFailed.rawValue,
      BridgeAXWire.ErrorKind.runtimeFailed.rawValue:
      return .failed(reason: message)
    default:
      return .failed(reason: message)
    }
  }

  static func availability(for error: any Error) -> SimulatorSettingsAvailability {
    let reason = error.localizedDescription
    switch SimulatorFailureKind(error) {
    case let .unsupported(capability):
      return .unsupported(reason: capability)
    case .notReady:
      return .notReady(reason: reason)
    case .failed:
      if case AXBridgeError.bridgeUnavailable = error {
        return .unsupported(reason: reason)
      }
      return .failed(reason: reason)
    }
  }
}
