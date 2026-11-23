/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import XPC

/// An available touchscreen, joined to display snapshots by stable identity.
package struct SimulatorTouchscreen: Equatable, Sendable {
  let displayUniqueID: String
  /// The explicit target accepted by the Indigo digitizer service.
  let digitizerTarget: UInt32
}

/// The universal HID service's `connectedServices` listing, of which the touchscreens are the
/// digitizer-page records that carry a display identity.
enum SimulatorTouchscreenProtocol {
  static let service = "com.apple.coredevice.feature.remote.universalhidservice"

  private struct Request: Encodable {
    struct Payload: Encodable {
      struct ConnectedServices: Encodable {}
      let connectedServices = ConnectedServices()
    }
    let isBarrier = false
    let payload = Payload()
  }

  static func request() throws -> xpc_object_t {
    try XPCEncoder().encode(Request())
  }

  /// The reply as the provider sends it: every HID service, with only the touchscreens read further.
  struct Reply: Decodable {
    /// One connected HID service. Only a digitizer-page touchscreen record is inspected beyond its
    /// usage; the keyboards, trackpads and buttons beside it can carry anything.
    struct Service: Decodable {
      struct Touchscreen {
        let serviceID: UInt64
        let displayUUID: String?
      }

      let touchscreen: Touchscreen?

      private enum CodingKeys: String, CodingKey {
        case primaryUsagePage = "PrimaryUsagePage"
        case primaryUsage = "PrimaryUsage"
        case serviceID = "_ServiceID"
        case displayUUID
      }

      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let page = try container.decodeIfPresent(XPCValue.self, forKey: .primaryUsagePage)
        let usage = try container.decodeIfPresent(XPCValue.self, forKey: .primaryUsage)
        guard page == .uint64(0x0D), usage == .uint64(0x04) else {
          touchscreen = nil
          return
        }
        touchscreen = Touchscreen(
          serviceID: try container.decode(UInt64.self, forKey: .serviceID),
          displayUUID: try container.decodeIfPresent(String.self, forKey: .displayUUID))
      }
    }

    let connectedServices: [Service]
  }

  private static let maximumServices = 256
  private static let maximumIdentityLength = 1024

  static func touchscreens(_ reply: xpc_object_t) throws -> [SimulatorTouchscreen] {
    let services = try SimulatorCoreDevice.decode(Reply.self, from: reply).connectedServices
    guard services.count <= maximumServices else {
      throw SimulatorCoreDeviceError.malformed("Too many HID services")
    }
    var identities: Set<String> = []
    var targets: Set<UInt32> = []
    var touchscreens: [SimulatorTouchscreen] = []
    var missingIdentity = false
    for service in services {
      guard let touchscreen = service.touchscreen else { continue }
      // HIDServiceID.touchscreenDisplayID accepts the 0x100 namespace. Indigo target zero is a main-screen alias.
      guard touchscreen.serviceID & ~0xFF == 0x100, touchscreen.serviceID & 0xFF != 0 else {
        throw SimulatorCoreDeviceError.malformed("HID service has no explicit touchscreen target")
      }
      let target = UInt32(touchscreen.serviceID & 0xFF)
      guard let uniqueID = touchscreen.displayUUID else {
        missingIdentity = true
        continue
      }
      guard !uniqueID.isEmpty, uniqueID.utf8.count <= maximumIdentityLength else {
        throw SimulatorCoreDeviceError.malformed("Invalid touchscreen display identity")
      }
      guard targets.insert(target).inserted else {
        throw SimulatorCoreDeviceError.malformed("Ambiguous touchscreen target")
      }
      guard identities.insert(uniqueID).inserted else {
        throw SimulatorCoreDeviceError.malformed("Ambiguous touchscreen display identity")
      }
      touchscreens.append(SimulatorTouchscreen(displayUniqueID: uniqueID, digitizerTarget: target))
    }
    if missingIdentity {
      guard touchscreens.isEmpty else { throw SimulatorCoreDeviceError.malformed("Partial touchscreen display identities") }
      throw SimulatorCoreDeviceError.unsupported("Touchscreen display identities")
    }
    return touchscreens.sorted { $0.displayUniqueID < $1.displayUniqueID }
  }
}
