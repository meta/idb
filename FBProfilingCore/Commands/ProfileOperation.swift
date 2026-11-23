/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// A profiler that has started.
public struct ProfileOperation: Sendable {
  /// Every sample a `resources` profiler takes; finishes immediately for every other profiler.
  public let samples: AsyncStream<ResourceSample>
  private let task: Task<ProfileResult, any Error>
  /// Nil for a profiler that only ever runs to completion.
  private let stopRequest: ProfileStopRequest?

  /// A profiler that runs to completion, so stopping it abandons it.
  public init(_ body: @escaping @Sendable () async throws -> ProfileResult) {
    samples = AsyncStream { $0.finish() }
    task = Task(operation: body)
    stopRequest = nil
  }

  /// A profiler that `body` ends early, reporting what it has, once its stop request is made.
  public init(samples: AsyncStream<ResourceSample> = AsyncStream { $0.finish() }, stoppable body: @escaping @Sendable (ProfileStopRequest) async throws -> ProfileResult) {
    let stopRequest = ProfileStopRequest()
    self.samples = samples
    task = Task { try await body(stopRequest) }
    self.stopRequest = stopRequest
  }

  /// Returns once the profiler finishes, throwing if its tool failed.
  public var result: ProfileResult {
    get async throws { try await task.value }
  }

  /// Ends a stoppable profiler early, so `result` reports what it recorded so far. A profiler that only runs to
  /// completion is cancelled instead, so `result` throws `CancellationError`.
  public func stop() {
    guard let stopRequest else {
      return task.cancel()
    }
    stopRequest.request()
  }

  /// Abandons the profiler without waiting for a report.
  public func cancel() {
    task.cancel()
  }
}
