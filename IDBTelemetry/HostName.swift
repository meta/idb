/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// What the host calls itself, so telemetry rows can be matched with the host's other metrics.
public enum HostName {

  /// `kern.hostname`, or `nil` where it can't be read. `ProcessInfo.hostName` resolves through the network, and on
  /// virtual machines is often empty or a name every clone of the image shares.
  public static let kernel: String? = {
    #if canImport(Darwin)
    var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
    guard gethostname(&buffer, buffer.count - 1) == 0 else {
      return nil
    }
    let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return name.isEmpty ? nil : name
    #else
    return nil
    #endif
  }()
}
