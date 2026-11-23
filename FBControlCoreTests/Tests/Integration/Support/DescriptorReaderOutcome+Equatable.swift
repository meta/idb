/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBControlCore

// FBControlCore never compares outcomes, so it does not carry this conformance; the reader tests do.

extension DescriptorReader.Outcome: Equatable {
  public static func == (lhs: DescriptorReader.Outcome, rhs: DescriptorReader.Outcome) -> Bool {
    switch (lhs, rhs) {
    case (.endOfFile, .endOfFile), (.stopped, .stopped):
      return true
    case let (.failed(left), .failed(right)):
      return left == right
    case (.endOfFile, _), (.stopped, _), (.failed, _):
      return false
    }
  }
}
