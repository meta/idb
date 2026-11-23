/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

private let shimulatorFileName = "libShimulator-iOS.dylib"
private let maculatorShimFileName = "libShimulator-macOS.dylib"

private enum CanonicalShim: CaseIterable {
  case iOSSimulatorTest
  case macTest

  var filename: String {
    switch self {
    case .iOSSimulatorTest: return shimulatorFileName
    case .macTest: return maculatorShimFileName
    }
  }

  var codesigningRequired: Bool {
    switch self {
    case .iOSSimulatorTest: return ControlCoreGlobalConfiguration.confirmCodesignaturesAreValid
    case .macTest: return false
    }
  }
}

enum XCTestShimError: Error {
  case shimMissing(path: String)
  case shimUnsigned(path: String, underlying: any Error)
  case searchPathUnresolvable
  case shimDirectoryMissing(directory: String)
  case shimsMissingInDirectory(shimNames: [String], directory: String, underlying: any Error)
}

extension XCTestShimError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .shimMissing(path):
      return "No shim located at expected location of \(path)"
    case let .shimUnsigned(path, _):
      return "Shim at path \(path) was required to be signed, but it was not"
    case .searchPathUnresolvable:
      return "Unable to determine the shim search path."
    case let .shimDirectoryMissing(directory):
      return "A shim directory was searched for at '\(directory)', but it was not there"
    case let .shimsMissingInDirectory(shimNames, directory, underlying):
      return "Could not find all shims \(CollectionInformation.oneLineDescription(from: shimNames)) in the expected directory \(directory): \(underlying.localizedDescription)"
    }
  }
}

public struct XCTestShimConfiguration: Sendable {

  public let iOSSimulatorTestShimPath: String
  public let macOSTestShimPath: String

  public init(iOSSimulatorTestShimPath: String, macOSTestShimPath: String) {
    assert(!iOSSimulatorTestShimPath.isEmpty)
    assert(!macOSTestShimPath.isEmpty)
    self.iOSSimulatorTestShimPath = iOSSimulatorTestShimPath
    self.macOSTestShimPath = macOSTestShimPath
  }

  public static let audioInjectionEnvironmentVariable = "IDB_AUDIO_INJECTION"

  public static func unarmedAudioInjectionEnvironment(_ environment: [String: String]) -> [String: String] {
    var unarmed = environment
    unarmed[audioInjectionEnvironmentVariable] = environment[audioInjectionEnvironmentVariable] ?? "0"
    return unarmed
  }

  // MARK: - Lookup

  private static func pathForCanonicallyNamedShim(_ shim: CanonicalShim, inDirectory directory: String) async throws -> String {
    let shimPath = (directory as NSString).appendingPathComponent(shim.filename)
    guard FileManager.default.fileExists(atPath: shimPath) else {
      throw XCTestShimError.shimMissing(path: shimPath)
    }
    guard shim.codesigningRequired else {
      return shimPath
    }
    let codesign = CodesignProvider(identityName: "-", logger: nil)
    do {
      _ = try await codesign.cdHash(ofBundleAtPath: shimPath)
    } catch {
      throw XCTestShimError.shimUnsigned(path: shimPath, underlying: error)
    }
    return shimPath
  }

  public static func findShimDirectory() async throws -> String {
    guard let searchPath = BundledResources.directoryPath() else {
      throw XCTestShimError.searchPathUnresolvable
    }
    do {
      return try await confirmExistenceOfRequiredShims(inDirectory: searchPath)
    } catch {
      throw XCTestShimError.shimsMissingInDirectory(shimNames: CanonicalShim.allCases.map(\.filename), directory: searchPath, underlying: error)
    }
  }

  private static func confirmExistenceOfRequiredShims(inDirectory directory: String) async throws -> String {
    guard FileManager.default.fileExists(atPath: directory) else {
      throw XCTestShimError.shimDirectoryMissing(directory: directory)
    }
    async let iOSSimulatorShim = pathForCanonicallyNamedShim(.iOSSimulatorTest, inDirectory: directory)
    async let macShim = pathForCanonicallyNamedShim(.macTest, inDirectory: directory)
    _ = try await (iOSSimulatorShim, macShim)
    return directory
  }

  // Caches the first resolution for the life of the process; actor isolation ensures exactly one resolution
  // runs even when first callers race.
  private actor SharedResolution {
    private var task: Task<XCTestShimConfiguration, any Error>?

    func configuration() async throws -> XCTestShimConfiguration {
      if let task {
        return try await task.value
      }
      let task = Task { try await XCTestShimConfiguration.defaultShimConfiguration() }
      self.task = task
      return try await task.value
    }
  }

  private static let sharedResolution = SharedResolution()

  public static func sharedShimConfiguration() async throws -> XCTestShimConfiguration {
    try await sharedResolution.configuration()
  }

  public static func defaultShimConfiguration() async throws -> XCTestShimConfiguration {
    let directory = try await findShimDirectory()
    return try await XCTestShimConfiguration(directory: directory)
  }

  /// The shims in `directory`, which must hold every required shim.
  public init(directory: String) async throws {
    _ = try await Self.confirmExistenceOfRequiredShims(inDirectory: directory)
    async let iOSSimulatorTestShimPath = Self.pathForCanonicallyNamedShim(.iOSSimulatorTest, inDirectory: directory)
    async let macOSTestShimPath = Self.pathForCanonicallyNamedShim(.macTest, inDirectory: directory)
    try await self.init(
      iOSSimulatorTestShimPath: iOSSimulatorTestShimPath,
      macOSTestShimPath: macOSTestShimPath)
  }

}
