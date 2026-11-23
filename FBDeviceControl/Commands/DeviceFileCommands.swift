/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import MobileDeviceAPI

private let MountRootPath = "mounted"
private let ExtractedSymbolsDirectory = "Symbols"

// MARK: - DeviceFileContainerError

public enum DeviceFileContainerError: Error {
  case tailNotImplemented
  case tailUnsupported(container: String)
  case operationUnsupported(operation: String, container: String)
  case moveOutsideMounts(destination: String)
  case notAMountableImage(path: String, available: [String])
  case removeOutsideMounts(path: String)
  case notAMountedImage(path: String, available: [String])
  case requiresRootedDevice(operation: String)
}

extension DeviceFileContainerError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .tailNotImplemented:
      return "tail is not implemented for DeviceFileContainer"
    case let .tailUnsupported(container):
      return "tail is not supported for \(container)"
    case let .operationUnsupported(operation, container):
      return "\(operation) does not make sense for \(container)"
    case let .moveOutsideMounts(destination):
      return "\(destination) only moving into mounts is supported."
    case let .notAMountableImage(path, available):
      return "\(path) is not one of \(CollectionInformation.oneLineDescription(from: available))"
    case let .removeOutsideMounts(path):
      return "\(path) cannot be removed, only mounts can be removed"
    case let .notAMountedImage(path, available):
      return "\(path) is not one of the available mounts \(CollectionInformation.oneLineDescription(from: available))"
    case let .requiresRootedDevice(operation):
      return "\(operation) not supported on devices, requires a rooted device"
    }
  }
}

// MARK: - DeviceFileContainer

public final class DeviceFileContainer: AsyncFileContainer {
  private let queue: DispatchQueue
  private let connection: FileConduit

  public init(afcConnection connection: FileConduit, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  // MARK: - AsyncFileContainer

  public func copy(fromHost sourcePath: String, toContainer destinationPath: String) async throws {
    try await queue.perform { [connection] in
      try connection.copy(fromHost: sourcePath, toContainerPath: destinationPath)
    }
  }

  public func copy(fromContainer sourcePath: String, toHost destinationPath: String) async throws -> String {
    var destination = destinationPath
    if DeviceFileContainer.isDirectory(destinationPath) {
      destination = (destinationPath as NSString).appendingPathComponent((sourcePath as NSString).lastPathComponent)
    }
    let data = try await readFile(inContainer: sourcePath)
    try data.write(to: URL(fileURLWithPath: destination))
    return destination
  }

  public func tail(_ path: String, to consumer: any DataConsumer) async throws -> FileContainerTailOperation {
    throw DeviceFileContainerError.tailNotImplemented
  }

  public func createDirectory(_ directoryPath: String) async throws {
    try await queue.perform { [connection] in
      try connection.createDirectory(directoryPath)
    }
  }

  public func move(from sourcePath: String, to destinationPath: String) async throws {
    try await queue.perform { [connection] in
      try connection.renamePath(sourcePath, destination: destinationPath)
    }
  }

  public func remove(_ path: String) async throws {
    try await queue.perform { [connection] in
      try connection.removePath(path, recursively: true)
    }
  }

  public func contents(ofDirectory path: String) async throws -> [String] {
    return try await queue.perform { [connection] in
      try connection.contents(ofDirectory: path)
    }
  }

  // MARK: - Private

  private func readFile(inContainer path: String) async throws -> Data {
    return try await queue.perform { [connection] in
      try connection.contents(ofPath: path)
    }
  }

  private static func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return unsafe FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
  }

  // MARK: - Wallpaper

  fileprivate class Wallpaper: AsyncFileContainer {
    let queue: DispatchQueue
    let springboard: SpringboardServicesClient
    let managedConfig: ManagedConfigClient

    init(springboard: SpringboardServicesClient, managedConfig: ManagedConfigClient, queue: DispatchQueue) {
      self.springboard = springboard
      self.managedConfig = managedConfig
      self.queue = queue
    }

    func copy(fromHost sourcePath: String, toContainer destinationPath: String) async throws {
      let data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
      try await managedConfig.changeWallpaper(name: (destinationPath as NSString).lastPathComponent, data: data)
    }

    func copy(fromContainer sourcePath: String, toHost destinationPath: String) async throws -> String {
      let imageData = try await springboard.wallpaperImageData(forKind: (sourcePath as NSString).lastPathComponent)
      try imageData.write(to: URL(fileURLWithPath: destinationPath), options: .atomic)
      return destinationPath
    }

    func tail(_ path: String, to consumer: any DataConsumer) async throws -> FileContainerTailOperation {
      throw DeviceFileContainerError.tailUnsupported(container: "Wallpaper File Containers")
    }

    func createDirectory(_ directoryPath: String) async throws {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "Wallpaper File Containers")
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "Wallpaper File Containers")
    }

    func remove(_ path: String) async throws {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "Wallpaper File Containers")
    }

    func contents(ofDirectory path: String) async throws -> [String] {
      [SpringboardServicesClient.wallpaperNameHomescreen, SpringboardServicesClient.wallpaperNameLockscreen]
    }
  }

  // MARK: - MDMProfiles

  fileprivate class MDMProfiles: AsyncFileContainer {
    let queue: DispatchQueue
    let managedConfig: ManagedConfigClient

    init(managedConfig: ManagedConfigClient, queue: DispatchQueue) {
      self.managedConfig = managedConfig
      self.queue = queue
    }

    func copy(fromHost sourcePath: String, toContainer destinationPath: String) async throws {
      let data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
      _ = try await managedConfig.installProfile(data)
    }

    func copy(fromContainer sourcePath: String, toHost destinationPath: String) async throws -> String {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "MDM Profile File Containers")
    }

    func tail(_ path: String, to consumer: any DataConsumer) async throws -> FileContainerTailOperation {
      throw DeviceFileContainerError.tailUnsupported(container: "MDM Profile File Containers")
    }

    func createDirectory(_ directoryPath: String) async throws {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "MDM Profile File Containers")
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "MDM Profile File Containers")
    }

    func remove(_ path: String) async throws {
      try await managedConfig.removeProfile(path)
    }

    func contents(ofDirectory path: String) async throws -> [String] {
      try await managedConfig.profileList()
    }
  }
}

// MARK: - DeviceFileCommands

public final class DeviceFileCommands: FileCommands {
  private let device: Device
  private let afcCalls: AFCCalls

  // MARK: - Initializers

  public init(device: Device, afcCalls: AFCCalls = FileConduit.defaultCalls) {
    self.device = device
    self.afcCalls = afcCalls
  }

  // MARK: - FileCommands

  public func withContainerApplication<R>(
    _ bundleID: String,
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    let queue = device.asyncQueue
    return try await device.withHouseArrestAFCConnection(forBundleID: bundleID, afcCalls: afcCalls) { connection in
      try await body(DeviceFileContainer(afcConnection: connection, queue: queue))
    }
  }

  public func withAuxiliary<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    return try await body(FileContainer.ContainedRoot(basePath: device.auxillaryDirectory))
  }

  public func withApplicationContainers<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    throw DeviceFileContainerError.requiresRootedDevice(operation: #function)
  }

  public func withGroupContainers<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    throw DeviceFileContainerError.requiresRootedDevice(operation: #function)
  }

  public func withRootFilesystem<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    throw DeviceFileContainerError.requiresRootedDevice(operation: #function)
  }

  public func withMediaDirectory<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    let queue = device.asyncQueue
    return try await device.withAFCConnection("com.apple.afc") { afc in
      try await body(DeviceFileContainer(afcConnection: afc, queue: queue))
    }
  }

  public func withProvisioningProfiles<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    return try await body(FileContainer.ProvisioningProfile(commands: DeviceProvisioningProfileCommands(device: device)))
  }

  public func withMDMProfiles<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    return try await device.withServiceConnection(ManagedConfigClient.serviceName) { connection in
      let managedConfig = ManagedConfigClient(connection: connection, logger: device.logger)
      return try await body(DeviceFileContainer.MDMProfiles(managedConfig: managedConfig, queue: device.workQueue))
    }
  }

  public func withSpringboardIconLayout<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    return try await device.withServiceConnection(SpringboardServicesClient.serviceName) { connection in
      let client = SpringboardServicesClient(connection: connection, logger: device.logger)
      return try await body(client.iconContainer())
    }
  }

  public func withWallpaper<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    return try await device.withServiceConnection(SpringboardServicesClient.serviceName) { springboardConnection in
      try await device.withServiceConnection(ManagedConfigClient.serviceName) { managedConfigConnection in
        let springboard = SpringboardServicesClient(connection: springboardConnection, logger: device.logger)
        let managedConfig = ManagedConfigClient(connection: managedConfigConnection, logger: device.logger)
        return try await body(
          DeviceFileContainer.Wallpaper(springboard: springboard, managedConfig: managedConfig, queue: device.workQueue))
      }
    }
  }

  public func withDiskImages<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    return try await body(DiskImages(commands: device.developerDiskImage, queue: device.asyncQueue))
  }

  public func withSymbols<R>(
    body: (any AsyncFileContainer) async throws -> R
  ) async throws -> R {
    return try await body(Symbols(commands: device.debugSymbols, queue: device.asyncQueue))
  }

  // MARK: - DiskImages

  private class DiskImages: AsyncFileContainer {
    let commands: any DeveloperDiskImageCommands
    let queue: DispatchQueue

    init(commands: any DeveloperDiskImageCommands, queue: DispatchQueue) {
      self.commands = commands
      self.queue = queue
    }

    // MARK: - AsyncFileContainer

    func copy(fromHost sourcePath: String, toContainer destinationPath: String) async throws {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "Disk Images")
    }

    func copy(fromContainer sourcePath: String, toHost destinationPath: String) async throws -> String {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "Disk Images")
    }

    func tail(_ path: String, to consumer: any DataConsumer) async throws -> FileContainerTailOperation {
      throw DeviceFileContainerError.tailUnsupported(container: "Disk Images")
    }

    func createDirectory(_ directoryPath: String) async throws {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "Disk Images")
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
      if !destinationPath.hasPrefix(MountRootPath) {
        throw DeviceFileContainerError.moveOutsideMounts(destination: destinationPath)
      }
      let mountableImagesByPath = self.mountableDiskImagesByPath
      guard let image = mountableImagesByPath[sourcePath] else {
        throw DeviceFileContainerError.notAMountableImage(path: sourcePath, available: mountableImagesByPath.keys.sorted())
      }
      _ = try await commands.mountDiskImage(image)
    }

    func remove(_ path: String) async throws {
      if !path.hasPrefix(MountRootPath) {
        throw DeviceFileContainerError.removeOutsideMounts(path: path)
      }
      let mountedImages = try await mountedDiskImages()
      guard let image = mountedImages[path] else {
        throw DeviceFileContainerError.notAMountedImage(path: path, available: Array(mountedImages.keys))
      }
      try await commands.unmountDiskImage(image)
    }

    func contents(ofDirectory path: String) async throws -> [String] {
      let diskImagePaths = try await allDiskImagePaths()
      return DiskImages.traverseAndDescendPaths(diskImagePaths, path: path)
    }

    // MARK: - Private

    private var mountableDiskImagesByPath: [String: DeveloperDiskImage] {
      let images = commands.mountableDiskImages()
      var mapping: [String: DeveloperDiskImage] = [:]
      for image in images {
        mapping[DiskImages.filePath(for: image)] = image
      }
      return mapping
    }

    private func mountedDiskImages() async throws -> [String: DeveloperDiskImage] {
      let mountedImages = try await commands.mountedDiskImages()
      var imagesByPath: [String: DeveloperDiskImage] = [:]
      for image in mountedImages {
        let mountedFilePath = (MountRootPath as NSString).appendingPathComponent(DiskImages.filePath(for: image))
        imagesByPath[mountedFilePath] = image
      }
      return imagesByPath
    }

    private func allDiskImagePaths() async throws -> [String] {
      let mountedDiskImages = try await mountedDiskImages()
      var paths: [String] = []
      let sortedKeys = self.mountableDiskImagesByPath.sorted { pair1, pair2 in
        let v1 = pair1.value.version
        let v2 = pair2.value.version
        if v1.majorVersion != v2.majorVersion { return v1.majorVersion < v2.majorVersion }
        return v1.minorVersion < v2.minorVersion
      }.map { $0.key }
      paths.append(contentsOf: sortedKeys)
      paths.append(MountRootPath)
      paths.append(contentsOf: mountedDiskImages.keys)
      return paths
    }

    static func traverseAndDescendPaths(_ paths: [String], path: String) -> [String] {
      let pathComponents = (path as NSString).pathComponents
      let firstPath = pathComponents.first
      if pathComponents.count == 1 && (firstPath == "." || firstPath == "/") {
        return paths
      }
      var traversedPaths: [String] = []
      for candidatePath in paths {
        if !candidatePath.hasPrefix(path) {
          continue
        }
        var relativePath = String(candidatePath.dropFirst(path.count))
        if relativePath.hasPrefix("/") {
          relativePath = String(relativePath.dropFirst())
        }
        traversedPaths.append(relativePath)
      }
      return traversedPaths
    }

    static func filePath(for image: DeveloperDiskImage) -> String {
      "\(image.version.majorVersion).\(image.version.minorVersion)/\((image.diskImagePath as NSString).lastPathComponent)"
    }
  }

  // MARK: - Symbols

  private class Symbols: AsyncFileContainer {
    let commands: DeviceDebugSymbolsCommands
    let queue: DispatchQueue

    init(commands: DeviceDebugSymbolsCommands, queue: DispatchQueue) {
      self.commands = commands
      self.queue = queue
    }

    func copy(fromHost sourcePath: String, toContainer destinationPath: String) async throws {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "Symbols")
    }

    func copy(fromContainer sourcePath: String, toHost destinationPath: String) async throws -> String {
      if sourcePath == ExtractedSymbolsDirectory {
        return try await commands.pullAndExtractSymbols(toDestinationDirectory: destinationPath)
      }
      return try await commands.pullSymbolFile(sourcePath, toDestinationPath: destinationPath)
    }

    func tail(_ path: String, to consumer: any DataConsumer) async throws -> FileContainerTailOperation {
      throw DeviceFileContainerError.tailUnsupported(container: "Symbols")
    }

    func createDirectory(_ directoryPath: String) async throws {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "Symbols")
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "Symbols")
    }

    func remove(_ path: String) async throws {
      throw DeviceFileContainerError.operationUnsupported(operation: #function, container: "Symbols")
    }

    func contents(ofDirectory path: String) async throws -> [String] {
      let listedSymbols = try await commands.listSymbols()
      return listedSymbols + [ExtractedSymbolsDirectory]
    }
  }
}
