/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBDeviceControl
import FBDeviceHID
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift

struct FocusMethodHandler {

  let target: CompanionTarget

  func handle(request: Idb_FocusRequest, context: ServerContext) async throws -> Idb_FocusResponse {
    try await target.simulator().lifecycle.focus()
    return .init()
  }
}

struct OpenUrlMethodHandler {

  let target: CompanionTarget

  func handle(request: Idb_OpenUrlRequest, context: ServerContext) async throws -> Idb_OpenUrlRequest {
    guard let parsed = URL(string: request.url) else {
      throw IDBCommandError.invalidURL(urlString: request.url)
    }
    try await target.simulator().lifecycle.open(parsed)
    return .init()
  }
}

struct SetLocationMethodHandler {

  let target: CompanionTarget

  func handle(request: Idb_SetLocationRequest, context: ServerContext) async throws -> Idb_SetLocationResponse {
    try await target.location.set(longitude: request.location.longitude, latitude: request.location.latitude)
    return .init()
  }
}

struct SimulateMemoryWarningMethodHandler {

  let target: CompanionTarget

  func handle(request: Idb_SimulateMemoryWarningRequest, context: ServerContext) async throws -> Idb_SimulateMemoryWarningResponse {
    try await target.simulator().memory.simulateWarning()
    return .init()
  }
}

struct HingeAngleMethodHandler {
  let target: CompanionTarget

  func handle(request: Idb_HingeAngleRequest, context: ServerContext) async throws -> Idb_HingeAngleResponse {
    let angle = try await target.simulator().hinge.current().degrees
    return .with { $0.angle = angle }
  }
}

struct OrientationMethodHandler {
  let target: CompanionTarget

  func get() async throws -> Idb_GetOrientationResponse {
    if let device = target as? Device {
      return Self.response(try await device.orientation.current())
    }
    return Self.response(try await target.simulator().orientation.current())
  }

  func set(request: Idb_SetOrientationRequest) async throws -> Idb_SetOrientationResponse {
    if let device = target as? Device {
      try await device.orientation.set(Self.physicalOrientation(request.orientation))
    } else {
      try await target.simulator().orientation.set(Self.orientation(request.orientation), convention: .device)
    }
    return .init()
  }

  static func physicalOrientation(_ value: Idb_HIDEvent.HIDOrientationType) throws -> DeviceOrientation {
    switch value {
    case .portrait: .portrait
    case .portraitUpsideDown: .portraitUpsideDown
    case .landscapeLeft: .landscapeLeft
    case .landscapeRight: .landscapeRight
    case .UNRECOGNIZED: throw RPCError(code: .invalidArgument, message: "Unrecognized orientation type")
    }
  }

  static func response(_ orientation: DeviceOrientation) -> Idb_GetOrientationResponse {
    .with {
      switch orientation {
      case .unknown: $0.orientation = .unknown
      case .portrait: $0.orientation = .portrait
      case .portraitUpsideDown: $0.orientation = .portraitUpsideDown
      case .landscapeLeft: $0.orientation = .landscapeLeft
      case .landscapeRight: $0.orientation = .landscapeRight
      case .faceUp: $0.orientation = .faceUp
      case .faceDown: $0.orientation = .faceDown
      }
    }
  }

  static func response(_ orientation: SimulatorDeviceOrientation) -> Idb_GetOrientationResponse {
    .with {
      switch orientation {
      case .unknown: $0.orientation = .unknown
      case .portrait: $0.orientation = .portrait
      case .portraitUpsideDown: $0.orientation = .portraitUpsideDown
      case .landscapeLeft: $0.orientation = .landscapeLeft
      case .landscapeRight: $0.orientation = .landscapeRight
      case .faceUp: $0.orientation = .faceUp
      case .faceDown: $0.orientation = .faceDown
      }
    }
  }

  /// Shared with the HID stream, which carries the same orientation type in a different convention.
  static func orientation(_ value: Idb_HIDEvent.HIDOrientationType) throws -> SimulatorHIDDeviceOrientation {
    switch value {
    case .portrait: return .portrait
    case .portraitUpsideDown: return .portraitUpsideDown
    case .landscapeLeft: return .landscapeLeft
    case .landscapeRight: return .landscapeRight
    case .UNRECOGNIZED: throw RPCError(code: .invalidArgument, message: "Unrecognized orientation type")
    }
  }
}
