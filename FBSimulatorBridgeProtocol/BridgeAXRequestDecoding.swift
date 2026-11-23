/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// Why a request cannot be answered: a frame whose request does not decode, a request that means nothing, or flat
/// parameters that do not spell one. The cases carry what the guest needs to name the problem; wording it is the
/// guest's job.
@frozen public enum BridgeAXRequestError: Error, Equatable, Sendable {
  /// What a field held when it was not what its verb needs: its JSON type, and its value when that is a scalar.
  @frozen public enum Found: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null
    case array
    case object
  }

  /// The verb is absent, not a string, or not one the bridge serves.
  case unsupportedVerb(Found?)
  case nonPositivePid(Int32)
  case invalidDisplayID
  /// The verb needs a numeric `x` and `y`, or for `describe` a pid instead.
  case missingPoint(BridgeAXWire.Verb)
  case unsupportedAction(Found?)
  case missingValue
  case unpairedAssertion
  case unassertableKey(String)
  case missingSetting
  case missingEnabled
  case unsupportedFrontmostMethod(String)
  /// The traversal is absent (nil), not a string, or not one the bridge runs.
  case unsupportedTraversal(Found?)
  /// The client type is absent (nil), not an integer, or not one the translator carries.
  case unsupportedClientType(Found?)
  /// A read named a client but a traversal that makes no translator request.
  case clientTypeNeedsSemanticTraversal(BridgeAXTraversal)
  /// A flag that is neither a boolean, a number nor a string.
  case malformedFlag(BridgeAXWire.Request)
  case negativeTunable(BridgeAXWire.Request, Int)
  /// A frame's request that is not one: the decoder's account of why.
  case undecodable(String)
}

extension BridgeAXRequest {
  /// Refuses a request that means nothing, however it arrived: a pid or display that names none, a client on a
  /// traversal that makes no translator request, or a negative tunable.
  public func validate() throws(BridgeAXRequestError) {
    if let pid, pid <= 0 { throw .nonPositivePid(pid) }
    if displayID == 0 { throw .invalidDisplayID }
    switch self {
    case let .read(_, options, _), let .readFrontmost(_, _, _, options, _):
      if options.clientType != .noClient, options.traversal != .semantic {
        throw .clientTypeNeedsSemanticTraversal(options.traversal)
      }
    case let .quiescence(_, busyThresholdMs, quietWindowMs, _, _, _, _):
      if let busyThresholdMs, busyThresholdMs < 0 { throw .negativeTunable(.busyThresholdMs, busyThresholdMs) }
      if let quietWindowMs, quietWindowMs < 0 { throw .negativeTunable(.quietWindowMs, quietWindowMs) }
    case .hitTest, .write, .deviceSettingRead, .deviceSettingWrite, .deviceSettingChanges, .displays:
      break
    }
  }

  /// The application the request names, if it names one.
  public var pid: Int32? {
    switch self {
    case let .read(pid, _, _): pid
    case let .hitTest(_, _, _, _, _, pid): pid
    case let .write(request): request.pid
    case let .quiescence(pid, _, _, _, _, _, _): pid
    case .readFrontmost, .deviceSettingRead, .deviceSettingWrite, .deviceSettingChanges, .displays: nil
    }
  }

  /// The display the request is scoped to, if it is scoped.
  public var displayID: UInt32? {
    switch self {
    case let .read(_, _, displayID), let .readFrontmost(_, _, _, _, displayID), let .hitTest(_, _, _, _, displayID, _): displayID
    case let .write(request): request.displayID
    case let .quiescence(_, _, _, displayID, _, _, _): displayID
    case .deviceSettingRead, .deviceSettingWrite, .deviceSettingChanges, .displays: nil
    }
  }
}

extension BridgeRequest {
  /// Why the accessibility request a frame carries cannot be answered, so the guest can answer it with an
  /// accessibility failure rather than failing the frame. Nil for a frame that is not an accessibility request, or
  /// whose request is usable.
  public static func accessibilityRequestError(of data: Data) -> BridgeAXRequestError? {
    guard let command = try? JSONDecoder().decode(AccessibilityCommand.self, from: data) else { return nil }
    switch command.command.accessibility.action {
    case let .success(request):
      do {
        try request.validate()
        return nil
      } catch {
        return error
      }
    case let .failure(description):
      return .undecodable(description)
    }
  }

  /// A frame whose command is an accessibility request, which may not decode.
  private struct AccessibilityCommand: Decodable {
    struct Command: Decodable {
      struct Parameters: Decodable {
        let action: Decoded
      }
      let accessibility: Parameters
    }
    let command: Command
  }

  private enum Decoded: Decodable {
    case success(BridgeAXRequest)
    case failure(String)

    init(from decoder: any Decoder) throws {
      do {
        self = .success(try BridgeAXRequest(from: decoder))
      } catch {
        self = .failure(String(describing: error))
      }
    }
  }
}
