/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import IOKit

/// The transport for vendor-defined HID reports: the hinge slider and the orientation picker of a
/// simulator whose runtime reports device motion. `dtuhidd` serves them on a service of their own,
/// beside the digitizer, so this is a second DTUHID connection rather than a second use of the
/// first.
///
/// Established on first use, since most simulators never send one, and then kept so a rotation or
/// hinge change costs a send rather than a connect, a liveness probe and a disconnect. A connection
/// that could not be established is attempted again on the next send.
///
/// One per simulator, owned by `simulator.hid` and dropped with its input connection when the
/// simulator changes state, since a connection made before a reboot is dead.
actor SimulatorVendorHIDTransport {
  typealias Connect = @Sendable () async throws -> SimulatorDTUHIDConnection

  static let serviceName = "com.apple.coredevice.feature.remote.hid.vendordefined"

  private let connection: SimulatorSharedConnection<SimulatorDTUHIDConnection>

  init(simulator: Simulator?) {
    self.init { [weak simulator] in
      guard let simulator else { throw WeakTargetError.simulator }
      return try await SimulatorDTUHIDConnection.connect(using: simulator.xpc, serviceName: Self.serviceName)
    }
  }

  init(connect: @escaping Connect) {
    connection = SimulatorSharedConnection(connect)
  }

  /// Sends one report and drains it, so the guest has acted on it when this returns.
  func send(_ event: IndigoVendorDefinedEvent) async throws {
    let connection = try await self.connection.connection()
    try await connection.send(messageType: "IndigoVendorDefinedEvent", payload: event)
    try await connection.flush()
  }

  /// Tears down the connection, if one was ever established.
  func disconnect() async {
    (try? await connection.reset()?.value)?.disconnect()
  }
}

extension IndigoVendorDefinedEvent {
  /// A report from one of the controls the guest's virtual-machine provider exposes, such as the
  /// hinge slider or the orientation picker.
  static func virtualMachineControl(source: String, type: String, value: Any) throws -> Self {
    let payload: [String: Any] = [
      "provider": "com.apple.Virtualization.VirtualMachines",
      "source": source,
      "type": type,
      "value": value,
    ]
    guard let serialized = IOCFSerialize(payload as CFDictionary, 1) else {
      throw SimulatorHIDError.vendorReportUnserializable(source: source)
    }
    return IndigoVendorDefinedEvent(usagePage: 0xff61, usage: 0x5b, version: 0, data: serialized as Data)
  }
}
