/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

private let fbxctestOutputLogDirectoryEnv = "FBXCTEST_LOG_DIRECTORY"
private let xctoolOutputLogDirectoryEnv = "XCTOOL_TEST_ENV_FB_LOG_DIRECTORY"

public final class XCTestLogger: ControlCoreLogger, Sendable {

  private let baseLogger: any ControlCoreLogger
  public let logDirectory: String

  private init(baseLogger: any ControlCoreLogger, logDirectory: String) {
    self.baseLogger = baseLogger
    self.logDirectory = logDirectory
  }

  // MARK: - Initializers

  /// Logs to stderr and to a new, uniquely named file in `directory`.
  public convenience init(directory: String) {
    self.init(baseLogger: XCTestLogger.baseLogger(writingToNewFileIn: directory), logDirectory: directory)
  }

  /// Logs in the directory the environment names, else `./tmp` if it exists, else the temporary directory.
  public convenience init() {
    self.init(directory: XCTestLogger.defaultLogDirectory())
  }

  private static func defaultLogDirectory() -> String {
    let env = ProcessInfo.processInfo.environment
    if let directory = env[fbxctestOutputLogDirectoryEnv] {
      return directory
    }
    if let directory = env[xctoolOutputLogDirectoryEnv] {
      return directory
    }
    let directory = FileManager.default.currentDirectoryPath.appending("/tmp")
    if FileManager.default.fileExists(atPath: directory) {
      return directory
    }
    return NSTemporaryDirectory()
  }

  private static func baseLogger(writingToNewFileIn directory: String) -> any ControlCoreLogger {
    let name = "\(ProcessInfo.processInfo.globallyUniqueString)_test.log"
    let success = (try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)) != nil
    assert(success, "Expected to create directory at path \(directory)")

    let path = (directory as NSString).appendingPathComponent(name)
    do {
      try Data().write(to: URL(fileURLWithPath: path))
    } catch {
      NSLog("Failed to create log file at path %@: %@", path, error.localizedDescription)
    }
    let stderrLogger = ControlCoreGlobalConfiguration.systemLogger(writingToStderr: true, debugLogging: true).withDateFormatEnabled(true)
    guard let fileHandle = FileHandle(forWritingAtPath: path) else {
      NSLog("Failed to open the log file at path %@ for writing, logging to stderr only", path)
      return stderrLogger
    }

    return CompositeLogger(loggers: [
      stderrLogger,
      ConsumerLogger(fileDescriptor: fileHandle.fileDescriptor, closeOnEndOfFile: false).withDateFormatEnabled(true),
    ])
  }

  // MARK: - ControlCoreLogger

  @discardableResult
  public func log(_ string: String) -> any ControlCoreLogger {
    baseLogger.log(string)
    return self
  }

  public func info() -> any ControlCoreLogger {
    XCTestLogger(baseLogger: baseLogger.info(), logDirectory: logDirectory)
  }

  public func debug() -> any ControlCoreLogger {
    XCTestLogger(baseLogger: baseLogger.debug(), logDirectory: logDirectory)
  }

  public func error() -> any ControlCoreLogger {
    XCTestLogger(baseLogger: baseLogger.error(), logDirectory: logDirectory)
  }

  public func withName(_ prefix: String) -> any ControlCoreLogger {
    XCTestLogger(baseLogger: baseLogger.withName(prefix), logDirectory: logDirectory)
  }

  public func withDateFormatEnabled(_ enabled: Bool) -> any ControlCoreLogger {
    XCTestLogger(baseLogger: baseLogger.withDateFormatEnabled(enabled), logDirectory: logDirectory)
  }

  public var name: String? {
    baseLogger.name
  }

  public var level: ControlCoreLogLevel {
    baseLogger.level
  }

  // MARK: - Log Consumption

  public func logConsumption(of consumer: any DataConsumer, toFileNamed fileName: String, logger: any ControlCoreLogger) async throws -> CompositeDataConsumer {
    let filePath = (logDirectory as NSString).appendingPathComponent(fileName)
    let writer = try await FileWriter.asyncWriter(forFilePath: filePath)
    logger.info().log("Mirroring output to \(filePath)")
    return CompositeDataConsumer(consumers: [
      consumer,
      writer,
      LoggingDataConsumer(logger: logger),
    ])
  }
}
