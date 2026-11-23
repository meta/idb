/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// A detail of a target that takes asynchronous work to read, so is only read on request.
public enum TargetDetailKey: Hashable, Sendable {
  case diagnostics
  case displays
}

public enum TargetDetail<Value> {
  /// This kind of target has no such detail.
  case unsupported
  case read(Value)
  case failed(any Error)
}

/// A display as a target describes it.
public struct TargetDisplayDescription: Sendable {
  public let uniqueID: String
  public let name: String
  public let isActive: Bool
  public let isIntegrated: Bool
  /// Pixel dimensions in the display's current orientation, or zero when the display reports none.
  public let widthPixels: UInt
  public let heightPixels: UInt
  public let scale: Double

  public init(uniqueID: String, name: String, isActive: Bool, isIntegrated: Bool, widthPixels: UInt, heightPixels: UInt, scale: Double) {
    self.uniqueID = uniqueID
    self.name = name
    self.isActive = isActive
    self.isIntegrated = isIntegrated
    self.widthPixels = widthPixels
    self.heightPixels = heightPixels
    self.scale = scale
  }
}

/// The requested details of a target. A detail that was not requested is `nil`.
public struct TargetDetails {
  public var diagnostics: TargetDetail<[String: Any]>?
  public var displays: TargetDetail<[TargetDisplayDescription]>?

  /// Every requested detail `unsupported`, for a target to replace with those it can read.
  public init(unsupported keys: Set<TargetDetailKey>) {
    diagnostics = keys.contains(.diagnostics) ? .unsupported : nil
    displays = keys.contains(.displays) ? .unsupported : nil
  }
}
