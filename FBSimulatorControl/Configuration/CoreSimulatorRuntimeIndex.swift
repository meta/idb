/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation

final class CoreSimulatorRuntimeIndex {
  let deviceTypes: [SimDeviceType]
  let runtimes: [SimRuntime]
  let index: SimulatorRuntimeIndex

  init(deviceTypes: [SimDeviceType], runtimes: [SimRuntime]) {
    let deviceTypes = deviceTypes.filter { $0.identifier != nil }
    let runtimes = runtimes.filter { $0.identifier != nil }
    self.deviceTypes = deviceTypes
    self.runtimes = runtimes
    self.index = SimulatorRuntimeIndex(
      devices: deviceTypes.map {
        SimulatorRuntimeIndex.Device(identifier: $0.identifier, name: $0.name ?? $0.identifier)
      },
      runtimes: runtimes.map { runtime in
        SimulatorRuntimeIndex.Runtime(
          identifier: runtime.identifier, name: runtime.name ?? runtime.identifier,
          version: runtime.versionString ?? "", build: runtime.buildVersionString ?? "",
          available: runtime.available,
          supportedDevices: Set(deviceTypes.filter { runtime.supportsDeviceType($0) }.compactMap { $0.identifier }))
      })
  }

  /// The device types and runtimes the shared CoreSimulator service supports.
  convenience init() throws {
    let service = try SimulatorServiceContext.sharedServiceContext()
    self.init(deviceTypes: service.supportedDeviceTypes(), runtimes: service.supportedRuntimes())
  }

  func resolve(_ request: SimulatorCreationRequest) throws -> (SimDeviceType, SimRuntime) {
    let match = try index.resolve(request)
    return (deviceTypes[match.device], runtimes[match.runtime])
  }
}
