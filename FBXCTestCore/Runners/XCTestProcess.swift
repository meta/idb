/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

private let CrashLogStartDateFuzz: TimeInterval = -20
private let CrashLogWaitTime: TimeInterval = 180
private let KillBackoffTimeout: TimeInterval = 1

enum XCTestProcessError: Error {
  case stalled(timeout: TimeInterval, processIdentifier: pid_t, stackshot: String)
  case crashed(info: String, rawLog: String)
  case crashLogTimedOut(processIdentifier: pid_t)
  case exitedWithoutCrashLog(processIdentifier: pid_t, lookupFailure: any Error)
}

extension XCTestProcessError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .stalled(timeout, processIdentifier, stackshot):
      return "Waited \(timeout) seconds for process \(processIdentifier) to terminate, but the xctest process stalled: \(stackshot)"
    case let .crashed(info, rawLog):
      return "xctest process crashed\n\(info)\n\nRaw Crash File Contents\n\(rawLog)"
    case let .crashLogTimedOut(processIdentifier):
      return "Crash logs for terminated process \(processIdentifier) to appear"
    case let .exitedWithoutCrashLog(processIdentifier, _):
      return "xctest process (\(processIdentifier)) exited abnormally with no crash log, to check for yourself look in ~/Library/Logs/DiagnosticReports"
    }
  }
}

extension XCTestProcessError: CustomNSError {
  public var errorUserInfo: [String: Any] {
    switch self {
    case let .exitedWithoutCrashLog(_, lookupFailure):
      return [NSUnderlyingErrorKey: lookupFailure]
    case .stalled, .crashed, .crashLogTimedOut:
      return [:]
    }
  }
}

enum XCTestProcess {

  /// Waits for `process` to exit within `timeout` and returns its exit code. A process that
  /// overstays is sampled, terminated and reported as stalled; one killed by a signal is reported
  /// with its crash log when `crashLogCommands` can find one.
  static func awaitExitCode(
    of process: RunningSubprocess,
    processName: String,
    completesWithin timeout: TimeInterval,
    crashLogCommands: (any CrashLogCommands)?,
    logger: any ControlCoreLogger,
    sampleStackshot: (pid_t) async throws -> String = ProcessFetcher.sampleStackshot
  ) async throws -> Int32 {
    let startDate = Date(timeIntervalSinceNow: CrashLogStartDateFuzz)
    let processIdentifier = process.processIdentifier

    logger.log("Waiting for \(processIdentifier) to exit within \(timeout) seconds")
    guard let status = try await process.terminationStatus(within: timeout) else {
      let stackshot: String
      do {
        stackshot = try await sampleStackshot(processIdentifier)
      } catch {
        stackshot = "stackshot unavailable: \(error.localizedDescription)"
      }
      logger.log("Terminating stalled xctest process \(processIdentifier)")
      await process.terminate(gracePeriod: KillBackoffTimeout)
      logger.log("Stalled xctest process \(processIdentifier) has been terminated")
      throw XCTestProcessError.stalled(timeout: timeout, processIdentifier: processIdentifier, stackshot: stackshot)
    }
    switch status {
    case .exited(let exitCode):
      return exitCode
    case .signalled(let signo):
      guard let crashLogCommands else {
        throw ProcessTerminationError.exitedWithSignal(processIdentifier: processIdentifier, processName: processName, signal: signo)
      }
      logger.log("xctest process (\(processIdentifier)) died prematurely, checking for crash log for \(CrashLogWaitTime) seconds")
      let crashLog: CrashLogInfo
      do {
        crashLog = try await crashLogCommands.notifyOfCrash(
          matching: CrashLogPredicate.processIdentifier(processIdentifier) && CrashLogPredicate.newer(than: startDate),
          within: CrashLogWaitTime,
          orThrow: XCTestProcessError.crashLogTimedOut(processIdentifier: processIdentifier))
      } catch {
        throw XCTestProcessError.exitedWithoutCrashLog(processIdentifier: processIdentifier, lookupFailure: error)
      }
      throw XCTestProcessError.crashed(info: String(describing: crashLog), rawLog: (try? crashLog.loadRawCrashLogString()) ?? "")
    }
  }

  public static func describeFailingExitCode(_ exitCode: Int32) -> String? {
    switch exitCode {
    case 0, 1:
      return nil
    case 10: // TestShimExitCodeDLOpenError
      return "DLOpen Error"
    case 11: // TestShimExitCodeBundleOpenError
      return "Error opening test bundle"
    case 12: // TestShimExitCodeMissingExecutable
      return "Missing executable"
    case 13: // TestShimExitCodeXCTestFailedLoading
      return "XCTest Framework failed loading"
    case 14: // TestShimExitCodeTestListWriteError
      return "Failed to write the test list"
    case 75: // XCTest's own: an async test failed with `continueAfterFailure = false`, ending the process.
      return "XCTest stopped the run after an async test failed with continueAfterFailure = false; later tests did not run"
    default:
      return "Unknown xctest exit code \(exitCode)"
    }
  }
}
