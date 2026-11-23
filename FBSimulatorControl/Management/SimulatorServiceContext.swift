/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreSimulator
import FBControlCore
import Foundation

/// Errors thrown while resolving the CoreSimulator `SimServiceContext` and its device sets.
public enum SimulatorServiceContextError: LocalizedError, Sendable {

  /// The `SimServiceContext` class is not present in the process even though CoreSimulator
  /// reported a successful load.
  case serviceContextClassUnavailable

  /// No full Xcode is selected, so `XcodeConfiguration.developerDirectory` is empty. Resolving a
  /// `SimServiceContext` against an empty developer directory crashes CoreSimulator with an opaque
  /// `NSException`, so this is thrown up-front instead.
  case noFullXcodeSelected

  case serviceContextUnavailable(developerDirectory: String, reason: String?)
  case defaultDeviceSetUnavailable(reason: String?)
  case deviceSetUnavailable(configuration: String, reason: String?)
  case deviceSetDirectoryCreationFailed(path: String, reason: String)
  case deviceSetPathResolutionFailed(path: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .serviceContextClassUnavailable:
      return "The SimServiceContext class is not present after loading CoreSimulator."
    case .noFullXcodeSelected:
      return "No full Xcode developer directory is selected. Select one with `xcode-select -s` or set DEVELOPER_DIR."
    case .serviceContextUnavailable(let developerDirectory, let reason):
      return Self.describe("Could not create a SimServiceContext for developer directory '\(developerDirectory)'", reason)
    case .defaultDeviceSetUnavailable(let reason):
      return Self.describe("Failed to get default device set", reason)
    case .deviceSetUnavailable(let configuration, let reason):
      return Self.describe("Could not create underlying device set for configuration \(configuration)", reason)
    case .deviceSetDirectoryCreationFailed(let path, let reason):
      return "Failed to create custom SimDeviceSet directory at \(path): \(reason)"
    case .deviceSetPathResolutionFailed(let path, let reason):
      return "Failed to get realpath for \(path) '\(reason)'"
    }
  }

  private static func describe(_ base: String, _ reason: String?) -> String {
    guard let reason else { return base }
    return "\(base): \(reason)"
  }
}

extension SimulatorServiceContextError: CustomStringConvertible {
  /// Mirrors `errorDescription` so string interpolation (`"\(error)"`) and logs surface the
  /// human-readable message rather than the synthesized case name.
  public var description: String { errorDescription ?? "SimulatorServiceContextError" }
}

public final class SimulatorServiceContext {

  private let serviceContext: SimServiceContext

  // MARK: - Initialization

  nonisolated(unsafe) private static var _sharedInstance: SimulatorServiceContext?
  private static let sharedLock = NSLock()

  public static func sharedServiceContext() throws -> SimulatorServiceContext {
    return try sharedServiceContext(withLogger: ControlCoreGlobalConfiguration.defaultLogger)
  }

  public static func sharedServiceContext(withLogger logger: (any ControlCoreLogger)?) throws -> SimulatorServiceContext {
    sharedLock.lock()
    defer { sharedLock.unlock() }
    if let instance = unsafe _sharedInstance {
      return instance
    }
    let instance = try createServiceContext(withLogger: logger)
    unsafe _sharedInstance = instance
    return instance
  }

  // MARK: - Private Initialization

  private static func createServiceContext(withLogger logger: (any ControlCoreLogger)?) throws -> SimulatorServiceContext {
    try SimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
    guard
      let serviceContextClass = NSClassFromString("SimServiceContext") as? SimServiceContext.Type,
      serviceContextClass.responds(to: NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"))
    else {
      throw SimulatorServiceContextError.serviceContextClassUnavailable
    }
    // An empty developer directory makes -[SimServiceContext sharedServiceContextForDeveloperDir:error:]
    // crash with an opaque NSException; throw a clear error instead.
    let developerDirectory = XcodeConfiguration.developerDirectory
    guard !developerDirectory.isEmpty else {
      throw SimulatorServiceContextError.noFullXcodeSelected
    }

    var innerError: AnyObject?
    let serviceContext =
      unsafe serviceContextClass
      .sharedServiceContext(forDeveloperDir: developerDirectory, error: &innerError)
    guard let serviceContext = serviceContext as? SimServiceContext else {
      throw SimulatorServiceContextError.serviceContextUnavailable(
        developerDirectory: developerDirectory,
        reason: (innerError as? NSError)?.localizedDescription)
    }
    return SimulatorServiceContext(serviceContext: serviceContext)
  }

  private init(serviceContext: SimServiceContext) {
    self.serviceContext = serviceContext
  }

  public func supportedRuntimes() -> [SimRuntime] {
    return (serviceContext.supportedRuntimes as? [SimRuntime]) ?? []
  }

  public func supportedDeviceTypes() -> [SimDeviceType] {
    return (serviceContext.supportedDeviceTypes as? [SimDeviceType]) ?? []
  }

  func createDeviceSet(with configuration: SimulatorControlConfiguration) throws -> SimDeviceSet {
    guard let deviceSetPath = configuration.deviceSetPath else {
      // defaultDeviceSetWithError: takes (id *) not (NSError **), so use the raw API
      var error: AnyObject?
      guard let deviceSet = unsafe serviceContext.defaultDeviceSetWithError(&error) as? SimDeviceSet else {
        throw SimulatorServiceContextError.defaultDeviceSetUnavailable(reason: (error as? NSError)?.localizedDescription)
      }
      return deviceSet
    }
    let resolvedPath = try SimulatorServiceContext.fullyQualifiedDeviceSetPath(deviceSetPath)
    var innerError: AnyObject?
    guard let deviceSet = unsafe serviceContext.deviceSet(withPath: resolvedPath, error: &innerError) as? SimDeviceSet else {
      throw SimulatorServiceContextError.deviceSetUnavailable(
        configuration: "\(configuration)",
        reason: (innerError as? NSError)?.localizedDescription)
    }
    return deviceSet
  }

  private static func fullyQualifiedDeviceSetPath(_ deviceSetPath: String) throws -> String {
    do {
      try FileManager.default.createDirectory(atPath: deviceSetPath, withIntermediateDirectories: true, attributes: nil)
    } catch {
      throw SimulatorServiceContextError.deviceSetDirectoryCreationFailed(
        path: deviceSetPath,
        reason: error.localizedDescription)
    }

    // -[NSString stringByResolvingSymlinksInPath] doesn't resolve /var to /private/var.
    // This is important for -[SimServiceContext deviceSetWithPath:error:], which internally caches based on a fully resolved path.
    var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    guard let result = unsafe realpath(deviceSetPath, &pathBuffer) else {
      throw unsafe SimulatorServiceContextError.deviceSetPathResolutionFailed(
        path: deviceSetPath,
        reason: String(cString: strerror(errno)))
    }
    return unsafe String(cString: result)
  }
}
