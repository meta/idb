/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// Reads an HTTP/1.1 response to a GET as its bytes arrive: the status and length once the head is complete, then the
/// body with any chunked framing removed. Interim (1xx) responses are skipped.
///
/// A response that can't be read throws a `URLError`, the code `URLSession` reports for the same fault.
struct HTTPResponseReader: Sendable {

  enum Event: Equatable, Sendable {
    /// The final response's head. `contentLength` is nil when the response doesn't state one.
    case head(statusCode: Int, contentLength: Int64?)
    case body(Data)
    /// The body is complete. Nothing after it is read.
    case end
  }

  /// A head larger than this is not a response to a download.
  static let maximumHeadLength = 64 << 10

  private enum Phase: Sendable {
    case head
    case length(remaining: Int64)
    case chunkSize
    case chunkData(remaining: Int64)
    case chunkDataEnd
    case trailers
    case untilClose
    /// The body is complete and `.end` not yet reported.
    case endOfBody
    case done
  }

  private var phase = Phase.head
  private var buffered = Data()
  /// The final response's headers, by lowercased name, repeated headers joined with commas; empty until its head is read.
  private(set) var headers: [String: String] = [:]

  /// Whether the body is complete.
  var isComplete: Bool {
    if case .done = phase {
      return true
    }
    return false
  }

  /// The events `data` completes, in order.
  mutating func consume(_ data: Data) throws -> [Event] {
    buffered.append(data)
    var events: [Event] = []
    while let event = try next() {
      events.append(event)
      if event == .end {
        break
      }
    }
    return events
  }

  /// The connection closed after everything consumed so far: the end of a body that runs until the connection closes,
  /// and a truncated response otherwise.
  mutating func finish() throws -> [Event] {
    switch phase {
    case .untilClose, .endOfBody:
      phase = .done
      return [.end]
    case .done:
      return []
    case .head, .length, .chunkSize, .chunkData, .chunkDataEnd, .trailers:
      throw URLError(.networkConnectionLost)
    }
  }

  // MARK: - Phases

  /// The next event in what is buffered, or nil once it needs more bytes.
  private mutating func next() throws -> Event? {
    switch phase {
    case .head:
      return try readHead()
    case .length(let remaining):
      guard !buffered.isEmpty else {
        return nil
      }
      let count = Int(min(remaining, Int64(buffered.count)))
      let body = takeBuffered(count)
      phase = remaining == Int64(count) ? .endOfBody : .length(remaining: remaining - Int64(count))
      return .body(body)
    case .untilClose:
      guard !buffered.isEmpty else {
        return nil
      }
      return .body(takeBuffered(buffered.count))
    case .chunkSize:
      guard let line = try takeLine() else {
        return nil
      }
      let size = try Self.chunkSize(line)
      phase = size == 0 ? .trailers : .chunkData(remaining: size)
      return try next()
    case .chunkData(let remaining):
      guard !buffered.isEmpty else {
        return nil
      }
      let count = Int(min(remaining, Int64(buffered.count)))
      let body = takeBuffered(count)
      phase = remaining == Int64(count) ? .chunkDataEnd : .chunkData(remaining: remaining - Int64(count))
      return .body(body)
    case .chunkDataEnd:
      guard let line = try takeLine() else {
        return nil
      }
      guard line.isEmpty else {
        throw URLError(.cannotParseResponse)
      }
      phase = .chunkSize
      return try next()
    case .trailers:
      guard let line = try takeLine() else {
        return nil
      }
      guard line.isEmpty else {
        return try next()
      }
      phase = .done
      return .end
    case .endOfBody:
      phase = .done
      return .end
    case .done:
      return nil
    }
  }

  private mutating func readHead() throws -> Event? {
    guard let end = buffered.range(of: Data("\r\n\r\n".utf8)) else {
      if buffered.count > Self.maximumHeadLength {
        throw URLError(.cannotParseResponse)
      }
      return nil
    }
    guard end.lowerBound - buffered.startIndex <= Self.maximumHeadLength else {
      throw URLError(.cannotParseResponse)
    }
    let head = String(decoding: buffered[buffered.startIndex..<end.lowerBound], as: UTF8.self)
    buffered = Data(buffered[end.upperBound...])
    var lines = head.components(separatedBy: "\r\n")
    let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let statusCode = Int(statusLine[1]), (100...999).contains(statusCode)
    else {
      throw URLError(.badServerResponse)
    }
    if (100...199).contains(statusCode) {
      // An interim response has no body; the final response follows it.
      return try readHead()
    }
    var contentLength: Int64?
    var chunked = false
    headers = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else {
        throw URLError(.cannotParseResponse)
      }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = headers[name].map { "\($0), \(value)" } ?? value
      switch name {
      case "content-length":
        guard let length = Int64(value), length >= 0, contentLength == nil || contentLength == length else {
          throw URLError(.cannotParseResponse)
        }
        contentLength = length
      case "transfer-encoding":
        let codings = value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // A body the server compressed would arrive here still compressed, so only chunked framing is accepted.
        guard codings.allSatisfy({ $0 == "chunked" || $0 == "identity" }) else {
          throw URLError(.cannotDecodeContentData)
        }
        chunked = codings.contains("chunked")
      default:
        break
      }
    }
    if chunked {
      phase = .chunkSize
      return .head(statusCode: statusCode, contentLength: nil)
    }
    if let contentLength {
      phase = contentLength == 0 ? .endOfBody : .length(remaining: contentLength)
    } else {
      phase = .untilClose
    }
    return .head(statusCode: statusCode, contentLength: contentLength)
  }

  // MARK: - Buffer

  private mutating func takeBuffered(_ count: Int) -> Data {
    let taken = Data(buffered.prefix(count))
    buffered = Data(buffered.dropFirst(count))
    return taken
  }

  /// The next CRLF-terminated line, without its terminator, or nil until one is buffered.
  private mutating func takeLine() throws -> String? {
    guard let end = buffered.range(of: Data("\r\n".utf8)) else {
      if buffered.count > Self.maximumHeadLength {
        throw URLError(.cannotParseResponse)
      }
      return nil
    }
    let line = String(decoding: buffered[buffered.startIndex..<end.lowerBound], as: UTF8.self)
    buffered = Data(buffered[end.upperBound...])
    return line
  }

  /// The size a chunk-size line declares, ignoring any extensions after it.
  private static func chunkSize(_ line: String) throws -> Int64 {
    let digits = line.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
    guard !digits.isEmpty, digits.count <= 15, let size = Int64(digits, radix: 16), size >= 0 else {
      throw URLError(.cannotParseResponse)
    }
    return size
  }
}
