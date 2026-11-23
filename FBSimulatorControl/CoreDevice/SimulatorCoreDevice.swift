/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation
import XPC

/// How a CoreDevice feature fails. Callers switch on `unsupported` to choose a fallback; the other
/// three are operational and surface as they are.
package enum SimulatorCoreDeviceError: Error, LocalizedError, Equatable {
  /// The runtime does not vend the feature, field or capability named.
  case unsupported(String)
  /// The service exists but could not be reached or answered with an error.
  case unavailable(String)
  /// The service answered with something the protocol does not describe.
  case malformed(String)
  /// The service did not answer within the request's deadline.
  case timedOut

  package var errorDescription: String? {
    switch self {
    case let .unsupported(detail): "Simulator CoreDevice capability not supported: \(detail)"
    case let .unavailable(detail): "Simulator CoreDevice service unavailable: \(detail)"
    case let .malformed(detail): "Invalid simulator CoreDevice response: \(detail)"
    case .timedOut: "Timed out waiting for the simulator CoreDevice reply"
    }
  }
}

enum SimulatorCoreDevice {
  static let cancellationKey = "CoreDevice.XPCMessageKey.cancellationRequested"

  /// Decodes a reply object; a failure means the peer answered with something the protocol does not describe.
  static func decode<T: Decodable>(_ type: T.Type, from object: xpc_object_t) throws -> T {
    do {
      return try XPCDecoder().decode(type, from: object)
    } catch let error as DecodingError {
      throw SimulatorCoreDeviceError(decoding: error)
    }
  }

  static func connect(using connector: SimulatorXPCConnector, service: String) throws -> xpc_connection_t {
    do {
      return try connector.connect(service)
    } catch let error as SimulatorXPCConnectionError {
      throw SimulatorCoreDeviceError(connection: error)
    }
  }
}

extension SimulatorCoreDeviceError {
  /// A service the runtime does not vend, and a toolchain without the simulator XPC symbols, are
  /// both a missing capability; everything else is operational.
  init(connection error: SimulatorXPCConnectionError) {
    switch error {
    case .symbolsUnavailable:
      self = .unsupported("Simulator XPC symbols")
    case let .notBooted(service, state):
      self = .unavailable("\(service): the simulator is \(state.stateString.rawValue), not booted")
    case let .lookupFailed(service, underlying):
      self = error.isServiceUnsupported ? .unsupported(service) : .unavailable(underlying?.localizedDescription ?? service)
    case .connectionFailed:
      self = .unavailable("Simulator XPC connection")
    }
  }

  /// A request the peer did not answer.
  init(channel error: SimulatorXPCError) {
    switch error {
    case let .peerUnavailable(detail): self = .unavailable(detail)
    case .timedOut: self = .timedOut
    case .invalidated: self = .unavailable(error.description)
    }
  }

  /// A reply the protocol does not describe, named by the path of the field that broke.
  init(decoding error: DecodingError) {
    let context: DecodingError.Context
    switch error {
    case let .typeMismatch(_, mismatch): context = mismatch
    case let .valueNotFound(_, missing): context = missing
    case let .keyNotFound(key, missing): context = DecodingError.Context(codingPath: missing.codingPath + [key], debugDescription: missing.debugDescription)
    case let .dataCorrupted(corrupted): context = corrupted
    @unknown default: context = DecodingError.Context(codingPath: [], debugDescription: "\(error)")
    }
    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
    self = .malformed(path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)")
  }
}
