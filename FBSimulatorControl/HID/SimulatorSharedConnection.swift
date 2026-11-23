/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// A connection made on first use and then shared. Callers that arrive while it is being made await
/// that attempt rather than starting their own, and an attempt that fails is forgotten so the next
/// caller starts afresh.
actor SimulatorSharedConnection<Connection: Sendable> {
  typealias Connect = @Sendable () async throws -> Connection

  private let connect: Connect
  private var attempt: Task<Connection, any Error>?

  init(_ connect: @escaping Connect) {
    self.connect = connect
  }

  func connection() async throws -> Connection {
    if let attempt {
      return try await attempt.value
    }
    let attempt = Task { try await connect() }
    self.attempt = attempt
    do {
      return try await attempt.value
    } catch {
      // The actor may have been re-entered during the await, so only forget the attempt that failed.
      if self.attempt == attempt {
        self.attempt = nil
      }
      throw error
    }
  }

  /// Forgets the connection so the next caller makes a new one. Returns the forgotten attempt, whose
  /// connection, if it produced one, is the caller's to close.
  func reset() -> Task<Connection, any Error>? {
    defer { attempt = nil }
    return attempt
  }
}
