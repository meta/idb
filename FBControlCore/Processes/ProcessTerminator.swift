/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

private let ProcessTableRemovalTimeout: TimeInterval = 20.0

enum ProcessTerminatorError: Error, LocalizedError {
  case processDoesNotExist(processIdentifier: pid_t)
  case killFailed(processIdentifier: pid_t, message: String)
  case processDidNotDisappear(processIdentifier: pid_t, processInfo: String)
  case sigkillAfterFailedKill(processIdentifier: pid_t, signo: Int32, underlying: any Error)

  public var errorDescription: String? {
    switch self {
    case let .processDoesNotExist(processIdentifier):
      return "Could not find that process \(processIdentifier) exists"
    case let .killFailed(processIdentifier, message):
      return "Failed to kill \(processIdentifier): '\(message)'"
    case let .processDidNotDisappear(processIdentifier, _):
      return "Timed out waiting for \(processIdentifier) to disappear from the process table"
    case let .sigkillAfterFailedKill(processIdentifier, signo, _):
      return "Attempted to SIGKILL \(processIdentifier) after failed kill with signo \(signo)"
    }
  }
}

public final class ProcessTerminator: Sendable {

  // MARK: - Private Properties

  private let configuration: Configuration
  private let processFetcher: ProcessFetcher
  private let workQueue: DispatchQueue
  private let logger: any ControlCoreLogger

  // MARK: - Initializers

  public init(
    configuration: Configuration = .default,
    processFetcher: ProcessFetcher,
    workQueue: DispatchQueue,
    logger: any ControlCoreLogger
  ) {
    precondition(
      configuration.signo > 0 && configuration.signo < 32,
      "Signal must be greater than 0 (SIGHUP) and less than 32 (SIGUSR2) was \(configuration.signo)")
    self.configuration = configuration
    self.processFetcher = processFetcher
    self.workQueue = workQueue
    self.logger = logger
  }

  // MARK: - Public Methods

  public func terminate(_ processIdentifier: pid_t) async throws {
    let checkExists = hasOption(.checkProcessExistsBeforeSignal)
    if checkExists && processFetcher.processInfo(for: processIdentifier) == nil {
      throw ProcessTerminatorError.processDoesNotExist(processIdentifier: processIdentifier)
    }

    logger.debug().log("Killing \(processIdentifier)")
    if kill(processIdentifier, configuration.signo) != 0 {
      throw unsafe ProcessTerminatorError.killFailed(processIdentifier: processIdentifier, message: String(cString: strerror(errno)))
    }

    let checkDeath = hasOption(.checkDeathAfterSignal)
    if !checkDeath {
      logger.debug().log("Killed \(processIdentifier)")
      return
    }

    logger.debug().log("Waiting on \(processIdentifier) to disappear from the process table")
    if try await waitForProcessIdentifierToDie(processIdentifier) {
      logger.debug().log("Process \(processIdentifier) terminated")
      return
    }

    let backoff = hasOption(.backoffToSIGKILL)
    if configuration.signo == SIGKILL || !backoff {
      let processInfo: Any = processFetcher.processInfo(for: processIdentifier) ?? ("No Process Info" as NSString)
      throw ProcessTerminatorError.processDidNotDisappear(processIdentifier: processIdentifier, processInfo: String(describing: processInfo))
    }

    var newConfiguration = configuration
    newConfiguration.signo = SIGKILL
    logger.debug().log("Backing off kill of \(processIdentifier) to SIGKILL")
    do {
      try await terminator(with: newConfiguration).terminate(processIdentifier)
    } catch {
      throw ProcessTerminatorError.sigkillAfterFailedKill(processIdentifier: processIdentifier, signo: configuration.signo, underlying: error)
    }
  }

  // MARK: - Private

  private func hasOption(_ option: Options) -> Bool {
    configuration.options.contains(option)
  }

  private func terminator(with configuration: Configuration) -> ProcessTerminator {
    ProcessTerminator(
      configuration: configuration,
      processFetcher: processFetcher,
      workQueue: workQueue,
      logger: logger
    )
  }

  /// Returns false when the process was still in the process table at the deadline.
  private func waitForProcessIdentifierToDie(_ processIdentifier: pid_t) async throws -> Bool {
    let processFetcher = self.processFetcher
    do {
      try await pollUntilTrue(
        on: workQueue,
        deadline: PollDeadline(timeout: ProcessTableRemovalTimeout, waitingFor: "process \(processIdentifier) to be removed from the process table")
      ) {
        processFetcher.processInfo(for: processIdentifier) == nil
      }
      return true
    } catch is PollTimeoutError {
      return false
    }
  }
}

extension ProcessTerminator {

  /// An Option Set for Process Termination.
  public struct Options: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) {
      self.rawValue = rawValue
    }

    /// Checks for the process to exist before signalling.
    public static let checkProcessExistsBeforeSignal = Options(rawValue: 1 << 2)
    /// Waits for the process to die before returning.
    public static let checkDeathAfterSignal = Options(rawValue: 1 << 3)
    /// Whether to backoff to SIGKILL if a less severe signal fails.
    public static let backoffToSIGKILL = Options(rawValue: 1 << 4)
  }

  /// A Configuration for the Terminator.
  public struct Configuration: Sendable {
    public var signo: Int32
    public var options: Options

    public init(signo: Int32, options: Options) {
      self.signo = signo
      self.options = options
    }

    /// SIGKILL, checking the process exists first and waiting for it to die after.
    public static let `default` = Configuration(
      signo: SIGKILL,
      options: [.checkProcessExistsBeforeSignal, .checkDeathAfterSignal, .backoffToSIGKILL]
    )
  }
}
