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

  /// Resolves `udid` against the target sets `makers` create, in order, creating a set only when
  /// the sets before it cannot resolve the UDID. Resolving the sole or sole booted target needs
  /// every set, so creates them all; resolving the Mac needs none.
  public static func target(withUDID udid: String, makingTargetSets makers: [TargetSetMaker], warmUp: Bool, logger: ControlCoreLogger) async throws -> CompanionTarget {
    let targetSets = try await makeTargetSets(withUDID: udid, makers: makers)
    return try target(withUDID: udid, targetSets: targetSets, warmUp: warmUp, logger: logger)
  }

  /// Keeps discovery active until the operation using the target finishes.
  public static func withTarget<Result>(
    withUDID udid: String,
    makingTargetSets makers: [TargetSetMaker],
    warmUp: Bool,
    logger: ControlCoreLogger,
    _ body: (CompanionTarget) async throws -> Result
  ) async throws -> Result {
    let targetSets = try await makeTargetSets(withUDID: udid, makers: makers)
    defer { withExtendedLifetime(targetSets) {} }
    let target = try target(withUDID: udid, targetSets: targetSets, warmUp: warmUp, logger: logger)
    return try await body(target)
  }

  private static func makeTargetSets(withUDID udid: String, makers: [TargetSetMaker]) async throws -> [TargetSet] {
    var targetSets: [TargetSet] = []
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
          break
        }
      }
    }
    return targetSets
  }

  public static func target(withUDID udid: String, targetSets: [TargetSet], warmUp: Bool, logger: ControlCoreLogger) throws -> CompanionTarget {
    switch udid.lowercased() {
    case "only":
      return try fetchSoleTarget(forTargetSets: targetSets, logger: logger)
    case "booted":
      return try fetchSoleBootedTarget(forTargetSets: targetSets, logger: logger)
    default:
      return try fetchTarget(withUDID: udid, targetSets: targetSets, logger: logger)
    }
  }

  private static func fetchTarget(withUDID udid: String, targetSets: [TargetSet], logger: ControlCoreLogger) throws -> CompanionTarget {
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

  private static func fetchSoleTarget(forTargetSets targetSets: [TargetSet], logger: ControlCoreLogger) throws -> CompanionTarget {
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

  private static func fetchSoleBootedTarget(forTargetSets targetSets: [TargetSet], logger: ControlCoreLogger) throws -> CompanionTarget {
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
