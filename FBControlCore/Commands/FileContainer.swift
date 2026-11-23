/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// A file addressed within some container. Conformers are value types holding only
/// the address, so the existential is `Sendable` and hops queues without boxing.
public protocol ContainedFile: Sendable {

  func removeItem() throws

  func contentsOfDirectory() throws -> [String]

  func contentsOfFile() throws -> Data

  func createDirectory() throws

  func fileExists() -> (exists: Bool, isDirectory: Bool)

  func move(to destination: any ContainedFile) throws

  func populate(withContentsOfHostPath path: String) throws

  func populateHostPath(withContents path: String) throws

  func file(byAppendingPathComponent component: String) throws -> any ContainedFile

  var pathOnHostFileSystem: String? { get }

  var pathMapping: [String: String]? { get }
}

enum FileContainerError: Error {
  case copyIntoContainerFailed(source: String, destination: String, underlying: any Error)
  case sourceDoesNotExist(source: String)
  case temporaryDirectoryCreationFailed(underlying: any Error)
  case removalBeforeOverwriteFailed(path: String, underlying: any Error)
  case copyOutOfContainerFailed(source: String, destination: String, underlying: any Error)
  case notOnLocalFilesystem(file: String)
  case directoryCreationFailed(directory: String, underlying: any Error)
  case moveFailed(source: String, destination: String, underlying: any Error)
  case removalFailed(path: String, underlying: any Error)
  case unsupportedForProvisioningProfiles(operation: String)
  case destinationNotOnHostFilesystem(destination: String)
  case unsupportedOnVirtualRoot(operation: String)
  case movingUnsupportedOnVirtualRoot
  case invalidRootPath(component: String, available: [String])
}

extension FileContainerError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .copyIntoContainerFailed(source, destination, underlying):
      return "Could not copy from \(source) to \(destination): \(underlying)"
    case let .sourceDoesNotExist(source):
      return "Source path does not exist: \(source)"
    case let .temporaryDirectoryCreationFailed(underlying):
      return "Could not create temporary directory: \(underlying)"
    case let .removalBeforeOverwriteFailed(path, underlying):
      return "Could not remove \(path): \(underlying)"
    case let .copyOutOfContainerFailed(source, destination, underlying):
      return "Could not copy from \(source) to \(destination): \(underlying)"
    case let .notOnLocalFilesystem(file):
      return "Cannot tail \(file), it is not on the local filesystem"
    case let .directoryCreationFailed(directory, underlying):
      return "Could not create directory \(directory): \(underlying)"
    case let .moveFailed(source, destination, underlying):
      return "Could not move item at \(source) to \(destination): \(underlying)"
    case let .removalFailed(path, underlying):
      return "Could not remove item at path \(path): \(underlying)"
    case let .unsupportedForProvisioningProfiles(operation):
      return "\(operation) is not implemented for provisioning profiles"
    case let .destinationNotOnHostFilesystem(destination):
      return "Cannot move to \(destination), it is not on the host filesystem"
    case let .unsupportedOnVirtualRoot(operation):
      return "\(operation) does not operate on root virtual containers"
    case .movingUnsupportedOnVirtualRoot:
      return "Moving files does not work on root virtual containers"
    case let .invalidRootPath(component, available):
      return "'\(component)' is not a valid root path out of \(CollectionInformation.oneLineDescription(from: available))"
    }
  }
}

/// Handle to a running `tail` started by a file container. Cancelling stops the
/// underlying `tail` subprocess and waits for it to exit.
public final class FileContainerTailOperation {
  private let running: RunningSubprocess
  init(running: RunningSubprocess) {
    self.running = running
  }

  public func cancel() async throws {
    await running.terminate(gracePeriod: 1)
  }
}

// MARK: - Container Kinds

/// The names of the file containers a target can expose.
public struct FileContainerKind: RawRepresentable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let application = FileContainerKind(rawValue: "application")
  public static let auxillary = FileContainerKind(rawValue: "auxillary")
  public static let crashes = FileContainerKind(rawValue: "crashes")
  public static let diskImages = FileContainerKind(rawValue: "disk_images")
  public static let group = FileContainerKind(rawValue: "group")
  public static let mdmProfiles = FileContainerKind(rawValue: "mdm_profiles")
  public static let media = FileContainerKind(rawValue: "media")
  public static let provisioningProfiles = FileContainerKind(rawValue: "provisioning_profiles")
  public static let root = FileContainerKind(rawValue: "root")
  public static let springboardIcons = FileContainerKind(rawValue: "springboard_icons")
  public static let symbols = FileContainerKind(rawValue: "symbols")
  public static let wallpaper = FileContainerKind(rawValue: "wallpaper")
  public static let xctest = FileContainerKind(rawValue: "xctest")
  public static let dylib = FileContainerKind(rawValue: "dylib")
  public static let dsym = FileContainerKind(rawValue: "dsym")
  public static let framework = FileContainerKind(rawValue: "framework")
}

// MARK: - Host Filesystem Contained Files

/// A file on the host filesystem, addressed by absolute path.
public struct HostFile: ContainedFile, CustomStringConvertible {

  let path: String

  /// The file or directory at `path` on the host.
  public init(path: String) {
    self.path = path
  }

  public func removeItem() throws {
    try FileManager.default.removeItem(atPath: path)
  }

  public func contentsOfDirectory() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: path)
  }

  public func contentsOfFile() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
  }

  public func createDirectory() throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }

  public func fileExists() -> (exists: Bool, isDirectory: Bool) {
    var isDirectory: ObjCBool = false
    let exists = unsafe FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return (exists, isDirectory.boolValue)
  }

  public func move(to destination: any ContainedFile) throws {
    guard let hostDestination = destination as? HostFile else {
      throw FileContainerError.destinationNotOnHostFilesystem(destination: String(describing: destination))
    }
    try FileManager.default.moveItem(atPath: path, toPath: hostDestination.path)
  }

  public func populate(withContentsOfHostPath path: String) throws {
    try FileManager.default.copyItem(atPath: path, toPath: self.path)
  }

  public func populateHostPath(withContents path: String) throws {
    try FileManager.default.copyItem(atPath: self.path, toPath: path)
  }

  public func file(byAppendingPathComponent component: String) throws -> any ContainedFile {
    HostFile(path: (path as NSString).appendingPathComponent(component))
  }

  public var pathOnHostFileSystem: String? { path }

  public var pathMapping: [String: String]? { nil }

  public var description: String {
    "Host File \(path)"
  }
}

/// A virtual root that maps first path components onto host paths.
public struct MappedHostFile: ContainedFile, CustomStringConvertible {

  let mappingPaths: [String: String]

  /// A virtual root whose entries are the names in `mappingPaths`, each standing for the host path it maps to.
  public init(mappingPaths: [String: String]) {
    self.mappingPaths = mappingPaths
  }

  public func removeItem() throws {
    throw FileContainerError.unsupportedOnVirtualRoot(operation: #function)
  }

  public func contentsOfDirectory() throws -> [String] {
    Array(mappingPaths.keys)
  }

  public func contentsOfFile() throws -> Data {
    throw FileContainerError.unsupportedOnVirtualRoot(operation: #function)
  }

  public func createDirectory() throws {
    throw FileContainerError.unsupportedOnVirtualRoot(operation: #function)
  }

  public func fileExists() -> (exists: Bool, isDirectory: Bool) {
    (false, false)
  }

  public func move(to destination: any ContainedFile) throws {
    throw FileContainerError.movingUnsupportedOnVirtualRoot
  }

  public func populate(withContentsOfHostPath path: String) throws {
    throw FileContainerError.unsupportedOnVirtualRoot(operation: #function)
  }

  public func populateHostPath(withContents path: String) throws {
    throw FileContainerError.unsupportedOnVirtualRoot(operation: #function)
  }

  public func file(byAppendingPathComponent component: String) throws -> any ContainedFile {
    // The root of the mapping itself has nothing further to resolve.
    let pathComponents = (component as NSString).pathComponents
    if Self.isRootPathOfContainer(pathComponents) {
      return self
    }
    guard let firstComponent = pathComponents.first, let mappedPath = mappingPaths[firstComponent] else {
      throw FileContainerError.invalidRootPath(component: pathComponents.first ?? "", available: Array(mappingPaths.keys))
    }
    let mapped = HostFile(path: mappedPath)
    return try mapped.file(byAppendingPathComponent: Self.popFirstPathComponent(pathComponents))
  }

  public var pathOnHostFileSystem: String? { nil }

  public var pathMapping: [String: String]? { mappingPaths }

  public var description: String {
    "Root mapping: \(CollectionInformation.oneLineDescription(from: Array(mappingPaths.keys)))"
  }

  private static func isRootPathOfContainer(_ pathComponents: [String]) -> Bool {
    if pathComponents.isEmpty {
      return true
    }
    if pathComponents.count == 1, let first = pathComponents.first, first == "." || first == "/" {
      return true
    }
    return false
  }

  private static func popFirstPathComponent(_ pathComponents: [String]) -> String {
    pathComponents.dropFirst().reduce("") { ($0 as NSString).appendingPathComponent($1) }
  }
}

// MARK: - Containers

/// Namespaces the file container a target exposes over a `ContainedFile`.
public enum FileContainer {

  /// File container backed by a synchronous `ContainedFile`. Each operation
  /// resolves the target path and runs the synchronous file work on a serial
  /// queue.
  public final class ContainedRoot: AsyncFileContainer {

    private let rootFile: any ContainedFile
    private let queue: DispatchQueue

    /// A container rooted at the host path `basePath`.
    public convenience init(basePath: String) {
      self.init(rootFile: HostFile(path: basePath))
    }

    /// A container whose root is a virtual directory of the names in `pathMapping`.
    public convenience init(pathMapping: [String: String]) {
      self.init(rootFile: MappedHostFile(mappingPaths: pathMapping))
    }

    public init(rootFile: any ContainedFile, queue: DispatchQueue = DispatchQueue(label: "com.facebook.fbcontrolcore.file_container")) {
      self.rootFile = rootFile
      self.queue = queue
    }

    // MARK: - Host path access

    public var pathOnHostFileSystem: String? { rootFile.pathOnHostFileSystem }

    public var pathMapping: [String: String]? { rootFile.pathMapping }

    // MARK: - AsyncFileContainer

    public func copy(fromHost sourcePath: String, toContainer destinationPath: String) async throws {
      let rootFile = self.rootFile
      try await queue.perform {
        let directory = try rootFile.file(byAppendingPathComponent: destinationPath)
        if !directory.fileExists().exists {
          try directory.createDirectory()
        }
        // Attempt to delete first to overwrite.
        let destination = try directory.file(byAppendingPathComponent: (sourcePath as NSString).lastPathComponent)
        try? destination.removeItem()
        do {
          try destination.populate(withContentsOfHostPath: sourcePath)
        } catch {
          throw FileContainerError.copyIntoContainerFailed(source: sourcePath, destination: destinationPath, underlying: error)
        }
      }
    }

    public func copy(fromContainer sourcePath: String, toHost destinationPath: String) async throws -> String {
      let rootFile = self.rootFile
      return try await queue.perform {
        let source = try rootFile.file(byAppendingPathComponent: sourcePath)
        let (sourceExists, sourceIsDirectory) = source.fileExists()
        guard sourceExists else {
          throw FileContainerError.sourceDoesNotExist(source: String(describing: source))
        }
        var dstPath = destinationPath
        if !sourceIsDirectory {
          do {
            try FileManager.default.createDirectory(atPath: dstPath, withIntermediateDirectories: true)
          } catch {
            throw FileContainerError.temporaryDirectoryCreationFailed(underlying: error)
          }
          dstPath = (dstPath as NSString).appendingPathComponent((sourcePath as NSString).lastPathComponent)
        }
        // If it already exists at the destination path it must be removed before copying again.
        var destinationIsDirectory: ObjCBool = false
        if unsafe FileManager.default.fileExists(atPath: dstPath, isDirectory: &destinationIsDirectory) {
          do {
            try FileManager.default.removeItem(atPath: dstPath)
          } catch {
            throw FileContainerError.removalBeforeOverwriteFailed(path: dstPath, underlying: error)
          }
        }
        do {
          try source.populateHostPath(withContents: dstPath)
        } catch {
          throw FileContainerError.copyOutOfContainerFailed(source: String(describing: source), destination: dstPath, underlying: error)
        }
        return destinationPath
      }
    }

    public func tail(_ path: String, to consumer: any DataConsumer) async throws -> FileContainerTailOperation {
      let rootFile = self.rootFile
      let serialQueue = queue
      let hostPath = try await serialQueue.perform {
        let fileToTail = try rootFile.file(byAppendingPathComponent: path)
        guard let hostPath = fileToTail.pathOnHostFileSystem else {
          throw FileContainerError.notOnLocalFilesystem(file: String(describing: fileToTail))
        }
        return hostPath
      }
      // The unset builder default buffered stderr into memory that nothing
      // ever read; an open null device discards it outright.
      let running = try await Subprocess(executable: "/usr/bin/tail", arguments: ["-c+1", "-f", hostPath])
        .launch(output: .consumer(consumer), error: .nullDevice)
      return FileContainerTailOperation(running: running)
    }

    public func createDirectory(_ directoryPath: String) async throws {
      let rootFile = self.rootFile
      try await queue.perform {
        let directory = try rootFile.file(byAppendingPathComponent: directoryPath)
        do {
          try directory.createDirectory()
        } catch {
          throw FileContainerError.directoryCreationFailed(directory: String(describing: directory), underlying: error)
        }
      }
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
      let rootFile = self.rootFile
      try await queue.perform {
        let source = try rootFile.file(byAppendingPathComponent: sourcePath)
        let destination = try rootFile.file(byAppendingPathComponent: destinationPath)
        do {
          try source.move(to: destination)
        } catch {
          throw FileContainerError.moveFailed(source: String(describing: source), destination: String(describing: destination), underlying: error)
        }
      }
    }

    public func remove(_ path: String) async throws {
      let rootFile = self.rootFile
      try await queue.perform {
        let file = try rootFile.file(byAppendingPathComponent: path)
        do {
          try file.removeItem()
        } catch {
          throw FileContainerError.removalFailed(path: String(describing: file), underlying: error)
        }
      }
    }

    public func contents(ofDirectory path: String) async throws -> [String] {
      let rootFile = self.rootFile
      return try await queue.perform {
        let directory = try rootFile.file(byAppendingPathComponent: path)
        return try directory.contentsOfDirectory()
      }
    }
  }

  /// File container backed by `ProvisioningProfileCommands`.
  public final class ProvisioningProfile: AsyncFileContainer {

    private let commands: any ProvisioningProfileCommands

    public init(commands: any ProvisioningProfileCommands) {
      self.commands = commands
    }

    // MARK: - AsyncFileContainer

    public func copy(fromHost sourcePath: String, toContainer destinationPath: String) async throws {
      let data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
      _ = try await commands.install(data)
    }

    public func copy(fromContainer sourcePath: String, toHost destinationPath: String) async throws -> String {
      throw FileContainerError.unsupportedForProvisioningProfiles(operation: #function)
    }

    public func tail(_ path: String, to consumer: any DataConsumer) async throws -> FileContainerTailOperation {
      throw FileContainerError.unsupportedForProvisioningProfiles(operation: #function)
    }

    public func createDirectory(_ directoryPath: String) async throws {
      throw FileContainerError.unsupportedForProvisioningProfiles(operation: #function)
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
      throw FileContainerError.unsupportedForProvisioningProfiles(operation: #function)
    }

    public func remove(_ path: String) async throws {
      _ = try await commands.remove(uuid: path)
    }

    public func contents(ofDirectory path: String) async throws -> [String] {
      let profiles = try await commands.all()
      var files: [String] = []
      for profile in profiles {
        if let uuid = profile["UUID"] as? String {
          files.append(uuid)
        }
      }
      return files
    }
  }
}
