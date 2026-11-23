/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

enum BundleDescriptorError: Error {
  case binaryPathUnavailable(bundlePath: String)
  case bundleLoadFailed(path: String)
  case bundleIdentifierUnavailable(name: String, path: String)
  case noApplicationInIPA(presentFiles: [String])
  case multipleApplicationsInIPA(count: Int, found: [String])
}

extension BundleDescriptorError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .binaryPathUnavailable(bundlePath):
      return "Could not obtain binary path for bundle \(bundlePath)"
    case let .bundleLoadFailed(path):
      return "Failed to load bundle at path \(path)"
    case let .bundleIdentifierUnavailable(name, path):
      return "Could not obtain Bundle ID for bundle '\(name)' at \(path)"
    case let .noApplicationInIPA(presentFiles):
      return "Could not find an Application in IPA, present files \(CollectionInformation.oneLineDescription(from: presentFiles))"
    case let .multipleApplicationsInIPA(count, found):
      return "Expected only one Application in IPA, found \(count): \(CollectionInformation.oneLineDescription(from: found))"
    }
  }
}

public struct BundleDescriptor: Hashable, Sendable, CustomStringConvertible {

  // Boxed so that the many types embedding a descriptor copy one reference rather than every field;
  // inline, the fields' value witnesses are expanded into each embedding type.
  private final class Storage: Sendable {
    let name: String
    let identifier: String
    let path: String
    let binary: BinaryDescriptor?

    init(name: String, identifier: String, path: String, binary: BinaryDescriptor?) {
      self.name = name
      self.identifier = identifier
      self.path = path
      self.binary = binary
    }
  }

  private let storage: Storage

  public var name: String { storage.name }
  public var identifier: String { storage.identifier }
  public var path: String { storage.path }
  public var binary: BinaryDescriptor? { storage.binary }

  public init(name: String, identifier: String, path: String, binary: BinaryDescriptor?) {
    storage = Storage(name: name, identifier: identifier, path: path, binary: binary)
  }

  /// Reads the bundle at `path`. With `fallbackIdentifier`, a bundle without a bundle identifier is
  /// identified by its name rather than rejected.
  public init(path: String, fallbackIdentifier: Bool = false) throws {
    guard let bundle = Bundle(path: path) else {
      throw BundleDescriptorError.bundleLoadFailed(path: path)
    }
    let bundleName = BundleDescriptor.bundleNameForBundle(bundle)
    guard let identifier = bundle.bundleIdentifier ?? (fallbackIdentifier ? bundleName : nil) else {
      throw BundleDescriptorError.bundleIdentifierUnavailable(name: (path as NSString).lastPathComponent, path: path)
    }
    let binary = try BundleDescriptor.binaryForBundle(bundle)
    self.init(name: bundleName, identifier: identifier, path: path, binary: binary)
  }

  public static func == (lhs: BundleDescriptor, rhs: BundleDescriptor) -> Bool {
    lhs.storage === rhs.storage
      || (lhs.name == rhs.name && lhs.identifier == rhs.identifier && lhs.path == rhs.path && lhs.binary == rhs.binary)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(name)
    hasher.combine(identifier)
    hasher.combine(path)
    hasher.combine(binary)
  }

  public var description: String {
    "Name: \(name) | ID: \(identifier)"
  }

  public func updatePathsForRelocation(codesign: CodesignProvider, logger: any ControlCoreLogger) async throws {
    let replacements = try replacementsForBinary()
    if !replacements.isEmpty {
      var arguments: [String] = []
      for (key, value) in replacements {
        arguments.append("-rpath")
        arguments.append(key)
        arguments.append(value)
      }
      if let binaryPath = binary?.path {
        arguments.append(binaryPath)
      }
      logger.log("Updating rpaths for binary \(CollectionInformation.oneLineDescription(from: replacements as [String: Any]))")
      _ = try await Subprocess(executable: "/usr/bin/install_name_tool", arguments: arguments)
        .run(output: .string, error: .logger(logger))
    }
    logger.log("Re-Codesigning after rpath update \(path)")
    try await codesign.signBundle(atPath: path)
  }

  private static func binaryForBundle(_ bundle: Bundle) throws -> BinaryDescriptor {
    guard let binaryPath = bundle.executablePath else {
      throw BundleDescriptorError.binaryPathUnavailable(bundlePath: bundle.bundlePath)
    }
    return try BinaryDescriptor(path: binaryPath)
  }

  private static func bundleNameForBundle(_ bundle: Bundle) -> String {
    return (bundle.infoDictionary?["CFBundleName"] as? String)
      ?? (bundle.infoDictionary?["CFBundleExecutable"] as? String)
      ?? ((bundle.bundlePath as NSString).deletingPathExtension as NSString).lastPathComponent
  }

  private func replacementsForBinary() throws -> [String: String] {
    guard let rpaths = try binary?.rpaths() else {
      return [:]
    }
    return BundleDescriptor.interpolateRpathReplacements(forRPaths: rpaths)
  }

  private static func interpolateRpathReplacements(forRPaths rpaths: [String]) -> [String: String] {
    guard let regex = try? NSRegularExpression(pattern: "(/Applications/(?:xcode|Xcode).*\\.app/Contents/Developer)(.*)", options: []) else {
      return [:]
    }
    var replacements: [String: String] = [:]
    for rpath in rpaths {
      let result = regex.firstMatch(in: rpath, options: [], range: NSRange(location: 0, length: (rpath as NSString).length))
      guard let result else {
        continue
      }
      let oldXcodePath = (rpath as NSString).substring(with: result.range(at: 1))
      replacements[rpath] = rpath.replacingOccurrences(of: oldXcodePath, with: XcodeConfiguration.developerDirectory)
    }
    return replacements
  }

}

extension BundleDescriptor {

  public static func findAppPath(fromDirectory directory: URL, logger: (any ControlCoreLogger)?) throws -> BundleDescriptor {
    let directoryEnumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [],
      errorHandler: nil
    )
    var applicationPaths: [String] = []
    var nonApplicationPaths: [String] = []
    logger?.log("Finding Application Path from root directory \(directory)")
    if let enumerator = directoryEnumerator {
      for case let fileURL as URL in enumerator {
        let path = fileURL.path
        if BundleDescriptor.isApplication(atPath: path) {
          logger?.log("Found application at path \(path)")
          applicationPaths.append(path)
          enumerator.skipDescendants()
        } else {
          logger?.log("Non-application path at \(path)")
          nonApplicationPaths.append(path)
        }
      }
    }
    if applicationPaths.isEmpty {
      let lastComponents = nonApplicationPaths.map { ($0 as NSString).lastPathComponent }
      throw BundleDescriptorError.noApplicationInIPA(presentFiles: lastComponents)
    }
    if applicationPaths.count > 1 {
      let lastComponents = applicationPaths.map { ($0 as NSString).lastPathComponent }
      throw BundleDescriptorError.multipleApplicationsInIPA(count: applicationPaths.count, found: lastComponents)
    }
    let applicationPath = applicationPaths[0]
    logger?.log("Using Application at path \(applicationPath)")
    let bundle = try BundleDescriptor(path: applicationPath)
    logger?.log("Bundle in IPA is \(bundle)")
    return bundle
  }

  public static func isApplication(atPath path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return unsafe path.hasSuffix(".app")
      && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}
