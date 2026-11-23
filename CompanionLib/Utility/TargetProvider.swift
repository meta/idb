/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBDeviceControl
import FBSimulatorControl
import FBVideoCore
import FBXCTestCore
import Foundation

enum TargetProviderError: Error {
  case targetNotUsable(udid: String, targetDescription: String)
  case targetNotFound(udid: String, targetSetsDescription: String)
  case targetDidNotAppear(udid: String, timeout: TimeInterval, targetSetsDescription: String)
  case multipleTargets(targetsDescription: String)
  case noTargets(targetSetsDescription: String)
  case multipleBootedTargets(targetsDescription: String)
  case noBootedTargets(targetSetsDescription: String)
}

extension TargetProviderError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .targetNotUsable(udid, targetDescription):
      return "\(udid) exists, but the target is not usable \(targetDescription)"
    case let .targetNotFound(udid, targetSetsDescription):
      return "\(udid) could not be resolved to any target in \(targetSetsDescription)"
    case let .targetDidNotAppear(udid, timeout, targetSetsDescription):
      return "No target with UDID \(udid) appeared within \(timeout)s in \(targetSetsDescription)"
    case let .multipleTargets(targetsDescription):
      return "Cannot get a sole target when multiple found \(targetsDescription)"
    case let .noTargets(targetSetsDescription):
      return "Cannot get a sole target when none were found in target sets \(targetSetsDescription)"
    case let .multipleBootedTargets(targetsDescription):
      return "Cannot get a sole booted target when multiple are booted \(targetsDescription)"
    case let .noBootedTargets(targetSetsDescription):
      return "Cannot get a sole booted target when none are booted in target sets \(targetSetsDescription)"
    }
  }
}

/// Creates a target set when a lookup needs it.
public typealias TargetSetMaker = () async throws -> any TargetSet

public enum TargetProvider {

  /// How long a lookup by UDID waits for the target to appear once every set has been created.
  /// A device set learns a device's UDID only after MobileDevice has connected to it and read its
  /// values, which can finish after the set is created; until then the device is listed without
  /// one. An unknown UDID costs this long before it fails.
  public static let targetAppearanceTimeout: TimeInterval = 5

  /// Resolves `udid` against the target sets `makers` create, in order, creating a set only when
  /// the sets before it cannot resolve the UDID. Resolving the sole or sole booted target needs
  /// every set, so creates them all; resolving the Mac needs none. A UDID no set holds yet is
  /// waited for, for up to `appearanceTimeout`.
  public static func target(
    withUDID udid: String,
    makingTargetSets makers: [TargetSetMaker],
    warmUp: Bool,
    appearanceTimeout: TimeInterval = targetAppearanceTimeout,
    logger: any ControlCoreLogger
  ) async throws -> CompanionTarget {
    let targetSets = try await makeTargetSets(withUDID: udid, makers: makers, appearanceTimeout: appearanceTimeout, logger: logger)
    return try target(withUDID: udid, targetSets: targetSets, warmUp: warmUp, logger: logger)
  }

  /// Keeps discovery active until the operation using the target finishes.
  public static func withTarget<Result>(
    withUDID udid: String,
    makingTargetSets makers: [TargetSetMaker],
    warmUp: Bool,
    appearanceTimeout: TimeInterval = targetAppearanceTimeout,
    logger: any ControlCoreLogger,
    _ body: (CompanionTarget) async throws -> Result
  ) async throws -> Result {
    let targetSets = try await makeTargetSets(withUDID: udid, makers: makers, appearanceTimeout: appearanceTimeout, logger: logger)
    defer { withExtendedLifetime(targetSets) {} }
    let target = try target(withUDID: udid, targetSets: targetSets, warmUp: warmUp, logger: logger)
    return try await body(target)
  }

  private static func makeTargetSets(withUDID udid: String, makers: [TargetSetMaker], appearanceTimeout: TimeInterval, logger: any ControlCoreLogger) async throws -> [any TargetSet] {
    var targetSets: [any TargetSet] = []
    switch udid.lowercased() {
    case "only", "booted":
      for make in makers {
        targetSets.append(try await make())
      }
    case "mac":
      break
    default:
      for make in makers {
        let targetSet = try await make()
        targetSets.append(targetSet)
        if targetSet.target(withUDID: udid) != nil {
          return targetSets
        }
      }
      try await awaitTarget(withUDID: udid, in: targetSets, timeout: appearanceTimeout, logger: logger)
    }
    return targetSets
  }

  /// Waits until one of `targetSets` holds `udid`. The sets are mutated on the main queue, so they
  /// are read there.
  private static func awaitTarget(withUDID udid: String, in targetSets: [any TargetSet], timeout: TimeInterval, logger: any ControlCoreLogger) async throws {
    let start = DispatchTime.now()
    let holdsTarget = { targetSets.contains { $0.target(withUDID: udid) != nil } }
    do {
      try await pollUntilTrue(on: .main, interval: 0.05, deadline: PollDeadline(timeout: timeout, waitingFor: udid), condition: holdsTarget)
    } catch is PollTimeoutError {
      throw TargetProviderError.targetDidNotAppear(udid: udid, timeout: timeout, targetSetsDescription: String(describing: targetSets))
    }
    let waited = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / Double(NSEC_PER_SEC)
    logger.log("\(udid) appeared \(String(format: "%.3f", waited))s after its target sets were created")
  }

  public static func target(withUDID udid: String, targetSets: [any TargetSet], warmUp: Bool, logger: any ControlCoreLogger) throws -> CompanionTarget {
    switch udid.lowercased() {
    case "only":
      return try fetchSoleTarget(forTargetSets: targetSets, logger: logger)
    case "booted":
      return try fetchSoleBootedTarget(forTargetSets: targetSets, logger: logger)
    default:
      return try fetchTarget(withUDID: udid, targetSets: targetSets, logger: logger)
    }
  }

  private static func fetchTarget(withUDID udid: String, targetSets: [any TargetSet], logger: any ControlCoreLogger) throws -> CompanionTarget {
    if udid.lowercased() == "mac" {
      return MacDevice(logger: logger)
    }
    for targetSet in targetSets {
      guard let targetInfo = targetSet.target(withUDID: udid) else {
        continue
      }
      guard let target = companionTarget(targetInfo) else {
        throw TargetProviderError.targetNotUsable(udid: udid, targetDescription: String(describing: targetInfo))
      }
      return target
    }

    throw TargetProviderError.targetNotFound(udid: udid, targetSetsDescription: String(describing: targetSets))
  }

  private static func fetchSoleTarget(forTargetSets targetSets: [any TargetSet], logger: any ControlCoreLogger) throws -> CompanionTarget {
    var targets: [CompanionTarget] = []
    for targetSet in targetSets {
      for info in targetSet.allTargetInfos {
        if let target = companionTarget(info) {
          targets.append(target)
        }
      }
    }
    if targets.count > 1 {
      throw TargetProviderError.multipleTargets(targetsDescription: CollectionInformation.oneLineDescription(from: targets))
    }
    guard let target = targets.first else {
      throw TargetProviderError.noTargets(targetSetsDescription: CollectionInformation.oneLineDescription(from: targetSets))
    }
    return target
  }

  private static func fetchSoleBootedTarget(forTargetSets targetSets: [any TargetSet], logger: any ControlCoreLogger) throws -> CompanionTarget {
    var bootedTargets: [CompanionTarget] = []
    for targetSet in targetSets {
      for info in targetSet.allTargetInfos {
        guard let target = companionTarget(info), target.state == .booted else {
          continue
        }
        bootedTargets.append(target)
      }
    }
    if bootedTargets.count > 1 {
      throw TargetProviderError.multipleBootedTargets(targetsDescription: CollectionInformation.oneLineDescription(from: bootedTargets))
    }
    guard let target = bootedTargets.first else {
      throw TargetProviderError.noBootedTargets(targetSetsDescription: CollectionInformation.oneLineDescription(from: targetSets))
    }
    return target
  }
}
