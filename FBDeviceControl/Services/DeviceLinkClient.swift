/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

private let ProcessMessage = "DLMessageProcessMessage"
private let DeviceReady = "DLMessageDeviceReady"

public enum DeviceLinkError: Error {
  case resultNotAnArray(result: String)
  case responseTypeNotAString(responseType: String, result: String)
  case unexpectedResponseType(responseType: String, expected: String)
  case responseBodyNotADictionary(body: String)
  case versionExchangeNotAnArray(plist: String)
  case handshakeVersionNotANumber(version: String)
  case deviceReadyMessageNotAString(message: String)
  case deviceNotReady(message: String, expected: String)
  case replyTooShort(reply: String, expectedCount: Int)
}

extension DeviceLinkError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .resultNotAnArray(result):
      return "Result is not an NSArray: \(result)"
    case let .responseTypeNotAString(responseType, result):
      return "\(responseType) is not an NSString in \(result)"
    case let .unexpectedResponseType(responseType, expected):
      return "\(responseType) should be a \(expected)"
    case let .responseBodyNotADictionary(body):
      return "\(body) is not an NSDictionary"
    case let .versionExchangeNotAnArray(plist):
      return "\(plist) is not an array in version exchange"
    case let .handshakeVersionNotANumber(version):
      return "\(version) is not an NSNumber for the handshake version"
    case let .deviceReadyMessageNotAString(message):
      return "\(message) is not an NSString for the device ready call"
    case let .deviceNotReady(message, expected):
      return "\(message) is not equal to \(expected)"
    case let .replyTooShort(reply, expectedCount):
      return "\(reply) has fewer than \(expectedCount) elements"
    }
  }
}

public final class DeviceLinkClient {
  private let connection: LockdownServiceConnection
  private let queue: DispatchQueue

  /// Performs the DeviceLink version exchange over `connection` before returning.
  public convenience init(connection: LockdownServiceConnection) async throws {
    let queue = DispatchQueue(label: "com.facebook.fbdevicecontrol.fbdevicelinkclient")
    try await DeviceLinkClient.performVersionExchange(connection: connection, queue: queue)
    self.init(connection: connection, queue: queue)
  }

  init(connection: LockdownServiceConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  func processMessage(_ message: Any) async throws -> [String: Any] {
    return try await queue.perform { [connection, message] in
      let result = try connection.sendAndReceiveMessage([ProcessMessage, message])
      guard let resultArray = result as? [Any] else {
        throw DeviceLinkError.resultNotAnArray(result: String(describing: result))
      }
      guard resultArray.count >= 2 else {
        throw DeviceLinkError.replyTooShort(reply: String(describing: resultArray), expectedCount: 2)
      }
      let responseType = resultArray[0]
      guard let responseString = responseType as? String else {
        throw DeviceLinkError.responseTypeNotAString(responseType: String(describing: responseType), result: String(describing: resultArray))
      }
      if responseString != ProcessMessage {
        throw DeviceLinkError.unexpectedResponseType(responseType: responseString, expected: ProcessMessage)
      }
      guard let response = resultArray[1] as? [String: Any] else {
        throw DeviceLinkError.responseBodyNotADictionary(body: String(describing: resultArray[1]))
      }
      return response
    }
  }

  private static func performVersionExchange(connection: LockdownServiceConnection, queue: DispatchQueue) async throws {
    try await queue.perform { [connection] in
      let plist = try connection.receiveMessage()
      guard let plistArray = plist as? [Any] else {
        throw DeviceLinkError.versionExchangeNotAnArray(plist: String(describing: plist))
      }
      guard plistArray.count >= 2 else {
        throw DeviceLinkError.replyTooShort(reply: String(describing: plistArray), expectedCount: 2)
      }
      let versionNumber = plistArray[1]
      guard versionNumber is NSNumber else {
        throw DeviceLinkError.handshakeVersionNotANumber(version: String(describing: versionNumber))
      }
      let response: [Any] = ["DLMessageVersionExchange", "DLVersionsOk", versionNumber]
      let reply = try connection.sendAndReceiveMessage(response)
      guard let replyArray = reply as? [Any] else {
        throw DeviceLinkError.versionExchangeNotAnArray(plist: String(describing: reply))
      }
      guard let message = replyArray.first else {
        throw DeviceLinkError.replyTooShort(reply: String(describing: replyArray), expectedCount: 1)
      }
      guard let messageString = message as? String else {
        throw DeviceLinkError.deviceReadyMessageNotAString(message: String(describing: message))
      }
      if messageString != DeviceReady {
        throw DeviceLinkError.deviceNotReady(message: messageString, expected: DeviceReady)
      }
    }
  }
}
