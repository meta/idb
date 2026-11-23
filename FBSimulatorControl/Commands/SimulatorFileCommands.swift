/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation

public enum SimulatorFileError: Error {
  case noDataContainer(applicationDescription: String)
  case noDataDirectory(simulatorDescription: String)
  case unsupportedOnSimulators(operation: String)
}

extension SimulatorFileError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .noDataContainer(applicationDescription):
      return "No data container present for application \(applicationDescription)"
    case let .noDataDirectory(simulatorDescription):
      return "No data directory for \(simulatorDescription), it may not have been booted"
    case let .unsupportedOnSimulators(operation):
      return "\(operation) not supported on simulators"
    }
  }
}

public final class SimulatorFileCommands: FileCommands {

  private let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Containers

  public func withContainerApplication<R>(
    _ bundleID: String,
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    try await body(FileContainer.ContainedRoot(rootFile: try await containedFile(forApplication: bundleID)))
  }

  public func withAuxiliary<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    try await body(FileContainer.ContainedRoot(basePath: simulator.auxillaryDirectory))
  }

  public func withApplicationContainers<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    try await body(FileContainer.ContainedRoot(rootFile: try containedFileForApplicationContainers()))
  }

  public func withGroupContainers<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    try await body(FileContainer.ContainedRoot(rootFile: try containedFileForGroupContainers()))
  }

  public func withRootFilesystem<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    try await body(FileContainer.ContainedRoot(basePath: try requireDataDirectory()))
  }

  public func withMediaDirectory<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    let mediaDirectory = (try requireDataDirectory() as NSString).appendingPathComponent("Media")
    return try await body(FileContainer.ContainedRoot(basePath: mediaDirectory))
  }

  public func withProvisioningProfiles<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    throw SimulatorFileError.unsupportedOnSimulators(operation: #function)
  }

  public func withMDMProfiles<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    throw SimulatorFileError.unsupportedOnSimulators(operation: #function)
  }

  public func withSpringboardIconLayout<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    throw SimulatorFileError.unsupportedOnSimulators(operation: #function)
  }

  public func withWallpaper<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    throw SimulatorFileError.unsupportedOnSimulators(operation: #function)
  }

  public func withDiskImages<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    throw SimulatorFileError.unsupportedOnSimulators(operation: #function)
  }

  public func withSymbols<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    throw SimulatorFileError.unsupportedOnSimulators(operation: #function)
  }

  // MARK: - Contained file accessors

  private func containedFile(forApplication bundleID: String) async throws -> any ContainedFile {
    let installedApplication = try await simulator.application.installed(bundleID: bundleID)
    guard let container = installedApplication.dataContainer else {
      throw SimulatorFileError.noDataContainer(applicationDescription: String(describing: installedApplication))
    }
    return HostFile(path: container)
  }

  private func containedFileForApplicationContainers() throws -> any ContainedFile {
    var mapping: [String: String] = [:]
    for (bundleID, appInfo) in try simulator.device.installedApps() {
      guard let bundleID = bundleID as? String,
        let info = appInfo as? [String: Any],
        let dataContainer = info["DataContainer"] as? URL
      else {
        continue
      }
      mapping[bundleID] = dataContainer.path
    }
    return MappedHostFile(mappingPaths: mapping)
  }

  private func containedFileForGroupContainers() throws -> any ContainedFile {
    var bundleIDToURL: [String: URL] = [:]
    for appInfo in try simulator.device.installedApps().values {
      guard let info = appInfo as? [String: Any],
        let appContainers = info["GroupContainers"] as? [String: URL]
      else {
        continue
      }
      for (key, value) in appContainers {
        bundleIDToURL[key] = value
      }
    }
    var pathMapping: [String: String] = [:]
    for (identifier, url) in bundleIDToURL {
      pathMapping[identifier] = url.path
    }
    return MappedHostFile(mappingPaths: pathMapping)
  }

  private func requireDataDirectory() throws -> String {
    guard let dataDirectory = simulator.dataDirectory else {
      throw SimulatorFileError.noDataDirectory(simulatorDescription: String(describing: simulator))
    }
    return dataDirectory
  }
}
