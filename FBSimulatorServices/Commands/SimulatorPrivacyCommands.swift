/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
@preconcurrency import FBControlCore
import FBSimulatorControl
@preconcurrency import Foundation

public enum SimulatorPrivacyError: Error {
  case noDataDirectoryForPlists
  case noServicesToGrant(bundleIDs: Set<String>)
  case noBundleIDsToGrant(services: Set<TargetSettingsService>)
  case unhandledGrantServices(services: Set<TargetSettingsService>)
  case noServicesToRevoke(bundleIDs: Set<String>)
  case noBundleIDsToRevoke(services: Set<TargetSettingsService>)
  case unhandledRevokeServices(services: Set<TargetSettingsService>)
  case emptyScheme(operation: String)
  case emptyBundleIDs(operation: String)
  case schemeApprovalPlistUnreadable(path: String)
  case schemeApprovalDirectoryCreationFailed(underlying: Error)
  case schemeApprovalPlistWriteFailed
  case schemeApprovalUnavailable(state: TargetState)
}

extension SimulatorPrivacyError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .noDataDirectoryForPlists:
      return "The Simulator has no data directory, so its plists cannot be located"
    case let .noServicesToGrant(bundleIDs):
      return "Cannot approve any services for \(bundleIDs) since no services were provided"
    case let .noBundleIDsToGrant(services):
      return "Cannot approve \(services) since no bundle ids were provided"
    case let .unhandledGrantServices(services):
      return "Cannot approve \(CollectionInformation.oneLineDescription(from: Array(services))) since there is no handling of it"
    case let .noServicesToRevoke(bundleIDs):
      return "Cannot revoke any services for \(bundleIDs) since no services were provided"
    case let .noBundleIDsToRevoke(services):
      return "Cannot revoke \(services) since no bundle ids were provided"
    case let .unhandledRevokeServices(services):
      return "Cannot revoke \(CollectionInformation.oneLineDescription(from: Array(services))) since there is no handling of it"
    case let .emptyScheme(operation):
      return "Empty scheme provided to \(operation)"
    case let .emptyBundleIDs(operation):
      return "Empty bundleID set provided to \(operation)"
    case let .schemeApprovalPlistUnreadable(path):
      return "Failed to read the file at \(path)"
    case .schemeApprovalDirectoryCreationFailed:
      return "Failed to create folders for scheme approval plist"
    case .schemeApprovalPlistWriteFailed:
      return "Failed to write scheme approval plist"
    case let .schemeApprovalUnavailable(state):
      return "Cannot change URL scheme approvals while the Simulator is \(state.stateString.rawValue); it must be \(TargetStateString.booted.rawValue) or \(TargetStateString.shutdown.rawValue)"
    }
  }
}

/// Grants and revokes an application's access to privacy-gated services and deeplink schemes.
public struct SimulatorPrivacyCommands {

  private let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Services

  public func grantAccess(_ bundleIDs: Set<String>, toServices services: Set<TargetSettingsService>) async throws {
    if services.isEmpty {
      throw SimulatorPrivacyError.noServicesToGrant(bundleIDs: bundleIDs)
    }
    if bundleIDs.isEmpty {
      throw SimulatorPrivacyError.noBundleIDsToGrant(services: services)
    }

    var toApprove = services
    let coreSimulatorSettingMapping = Self.coreSimulatorSettingMapping

    if simulator.device.responds(to: NSSelectorFromString("setPrivacyAccessForService:bundleID:granted:error:")) {
      let simDeviceServices = toApprove.intersection(Set(coreSimulatorSettingMapping.keys))
      if !simDeviceServices.isEmpty {
        var internalServices = Set<String>()
        for service in simDeviceServices {
          if let internalService = coreSimulatorSettingMapping[service] {
            internalServices.insert(internalService)
          }
        }
        toApprove.subtract(simDeviceServices)
        try coreSimulatorApprove(withBundleIDs: bundleIDs, toServices: internalServices)
      }
    }
    if !toApprove.isEmpty && !toApprove.isDisjoint(with: Set(Self.privacyServiceMapping.keys)) {
      let tccServices = toApprove.intersection(Set(Self.privacyServiceMapping.keys))
      toApprove.subtract(tccServices)
      try await updatePrivacyService(bundleIDs, services: tccServices, approve: true)
    }
    if !toApprove.isEmpty && toApprove.contains(TargetSettingsService.location) {
      try await authorizeLocationSettings(Array(bundleIDs))
      toApprove.remove(TargetSettingsService.location)
    }
    if !toApprove.isEmpty && toApprove.contains(.notification) {
      try await updateNotificationService(Array(bundleIDs), approve: true)
      toApprove.remove(.notification)
    }
    if !toApprove.isEmpty && toApprove.contains(.health) {
      try await updateHealthService(Array(bundleIDs), approve: true)
      toApprove.remove(.health)
    }

    if !toApprove.isEmpty {
      throw SimulatorPrivacyError.unhandledGrantServices(services: toApprove)
    }
  }

  public func revokeAccess(_ bundleIDs: Set<String>, toServices services: Set<TargetSettingsService>) async throws {
    if services.isEmpty {
      throw SimulatorPrivacyError.noServicesToRevoke(bundleIDs: bundleIDs)
    }
    if bundleIDs.isEmpty {
      throw SimulatorPrivacyError.noBundleIDsToRevoke(services: services)
    }

    var toRevoke = services
    let coreSimulatorSettingMapping = Self.coreSimulatorSettingMapping

    if simulator.device.responds(to: NSSelectorFromString("setPrivacyAccessForService:bundleID:granted:error:")) {
      let simDeviceServices = toRevoke.intersection(Set(coreSimulatorSettingMapping.keys))
      if !simDeviceServices.isEmpty {
        var internalServices = Set<String>()
        for service in simDeviceServices {
          if let internalService = coreSimulatorSettingMapping[service] {
            internalServices.insert(internalService)
          }
        }
        toRevoke.subtract(simDeviceServices)
        try coreSimulatorRevoke(withBundleIDs: bundleIDs, toServices: internalServices)
      }
    }
    if !toRevoke.isEmpty && !toRevoke.isDisjoint(with: Set(Self.privacyServiceMapping.keys)) {
      let tccServices = toRevoke.intersection(Set(Self.privacyServiceMapping.keys))
      toRevoke.subtract(tccServices)
      try await updatePrivacyService(bundleIDs, services: tccServices, approve: false)
    }
    if !toRevoke.isEmpty && toRevoke.contains(TargetSettingsService.location) {
      try await revokeLocationSettings(Array(bundleIDs))
      toRevoke.remove(TargetSettingsService.location)
    }
    if !toRevoke.isEmpty && toRevoke.contains(.notification) {
      try await updateNotificationService(Array(bundleIDs), approve: false)
      toRevoke.remove(.notification)
    }
    if !toRevoke.isEmpty && toRevoke.contains(.health) {
      try await updateHealthService(Array(bundleIDs), approve: false)
      toRevoke.remove(.health)
    }

    if !toRevoke.isEmpty {
      throw SimulatorPrivacyError.unhandledRevokeServices(services: toRevoke)
    }
  }

  // MARK: - Deeplinks

  public func grantAccess(_ bundleIDs: Set<String>, toDeeplink scheme: String) async throws {
    if scheme.isEmpty {
      throw SimulatorPrivacyError.emptyScheme(operation: "url approve")
    }
    if bundleIDs.isEmpty {
      throw SimulatorPrivacyError.emptyBundleIDs(operation: "url approve")
    }

    let urlKey = Self.magicDeeplinkKey(forScheme: scheme)
    switch try schemeApprovalStore() {
    case .preferencesDaemon:
      let defaults = SimulatorDefaults(simulator: simulator)
      for bundleID in bundleIDs {
        try await defaults.setPreference(urlKey, value: bundleID, type: "string", domain: Self.schemeApprovalDomain)
      }
    case .plist:
      try grantInSchemeApprovalPlist(bundleIDs, urlKey: urlKey)
    }
  }

  public func revokeAccess(_ bundleIDs: Set<String>, toDeeplink scheme: String) async throws {
    if scheme.isEmpty {
      throw SimulatorPrivacyError.emptyScheme(operation: "url revoke")
    }
    if bundleIDs.isEmpty {
      throw SimulatorPrivacyError.emptyBundleIDs(operation: "url revoke")
    }

    let urlKey = Self.magicDeeplinkKey(forScheme: scheme)
    switch try schemeApprovalStore() {
    case .preferencesDaemon:
      try await SimulatorDefaults(simulator: simulator).removePreference(urlKey, domain: Self.schemeApprovalDomain)
    case .plist:
      try revokeInSchemeApprovalPlist(urlKey: urlKey)
    }
  }

  // MARK: - Private

  /// Where a URL scheme approval has to be written for LaunchServices to read it.
  private enum SchemeApprovalStore {
    /// The booted Simulator's preferences daemon. `lsd` keeps the approval domain cached in process and drops
    /// that cache only when the daemon reports a change, so a plist rewritten underneath it goes unseen.
    case preferencesDaemon
    /// The plist itself, which nothing holds a copy of while the Simulator is shut down.
    case plist
  }

  private func schemeApprovalStore() throws -> SchemeApprovalStore {
    let state = simulator.state
    switch state {
    case .booted:
      return .preferencesDaemon
    case .shutdown:
      return .plist
    case .creating, .booting, .shuttingDown, .DFU, .recovery, .restoreOS, .unknown:
      throw SimulatorPrivacyError.schemeApprovalUnavailable(state: state)
    }
  }

  private func grantInSchemeApprovalPlist(_ bundleIDs: Set<String>, urlKey: String) throws {
    let preferencesDirectory = (try requireDataDirectory() as NSString).appendingPathComponent("Library/Preferences")
    let schemeApprovalPlistPath = (preferencesDirectory as NSString).appendingPathComponent("\(Self.schemeApprovalDomain).plist")

    var schemeApprovalProperties: NSMutableDictionary = NSMutableDictionary()
    if FileManager.default.fileExists(atPath: schemeApprovalPlistPath) {
      guard let dict = NSDictionary(contentsOfFile: schemeApprovalPlistPath)?.mutableCopy() as? NSMutableDictionary else {
        throw SimulatorPrivacyError.schemeApprovalPlistUnreadable(path: schemeApprovalPlistPath)
      }
      schemeApprovalProperties = dict
    }

    for bundleID in bundleIDs {
      schemeApprovalProperties[urlKey] = bundleID
    }

    do {
      try FileManager.default.createDirectory(atPath: preferencesDirectory, withIntermediateDirectories: true, attributes: nil)
    } catch {
      throw SimulatorPrivacyError.schemeApprovalDirectoryCreationFailed(underlying: error)
    }
    if !schemeApprovalProperties.write(toFile: schemeApprovalPlistPath, atomically: true) {
      throw SimulatorPrivacyError.schemeApprovalPlistWriteFailed
    }
  }

  private func revokeInSchemeApprovalPlist(urlKey: String) throws {
    let preferencesDirectory = (try requireDataDirectory() as NSString).appendingPathComponent("Library/Preferences")
    let schemeApprovalPlistPath = (preferencesDirectory as NSString).appendingPathComponent("\(Self.schemeApprovalDomain).plist")

    guard FileManager.default.fileExists(atPath: schemeApprovalPlistPath) else {
      return
    }
    guard let schemeApprovalProperties = NSDictionary(contentsOfFile: schemeApprovalPlistPath)?.mutableCopy() as? NSMutableDictionary else {
      throw SimulatorPrivacyError.schemeApprovalPlistUnreadable(path: schemeApprovalPlistPath)
    }

    schemeApprovalProperties.removeObject(forKey: urlKey)

    if !schemeApprovalProperties.write(toFile: schemeApprovalPlistPath, atomically: true) {
      throw SimulatorPrivacyError.schemeApprovalPlistWriteFailed
    }
  }

  private func requireDataDirectory() throws -> String {
    guard let dataDirectory = simulator.dataDirectory else {
      throw SimulatorPrivacyError.noDataDirectoryForPlists
    }
    return dataDirectory
  }

  private func authorizeLocationSettings(_ bundleIDs: [String]) async throws {
    try await SimulatorDefaults(simulator: simulator)
      .approveLocationServices(forBundleIDs: bundleIDs)
  }

  private func revokeLocationSettings(_ bundleIDs: [String]) async throws {
    try await SimulatorDefaults(simulator: simulator)
      .revokeLocationServices(forBundleIDs: bundleIDs)
  }

  private func updateHealthService(_ bundleIDs: [String], approve approved: Bool) async throws {
    if bundleIDs.isEmpty {
      throw SimulatorPrivacyError.emptyBundleIDs(operation: "health approve")
    }
    for bundleID in bundleIDs {
      try await simulator.runSimulatorFrameworkBridge(
        .health(
          approved
            ? .approve(bundleID: bundleID, typeIDs: [])
            : .revoke(bundleID: bundleID, typeIDs: [])))
    }
  }

  private func updateNotificationService(_ bundleIDs: [String], approve approved: Bool) async throws {
    if bundleIDs.isEmpty {
      throw SimulatorPrivacyError.emptyBundleIDs(operation: "notifications approve")
    }

    for bundleID in bundleIDs {
      try await simulator.runSimulatorFrameworkBridge(
        .notifications(
          approved
            ? .approve(bundleID: bundleID)
            : .revoke(bundleID: bundleID)))
    }
  }

  private func coreSimulatorApprove(withBundleIDs bundleIDs: Set<String>, toServices services: Set<String>) throws {
    for bundleID in bundleIDs {
      for internalService in services {
        try simulator.device.setPrivacyAccessForService(internalService, bundleID: bundleID, granted: true)
      }
    }
  }

  private func coreSimulatorRevoke(withBundleIDs bundleIDs: Set<String>, toServices services: Set<String>) throws {
    for bundleID in bundleIDs {
      for internalService in services {
        try simulator.device.resetPrivacyAccess(forService: internalService, bundleID: bundleID)
      }
    }
  }

  private func updatePrivacyService(_ bundleIDs: Set<String>, services: Set<TargetSettingsService>, approve: Bool) async throws {
    for invocation in Self.privacyInvocations(bundleIDs: bundleIDs, services: services, approve: approve) {
      try await simulator.runSimulatorFrameworkBridge(
        withService: "privacy",
        action: invocation.action,
        arguments: invocation.arguments)
    }
  }

  /// One `privacy <action> <bundleID> <service>...` call on the guest.
  internal struct PrivacyInvocation: Equatable {
    let action: String
    let arguments: [String]
  }

  /// The guest calls an approve or revoke resolves to: one per bundle id, each
  /// carrying every requested service, ordered so a trace is comparable between runs.
  internal static func privacyInvocations(
    bundleIDs: Set<String>,
    services: Set<TargetSettingsService>,
    approve: Bool
  ) -> [PrivacyInvocation] {
    let names = services.compactMap { privacyServiceMapping[$0] }.sorted()
    let action = approve ? "approve" : "revoke"
    return bundleIDs.sorted().map { PrivacyInvocation(action: action, arguments: [$0] + names) }
  }

  // MARK: - Service Mappings

  private static let privacyServiceMapping: [TargetSettingsService: String] = [
    .contacts: "contacts",
    .photos: "photos",
    .camera: "camera",
    .microphone: "microphone",
  ]

  private static let coreSimulatorSettingMapping: [TargetSettingsService: String] = [
    .location: "__CoreLocationAlways"
  ]

  private static let schemeApprovalDomain = "com.apple.launchservices.schemeapproval"

  internal static func magicDeeplinkKey(forScheme scheme: String) -> String {
    "com.apple.CoreSimulator.CoreSimulatorBridge-->\(scheme)"
  }
}
