/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

enum ManagedTestRunError: Error, LocalizedError {
  case frameworkLoadingFailed(underlying: any Error)

  public var errorDescription: String? {
    switch self {
    case let .frameworkLoadingFailed(underlying):
      return underlying.localizedDescription
    }
  }
}

public enum ManagedTestRunner {

  public static func runToCompletion(withTarget target: any XCTestExtendedTarget, configuration: TestLaunchConfiguration, codesign: CodesignProvider?, workingDirectory: String, reporter: any XCTestReporter, logger: any ControlCoreLogger) async throws {
    do {
      try XCTestBootstrapFrameworkLoader.allDependentFrameworks.loadPrivateFrameworks(target.logger)
    } catch {
      throw ManagedTestRunError.frameworkLoadingFailed(underlying: error)
    }

    let runnerConfiguration = try await TestRunnerConfiguration(
      target: target,
      testLaunchConfiguration: configuration,
      workingDirectory: workingDirectory,
      codesign: codesign
    )

    let testHostLaunchConfiguration = prepareApplicationLaunchConfiguration(configuration.applicationLaunchConfiguration, withTestRunnerConfiguration: runnerConfiguration)

    let context = TestManagerContext(
      sessionIdentifier: runnerConfiguration.sessionIdentifier,
      timeout: configuration.timeout,
      testHostLaunchConfiguration: testHostLaunchConfiguration,
      testedApplicationAdditionalEnvironment: runnerConfiguration.testedApplicationAdditionalEnvironment,
      testConfiguration: runnerConfiguration.testConfiguration
    )

    try await TestManagerAPIMediator.connectAndRunUntilCompletion(
      with: context,
      target: target,
      reporter: reporter,
      logger: logger
    )
  }

  private static func prepareApplicationLaunchConfiguration(_ applicationLaunchConfiguration: ApplicationLaunchConfiguration, withTestRunnerConfiguration testRunnerConfiguration: TestRunnerConfiguration) -> ApplicationLaunchConfiguration {
    ApplicationLaunchConfiguration(
      bundleID: testRunnerConfiguration.testRunner.identifier,
      bundleName: testRunnerConfiguration.testRunner.identifier,
      arguments: arguments(fromConfiguration: testRunnerConfiguration, attributes: applicationLaunchConfiguration.arguments),
      environment: environment(fromConfiguration: testRunnerConfiguration, environment: applicationLaunchConfiguration.environment),
      waitForDebugger: applicationLaunchConfiguration.waitForDebugger,
      stdOut: applicationLaunchConfiguration.stdOut,
      stdErr: applicationLaunchConfiguration.stdErr,
      launchMode: .relaunchIfRunning
    )
  }

  private static func arguments(fromConfiguration configuration: TestRunnerConfiguration, attributes: [String]) -> [String] {
    configuration.launchArguments + attributes
  }

  private static func environment(fromConfiguration configuration: TestRunnerConfiguration, environment: [String: String]) -> [String: String] {
    var mEnvironment = configuration.launchEnvironment
    for (key, value) in environment {
      mEnvironment[key] = value
    }
    return mEnvironment
  }
}
