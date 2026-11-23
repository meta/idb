/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import os

private let ConfirmShimsAreSignedEnv = "FBCONTROLCORE_CONFIRM_SIGNED_SHIMS"

public enum ControlCoreGlobalConfiguration {

  /// Environment variable; when truthy, the default logger mirrors its output to stderr.
  public static let stderrLoggingEnvironmentVariable = "FBCONTROLCORE_LOGGING"
  /// Environment variable; when truthy, the default logger emits debug-level output.
  public static let debugLoggingEnvironmentVariable = "FBCONTROLCORE_DEBUG_LOGGING"

  // Guarded by _loggerLock.
  nonisolated(unsafe) private static var _logger: (any ControlCoreLogger)?
  private static let _loggerLock = NSLock()

  // MARK: - Timeouts

  public static var fastTimeout: TimeInterval { 10 }
  public static var regularTimeout: TimeInterval { 30 }
  public static var slowTimeout: TimeInterval { 120 }

  // MARK: - Logger

  /// The logger used wherever a nullable logger parameter is passed as nil.
  ///
  /// By default it writes only to os_log (subsystem `com.facebook.fbcontrolcore`) at info level, so
  /// in a process without a terminal nothing reaches stderr and diagnostics are only visible via
  /// `log stream --predicate 'subsystem == "com.facebook.fbcontrolcore"'`.
  /// `FBCONTROLCORE_LOGGING` mirrors output to stderr; `FBCONTROLCORE_DEBUG_LOGGING` raises the level to debug.
  public static var defaultLogger: any ControlCoreLogger {
    get {
      _loggerLock.lock()
      defer { _loggerLock.unlock() }
      if let existing = _logger { return existing }
      let created = createDefaultLogger()
      _logger = created
      return created
    }
    set {
      _loggerLock.lock()
      let previous = _logger
      _logger = newValue
      _loggerLock.unlock()
      // Outside the critical section: logging through an arbitrary logger implementation must
      // not run under the lock.
      if previous != nil {
        newValue.debug().log("Overriding the Default Logger with \(newValue)")
      }
    }
  }

  public static var confirmCodesignaturesAreValid: Bool {
    guard let value = ProcessInfo.processInfo.environment[ConfirmShimsAreSignedEnv] else { return false }
    return (value as NSString).boolValue
  }

  public static var description: String {
    _loggerLock.lock()
    let logger = _logger
    _loggerLock.unlock()
    // Stringified outside the critical section: an arbitrary logger implementation must not run
    // under the lock.
    return "Default Logger \(logger.map(String.init(describing:)) ?? "(nil)")"
  }

  private static func createDefaultLogger() -> any ControlCoreLogger {
    ControlCoreGlobalConfiguration.systemLogger(writingToStderr: stderrLoggingEnabledByDefault, debugLogging: debugLoggingEnabledByDefault)
  }

  private static var stderrLoggingEnabledByDefault: Bool {
    guard let value = ProcessInfo.processInfo.environment[stderrLoggingEnvironmentVariable] else { return false }
    return (value as NSString).boolValue
  }

  private static var debugLoggingEnabledByDefault: Bool {
    guard let value = ProcessInfo.processInfo.environment[debugLoggingEnvironmentVariable] else { return false }
    return (value as NSString).boolValue
  }

  // MARK: - System Logger

  /// A logger backed by os_log.
  /// `writeToStdErr` additionally mirrors output to stderr unless os_log already does so in this environment.
  /// `debugLogging` selects the debug level rather than info.
  public static func systemLogger(writingToStderr writeToStdErr: Bool, debugLogging: Bool) -> any ControlCoreLogger {
    let systemLogger = OSLogLogger(client: OSLog(subsystem: OSLogLogger.subsystem, category: ""), name: nil, level: debugLogging ? .debug : .info)
    guard writeToStdErr, !systemLoggerWillLogToStdErr else {
      return systemLogger
    }
    return CompositeLogger(loggers: [
      systemLogger,
      ConsumerLogger(fileDescriptor: STDERR_FILENO, closeOnEndOfFile: false),
    ])
  }

  // rdar://36919139: os_log writes to stderr itself when any of these are set.
  private static var systemLoggerWillLogToStdErr: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["OS_ACTIVITY_DT_MODE"] != nil || environment["ACTIVITY_LOG_STDERR"] != nil || environment["CFLOG_FORCE_STDERR"] != nil
  }

}
