/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import Testing

private struct PerformTestError: Error {}

@Suite
struct DispatchQueuePerformTests {

  @Test
  func returnsWhatTheWorkReturns() async throws {
    let queue = DispatchQueue(label: "com.facebook.fbcontrolcore.tests.perform")

    #expect(await queue.perform { 42 } == 42)
  }

  @Test
  func throwsWhatTheWorkThrows() async {
    let queue = DispatchQueue(label: "com.facebook.fbcontrolcore.tests.perform")

    await #expect(throws: PerformTestError.self) {
      try await queue.perform { throw PerformTestError() }
    }
  }

  @Test
  func runsTheWorkOnTheQueue() async throws {
    let queue = DispatchQueue(label: "com.facebook.fbcontrolcore.tests.perform")
    let key = DispatchSpecificKey<Bool>()
    queue.setSpecific(key: key, value: true)

    #expect(await queue.perform { DispatchQueue.getSpecific(key: key) } == true)
  }

  @Test
  func workThatCannotFailIsAwaitedWithoutTry() async {
    let queue = DispatchQueue(label: "com.facebook.fbcontrolcore.tests.perform")

    #expect(await queue.perform { "done" } == "done")
  }

  @Test
  func acceptsWorkThatIsNotSendable() async throws {
    final class Counter {
      var value = 0
    }
    let queue = DispatchQueue(label: "com.facebook.fbcontrolcore.tests.perform")
    let counter = Counter()

    await queue.perform { counter.value += 1 }

    #expect(counter.value == 1)
  }
}
