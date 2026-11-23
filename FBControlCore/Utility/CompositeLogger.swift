/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// A composite logger that logs to many loggers.
public final class CompositeLogger: ControlCoreLogger, Sendable {

  /// The loggers to log to.
  public let loggers: [any ControlCoreLogger]

  public init(loggers: [any ControlCoreLogger]) {
    self.loggers = loggers
  }

  @discardableResult
  public func log(_ message: String) -> any ControlCoreLogger {
    guard let message = loggableStringLine(message) else {
      return self
    }
    for logger in loggers {
      logger.log(message)
    }
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
    applying { $0.withName(name) }
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

  private func applying(_ transform: (any ControlCoreLogger) -> any ControlCoreLogger) -> any ControlCoreLogger {
    CompositeLogger(loggers: loggers.map(transform))
  }
}
