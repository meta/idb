/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorServices
import GRPCCore
import IDBGRPCSwift

struct ApproveMethodHandler {

  let target: CompanionTarget

  func handle(request: Idb_ApproveRequest, context: ServerContext) async throws -> Idb_ApproveResponse {

    let mapping: [Idb_ApproveRequest.Permission: TargetSettingsService] = [
      .microphone: .microphone,
      .photos: .photos,
      .camera: .camera,
      .contacts: .contacts,
      .url: .url,
      .location: .location,
      .notification: .notification,
    ]

    let (services, includesURL) = try settingsServices(request.permissions, mapping: mapping)
    if includesURL {
      try await target.simulator().privacy.grantAccess(Set([request.bundleID]), toDeeplink: request.scheme)
    }

    if !services.isEmpty {
      try await target.simulator().privacy.grantAccess(Set([request.bundleID]), toServices: services)
    }
    return .init()
  }
}

struct RevokeMethodHandler {

  let target: CompanionTarget

  func handle(request: Idb_RevokeRequest, context: ServerContext) async throws -> Idb_RevokeResponse {

    let mapping: [Idb_RevokeRequest.Permission: TargetSettingsService] = [
      .microphone: .microphone,
      .photos: .photos,
      .camera: .camera,
      .contacts: .contacts,
      .url: .url,
      .location: .location,
      .notification: .notification,
    ]

    let (services, includesURL) = try settingsServices(request.permissions, mapping: mapping)
    if includesURL {
      try await target.simulator().privacy.revokeAccess(Set([request.bundleID]), toDeeplink: request.scheme)
    }

    if !services.isEmpty {
      try await target.simulator().privacy.revokeAccess(Set([request.bundleID]), toServices: services)
    }
    return .init()
  }
}

/// The services `permissions` name, with the URL scheme permission split out: it is granted or revoked
/// per deeplink rather than as a service.
private func settingsServices<Permission: Hashable>(
  _ permissions: [Permission], mapping: [Permission: TargetSettingsService]
) throws -> (services: Set<TargetSettingsService>, includesURL: Bool) {
  var services = try Set(
    permissions.map { permission -> TargetSettingsService in
      guard let service = mapping[permission] else {
        throw RPCError(code: .invalidArgument, message: "Unrecognized permission \(permission)")
      }
      return service
    }
  )
  let includesURL = services.remove(.url) != nil
  return (services, includesURL)
}
