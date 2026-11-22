/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
internal import FBControlCore
internal import FBControlCoreObjC
import Foundation

#if arch(arm64)
@_weakLinked internal import CoreDevice

enum DeviceHIDDisplaySource {
  static func consume(device: RemoteDevice, receive: @escaping @Sendable (DeviceHIDDisplaySnapshot) -> Void) async throws {
    let implementation = try await DeviceHIDTransport.checkedImplementation(
      for: CapabilityStaticMember<DisplayInfoCapability>(), on: device, as: (any DisplayInfoProtocol).self)
    try Task.checkCancellation()
    let updates = try await implementation.displayInfoUpdates()
    for try await value in updates {
      try Task.checkCancellation()
      let observed = try FBObjCExceptionGuard.guarded { try snapshot(value) }
      receive(observed)
    }
  }

  private static func snapshot(_ value: DisplayInfo) throws -> DeviceHIDDisplaySnapshot {
    let orientation = value.orientation
    let displays = value.displays
    guard displays.count <= 64 else { throw DeviceHIDError.preparationFailed("Display observation exceeds the display count bound") }
    return DeviceHIDDisplaySnapshot(
      displays: displays.map { display in
        let integrated: Bool
        switch display.type {
        case .integrated: integrated = true
        default: integrated = false
        }
        return DeviceHIDDisplaySnapshot.Display(
          identifier: display.displayId, primary: display.primary, integrated: integrated,
          bounds: display.bounds, nativeSize: display.nativeSize, pointScale: Double(display.pointScale),
          nativeOrientation: display.nativeOrientation, currentOrientation: display.currentOrientation)
      },
      orientation: orientation.map { mapped($0.currentDeviceOrientation) },
      nonFlatOrientation: orientation.map { mapped($0.currentDeviceNonFlatOrientation) })
  }

  private static func mapped(_ orientation: CoreDevice.DeviceOrientation) -> DeviceHIDDisplaySnapshot.Orientation {
    switch orientation {
    case .portrait: return .portrait
    case .faceUp: return .faceUp
    default: return .unsupported
    }
  }
}
#endif
