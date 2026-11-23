/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreVideo
import Foundation

extension OSType {
  /// Human-readable rendering of this FourCC. Returns the literal four ASCII
  /// characters when every byte is printable ASCII (0x20–0x7e, i.e. excludes
  /// NUL, control bytes, DEL, and any high-bit byte); otherwise falls back to
  /// an `0x`-prefixed 8-digit hex string so the result is always safe to log.
  public var fourCharCodeString: String {
    let bytes: [UInt8] = [
      UInt8((self >> 24) & 0xff),
      UInt8((self >> 16) & 0xff),
      UInt8((self >> 8) & 0xff),
      UInt8(self & 0xff),
    ]
    if bytes.allSatisfy({ (0x20...0x7e).contains($0) }),
      let printable = String(bytes: bytes, encoding: .ascii)
    {
      return printable
    }
    return unsafe String(format: "0x%08x", self)
  }
}
