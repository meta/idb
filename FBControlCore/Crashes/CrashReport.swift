/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// The kind of process that crashed.
public struct CrashLogInfoProcessType: OptionSet, Sendable {
  public let rawValue: UInt

  public init(rawValue: UInt) {
    self.rawValue = rawValue
  }

  /// A process that is part of the operating system runtime.
  public static let system = CrashLogInfoProcessType(rawValue: 1 << 0)
  /// A process that is an application.
  public static let application = CrashLogInfoProcessType(rawValue: 1 << 1)
  /// A process that is neither an application nor part of the operating system runtime.
  public static let custom = CrashLogInfoProcessType(rawValue: 1 << 2)
}

public final class CrashReport: CustomStringConvertible {

  public let info: CrashLogInfo
  public let contents: String

  public init(info: CrashLogInfo, contents: String) {
    self.info = info
    self.contents = contents
  }

  public var description: String {
    "Crash Info: \(info) \n Crash Report: \(contents)\n"
  }

  // MARK: - Public

  public static func dateFormatter() -> DateFormatter {
    CrashReportDateFormatter
  }
}

private let CrashReportDateFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
  formatter.isLenient = true
  formatter.locale = Locale(identifier: "en_US")
  return formatter
}()

enum CrashLogError: Error {
  case fileDoesNotExist(path: String)
  case fileNotReadable(path: String)
  case dataReadFailed(path: String, underlying: any Error)
  case fileEmpty(path: String)
  case stringExtractionFailed(path: String)
  case readFailed(path: String, underlying: any Error)
  case parseFailed(underlying: any Error)
  case missingField(field: String)
}

extension CrashLogError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .fileDoesNotExist(path):
      return "File does not exist at given crash path: \(path)"
    case let .fileNotReadable(path):
      return "Crash file at \(path) is not readable"
    case let .dataReadFailed(path, _):
      return "Could not read data from \(path)"
    case let .fileEmpty(path):
      return "Crash file at \(path) is empty"
    case let .stringExtractionFailed(path):
      return "Could not extract string from \(path)"
    case let .readFailed(path, _):
      return "Failed to read crash log at path \(path)"
    case let .parseFailed(underlying):
      return "Could not parse crash string \(underlying)"
    case let .missingField(field):
      return "Missing \(field) in crash log"
    }
  }
}

public final class CrashLogInfo: CustomStringConvertible, Sendable {

  // MARK: - Properties

  public let crashPath: String
  public let executablePath: String
  public let identifier: String
  public let processName: String
  public let processIdentifier: pid_t
  public let parentProcessName: String
  public let parentProcessIdentifier: pid_t
  public let date: Date
  public let processType: CrashLogInfoProcessType
  public let exceptionDescription: String?
  public let crashedThreadDescription: String?
  public let coalitionName: String?

  public var name: String {
    (crashPath as NSString).lastPathComponent
  }

  public init(
    crashPath: String,
    executablePath: String,
    identifier: String,
    processName: String,
    processIdentifier: pid_t,
    parentProcessName: String,
    parentProcessIdentifier: pid_t,
    date: Date,
    processType: CrashLogInfoProcessType,
    exceptionDescription: String?,
    crashedThreadDescription: String?,
    coalitionName: String? = nil
  ) {
    self.crashPath = crashPath
    self.executablePath = executablePath
    self.identifier = identifier
    self.processName = processName
    self.processIdentifier = processIdentifier
    self.parentProcessName = parentProcessName
    self.parentProcessIdentifier = parentProcessIdentifier
    self.date = date
    self.processType = processType
    self.exceptionDescription = exceptionDescription
    self.crashedThreadDescription = crashedThreadDescription
    self.coalitionName = coalitionName
  }

  // MARK: - Factory Methods

  public static func fromCrashLog(atPath crashPath: String) throws -> CrashLogInfo {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: crashPath) {
      throw CrashLogError.fileDoesNotExist(path: crashPath)
    }
    if !fileManager.isReadableFile(atPath: crashPath) {
      throw CrashLogError.fileNotReadable(path: crashPath)
    }
    let crashFileData: Data
    do {
      crashFileData = try Data(contentsOf: URL(fileURLWithPath: crashPath))
    } catch {
      throw CrashLogError.dataReadFailed(path: crashPath, underlying: error)
    }
    return try fromCrashLogData(crashFileData, crashPath: crashPath)
  }

  /// Reads the log without blocking the calling thread on the file's contents.
  static func readCrashLog(atPath crashPath: String) async throws -> CrashLogInfo {
    var crashFileData = Data()
    do {
      for try await byte in URL(fileURLWithPath: crashPath).resourceBytes {
        crashFileData.append(byte)
      }
    } catch {
      throw CrashLogError.dataReadFailed(path: crashPath, underlying: error)
    }
    return try fromCrashLogData(crashFileData, crashPath: crashPath)
  }

  private static func fromCrashLogData(_ crashFileData: Data, crashPath: String) throws -> CrashLogInfo {
    if crashFileData.isEmpty {
      throw CrashLogError.fileEmpty(path: crashPath)
    }
    guard let crashString = String(data: crashFileData, encoding: .utf8) else {
      throw CrashLogError.stringExtractionFailed(path: crashPath)
    }
    let parser = getPreferredCrashLogParser(forCrashString: crashString)
    return try fromCrashLogString(crashString, crashPath: crashPath, parser: parser)
  }

  public static func isParsableCrashLog(_ data: Data) -> Bool {
    #if canImport(Darwin)
    guard let crashString = String(data: data, encoding: .utf8) else {
      return false
    }
    let parser = getPreferredCrashLogParser(forCrashString: crashString)
    do {
      _ = try fromCrashLogString(crashString, crashPath: "", parser: parser)
      return true
    } catch {
      return false
    }
    #else
    return false
    #endif
  }

  public var description: String {
    "Identifier \(identifier) | Executable Path \(executablePath) | Process \(processName) | pid \(processIdentifier) | Parent \(parentProcessName) | ppid \(parentProcessIdentifier) | Date \(date) | Path \(crashPath) | Exception: \(exceptionDescription ?? "nil") | Trace: \(crashedThreadDescription ?? "nil")"
  }

  public func loadRawCrashLogString() throws -> String {
    try String(contentsOfFile: crashPath, encoding: .utf8)
  }

  // MARK: - Bulk Collection

  /// Directory listings and modification dates are read synchronously: Foundation has no async
  /// form of either, and both are metadata lookups rather than reads of a log's contents.
  public static func crashInfo(afterDate date: Date, logger: (any ControlCoreLogger)?) async -> [CrashLogInfo] {
    var allCrashInfos: [CrashLogInfo] = []
    for basePath in diagnosticReportsPaths {
      let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: basePath)) ?? []
      for fileName in fileNames where isCrashLog(fileName, inDirectory: basePath, modifiedOnOrAfter: date) {
        do {
          allCrashInfos.append(try await readCrashLog(atPath: (basePath as NSString).appendingPathComponent(fileName)))
        } catch {
          logger?.log("Error parsing log \(error)")
        }
      }
    }
    return allCrashInfos
  }

  // MARK: - Contents

  public func obtainCrashLog() throws -> CrashReport {
    let contents: String
    do {
      contents = try loadRawCrashLogString()
    } catch {
      throw CrashLogError.readFailed(path: crashPath, underlying: error)
    }
    return CrashReport(info: self, contents: contents)
  }

  public static var diagnosticReportsPaths: [String] {
    [
      (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/DiagnosticReports"),
      "/Library/Logs/DiagnosticReports",
    ]
  }

  // MARK: - Private

  private static func getPreferredCrashLogParser(forCrashString crashString: String) -> any CrashLogParser {
    if !crashString.isEmpty && crashString.first == "{" {
      return ConcatedJSONCrashLogParser()
    } else {
      return PlainTextCrashLogParser()
    }
  }

  private static func fromCrashLogString(_ crashString: String, crashPath: String, parser: any CrashLogParser) throws -> CrashLogInfo {
    let parsed: ParsedCrashLog
    do {
      parsed = try parser.parse(crashString)
    } catch {
      throw CrashLogError.parseFailed(underlying: error)
    }

    if parsed.processName.isEmpty {
      throw CrashLogError.missingField(field: "process name")
    }
    if parsed.identifier.isEmpty {
      throw CrashLogError.missingField(field: "identifier")
    }
    if parsed.parentProcessName.isEmpty {
      throw CrashLogError.missingField(field: "parent process name")
    }
    if parsed.executablePath.isEmpty {
      throw CrashLogError.missingField(field: "executable path")
    }
    if parsed.processIdentifier == -1 {
      throw CrashLogError.missingField(field: "process identifier")
    }
    if parsed.parentProcessIdentifier == -1 {
      throw CrashLogError.missingField(field: "parent process identifier")
    }

    return CrashLogInfo(
      crashPath: crashPath,
      executablePath: parsed.executablePath,
      identifier: parsed.identifier,
      processName: parsed.processName,
      processIdentifier: parsed.processIdentifier,
      parentProcessName: parsed.parentProcessName,
      parentProcessIdentifier: parsed.parentProcessIdentifier,
      date: parsed.date,
      processType: processType(forExecutablePath: parsed.executablePath),
      exceptionDescription: parsed.exceptionDescription.isEmpty ? nil : parsed.exceptionDescription,
      crashedThreadDescription: parsed.crashedThreadDescription.isEmpty ? nil : parsed.crashedThreadDescription,
      coalitionName: parsed.coalitionName.isEmpty ? nil : parsed.coalitionName
    )
  }

  private static func processType(forExecutablePath executablePath: String) -> CrashLogInfoProcessType {
    if executablePath.contains("Platforms/iPhoneSimulator.platform") {
      return .system
    }
    if executablePath.contains(".app") {
      return .application
    }
    return .custom
  }

  private static func isCrashLog(_ fileName: String, inDirectory basePath: String, modifiedOnOrAfter date: Date) -> Bool {
    guard ["crash", "ips"].contains((fileName as NSString).pathExtension) else {
      return false
    }
    let path = (basePath as NSString).appendingPathComponent(fileName)
    guard let modificationDate = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
      return false
    }
    return modificationDate >= date
  }
}
