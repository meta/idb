/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import IDBConcurrency

/// Forwards each chunk of data it consumes, in order on a private queue, until a send fails or
/// `stopForwarding()` is called. Data consumed after that is dropped, so a stream that has gone away
/// is never written to again.
final class ResponseForwardingConsumer: DataConsumer, DataConsumerLifecycle, Sendable {
  private let stopped: Atomic<Bool>
  private let consumer: AsynchronousDataConsumer

  init(send: @escaping @Sendable (Data) throws -> Void) {
    let stopped = Atomic(wrappedValue: false)
    self.stopped = stopped
    self.consumer = AsynchronousDataConsumer { data in
      guard !stopped.wrappedValue else { return }
      do {
        try send(data)
      } catch {
        stopped.set(true)
      }
    }
  }

  func stopForwarding() {
    stopped.set(true)
  }

  func consumeData(_ data: Data) {
    consumer.consumeData(data)
  }

  func consumeEndOfFile() {
    consumer.consumeEndOfFile()
  }

  var finishedConsuming: AsyncEvent<Void> {
    consumer.finishedConsuming
  }

  var consumption: DataConsumption {
    consumer.consumption
  }
}
