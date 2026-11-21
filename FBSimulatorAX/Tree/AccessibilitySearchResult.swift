/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import Foundation

/// Nonmatching values of the searched key from one traversal, or that probe's read failure.
public struct AccessibilitySearchDiagnostics: Equatable, Sendable {
  public private(set) var unmatchedValues: [String] = []
  /// Only the diagnostic sample was shortened; the search can still be complete.
  public var truncated: Bool = false
  /// Whether the tree walk stopped at a bound; nil if the backend cannot report it.
  public var readTruncated: Bool? = nil
  public let readError: String?

  public init(
    unmatchedValues: [String] = [], truncated: Bool = false, readError: String? = nil,
    readTruncated: Bool? = nil
  ) {
    self.readError = readError
    self.readTruncated = readTruncated
    self.truncated = truncated
    for value in unmatchedValues {
      record(value)
    }
  }

  /// Records a nonmatch without retaining an unbounded tree's worth of text. The search itself
  /// must continue after this sample fills, so a later match can still succeed.
  mutating func record(_ value: String) {
    guard unmatchedValues.count < 50 else {
      truncated = true
      return
    }
    let sample = String(value.prefix(200))
    truncated = truncated || sample != value
    unmatchedValues.append(sample)
  }

}

/// A match and the nonmatching values visited before it, or the final unsuccessful probe.
struct AccessibilitySearchResult<Match> {
  var match: Match?
  var diagnostics: AccessibilitySearchDiagnostics?

  init(match: Match?, diagnostics: AccessibilitySearchDiagnostics? = nil) {
    self.match = match
    self.diagnostics = diagnostics
  }

  func map<T>(_ transform: (Match) -> T) -> AccessibilitySearchResult<T> {
    AccessibilitySearchResult<T>(match: match.map(transform), diagnostics: diagnostics)
  }
}
