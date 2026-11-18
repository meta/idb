/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

public enum DeviceHIDError: Error, LocalizedError, Sendable {
  case deviceUnavailable
  case busy
  case uncertainState
  case preparationFailed(String)
  case unsupportedRuntime(String)
  case deviceMatchFailed(identifier: UUID, count: Int)
  case deadlineExceeded
  case assertionInvalidated
  case unexpectedCompletion
  case nativeFailure(operation: String, domain: String, code: Int, message: String)

  public var errorDescription: String? {
    switch self {
    case .deviceUnavailable:
      return "The selected physical device is no longer available"
    case .busy:
      return "This physical device already has an input operation in progress"
    case .uncertainState:
      return "The previous physical input has an uncertain outcome; further input is refused"
    case .preparationFailed(let message):
      return "Physical tap preparation failed: \(message)"
    case .unsupportedRuntime(let message):
      return "Physical input is unavailable on this runtime: \(message)"
    case .deviceMatchFailed(let identifier, let count):
      return "Expected one current CoreDevice match for \(identifier), found \(count)"
    case .deadlineExceeded:
      return "The physical input could not finish within its execution budget"
    case .assertionInvalidated:
      return "The physical tap's owned usage assertion was invalidated"
    case .unexpectedCompletion:
      return "A physical input operation delivered an unexpected completion"
    case .nativeFailure(let operation, let domain, let code, let message):
      return "Physical input \(operation) failed: \(message) [\(domain) (\(code))]"
    }
  }

  static func native(_ error: any Error, operation: String) -> DeviceHIDError {
    if let error = error as? DeviceHIDError { return error }
    let error = error as NSError
    return .nativeFailure(operation: operation, domain: error.domain, code: error.code, message: error.localizedDescription)
  }
}
