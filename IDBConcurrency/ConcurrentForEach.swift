/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

extension Sequence where Element: Sendable {

  /// Runs `operation` concurrently for each element in the sequence. All
  /// operations are launched regardless of failures, and the call returns once
  /// every operation has finished. If one or more threw, the first observed
  /// error is rethrown — additional errors are dropped.
  ///
  /// Deliberately not `@Sendable`, so callers can capture non-`Sendable` references; the closure body
  /// must not race on captured mutable state.
  public func concurrentForEachThrowingFirstError(
    _ operation: @escaping (Element) async throws -> Void
  ) async throws {
    let operationBox = _UncheckedSendable(operation)
    let firstError: (any Error)? = await withTaskGroup(of: (any Error)?.self) { group in
      for element in self {
        group.addTask {
          do {
            try await operationBox.value(element)
            return nil
          } catch {
            return error
          }
        }
      }
      var first: (any Error)?
      for await error in group {
        if first == nil, let error {
          first = error
        }
      }
      return first
    }
    if let firstError {
      throw firstError
    }
  }
}

/// Bridges a value of any type into a `Sendable` context. Used by
/// `concurrentForEachThrowingFirstError` so the per-task closure body — which
/// `withTaskGroup` requires to be `@Sendable` — can call into the caller's
/// non-`Sendable` closure capture.
private struct _UncheckedSendable<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}
