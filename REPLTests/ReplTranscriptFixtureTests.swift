/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import IDBGRPCSwift
import SwiftProtobuf
import Testing

private final class ReplTranscriptFixtureBundleToken {}

private enum StrictJSONError: Error {
  case duplicateKey(String)
  case invalidSyntax
}

private struct StrictJSONParser {
  private let bytes: [UInt8]
  private var index = 0

  init(data: Data) {
    bytes = Array(data)
  }

  mutating func parse() throws {
    try parseValue()
    skipWhitespace()
    guard index == bytes.count else {
      throw StrictJSONError.invalidSyntax
    }
  }

  private mutating func parseValue() throws {
    skipWhitespace()
    guard let byte = current else {
      throw StrictJSONError.invalidSyntax
    }
    switch byte {
    case UInt8(ascii: "{"):
      try parseObject()
    case UInt8(ascii: "["):
      try parseArray()
    case UInt8(ascii: "\""):
      _ = try parseString()
    case UInt8(ascii: "t"):
      try consume("true")
    case UInt8(ascii: "f"):
      try consume("false")
    case UInt8(ascii: "n"):
      try consume("null")
    default:
      guard byte == UInt8(ascii: "-") || byte.isASCIIDigit else {
        throw StrictJSONError.invalidSyntax
      }
      repeat {
        index += 1
      } while current.map({ !$0.isJSONDelimiter }) == true
    }
  }

  private mutating func parseObject() throws {
    index += 1
    skipWhitespace()
    if consumeIf(UInt8(ascii: "}")) {
      return
    }
    var keys = Set<String>()
    while true {
      let key = try parseString()
      guard keys.insert(key).inserted else {
        throw StrictJSONError.duplicateKey(key)
      }
      skipWhitespace()
      guard consumeIf(UInt8(ascii: ":")) else {
        throw StrictJSONError.invalidSyntax
      }
      try parseValue()
      skipWhitespace()
      if consumeIf(UInt8(ascii: "}")) {
        return
      }
      guard consumeIf(UInt8(ascii: ",")) else {
        throw StrictJSONError.invalidSyntax
      }
      skipWhitespace()
    }
  }

  private mutating func parseArray() throws {
    index += 1
    skipWhitespace()
    if consumeIf(UInt8(ascii: "]")) {
      return
    }
    while true {
      try parseValue()
      skipWhitespace()
      if consumeIf(UInt8(ascii: "]")) {
        return
      }
      guard consumeIf(UInt8(ascii: ",")) else {
        throw StrictJSONError.invalidSyntax
      }
    }
  }

  private mutating func parseString() throws -> String {
    skipWhitespace()
    guard current == UInt8(ascii: "\"") else {
      throw StrictJSONError.invalidSyntax
    }
    let start = index
    index += 1
    while let byte = current {
      index += 1
      if byte == UInt8(ascii: "\\") {
        guard current != nil else {
          throw StrictJSONError.invalidSyntax
        }
        index += 1
      } else if byte == UInt8(ascii: "\"") {
        return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
      }
    }
    throw StrictJSONError.invalidSyntax
  }

  private mutating func consume(_ literal: String) throws {
    let expected = Array(literal.utf8)
    guard bytes[index...].starts(with: expected) else {
      throw StrictJSONError.invalidSyntax
    }
    index += expected.count
  }

  private mutating func consumeIf(_ byte: UInt8) -> Bool {
    guard current == byte else {
      return false
    }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    while current.map({ $0.isJSONWhitespace }) == true {
      index += 1
    }
  }

  private var current: UInt8? {
    index < bytes.count ? bytes[index] : nil
  }
}

private extension UInt8 {
  var isASCIIDigit: Bool {
    self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9")
  }

  var isJSONDelimiter: Bool {
    isJSONWhitespace || self == UInt8(ascii: ",") || self == UInt8(ascii: "]")
      || self == UInt8(ascii: "}")
  }

  var isJSONWhitespace: Bool {
    self == 0x20 || self == 0x09 || self == 0x0a || self == 0x0d
  }
}

@Suite
struct ReplTranscriptFixtureTests {
  private struct Transcript: Decodable {
    let version: Int
    let scope: String
    let steps: [Step]
  }

  private struct Step: Decodable {
    enum Kind: String, Decodable {
      case start = "Start"
      case ready = "Ready"
      case execute = "Execute"
      case result = "Result"
      case clientHalfClose = "client_half_close"
      case stopped = "Stopped"
    }

    let kind: Kind
    let protobufBase64: String?

    enum CodingKeys: String, CodingKey {
      case kind
      case protobufBase64 = "protobuf_base64"
    }
  }

  @Test
  func languageNeutralTranscript() throws {
    let url = try #require(
      Bundle(for: ReplTranscriptFixtureBundleToken.self)
        .url(forResource: "repl_transcript.v1", withExtension: "json")
    )
    let data = try Data(contentsOf: url)
    var strictParser = StrictJSONParser(data: data)
    try strictParser.parse()
    var duplicateParser = StrictJSONParser(
      data: Data("{\"version\":1,\"version\":2}".utf8)
    )
    do {
      try duplicateParser.parse()
      Issue.record("Expected duplicate JSON keys to fail")
    } catch StrictJSONError.duplicateKey(let key) {
      #expect(key == "version")
    } catch {
      Issue.record("Expected a duplicate-key error, got \(error)")
    }
    let rawTranscript = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(Set(rawTranscript.keys) == ["scope", "steps", "version"])
    let rawSteps = try #require(rawTranscript["steps"] as? [[String: Any]])
    for rawStep in rawSteps {
      let kind = try #require(rawStep["kind"] as? String)
      let expectedKeys =
        kind == "client_half_close"
        ? Set(["kind"])
        : Set(["kind", "protobuf_base64"])
      #expect(Set(rawStep.keys) == expectedKeys)
    }

    let transcript = try JSONDecoder().decode(Transcript.self, from: data)

    #expect(transcript.version == 1)
    #expect(transcript.scope == "swift-protobuf-wire-contract")
    #expect(
      transcript.steps.map(\.kind)
        == [.start, .ready, .execute, .result, .clientHalfClose, .stopped]
    )

    let startBytes = try protobufBytes(transcript.steps[0])
    var expectedStartPayload = Idb_ReplRequest.Start()
    expectedStartPayload.testBundlePath = "FixtureTests.xctest"
    expectedStartPayload.context = .test
    expectedStartPayload.probeFilePath = "/tmp/idb-repl-fixture-probe"
    var expectedStart = Idb_ReplRequest()
    expectedStart.control = .start(expectedStartPayload)
    #expect(try expectedStart.serializedData() == startBytes)
    let startRequest = try Idb_ReplRequest(serializedBytes: startBytes)
    #expect(startRequest == expectedStart)
    #expect(try startRequest.serializedData() == startBytes)
    guard case let .start(start) = startRequest.control else {
      Issue.record("Expected Start")
      return
    }
    #expect(start.testBundlePath == "FixtureTests.xctest")
    #expect(start.context == .test)
    #expect(start.probeFilePath == "/tmp/idb-repl-fixture-probe")

    let readyBytes = try protobufBytes(transcript.steps[1])
    var expectedInterface = Idb_ReplResponse.Ready.GeneratedInterface()
    expectedInterface.moduleName = "IDB"
    expectedInterface.contents = "public struct Fixture {}"
    var expectedReadyPayload = Idb_ReplResponse.Ready()
    expectedReadyPayload.deviceType = "iphone"
    expectedReadyPayload.generatedInterfaces = [expectedInterface]
    expectedReadyPayload.osVersion = "26.0"
    expectedReadyPayload.nextRunIndex = 0
    expectedReadyPayload.sharedFilesystem = true
    expectedReadyPayload.sessionID = "fixture-session"
    var expectedReady = Idb_ReplResponse()
    expectedReady.event = .ready(expectedReadyPayload)
    #expect(try expectedReady.serializedData() == readyBytes)
    let readyResponse = try Idb_ReplResponse(serializedBytes: readyBytes)
    #expect(readyResponse == expectedReady)
    #expect(try readyResponse.serializedData() == readyBytes)
    guard case let .ready(ready) = readyResponse.event else {
      Issue.record("Expected Ready")
      return
    }
    #expect(ready.deviceType == "iphone")
    #expect(ready.generatedInterfaces.count == 1)
    #expect(ready.generatedInterfaces[0].moduleName == "IDB")
    #expect(ready.generatedInterfaces[0].contents == "public struct Fixture {}")
    #expect(ready.osVersion == "26.0")
    #expect(ready.nextRunIndex == 0)
    #expect(ready.sharedFilesystem)
    #expect(ready.sessionID == "fixture-session")

    let executeBytes = try protobufBytes(transcript.steps[2])
    var expectedExecutePayload = Idb_ReplRequest.Execute()
    expectedExecutePayload.dylib = Data([0xca, 0xfe])
    expectedExecutePayload.symbol = "idb_repl_0"
    var expectedExecute = Idb_ReplRequest()
    expectedExecute.control = .execute(expectedExecutePayload)
    #expect(try expectedExecute.serializedData() == executeBytes)
    let executeRequest = try Idb_ReplRequest(serializedBytes: executeBytes)
    #expect(executeRequest == expectedExecute)
    #expect(try executeRequest.serializedData() == executeBytes)
    guard case let .execute(execute) = executeRequest.control else {
      Issue.record("Expected Execute")
      return
    }
    #expect(execute.dylib == Data([0xca, 0xfe]))
    #expect(execute.symbol == "idb_repl_0")

    let resultBytes = try protobufBytes(transcript.steps[3])
    var expectedArtifact = Idb_ReplResponse.Result.Artifact()
    expectedArtifact.hostPath = "/tmp/idb-repl-artifacts/fixture-session/capture.png"
    expectedArtifact.containerPath = "idb-repl-artifacts/fixture-session/capture.png"
    var expectedResultPayload = Idb_ReplResponse.Result()
    expectedResultPayload.success = true
    expectedResultPayload.output = "ok"
    expectedResultPayload.nextRunIndex = 1
    expectedResultPayload.artifacts = [expectedArtifact]
    var expectedResult = Idb_ReplResponse()
    expectedResult.event = .result(expectedResultPayload)
    #expect(try expectedResult.serializedData() == resultBytes)
    let resultResponse = try Idb_ReplResponse(serializedBytes: resultBytes)
    #expect(resultResponse == expectedResult)
    #expect(try resultResponse.serializedData() == resultBytes)
    guard case let .result(result) = resultResponse.event else {
      Issue.record("Expected Result")
      return
    }
    #expect(result.success)
    #expect(result.output == "ok")
    #expect(result.nextRunIndex == 1)
    #expect(result.artifacts.count == 1)
    #expect(
      result.artifacts[0].hostPath
        == "/tmp/idb-repl-artifacts/fixture-session/capture.png"
    )
    #expect(
      result.artifacts[0].containerPath
        == "idb-repl-artifacts/fixture-session/capture.png"
    )

    #expect(transcript.steps[4].protobufBase64 == nil)

    let stoppedBytes = try protobufBytes(transcript.steps[5])
    var expectedStoppedPayload = Idb_ReplResponse.Stopped()
    expectedStoppedPayload.desc = "REPL session ended"
    var expectedStopped = Idb_ReplResponse()
    expectedStopped.event = .stopped(expectedStoppedPayload)
    #expect(try expectedStopped.serializedData() == stoppedBytes)
    let stoppedResponse = try Idb_ReplResponse(serializedBytes: stoppedBytes)
    #expect(stoppedResponse == expectedStopped)
    #expect(try stoppedResponse.serializedData() == stoppedBytes)
    guard case let .stopped(stopped) = stoppedResponse.event else {
      Issue.record("Expected Stopped")
      return
    }
    #expect(stopped.desc == "REPL session ended")
  }

  private func protobufBytes(_ step: Step) throws -> Data {
    let encoded = try #require(step.protobufBase64)
    return try #require(Data(base64Encoded: encoded))
  }
}
