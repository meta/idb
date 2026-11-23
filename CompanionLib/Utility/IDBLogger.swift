/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
@preconcurrency import FBControlCore
import Foundation

/// A failure to construct the companion's logger.
public enum IDBLoggerError: Error, CustomStringConvertible {

  /// The directory containing the requested log file did not exist and could not be created.
  case logDirectoryCreationFailed(path: String, underlyingError: any Error)

  /// The requested log file could not be opened for appending.
  case logFileOpenFailed(path: String, code: Int32)

  public var description: String {
    switch self {
    case let .logDirectoryCreationFailed(path, underlyingError):
      return "Couldn't create the log directory at \(path): \(underlyingError)"
    case let .logFileOpenFailed(path, code):
      return "Couldn't open the log file at \(path): \(String(cString: strerror(code)))"
    }
  }
}

// MARK: - LocalizedError

// So that a caller reporting through `localizedDescription` — as the companion's top-level
// error handling does — gets the description above rather than the bare case name.
extension IDBLoggerError: LocalizedError {
  public var errorDescription: String? {
    description
  }
}

/// The loggers every `IDBLogger` fans out to in addition to its own, added and removed by the
/// log operations that tail the companion's output.
///
// SAFETY: `loggers` is only ever read or written inside `lock`.
// patternlint-disable-next-line unchecked-sendable
private final class GlobalLoggers: @unchecked Sendable {
  private let lock = NSLock()
  private var loggers: [any ControlCoreLogger] = []

  var all: [any ControlCoreLogger] {
    lock.withLock { loggers }
  }

  func add(_ logger: any ControlCoreLogger) {
    lock.withLock { loggers.append(logger) }
  }

  func remove(_ logger: any ControlCoreLogger) {
    lock.withLock { loggers.removeAll { $0 === logger } }
  }
}

private let globalLoggers = GlobalLoggers()

private final class IDBLoggerOperation: LogOperation, Sendable {
  let consumer: any DataConsumer
  let logger: any ControlCoreLogger

  init(consumer: any DataConsumer, logger: any ControlCoreLogger) {
    self.consumer = consumer
    self.logger = logger
  }

  /// Tails until cancelled, then stops delivering to the consumer.
  func waitUntilCompleted() async throws {
    do {
      try await AsyncEvent<Void>().wait()
    } catch {
      globalLoggers.remove(logger)
      throw error
    }
  }
}

public final class IDBLogger: ControlCoreLogger {

  private let ownLoggers: [any ControlCoreLogger]
  // Applied to the global loggers as each line is logged, because they come and go after this
  // logger is derived.
  private let deriveGlobal: @Sendable (any ControlCoreLogger) -> any ControlCoreLogger

  init(loggers: [any ControlCoreLogger], deriveGlobal: @escaping @Sendable (any ControlCoreLogger) -> any ControlCoreLogger = { $0 }) {
    self.ownLoggers = loggers
    self.deriveGlobal = deriveGlobal
  }

  /// The logger the companion writes to, which is the stderr logger plus, when
  /// `-log-file-path` is given, a logger appending to that file.
  ///
  /// - Throws: `IDBLoggerError` if the log file's directory cannot be created or the file
  ///   cannot be opened. A caller handling that has `systemLogger(withUserDefaults:)` to
  ///   report it through.
  public static func logger(withUserDefaults userDefaults: UserDefaults) throws -> IDBLogger {
    var loggers: [any ControlCoreLogger] = [systemLoggerSink(withUserDefaults: userDefaults)]
    if let logFilePath = userDefaults.string(forKey: "-log-file-path") {
      let fileDescriptor = try openLogFile(atPath: logFilePath)
      loggers.append(ConsumerLogger(fileDescriptor: fileDescriptor, closeOnEndOfFile: true))
    }
    return IDBLogger(loggers: loggers).dateFormatted()
  }

  /// The stderr-only logger. Nothing about it can fail, so a caller can build one to report
  /// a failure of `logger(withUserDefaults:)` itself.
  public static func systemLogger(withUserDefaults userDefaults: UserDefaults) -> IDBLogger {
    IDBLogger(loggers: [systemLoggerSink(withUserDefaults: userDefaults)]).dateFormatted()
  }

  private static func systemLoggerSink(withUserDefaults userDefaults: UserDefaults) -> any ControlCoreLogger {
    let debugLogging = userDefaults.string(forKey: "-log-level")?.lowercased() != "info"
    return ControlCoreGlobalConfiguration.systemLogger(writingToStderr: true, debugLogging: debugLogging)
  }

  private static func openLogFile(atPath path: String) throws -> Int32 {
    let logFileURL = URL(fileURLWithPath: path)
    let directoryURL = logFileURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [:])
    } catch {
      throw IDBLoggerError.logDirectoryCreationFailed(path: directoryURL.path, underlyingError: error)
    }

    // O_CLOEXEC because the companion spawns processes throughout its life and
    // none of them have any business inheriting the log.
    let fileDescriptor = open(logFileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    let openError = errno
    guard fileDescriptor >= 0 else {
      throw IDBLoggerError.logFileOpenFailed(path: logFileURL.path, code: openError)
    }
    return fileDescriptor
  }

  var loggers: [any ControlCoreLogger] {
    ownLoggers + globalLoggers.all.map(deriveGlobal)
  }

  @discardableResult
  public func log(_ message: String) -> any ControlCoreLogger {
    CompositeLogger(loggers: loggers).log(message)
    return self
  }

  public func info() -> any ControlCoreLogger {
    applying { $0.info() }
  }

  public func debug() -> any ControlCoreLogger {
    applying { $0.debug() }
  }

  public func error() -> any ControlCoreLogger {
    applying { $0.error() }
  }

  public func withName(_ name: String) -> any ControlCoreLogger {
    named(name)
  }

  public func withDateFormatEnabled(_ enabled: Bool) -> any ControlCoreLogger {
    applying { $0.withDateFormatEnabled(enabled) }
  }

  public var name: String? {
    nil
  }

  public var level: ControlCoreLogLevel {
    .multiple
  }

  public func named(_ name: String) -> IDBLogger {
    applying { $0.withName(name) }
  }

  func dateFormatted() -> IDBLogger {
    applying { $0.withDateFormatEnabled(true) }
  }

  private func applying(_ transform: @escaping @Sendable (any ControlCoreLogger) -> any ControlCoreLogger) -> IDBLogger {
    IDBLogger(loggers: ownLoggers.map(transform), deriveGlobal: { [deriveGlobal] in transform(deriveGlobal($0)) })
  }

  func tailToConsumer(_ consumer: any DataConsumer) async throws -> any LogOperation {
    let logger = ConsumerLogger(consumer: consumer)
    globalLoggers.add(logger)
    return IDBLoggerOperation(consumer: consumer, logger: logger)
  }
}
