/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// `XCTCapabilitiesBuilder`, messaged through its selectors: naming XCTest's private classes as types
/// would link against the private frameworks that vend them.
@objc private protocol XCTCapabilitiesBuilderMessaging {
  @objc(registerCapability:) func registerCapability(_ capability: NSString)
  @objc(capabilities) func capabilities() -> AnyObject
}

@objc private protocol XCTTestIdentifierSetBuilderMessaging {
  @objc(init) func initialize() -> AnyObject?
  @objc(addTestIdentifier:) func add(_ identifier: AnyObject)
  @objc(testIdentifierSet) func testIdentifierSet() -> AnyObject
}

@objc private protocol XCTTestIdentifierMessaging {
  @objc(initWithStringRepresentation:preserveModulePrefix:) func initialize(stringRepresentation: NSString, preserveModulePrefix: Bool) -> AnyObject?
}

public enum TestConfigurationError: Error, LocalizedError {
  case classUnavailable(className: String)
  case archivingFailed(underlying: any Error)

  public var errorDescription: String? {
    switch self {
    case let .classUnavailable(className):
      return "\(className) is not loaded, so a test configuration cannot be built"
    case let .archivingFailed(underlying):
      return "The test configuration could not be archived: \(underlying.localizedDescription)"
    }
  }
}

/// Represents the `XCTestConfiguration` Apple uses to configure a test run (an `.xctestconfiguration`).
@objc public final class TestConfiguration: NSObject {

  @objc public let sessionIdentifier: UUID
  /// The name of the test module.
  @objc public let moduleName: String
  /// The path to the test bundle.
  @objc public let testBundlePath: String
  /// The path the configuration was written to.
  @objc public let path: String
  /// Whether the test runner initializes for UI testing.
  @objc public let shouldInitializeForUITesting: Bool
  /// The underlying `XCTestConfiguration`.
  @objc public let xcTestConfiguration: NSObject

  /// Builds a test configuration and writes it beside the test bundle, as
  /// `<moduleName>-<sessionIdentifier>.xctestconfiguration`.
  public convenience init(
    byWritingToFileWithSessionIdentifier sessionIdentifier: UUID,
    moduleName: String,
    testBundlePath: String,
    uiTesting: Bool,
    testsToRun: Set<String>?,
    testsToSkip: Set<String>?,
    targetApplicationPath: String?,
    targetApplicationBundleID: String?,
    testApplicationDependencies: [String: String]?,
    automationFrameworkPath: String?,
    reportActivities: Bool
  ) throws {
    guard let configuration = RuntimeClassAllocation.new("XCTestConfiguration") as? NSObject else {
      throw TestConfigurationError.classUnavailable(className: "XCTestConfiguration")
    }
    configuration.setValue(sessionIdentifier, forKey: "sessionIdentifier")
    configuration.setValue(URL(fileURLWithPath: testBundlePath), forKey: "testBundleURL")
    configuration.setValue(false, forKey: "treatMissingBaselinesAsFailures")
    configuration.setValue(moduleName, forKey: "productModuleName")
    configuration.setValue(true, forKey: "reportResultsToIDE")
    configuration.setValue(uiTesting, forKey: "testsMustRunOnMainThread")
    configuration.setValue(uiTesting, forKey: "initializeForUITesting")
    configuration.setValue(try Self.testIdentifierSet(testsToSkip), forKey: "testsToSkip")
    configuration.setValue(try Self.testIdentifierSet(testsToRun), forKey: "testsToRun")
    configuration.setValue(targetApplicationPath, forKey: "targetApplicationPath")
    configuration.setValue(targetApplicationBundleID, forKey: "targetApplicationBundleID")
    configuration.setValue(automationFrameworkPath, forKey: "automationFrameworkPath")
    configuration.setValue(reportActivities, forKey: "reportActivities")
    configuration.setValue(false, forKey: "testsDrivenByIDE")
    configuration.setValue(testApplicationDependencies, forKey: "testApplicationDependencies")

    configuration.setValue(try Self.ideCapabilities(), forKey: "IDECapabilities")

    let data: Data
    do {
      data = try NSKeyedArchiver.archivedData(withRootObject: configuration, requiringSecureCoding: false)
    } catch {
      throw TestConfigurationError.archivingFailed(underlying: error)
    }
    let path = ((testBundlePath as NSString).deletingLastPathComponent as NSString)
      .appendingPathComponent("\(moduleName)-\(sessionIdentifier.uuidString).xctestconfiguration")
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    self.init(
      sessionIdentifier: sessionIdentifier,
      moduleName: moduleName,
      testBundlePath: testBundlePath,
      path: path,
      uiTesting: uiTesting,
      xcTestConfiguration: configuration)
  }

  init(sessionIdentifier: UUID, moduleName: String, testBundlePath: String, path: String, uiTesting: Bool, xcTestConfiguration: NSObject) {
    self.sessionIdentifier = sessionIdentifier
    self.moduleName = moduleName
    self.testBundlePath = testBundlePath
    self.path = path
    self.shouldInitializeForUITesting = uiTesting
    self.xcTestConfiguration = xcTestConfiguration
    super.init()
  }

  /// The `XCTCapabilities` idb declares as the IDE, to the test runner and to testmanagerd.
  static func ideCapabilities() throws -> AnyObject {
    guard let capabilitiesBuilderInstance = RuntimeClassAllocation.new("XCTCapabilitiesBuilder") else {
      throw TestConfigurationError.classUnavailable(className: "XCTCapabilitiesBuilder")
    }
    let capabilitiesBuilder = unsafe unsafeBitCast(capabilitiesBuilderInstance, to: (any XCTCapabilitiesBuilderMessaging).self)
    capabilitiesBuilder.registerCapability("XCTIssue capability")
    capabilitiesBuilder.registerCapability("ubiquitous test identifiers")
    return capabilitiesBuilder.capabilities()
  }

  private static func testIdentifierSet(_ tests: Set<String>?) throws -> AnyObject? {
    guard let tests else {
      return nil
    }
    guard
      let allocatedBuilder = RuntimeClassAllocation.alloc("XCTTestIdentifierSetBuilder"),
      let builderInstance = unsafe unsafeBitCast(allocatedBuilder, to: (any XCTTestIdentifierSetBuilderMessaging).self).initialize()
    else {
      throw TestConfigurationError.classUnavailable(className: "XCTTestIdentifierSetBuilder")
    }
    let builder = unsafe unsafeBitCast(builderInstance, to: (any XCTTestIdentifierSetBuilderMessaging).self)
    for test in tests {
      guard
        let allocatedIdentifier = RuntimeClassAllocation.alloc("XCTTestIdentifier"),
        let identifier = unsafe unsafeBitCast(allocatedIdentifier, to: (any XCTTestIdentifierMessaging).self)
          .initialize(stringRepresentation: test as NSString, preserveModulePrefix: true)
      else {
        throw TestConfigurationError.classUnavailable(className: "XCTTestIdentifier")
      }
      builder.add(identifier)
    }
    return builder.testIdentifierSet()
  }
}
