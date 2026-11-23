/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Streams encoded video frames to a data consumer. `Sendable` because the async lifecycle methods
/// are awaited across concurrency domains.
public protocol VideoStreamOperation: AnyObject, Sendable {
  /// Starts the Streaming, to a Data Consumer.
  func startStreaming(_ consumer: any DataConsumer) async throws

  /// Stops the Streaming.
  func stopStreaming() async throws

  /// Waits for the stream to complete (returns once it has stopped).
  func awaitCompletion() async throws
}
