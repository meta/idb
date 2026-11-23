/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

// MARK: - DTX Internals

// Understanding of the DTXMessage protocol is informed by the ios_instruments_client project:
// https://github.com/troybowman/ios_instruments_client
//
// The headers are encoded and decoded field by field, in declaration order, rather than by copying
// a struct's memory: Swift makes no guarantee about a struct's layout, so the wire format cannot
// be derived from it.

private let DTXMessageHeaderMagic: UInt32 = 0x1F3D_5B79

/// 32 bytes on the wire.
private struct DTXMessageHeader {
  var magic: UInt32 = 0
  var cb: UInt32 = 0
  var fragmentId: UInt16 = 0
  var fragmentCount: UInt16 = .max
  var length: UInt32 = 0
  var identifier: UInt32 = 0
  var conversationIndex: UInt32 = 0
  var channelCode: UInt32 = 0
  var expectsReply: UInt32 = 0

  static let wireSize = 32

  static func decode(_ data: Data) -> DTXMessageHeader {
    var reader = WireReader(data)
    var header = DTXMessageHeader()
    header.magic = reader.readUInt32()
    header.cb = reader.readUInt32()
    header.fragmentId = reader.readUInt16()
    header.fragmentCount = reader.readUInt16()
    header.length = reader.readUInt32()
    header.identifier = reader.readUInt32()
    header.conversationIndex = reader.readUInt32()
    header.channelCode = reader.readUInt32()
    header.expectsReply = reader.readUInt32()
    return header
  }

  func encode(into data: inout Data) {
    data.appendValue(magic)
    data.appendValue(cb)
    data.appendValue(fragmentId)
    data.appendValue(fragmentCount)
    data.appendValue(length)
    data.appendValue(identifier)
    data.appendValue(conversationIndex)
    data.appendValue(channelCode)
    data.appendValue(expectsReply)
  }
}

/// 16 bytes on the wire.
private struct DTXMessagePayloadHeader {
  var flags: UInt32 = 0
  var auxiliaryLength: UInt32 = 0
  var totalLength: UInt64 = 0

  static let wireSize = 16

  static func decode(_ data: Data) -> DTXMessagePayloadHeader {
    var reader = WireReader(data)
    var header = DTXMessagePayloadHeader()
    header.flags = reader.readUInt32()
    header.auxiliaryLength = reader.readUInt32()
    header.totalLength = reader.readUInt64()
    return header
  }

  func encode(into data: inout Data) {
    data.appendValue(flags)
    data.appendValue(auxiliaryLength)
    data.appendValue(totalLength)
  }
}

/// Reads fixed-width host-order values off the front of a buffer.
private struct WireReader {
  private var data: Data

  init(_ data: Data) {
    self.data = data
  }

  mutating func readUInt16() -> UInt16 {
    read()
  }

  mutating func readUInt32() -> UInt32 {
    read()
  }

  mutating func readUInt64() -> UInt64 {
    read()
  }

  private mutating func read<T: FixedWidthInteger>() -> T {
    var value: T = 0
    withUnsafeMutableBytes(of: &value) { destination in
      unsafe destination.copyBytes(from: data.prefix(MemoryLayout<T>.size))
    }
    data = data.dropFirst(MemoryLayout<T>.size)
    return value
  }
}

extension Data {
  fileprivate mutating func appendValue<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value) { unsafe append(contentsOf: $0) }
  }
}

// MARK: - Object Internals

private struct ResponsePayload {
  var messageIdentifier: UInt32
  var channelCode: UInt32
  var returnValue: Any?
  var auxillaryValues: [Any]?
}

private struct RequestPayload {
  var selector: String
  var argumentsData: [Data]?
  var messageIdentifier: UInt32
  var channelCode: UInt32
  var expectsReply: Bool
}

public enum InstrumentsClientError: Error {
  case channelsNotADictionary(described: String)
  case auxillaryDataTooShort(described: String)
  case undecodableArgumentType(type: UInt32)
  case undecodableArgument(described: String)
  case corruptHeader
  case compressedResponse
  case staleResponseIdentifier(received: UInt32, requested: UInt32)
  case mismatchedResponseIdentifier(received: UInt32, requested: UInt32)
  case unknownChannel(identifier: String, available: [String])
  case inconsistentPayloadLengths(total: UInt64, auxiliary: UInt32, received: Int)
  case unexpectedLaunchResult(described: String)
}

extension InstrumentsClientError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .channelsNotADictionary(described):
      return "\(described) is not a dictionary"
    case let .auxillaryDataTooShort(described):
      return "Data is of insufficient length \(described)"
    case let .undecodableArgumentType(type):
      return "Cannot decode argument of type \(type)"
    case let .undecodableArgument(described):
      return "Failed to decode argument \(described)"
    case .corruptHeader:
      return "Response header does not carry the DTXMessage magic"
    case .compressedResponse:
      return "Response payload is compressed, which is not supported"
    case let .staleResponseIdentifier(received, requested):
      return "Response identifier \(received) with lower identifier than that requested (\(requested))"
    case let .mismatchedResponseIdentifier(received, requested):
      return "Response identifier \(received) is not the same as requested identifier (\(requested))"
    case let .unknownChannel(identifier, available):
      return "Could not make a channel \(identifier) as it is not one of \(available)"
    case let .inconsistentPayloadLengths(total, auxiliary, received):
      return "Response payload lengths are inconsistent: total \(total), auxiliary \(auxiliary), received \(received)"
    case let .unexpectedLaunchResult(described):
      return "Expected a process identifier from the launch, got \(described)"
    }
  }
}

private let ProcessControlChannel = "com.apple.instruments.server.services.processcontrol"

/// A client to instruments-related services on a device, talking the DTXMessage protocol over a
/// lockdown service connection.
final class InstrumentsClient {

  // MARK: - Properties

  private var lastMessageIdentifier: UInt32
  private var lastChannelIdentifier: Int32 = 0
  private let channels: [String: Any]
  private let connection: LockdownServiceConnection
  private let logger: any ControlCoreLogger

  // MARK: - Initializers

  /// Performs the handshake on `connection`, which is read and written synchronously from then on.
  /// The client is not safe to use from more than one thread at a time.
  init(connection: LockdownServiceConnection, logger: any ControlCoreLogger) throws {
    let (channels, responseMessageIdentifier) = try Self.availableChannels(on: connection)
    self.connection = connection
    self.channels = channels
    self.lastMessageIdentifier = responseMessageIdentifier
    self.logger = logger
  }

  // MARK: - Public

  func launchApplication(_ configuration: ApplicationLaunchConfiguration) throws -> pid_t {
    let options: [String: Any] = [
      "StartSuspendedKey": configuration.waitForDebugger,
      "KillExisting": configuration.launchMode != .failIfRunning,
    ]
    let response = try onChannel(
      identifier: ProcessControlChannel,
      performSelector: "launchSuspendedProcessWithDevicePath:bundleIdentifier:environment:arguments:options:",
      argumentsData: [
        Self.argumentData(forArgument: ""), // devicePath:
        Self.argumentData(forArgument: configuration.bundleID), // bundleIdentifier:
        Self.argumentData(forArgument: configuration.environment), // environment:
        Self.argumentData(forArgument: configuration.arguments), // arguments:
        Self.argumentData(forArgument: options), // options:
      ])
    guard let processIdentifier = response.returnValue as? NSNumber else {
      throw InstrumentsClientError.unexpectedLaunchResult(described: String(describing: response.returnValue))
    }
    return processIdentifier.int32Value
  }

  func killProcess(_ processIdentifier: pid_t) throws {
    _ = try onChannel(
      identifier: ProcessControlChannel,
      performSelector: "killPid:",
      argumentsData: [
        Self.argumentData(forArgument: NSNumber(value: processIdentifier)) // pid:
      ])
  }

  // MARK: - The wire format

  private static let capabilitiesArgumentData = argumentData(
    forArgument: ["com.apple.private.DTXBlockCompression": 2, "com.apple.private.DTXConnection": 1])

  private static let supportedReturnSerializerValues: [AnyClass] = [
    NSString.self, NSNumber.self, NSDate.self, NSError.self, NSData.self, NSDictionary.self, NSArray.self,
  ]

  private static let ArgumentMagic: UInt64 = 0x1F0
  private static let EmptyDictionaryKey: UInt32 = 10
  private static let ObjectArgumentType: UInt32 = 2
  private static let Int32ArgumentType: UInt32 = 3

  static func argumentData(forArgument argument: Any) -> Data {
    // These are plist-shaped values the caller controls, so archiver failure is programmer error.
    // swiftlint:disable:next force_try
    let argumentData = try! NSKeyedArchiver.archivedData(withRootObject: argument, requiringSecureCoding: false)
    var data = Data()
    data.appendValue(EmptyDictionaryKey)
    data.appendValue(ObjectArgumentType)
    data.appendValue(UInt32(argumentData.count))
    data.append(argumentData)
    return data
  }

  static func argumentData(forInt32 value: Int32) -> Data {
    var data = Data()
    data.appendValue(EmptyDictionaryKey)
    data.appendValue(Int32ArgumentType)
    data.appendValue(value)
    return data
  }

  static func auxillaryData(fromArgumentsData arguments: [Data]?) -> Data {
    guard let arguments else {
      return Data()
    }
    var argumentsData = Data()
    for argument in arguments {
      argumentsData.append(argument)
    }
    var data = Data()
    data.appendValue(ArgumentMagic)
    data.appendValue(UInt64(argumentsData.count))
    data.append(argumentsData)
    return data
  }

  static func objectArguments(fromAuxillaryData data: Data) throws -> [Any] {
    guard data.count >= 16 else {
      throw InstrumentsClientError.auxillaryDataTooShort(described: String(describing: data as NSData))
    }
    // The magic and payload length occupy the first 16 bytes; nothing reads their values.
    var remaining = data.dropFirst(16)

    // At least the three length-prefixing fields of an argument must remain in the buffer.
    var arguments: [Any] = []
    while remaining.count > MemoryLayout<UInt32>.size * 3 {
      var argumentReader = WireReader(Data(remaining))
      _ = argumentReader.readUInt32() // dictionary key
      let argumentType = argumentReader.readUInt32()
      guard argumentType == ObjectArgumentType else {
        throw InstrumentsClientError.undecodableArgumentType(type: argumentType)
      }
      let argumentLength = argumentReader.readUInt32()
      // Wire-supplied length: validate before indexing, or a truncated payload traps.
      guard remaining.count >= 12 + Int(argumentLength) else {
        throw InstrumentsClientError.auxillaryDataTooShort(described: String(describing: Data(remaining) as NSData))
      }
      let argumentStart = remaining.index(remaining.startIndex, offsetBy: 12)
      let argumentEnd = remaining.index(argumentStart, offsetBy: Int(argumentLength))
      let argumentData = Data(remaining[argumentStart..<argumentEnd])
      remaining = remaining[argumentEnd...]
      guard
        let argument = try? NSKeyedUnarchiver.unarchivedObject(
          ofClasses: supportedReturnSerializerValues, from: argumentData)
      else {
        throw InstrumentsClientError.undecodableArgument(described: String(describing: argumentData as NSData))
      }
      arguments.append(argument)
    }
    return arguments
  }

  // MARK: - The DTXMessage exchange

  private static func availableChannels(on connection: LockdownServiceConnection) throws -> ([String: Any], UInt32) {
    let request = RequestPayload(
      selector: "_notifyOfPublishedCapabilities:",
      argumentsData: [capabilitiesArgumentData],
      messageIdentifier: 1,
      channelCode: 0,
      expectsReply: false)
    let response = try sendAndReceive(request, on: connection)
    guard let channels = response.auxillaryValues?.first as? [String: Any] else {
      throw InstrumentsClientError.channelsNotADictionary(
        described: String(describing: response.auxillaryValues?.first))
    }
    return (channels, response.messageIdentifier)
  }

  private static func sendAndReceive(
    _ request: RequestPayload, on connection: LockdownServiceConnection
  ) throws -> ResponsePayload {
    try connection.send(requestData(from: request))
    return try receiveMessage(on: connection, request: request)
  }

  private static func requestData(from request: RequestPayload) -> Data {
    let auxillaryData = auxillaryData(fromArgumentsData: request.argumentsData)

    // The selector is the "return value" of a request. In a response this will be the return
    // value of the remote method.
    // swiftlint:disable:next force_try
    let selectorData = try! NSKeyedArchiver.archivedData(withRootObject: request.selector, requiringSecureCoding: false)

    var payloadHeader = DTXMessagePayloadHeader()
    payloadHeader.flags = 0x2 | (request.expectsReply ? 0x1000 : 0)
    payloadHeader.auxiliaryLength = UInt32(auxillaryData.count)
    payloadHeader.totalLength = UInt64(auxillaryData.count + selectorData.count)

    // All messages have a magic number, sent in a single fragment.
    var messageHeader = DTXMessageHeader()
    messageHeader.magic = DTXMessageHeaderMagic
    messageHeader.cb = UInt32(DTXMessageHeader.wireSize)
    messageHeader.fragmentId = 0
    messageHeader.fragmentCount = 1
    messageHeader.length = UInt32(DTXMessagePayloadHeader.wireSize) + UInt32(payloadHeader.totalLength)
    messageHeader.identifier = request.messageIdentifier
    messageHeader.conversationIndex = 0
    messageHeader.channelCode = request.channelCode
    messageHeader.expectsReply = request.expectsReply ? 1 : 0

    var data = Data()
    messageHeader.encode(into: &data)
    payloadHeader.encode(into: &data)
    data.append(auxillaryData)
    data.append(selectorData)
    return data
  }

  private static func receiveMessage(
    on connection: LockdownServiceConnection, request: RequestPayload
  ) throws -> ResponsePayload {
    var messageHeader = DTXMessageHeader()
    var payloadData = Data()

    // Compared as `Int`: a fragment count of zero underflows the unsigned subtraction.
    while Int(messageHeader.fragmentId) < Int(messageHeader.fragmentCount) - 1 {
      messageHeader = DTXMessageHeader.decode(try connection.receive(DTXMessageHeader.wireSize))
      guard messageHeader.magic == DTXMessageHeaderMagic else {
        throw InstrumentsClientError.corruptHeader
      }
      if messageHeader.conversationIndex == 0 && messageHeader.identifier < request.messageIdentifier {
        throw InstrumentsClientError.staleResponseIdentifier(
          received: messageHeader.identifier, requested: request.messageIdentifier)
      }
      if messageHeader.conversationIndex == 1 && messageHeader.identifier != request.messageIdentifier {
        throw InstrumentsClientError.mismatchedResponseIdentifier(
          received: messageHeader.identifier, requested: request.messageIdentifier)
      }
      // The first message in a multi-part fragment has no payload; the next fragment does.
      if messageHeader.fragmentCount > 1 && messageHeader.fragmentId == 0 {
        continue
      }
      payloadData.append(try connection.receive(Int(messageHeader.length)))
    }
    return try consume(payloadData: payloadData, messageHeader: messageHeader)
  }

  private static func consume(payloadData: Data, messageHeader: DTXMessageHeader) throws -> ResponsePayload {
    // A single payload header starts the payload, even for a multi-part message.
    let payloadHeader = DTXMessagePayloadHeader.decode(payloadData)
    var remaining = payloadData.dropFirst(DTXMessagePayloadHeader.wireSize)
    let compression = (payloadHeader.flags & 0xFF000) >> 12
    guard compression == 0 else {
      throw InstrumentsClientError.compressedResponse
    }

    // Wire-supplied lengths: validate before subtracting or indexing, either of which would trap.
    guard
      payloadHeader.totalLength >= UInt64(payloadHeader.auxiliaryLength),
      payloadHeader.totalLength <= UInt64(remaining.count)
    else {
      throw InstrumentsClientError.inconsistentPayloadLengths(
        total: payloadHeader.totalLength, auxiliary: payloadHeader.auxiliaryLength, received: remaining.count)
    }

    var auxillaryData: Data?
    if payloadHeader.auxiliaryLength > 0 {
      let end = remaining.index(remaining.startIndex, offsetBy: Int(payloadHeader.auxiliaryLength))
      auxillaryData = Data(remaining[remaining.startIndex..<end])
      remaining = remaining[end...]
    }

    let returnValueDataLength = Int(payloadHeader.totalLength - UInt64(payloadHeader.auxiliaryLength))
    var returnValueData: Data?
    if returnValueDataLength > 0 {
      let end = remaining.index(remaining.startIndex, offsetBy: returnValueDataLength)
      returnValueData = Data(remaining[remaining.startIndex..<end])
    }

    return try parse(returnValueData: returnValueData, auxillaryData: auxillaryData, messageHeader: messageHeader)
  }

  private static func parse(
    returnValueData: Data?, auxillaryData: Data?, messageHeader: DTXMessageHeader
  ) throws -> ResponsePayload {
    // Only the handshake response is read for auxillary values.
    var auxillaryValues: [Any]?
    if let auxillaryData, !auxillaryData.isEmpty {
      auxillaryValues = try objectArguments(fromAuxillaryData: auxillaryData)
    }

    // For some calls the return value is the selector name.
    var returnValue: Any?
    if let returnValueData, !returnValueData.isEmpty {
      returnValue = try NSKeyedUnarchiver.unarchivedObject(
        ofClasses: supportedReturnSerializerValues, from: returnValueData)
      if let error = returnValue as? NSError {
        throw error
      }
    }

    return ResponsePayload(
      messageIdentifier: messageHeader.identifier,
      channelCode: messageHeader.channelCode,
      returnValue: returnValue,
      auxillaryValues: auxillaryValues)
  }

  // MARK: - Channels

  private func onChannel(
    identifier channelIdentifier: String, performSelector selector: String, argumentsData: [Data]?
  ) throws -> ResponsePayload {
    let channelCode = try makeChannel(identifier: channelIdentifier)
    let request = RequestPayload(
      selector: selector,
      argumentsData: argumentsData,
      messageIdentifier: nextMessageIdentifier(),
      channelCode: UInt32(channelCode),
      expectsReply: true)
    return try sendAndReceive(request)
  }

  private func makeChannel(identifier: String) throws -> Int32 {
    guard channels[identifier] != nil else {
      throw InstrumentsClientError.unknownChannel(identifier: identifier, available: Array(channels.keys))
    }
    let channelIdentifier = nextChannelIdentifier()
    let request = RequestPayload(
      selector: "_requestChannelWithCode:identifier:",
      argumentsData: [
        Self.argumentData(forInt32: channelIdentifier),
        Self.argumentData(forArgument: identifier),
      ],
      messageIdentifier: nextMessageIdentifier(),
      channelCode: 0,
      expectsReply: true)
    _ = try sendAndReceive(request)
    return channelIdentifier
  }

  private func sendAndReceive(_ request: RequestPayload) throws -> ResponsePayload {
    let response = try Self.sendAndReceive(request, on: connection)
    lastMessageIdentifier = response.messageIdentifier
    return response
  }

  private func nextMessageIdentifier() -> UInt32 {
    lastMessageIdentifier += 1
    return lastMessageIdentifier
  }

  private func nextChannelIdentifier() -> Int32 {
    lastChannelIdentifier += 1
    return lastChannelIdentifier
  }
}
