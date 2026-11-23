/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import GRPCCore
import Testing

@Suite
struct RPCCancellationTests {
  @Test
  func completedOperationDoesNotWaitForDisconnect() async throws {
    let cancellation = ServerContext.RPCCancellationHandle()
    try await withRPCCancellation(cancellation) {}
    #expect(!cancellation.isCancelled)
  }

  @Test
  func alreadyCancelledRPCDoesNotStartOperation() async {
    let cancellation = ServerContext.RPCCancellationHandle()
    cancellation.cancel()
    do {
      _ = try await withRPCCancellation(cancellation) {
        Issue.record("Cancelled RPC must not begin the operation")
      }
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func disconnectCancelsOperationAndJoinsCleanup() async throws {
    let cancellation = ServerContext.RPCCancellationHandle()
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let cleanup = CleanupState()
    async let result: Void = withRPCCancellation(cancellation) {
      continuation.yield(())
      do {
        try await Task.sleep(nanoseconds: 30_000_000_000)
      } catch {
        await cleanup.complete()
        throw error
      }
    }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    cancellation.cancel()
    do {
      try await result
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    let completed = await cleanup.completed
    #expect(completed)
  }

  private actor CleanupState {
    private(set) var completed = false
    func complete() { completed = true }
  }
}
