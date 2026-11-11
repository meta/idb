/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBArtifactStaging
import Foundation
import Testing

@Suite
struct HTTPResponseReaderTests {

  /// Feeds `response` to a reader `step` bytes at a time, then closes the connection, returning every event.
  private func events(_ response: String, step: Int = 3) throws -> [HTTPResponseReader.Event] {
    var reader = HTTPResponseReader()
    let bytes = Data(response.utf8)
    var events: [HTTPResponseReader.Event] = []
    for start in stride(from: 0, to: bytes.count, by: step) {
      events += try reader.consume(bytes.subdata(in: start..<min(start + step, bytes.count)))
    }
    if !reader.isComplete {
      events += try reader.finish()
    }
    return events
  }

  private func body(_ events: [HTTPResponseReader.Event]) -> String {
    let data = events.reduce(into: Data()) { data, event in
      if case .body(let part) = event {
        data.append(part)
      }
    }
    return String(decoding: data, as: UTF8.self)
  }

  @Test
  func aBodyOfTheStatedLengthEndsWithoutTheConnectionClosing() throws {
    var reader = HTTPResponseReader()
    let events = try reader.consume(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8))

    #expect(events == [.head(statusCode: 200, contentLength: 5), .body(Data("hello".utf8)), .end])
    #expect(reader.isComplete)
  }

  @Test
  func theFinalResponsesHeadersAreKeptByLowercasedNameWithRepeatsJoined() throws {
    var reader = HTTPResponseReader()
    _ = try reader.consume(
      Data("HTTP/1.1 100 Continue\r\nX-Interim: yes\r\n\r\nHTTP/1.1 200 OK\r\nCache-Control: max-age=60\r\nAge: 5\r\nVia: a\r\nVia: b\r\nContent-Length: 0\r\n\r\n".utf8))

    #expect(reader.headers == ["cache-control": "max-age=60", "age": "5", "via": "a, b", "content-length": "0"])
  }

  @Test
  func aHeadAndBodySplitAcrossReadsAreReassembled() throws {
    let events = try events("HTTP/1.1 200 OK\r\ncontent-length: 11\r\nX-Other: a:b\r\n\r\nhello world", step: 2)

    #expect(events.first == .head(statusCode: 200, contentLength: 11))
    #expect(body(events) == "hello world")
    #expect(events.last == .end)
  }

  @Test
  func aChunkedBodyIsDeliveredWithoutItsFraming() throws {
    let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nTrailer: x\r\n\r\n"

    let events = try events(response)

    #expect(events.first == .head(statusCode: 200, contentLength: nil))
    #expect(body(events) == "hello world")
    #expect(events.last == .end)
  }

  @Test
  func anInterimResponseIsSkipped() throws {
    let events = try events("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")

    #expect(events.first == .head(statusCode: 200, contentLength: 2))
    #expect(body(events) == "ok")
  }

  @Test
  func aBodyWithoutALengthEndsWhenTheConnectionCloses() throws {
    var reader = HTTPResponseReader()
    let events = try reader.consume(Data("HTTP/1.0 200 OK\r\n\r\nall of it".utf8))

    #expect(!reader.isComplete)
    #expect(try reader.finish() == [.end])
    #expect(body(events) == "all of it")
  }

  @Test
  func aRejectionReportsItsStatus() throws {
    var reader = HTTPResponseReader()
    let events = try reader.consume(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found".utf8))

    #expect(events.first == .head(statusCode: 404, contentLength: 9))
  }

  @Test
  func aBodyCutShortOfItsLengthIsALostConnection() throws {
    var reader = HTTPResponseReader()
    _ = try reader.consume(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort".utf8))

    #expect(throws: URLError(.networkConnectionLost)) { try reader.finish() }
  }

  @Test
  func aChunkedBodyCutShortIsALostConnection() throws {
    var reader = HTTPResponseReader()
    _ = try reader.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel".utf8))

    #expect(throws: URLError(.networkConnectionLost)) { try reader.finish() }
  }

  @Test
  func somethingOtherThanHTTPIsABadResponse() throws {
    var reader = HTTPResponseReader()

    #expect(throws: URLError(.badServerResponse)) { try reader.consume(Data("SSH-2.0-OpenSSH\r\n\r\n".utf8)) }
  }

  @Test
  func aCompressedTransferIsRefusedRatherThanPassedOnCompressed() throws {
    var reader = HTTPResponseReader()

    #expect(throws: URLError(.cannotDecodeContentData)) {
      try reader.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".utf8))
    }
  }

  @Test
  func lengthsThatDisagreeAreRefused() throws {
    var reader = HTTPResponseReader()

    #expect(throws: URLError(.cannotParseResponse)) {
      try reader.consume(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n".utf8))
    }
  }

  @Test
  func aMalformedChunkSizeIsRefused() throws {
    var reader = HTTPResponseReader()

    #expect(throws: URLError(.cannotParseResponse)) {
      try reader.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8))
    }
  }

  @Test
  func aHeadThatNeverEndsIsRefused() throws {
    var reader = HTTPResponseReader()
    let endless = Data(("HTTP/1.1 200 OK\r\n" + String(repeating: "X-Filler: 0123456789\r\n", count: 4000)).utf8)

    #expect(throws: URLError(.cannotParseResponse)) { try reader.consume(endless) }
  }
}
