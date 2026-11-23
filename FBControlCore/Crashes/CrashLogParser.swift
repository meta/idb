/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// The fields a crash log parser extracts. A field the log does not have is left at its default.
struct ParsedCrashLog {
  var executablePath = ""
  var identifier = ""
  var processName = ""
  var parentProcessName = ""
  var processIdentifier: pid_t = -1
  var parentProcessIdentifier: pid_t = -1
  var date = Date()
  var exceptionDescription = ""
  var crashedThreadDescription = ""
  var coalitionName = ""
}

protocol CrashLogParser {
  func parse(_ str: String) throws -> ParsedCrashLog
}

/// A macOS 12+ `.ips` file is two concatenated JSON objects (metadata, then content) with some fields
/// repeated. Apple can change the layout, so every object is searched for each needed field rather
/// than assuming a position.
struct ConcatedJSONCrashLogParser: CrashLogParser {

  func parse(_ str: String) throws -> ParsedCrashLog {
    var parsed = ParsedCrashLog()
    let parsedReport = try ConcatedJsonParser.parseConcatenatedJSON(from: str)

    if let procPath = parsedReport["procPath"] as? String {
      parsed.executablePath = procPath
    }

    if let procName = parsedReport["procName"] as? String {
      parsed.processName = procName
      parsed.identifier = procName
    }
    // An app's report records its bundle id; a process without one is identified by its name.
    let bundleInfo = parsedReport["bundleInfo"] as? [String: Any]
    if let bundleID = bundleInfo?["CFBundleIdentifier"] as? String ?? parsedReport["bundleID"] as? String {
      parsed.identifier = bundleID
    }
    if let pid = parsedReport["pid"] as? NSNumber {
      parsed.processIdentifier = pid.int32Value
    }

    if let parentProc = parsedReport["parentProc"] as? String {
      parsed.parentProcessName = parentProc
    }
    if let parentPid = parsedReport["parentPid"] as? NSNumber {
      parsed.parentProcessIdentifier = parentPid.int32Value
    }
    if let coalitionName = parsedReport["coalitionName"] as? String {
      parsed.coalitionName = coalitionName
    }
    if let captureTime = parsedReport["captureTime"] as? String {
      if let date = CrashReport.dateFormatter().date(from: captureTime) {
        parsed.date = date
      }
    }

    if let exceptionDictionary = parsedReport["exception"] as? [String: Any] {
      var exceptionDescriptionMutable = ""
      if let exceptionType = exceptionDictionary["type"] as? String {
        exceptionDescriptionMutable += exceptionType
      }
      if let exceptionSignal = exceptionDictionary["signal"] as? String {
        exceptionDescriptionMutable += " " + exceptionSignal
      }
      if let exceptionSubtype = exceptionDictionary["subtype"] as? String {
        exceptionDescriptionMutable += " " + exceptionSubtype
      }
      parsed.exceptionDescription = exceptionDescriptionMutable
    }

    var imageNames: [String] = []
    if let imageDictionaries = parsedReport["usedImages"] as? [[String: Any]] {
      for imageDictionary in imageDictionaries {
        if let imageName = imageDictionary["name"] as? String {
          imageNames.append(imageName)
        }
      }
    }

    if let threads = parsedReport["threads"] as? [[String: Any]] {
      for threadDictionary in threads {
        guard (threadDictionary["triggered"] as? NSNumber)?.boolValue == true else {
          continue
        }
        if let frames = threadDictionary["frames"] as? [[String: Any]] {
          var crashedThreadDescriptionMutable = ""
          for frameDictionary in frames {
            let imageIndex = (frameDictionary["imageIndex"] as? NSNumber)?.uintValue ?? 0
            if imageNames.count > Int(imageIndex) {
              var imageNameString = imageNames[Int(imageIndex)]
              if imageNameString.count < 30 {
                imageNameString = imageNameString.padding(toLength: 30, withPad: " ", startingAt: 0)
              }
              crashedThreadDescriptionMutable += imageNameString + "\t"
            }
            if let symbol = frameDictionary["symbol"] as? String {
              crashedThreadDescriptionMutable += symbol + "\n"
            }
          }
          parsed.crashedThreadDescription = crashedThreadDescriptionMutable.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        break
      }
    }
    return parsed
  }
}

/// Parses the pre-macOS 12 plain-text `.crash` format.
struct PlainTextCrashLogParser: CrashLogParser {

  private static let maxLineSearch: UInt = 20

  // Leaves `coalitionName` empty: this format has no coalition field, and it never redacts the simulator path, which `CrashLogPredicate.simulatorUDID(_:)` matches instead.
  func parse(_ str: String) throws -> ParsedCrashLog {
    var parsed = ParsedCrashLog()
    let nsStr = str as NSString
    let length = nsStr.length
    var paraStart: Int = 0
    var paraEnd: Int = 0
    var contentsEnd: Int = 0
    var linesParsed: UInt = 0

    while paraEnd < length && linesParsed < PlainTextCrashLogParser.maxLineSearch {
      linesParsed += 1
      unsafe nsStr.getParagraphStart(&paraStart, end: &paraEnd, contentsEnd: &contentsEnd, for: NSRange(location: paraEnd, length: 0))
      let line = nsStr.substring(with: NSRange(location: paraStart, length: contentsEnd - paraStart))

      if let match = parseProcessLine(line) {
        parsed.processName = match.name
        parsed.processIdentifier = match.pid
        continue
      }
      if let identifier = parseIdentifierLine(line) {
        parsed.identifier = identifier
        continue
      }
      if let match = parseParentProcessLine(line) {
        parsed.parentProcessName = match.name
        parsed.parentProcessIdentifier = match.pid
        continue
      }
      if let path = parsePathLine(line) {
        parsed.executablePath = path
        continue
      }
      if let date = parseDateLine(line) {
        parsed.date = date
        continue
      }
    }
    return parsed
  }

  // MARK: - Private

  private func parseProcessLine(_ line: String) -> (name: String, pid: pid_t)? {
    let scanner = Scanner(string: line)
    guard scanner.scanString("Process:") != nil,
      let name = scanner.scanUpToString("["),
      scanner.scanString("[") != nil
    else {
      return nil
    }
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    guard let pid = scanner.scanInt32() else {
      return (trimmedName, 0)
    }
    return (trimmedName, pid)
  }

  private func parseIdentifierLine(_ line: String) -> String? {
    let scanner = Scanner(string: line)
    guard scanner.scanString("Identifier:") != nil else { return nil }
    let remaining = String(line[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
    let components = remaining.components(separatedBy: .whitespaces)
    return components.first
  }

  private func parseParentProcessLine(_ line: String) -> (name: String, pid: pid_t)? {
    let scanner = Scanner(string: line)
    guard scanner.scanString("Parent Process:") != nil,
      let name = scanner.scanUpToString("["),
      scanner.scanString("[") != nil
    else {
      return nil
    }
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    guard let pid = scanner.scanInt32() else {
      return (trimmedName, 0)
    }
    return (trimmedName, pid)
  }

  private func parsePathLine(_ line: String) -> String? {
    let scanner = Scanner(string: line)
    guard scanner.scanString("Path:") != nil else { return nil }
    let remaining = String(line[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
    let components = remaining.components(separatedBy: .whitespaces)
    return components.first
  }

  private func parseDateLine(_ line: String) -> Date? {
    let scanner = Scanner(string: line)
    guard scanner.scanString("Date/Time:") != nil else { return nil }
    let remaining = String(line[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
    return CrashReport.dateFormatter().date(from: remaining)
  }
}
