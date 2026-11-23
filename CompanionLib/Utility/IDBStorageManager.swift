/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBArtifactStaging
import FBControlCore
import FBXCTestCore
import Foundation

let IdbTestBundlesFolder: String = "idb-test-bundles"
let IdbApplicationsFolder: String = "idb-applications"
let IdbDylibsFolder: String = "idb-dylibs"
let IdbDsymsFolder: String = "idb-dsyms"
let IdbFrameworksFolder: String = "idb-frameworks"

// MARK: - InstalledArtifact

enum IDBStorageError: Error {
  case bundleMissingBinary(name: String)
  case architecturesIncompatible(supported: [String], bundle: [String])
  case testNotFoundByID(bundleID: String)
  case baseDirectoryUnreadable
  case notExactlyOneTest(count: Int)
  case storageLocationCreationFailed(path: URL, underlying: any Error)
}

extension IDBStorageError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .bundleMissingBinary(name):
      return "Cannot check the architectures of \(name), it has no binary"
    case let .architecturesIncompatible(supported, bundle):
      return "The supported architectures of the target \(CollectionInformation.oneLineDescription(from: supported)) do not intersect with any architectures in the bundle: \(CollectionInformation.oneLineDescription(from: bundle))"
    case let .testNotFoundByID(bundleID):
      return "Couldn't find test with id: \(bundleID)"
    case .baseDirectoryUnreadable:
      return "Error reading test bundle base directory"
    case let .notExactlyOneTest(count):
      return "Expected exactly one test in the xctestrun file, got: \(count)"
    case let .storageLocationCreationFailed(path, _):
      return "Failed to create xctest storage location \(path)"
    }
  }
}

public final class InstalledArtifact {
  public let name: String
  public let uuid: NSUUID?
  public let path: URL

  public init(name: String, uuid: NSUUID?, path: URL) {
    self.name = name
    self.uuid = uuid
    self.path = path
  }
}

extension InstalledArtifact: InstalledName {
  public var installedName: String { name }
}

// MARK: - IDBStorage

public class IDBStorage {
  public let target: any Target
  public let basePath: URL
  public let queue: DispatchQueue
  public let logger: any ControlCoreLogger

  public init(target: any Target, basePath: URL, queue: DispatchQueue, logger: any ControlCoreLogger) {
    self.target = target
    self.basePath = basePath
    self.queue = queue
    self.logger = logger
  }

  public func clean() throws {
    let urls = try FileManager.default.contentsOfDirectory(at: basePath, includingPropertiesForKeys: nil, options: [])
    for url in urls {
      try FileManager.default.removeItem(atPath: url.path)
    }
  }

  func asFileContainer() -> any AsyncFileContainer {
    FileContainer.ContainedRoot(basePath: basePath.path)
  }

  public var replacementMapping: [String: String] {
    var mapping: [String: String] = [:]
    let urls = try? FileManager.default.contentsOfDirectory(at: basePath, includingPropertiesForKeys: nil, options: [])
    if let urls {
      for url in urls {
        mapping[url.lastPathComponent] = url.path
      }
    }
    return mapping
  }
}

// MARK: - FileStorage

public final class FileStorage: IDBStorage {

  func saveFile(_ url: URL) throws -> InstalledArtifact {
    return try copyInto(basePath, from: url)
  }

  func saveFileInUniquePath(_ url: URL) throws -> InstalledArtifact {
    var baseURL = basePath
    baseURL = baseURL.appendingPathComponent(NSUUID().uuidString)
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true, attributes: nil)
    return try copyInto(baseURL, from: url)
  }

  private func copyInto(_ basePath: URL, from fromURL: URL) throws -> InstalledArtifact {
    let destination = basePath.appendingPathComponent(fromURL.lastPathComponent)
    logger.log("Persisting \(fromURL.lastPathComponent) to \(destination)")
    try FileManager.default.copyItem(at: fromURL, to: destination)
    logger.log("Persisted \(destination.lastPathComponent)")
    return InstalledArtifact(name: destination.lastPathComponent, uuid: nil, path: destination)
  }
}

// MARK: - BundleStorage

public class BundleStorage: IDBStorage {
  public let relocateLibraries: Bool

  public init(target: any Target, basePath: URL, queue: DispatchQueue, logger: any ControlCoreLogger, relocateLibraries: Bool) {
    self.relocateLibraries = relocateLibraries
    super.init(target: target, basePath: basePath, queue: queue, logger: logger)
  }

  func checkArchitecture(_ bundle: BundleDescriptor) throws {
    guard let binary = bundle.binary else {
      throw IDBStorageError.bundleMissingBinary(name: bundle.name)
    }
    let binaryArchitectures = Set(binary.architectures.map { $0.rawValue })
    let targetArchs = target.architectures
    let supportedArchitectures = Set(TargetConfiguration.baseArchsToCompatibleArch(targetArchs).map { $0.rawValue })

    let containsExactArch = !binaryArchitectures.isDisjoint(with: supportedArchitectures)
    let arm64eEquivalent = targetArchs.contains(Architecture.arm64e) && binaryArchitectures.contains("arm64")

    if !(containsExactArch || arm64eEquivalent) {
      throw IDBStorageError.architecturesIncompatible(supported: supportedArchitectures.sorted(), bundle: binaryArchitectures.sorted())
    }
  }

  func saveBundle(_ bundle: BundleDescriptor) async throws -> InstalledArtifact {
    return try await saveBundle(bundle, usingSymlink: true, skipSigningBundles: false)
  }

  func saveBundle(_ bundle: BundleDescriptor, usingSymlink useSymlink: Bool, skipSigningBundles: Bool) async throws -> InstalledArtifact {
    try checkArchitecture(bundle)

    let storageDirectory = basePath.appendingPathComponent(bundle.identifier)
    try prepareDirectory(with: storageDirectory)

    let sourceBundlePath = URL(fileURLWithPath: bundle.path)
    let destinationBundlePath = storageDirectory.appendingPathComponent(sourceBundlePath.lastPathComponent)
    if useSymlink {
      logger.log("Symlink \(bundle.identifier) to \(destinationBundlePath)")
      try FileManager.default.createSymbolicLink(at: destinationBundlePath, withDestinationURL: sourceBundlePath)
    } else {
      logger.log("Moving \(bundle.identifier) to \(destinationBundlePath)")
      try FileManager.default.moveItem(at: sourceBundlePath, to: destinationBundlePath)
      logger.log("Moved \(bundle.identifier)")
    }

    let artifact = InstalledArtifact(name: bundle.identifier, uuid: bundle.binary?.uuid as NSUUID?, path: destinationBundlePath)
    if !relocateLibraries || !target.requiresBundlesToBeSigned() || skipSigningBundles {
      return artifact
    }
    let updatedBundle = try BundleDescriptor(path: destinationBundlePath.path)
    let provider = CodesignProvider(identityName: "-", logger: logger)
    try await updatedBundle.updatePathsForRelocation(codesign: provider, logger: logger)
    return artifact
  }

  public var persistedBundleIDs: Set<String> {
    let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath.path)
    return Set(contents ?? [])
  }

  var persistedBundles: [String: BundleDescriptor] {
    var mapping: [String: BundleDescriptor] = [:]
    guard let enumerator = FileManager.default.enumerator(at: basePath, includingPropertiesForKeys: nil, options: .skipsSubdirectoryDescendants, errorHandler: nil) else {
      return mapping
    }
    for case let directory as URL in enumerator {
      let key = directory.lastPathComponent
      guard let bundlePath = try? StorageUtils.findUniqueFile(inDirectory: directory) else {
        continue
      }
      do {
        let bundle = try BundleDescriptor(path: bundlePath.path)
        mapping[key] = bundle
      } catch {
        logger.log("Failed to get bundle info for bundle at path \(bundlePath)")
      }
    }
    return mapping
  }

  public override var replacementMapping: [String: String] {
    let bundles = persistedBundles
    var mapping: [String: String] = [:]
    for (_, bundle) in bundles {
      mapping[bundle.identifier] = bundle.path
      if let uuid = bundle.binary?.uuid {
        mapping[uuid.uuidString] = bundle.path
      }
    }
    return mapping
  }

  private func prepareDirectory(with url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.discardItem(at: url)
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
  }
}

// MARK: - XCTestBundleStorage

private let XctestExtension = "xctest"
private let XctestRunExtension = "xctestrun"

public final class XCTestBundleStorage: BundleStorage {

  func listTestDescriptors() throws -> [any XCTestDescriptor] {
    var testDescriptors: [any XCTestDescriptor] = []

    let testURLs = try listTestBundles()
    let xcTestRunURLs = try listXCTestRunFiles()

    for testURL in testURLs {
      do {
        let bundle = try BundleDescriptor(path: testURL.path, fallbackIdentifier: true)
        let testDescriptor = XCTestBootstrapDescriptor(url: testURL, name: bundle.name, testBundle: bundle)
        testDescriptors.append(testDescriptor)
      } catch {
        logger.error().log("\(error)")
      }
    }

    for xcTestRunURL in xcTestRunURLs {
      do {
        let descriptors = try getXCTestRunDescriptors(from: xcTestRunURL)
        testDescriptors.append(contentsOf: descriptors)
      } catch {
        logger.error().log("\(error)")
      }
    }

    return testDescriptors
  }

  func testDescriptor(withID bundleId: String) throws -> any XCTestDescriptor {
    let testDescriptors = try listTestDescriptors()
    for testDescriptor in testDescriptors {
      if testDescriptor.testBundleID == bundleId {
        return testDescriptor
      }
    }
    throw IDBStorageError.testNotFoundByID(bundleID: bundleId)
  }

  func getXCTestRunDescriptors(from xctestrunURL: URL) throws -> [any XCTestDescriptor] {
    let contentDict = try XCTestRunFileReader.readContents(of: xctestrunURL, expandPlaceholderWithPath: target.auxillaryDirectory)
    let xctestrunMetadata = contentDict["__xctestrun_metadata__"] as? [String: NSNumber]
    if let xctestrunMetadata {
      logger.info().log("Using xctestrun format version: \(xctestrunMetadata["FormatVersion"] ?? 0)")
      return getDescriptors(from: contentDict, with: xctestrunURL)
    } else {
      logger.info().log("Using the legacy xctestrun file format")
      return legacyGetDescriptors(from: contentDict, with: xctestrunURL)
    }
  }

  // MARK: - Private

  private func listTestBundles() throws -> Set<URL> {
    return try listXCTestContents(withExtension: XctestExtension)
  }

  private func listXCTestRunFiles() throws -> Set<URL> {
    return try listXCTestContents(withExtension: XctestRunExtension)
  }

  private func listXCTestContents(withExtension ext: String) throws -> Set<URL> {
    guard let directories = try? FileManager.default.contentsOfDirectory(at: basePath, includingPropertiesForKeys: nil, options: .skipsSubdirectoryDescendants) else {
      throw IDBStorageError.baseDirectoryUnreadable
    }

    var tests = Set<URL>()
    for innerDirectory in directories {
      if let bundleURL = try? StorageUtils.findFile(withExtension: ext, at: innerDirectory) {
        tests.insert(bundleURL)
      }
    }
    return tests
  }

  private func getDescriptors(from xctestrunContents: [String: Any], with xctestrunURL: URL) -> [any XCTestDescriptor] {
    var descriptors: [any XCTestDescriptor] = []
    for field in xctestrunContents.keys {
      logger.info().log("Checking the \(field) field to extract test descriptors")
      if field == "__xctestrun_metadata__" || field == "CodeCoverageBuildableInfos" {
        continue
      }
      if let descriptor = getDescriptor(for: field, from: xctestrunContents, with: xctestrunURL) {
        descriptors.append(descriptor)
      }
    }
    return descriptors
  }

  private func legacyGetDescriptors(from xctestrunContents: [String: Any], with xctestrunURL: URL) -> [any XCTestDescriptor] {
    var descriptors: [any XCTestDescriptor] = []
    for testTarget in xctestrunContents.keys {
      if let descriptor = getDescriptor(for: testTarget, from: xctestrunContents, with: xctestrunURL) {
        descriptors.append(descriptor)
      }
    }
    return descriptors
  }

  private func getDescriptor(for testTarget: String, from xctestrunContents: [String: Any], with xctestrunURL: URL) -> (any XCTestDescriptor)? {
    guard let testTargetProperties = xctestrunContents[testTarget] as? [String: Any] else {
      return nil
    }
    let useArtifacts = testTargetProperties["UseDestinationArtifacts"] as? NSNumber
    if let useArtifacts, useArtifacts.boolValue {
      guard let hostIdentifier = testTargetProperties["TestHostBundleIdentifier"] as? String else {
        logger.error().log("Using UseDestinationArtifacts requires TestHostBundleIdentifier")
        return nil
      }
      guard let testIdentifier = testTargetProperties["FB_TestBundleIdentifier"] as? String else {
        logger.error().log("Using UseDestinationArtifacts requires FB_TestBundleIdentifier")
        return nil
      }
      let testBundle = BundleDescriptor(name: testIdentifier, identifier: testIdentifier, path: "", binary: nil)
      let hostBundle = BundleDescriptor(name: hostIdentifier, identifier: hostIdentifier, path: "", binary: nil)
      return XCodebuildTestRunDescriptor(url: xctestrunURL, name: testTarget, testBundle: testBundle, testHostBundle: hostBundle)
    }
    guard let testHostPath = testTargetProperties["TestHostPath"] as? String,
      let testBundlePath = testTargetProperties["TestBundlePath"] as? String
    else {
      return nil
    }
    guard let testHostBundle = try? BundleDescriptor(path: testHostPath) else {
      return nil
    }
    guard let testBundle = try? BundleDescriptor(path: testBundlePath) else {
      return nil
    }
    return XCodebuildTestRunDescriptor(url: xctestrunURL, name: testTarget, testBundle: testBundle, testHostBundle: testHostBundle)
  }

  func saveTestBundle(_ testBundleURL: URL, usingSymlink useSymlink: Bool, skipSigningBundles: Bool) async throws -> InstalledArtifact {
    let bundle = try BundleDescriptor(path: testBundleURL.path, fallbackIdentifier: true)
    return try await saveBundle(bundle, usingSymlink: useSymlink, skipSigningBundles: skipSigningBundles)
  }

  func saveTestRun(_ xcTestRunURL: URL) throws -> InstalledArtifact {
    let descriptors = try getXCTestRunDescriptors(from: xcTestRunURL)
    if descriptors.count != 1 {
      throw IDBStorageError.notExactlyOneTest(count: descriptors.count)
    }

    let descriptor = descriptors[0]
    if let toDelete = try? testDescriptor(withID: descriptor.testBundleID) {
      try FileManager.default.removeItem(at: toDelete.url.deletingLastPathComponent())
    }

    let uuidString = NSUUID().uuidString
    let newPath = basePath.appendingPathComponent(uuidString)
    try prepareDirectory(with: newPath)

    let dir = xcTestRunURL.deletingLastPathComponent()
    let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])
    for url in contents {
      try FileManager.default.copyItem(at: url, to: newPath.appendingPathComponent(url.lastPathComponent))
    }

    return InstalledArtifact(name: descriptor.testBundleID, uuid: nil, path: dir)
  }

  private func prepareDirectory(with url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
  }
}

// MARK: - IDBStorageManager

public final class IDBStorageManager {
  public let xctest: XCTestBundleStorage
  public let application: BundleStorage
  public let dylib: FileStorage
  public let dsym: FileStorage
  public let framework: BundleStorage
  public let logger: any ControlCoreLogger

  private init(xctest: XCTestBundleStorage, application: BundleStorage, dylib: FileStorage, dsym: FileStorage, framework: BundleStorage, logger: any ControlCoreLogger) {
    self.xctest = xctest
    self.application = application
    self.dylib = dylib
    self.dsym = dsym
    self.framework = framework
    self.logger = logger
  }

  /// Prepares the storage directories for `target`, creating them if needed.
  public convenience init(target: any Target, logger: any ControlCoreLogger) throws {
    let queue = DispatchQueue(label: "com.facebook.idb.bundle_storage")

    let xctestBasePath = try IDBStorageManager.prepareStoragePath(withName: IdbTestBundlesFolder, target: target)
    let xctest = XCTestBundleStorage(target: target, basePath: xctestBasePath, queue: queue, logger: logger, relocateLibraries: true)

    let appBasePath = try IDBStorageManager.prepareStoragePath(withName: IdbApplicationsFolder, target: target)
    let application = BundleStorage(target: target, basePath: appBasePath, queue: queue, logger: logger, relocateLibraries: false)

    let dylibBasePath = try IDBStorageManager.prepareStoragePath(withName: IdbDylibsFolder, target: target)
    let dylib = FileStorage(target: target, basePath: dylibBasePath, queue: queue, logger: logger)

    let dsymBasePath = try IDBStorageManager.prepareStoragePath(withName: IdbDsymsFolder, target: target)
    let dsym = FileStorage(target: target, basePath: dsymBasePath, queue: queue, logger: logger)

    let frameworkBasePath = try IDBStorageManager.prepareStoragePath(withName: IdbFrameworksFolder, target: target)
    let framework = BundleStorage(target: target, basePath: frameworkBasePath, queue: queue, logger: logger, relocateLibraries: true)

    self.init(xctest: xctest, application: application, dylib: dylib, dsym: dsym, framework: framework, logger: logger)
  }

  public func clean() throws {
    try xctest.clean()
    try application.clean()
    try dylib.clean()
    try dsym.clean()
    try framework.clean()
  }

  public var replacementMapping: [String: String] {
    var combined: [String: String] = [:]
    for mapping in [application.replacementMapping, dylib.replacementMapping, framework.replacementMapping, dsym.replacementMapping] {
      combined.merge(mapping) { _, new in new }
    }
    return combined
  }

  private static func prepareStoragePath(withName name: String, target: any Target) throws -> URL {
    let basePath = URL(fileURLWithPath: target.auxillaryDirectory).appendingPathComponent(name)
    do {
      try FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true, attributes: nil)
    } catch {
      throw IDBStorageError.storageLocationCreationFailed(path: basePath, underlying: error)
    }
    return basePath
  }
}
