/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBXCTestCore
import Foundation

public final class IDBTestOperation: CustomStringConvertible {

  /// The configuration the run was started from. A logic test and an app-hosted test are
  /// configured by unrelated types, and only one of the two is ever in play.
  public enum Configuration: CustomStringConvertible {
    case logic(LogicTestConfiguration)
    case appHosted(TestLaunchConfiguration)

    public var description: String {
      switch self {
      case let .logic(configuration):
        return String(describing: configuration)
      case let .appHosted(configuration):
        return String(describing: configuration)
      }
    }
  }

  public let logger: any ControlCoreLogger
  public let queue: DispatchQueue
  public let reporter: any XCTestReporter
  public let reporterConfiguration: XCTestReporterConfiguration
  private let configuration: Configuration
  private let completion: Task<Void, any Error>

  public init(configuration: Configuration, reporterConfiguration: XCTestReporterConfiguration, reporter: any XCTestReporter, logger: any ControlCoreLogger, completion: Task<Void, any Error>, queue: DispatchQueue) {
    self.configuration = configuration
    self.reporterConfiguration = reporterConfiguration
    self.reporter = reporter
    self.logger = logger
    self.completion = completion
    self.queue = queue
  }

  /// Cancelling the waiting task cancels the run.
  public func awaitCompletion() async throws {
    let completion = self.completion
    try await withTaskCancellationHandler {
      try await completion.value
    } onCancel: {
      completion.cancel()
    }
  }

  public var description: String {
    "Test Run (\(configuration))"
  }
}
