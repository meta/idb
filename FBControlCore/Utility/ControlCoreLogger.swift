/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import os

/// The Log Level.
/// The Multiple Level exists so that composite loggers can decide whether to log individually.
public enum ControlCoreLogLevel: Sendable {
  case error
  case info
  case debug
  case multiple
}

/// Receives log messages. Conformers must be thread-safe: loggers are shared across queues,
/// private-framework callback threads and actors.
public protocol ControlCoreLogger: AnyObject, Sendable {
  /// Logs a Message with the provided String.
  @discardableResult
  func log(_ message: String) -> any ControlCoreLogger

  /// Returns the Info Logger variant.
  func info() -> any ControlCoreLogger

  /// Returns the Debug Logger variant.
  func debug() -> any ControlCoreLogger

  /// Returns the Error Logger variant.
  func error() -> any ControlCoreLogger

  /// Returns a Logger for a named 'facility' or 'tag'.
  func withName(_ name: String) -> any ControlCoreLogger

  /// Enables or Disables date formatting in the logger.
  func withDateFormatEnabled(_ enabled: Bool) -> any ControlCoreLogger

  /// The Prefix for the Logger, if set.
  var name: String? { get }

  /// The Current Log Level.
  var level: ControlCoreLogLevel { get }
}

/// Trims surrounding whitespace and newlines; returns nil when nothing remains to log.
func loggableStringLine(_ string: String) -> String? {
  let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

// MARK: - OSLogLogger

final class OSLogLogger: ControlCoreLogger, Sendable {

  static let subsystem = "com.facebook.fbcontrolcore"

  private let client: OSLog
  let name: String?
  let level: ControlCoreLogLevel

  init(client: OSLog, name: String?, level: ControlCoreLogLevel) {
    self.client = client
    self.name = name
    self.level = level
  }

  @discardableResult
  func log(_ message: String) -> any ControlCoreLogger {
    unsafe os_log("%{public}s", log: client, type: logType, message)
    return self
  }

  func info() -> any ControlCoreLogger {
    OSLogLogger(client: client, name: name, level: .info)
  }

  func debug() -> any ControlCoreLogger {
    OSLogLogger(client: client, name: name, level: .debug)
  }

  func error() -> any ControlCoreLogger {
    OSLogLogger(client: client, name: name, level: .error)
  }

  func withName(_ name: String) -> any ControlCoreLogger {
    OSLogLogger(client: OSLog(subsystem: OSLogLogger.subsystem, category: name), name: name, level: level)
  }

  func withDateFormatEnabled(_ enabled: Bool) -> any ControlCoreLogger {
    self
  }

  private var logType: OSLogType {
    switch level {
    case .error:
      return .error
    case .info:
      return .info
    case .debug:
      return .debug
    case .multiple:
      return .default
    }
  }
}

// MARK: - ConsumerLogger

/// Logs each message as a line of text to a data consumer.
public final class ConsumerLogger: ControlCoreLogger, Sendable {

  private let consumer: any DataConsumer
  private let writeLock: NSLock
  private let dateFormatter: DateFormatter?
  public let name: String?

  // Nothing filters on a consumer logger's level; it writes every message.
  public var level: ControlCoreLogLevel {
    .info
  }

  /// Logs to `consumer`.
  public convenience init(consumer: any DataConsumer) {
    self.init(consumer: consumer, name: nil, dateFormatter: nil)
  }

  /// Logs to `fileDescriptor`, closing it on end of file if `closeOnEndOfFile` is set.
  public convenience init(fileDescriptor: Int32, closeOnEndOfFile: Bool) {
    self.init(consumer: FileWriter.syncWriter(withFileDescriptor: fileDescriptor, closeOnEndOfFile: closeOnEndOfFile))
  }

  init(consumer: any DataConsumer, name: String?, dateFormatter: DateFormatter?, writeLock: NSLock = NSLock()) {
    self.consumer = consumer
    self.writeLock = writeLock
    self.name = name
    self.dateFormatter = dateFormatter
  }

  @discardableResult
  public func log(_ message: String) -> any ControlCoreLogger {
    guard let message = loggableStringLine(message) else {
      return self
    }
    var line = ""
    if let dateFormatter {
      line += "\(dateFormatter.string(from: Date())) "
    }
    if let name {
      line += "[\(name)] "
    }
    line += message + "\n"
    writeLock.withLock {
      consumer.consumeData(Data(line.utf8))
    }
    return self
  }

  public func info() -> any ControlCoreLogger {
    self
  }

  public func debug() -> any ControlCoreLogger {
    self
  }

  public func error() -> any ControlCoreLogger {
    self
  }

  public func withName(_ name: String) -> any ControlCoreLogger {
    ConsumerLogger(consumer: consumer, name: name, dateFormatter: dateFormatter, writeLock: writeLock)
  }

  public func withDateFormatEnabled(_ enabled: Bool) -> any ControlCoreLogger {
    guard enabled else {
      return ConsumerLogger(consumer: consumer, name: name, dateFormatter: nil, writeLock: writeLock)
    }
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZZZ"
    return ConsumerLogger(consumer: consumer, name: name, dateFormatter: dateFormatter, writeLock: writeLock)
  }
}
