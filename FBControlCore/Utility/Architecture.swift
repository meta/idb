/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// An open instruction set architecture name supplied by the target.
public struct Architecture: RawRepresentable, Hashable, Codable, Sendable {

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let i386 = Architecture(rawValue: "i386")
  public static let x86_64 = Architecture(rawValue: "x86_64")
  public static let armv7 = Architecture(rawValue: "armv7")
  public static let armv7s = Architecture(rawValue: "armv7s")
  public static let arm64 = Architecture(rawValue: "arm64")
  public static let arm64e = Architecture(rawValue: "arm64e")
  public static let arm64eX1 = Architecture(rawValue: "arm64e.x1")
}
