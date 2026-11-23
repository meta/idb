/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
@testable import IDBConcurrency
import Testing
import os

@Suite
struct IDBConcurrencyTransientTests {

  // MARK: - Mutex Tests

  @Test
  func mutexSyncThrows() {
    struct TestError: Error {}
    let mutex = Mutex()
    #expect(throws: (any Error).self) { try mutex.sync { throw TestError() } }
  }

  @Test
  func mutexConcurrentAccess() {
    let mutex = Mutex()
    // Each increment reads and writes in separate critical sections of its own lock, so only `mutex`
    // keeps increments from being lost.
    let counter = OSAllocatedUnfairLock(initialState: 0)
    DispatchQueue.concurrentPerform(iterations: 1000) { _ in
      mutex.sync {
        let value = counter.withLock { $0 }
        counter.withLock { $0 = value + 1 }
      }
    }
    #expect(counter.withLock { $0 } == 1000)
  }

  // MARK: - CodeLocation Tests

  @Test
  func codeLocationDescriptionWithFunction() {
    let location = CodeLocation(function: "testFunc", file: "TestFile.swift", line: 10, column: 5)
    #expect(location.description == "Located at file: TestFile.swift, line: 10, column: 5, function: testFunc")
  }

  @Test
  func codeLocationDescriptionWithoutFunction() {
    let location = CodeLocation(function: nil, file: "TestFile.swift", line: 10, column: 5)
    #expect(location.description == "Located at file: TestFile.swift, line: 10, column: 5")
  }

  // MARK: - TaskTimeoutError Tests

  @Test
  func taskTimeoutErrorDescription() {
    let location = CodeLocation(function: "myFunc", file: "File.swift", line: 1, column: 1)
    let error = TaskTimeoutError(location: location)
    #expect(error.errorDescription?.contains("timeout") == true)
    #expect(error.errorDescription?.contains("File.swift") == true)
  }

  // MARK: - Task.select Tests

  @Test
  func selectReturnsFirstCompletedTask() async {
    let fast = Task<Int, Never> { 1 }
    let slow = Task<Int, Never> {
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      return 2
    }
    let winner = await Task.select(fast, slow)
    let value = await winner.value
    #expect(value == 1)
    slow.cancel()
  }

  @Test
  func selectWithSequence() async {
    let tasks = (0..<3).map { i in
      Task<Int, Never> {
        if i == 1 {
          return 99
        }
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        return i
      }
    }
    let winner = await Task.select(tasks)
    let value = await winner.value
    #expect(value == 99)
    for task in tasks { task.cancel() }
  }

  @Test
  func selectCancellationCancelsTasks() async throws {
    let task1 = Task<Int, Never> {
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      return 1
    }
    let task2 = Task<Int, Never> {
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      return 2
    }

    let selectTask = Task<Task<Int, Never>, Never> {
      await Task.select(task1, task2)
    }

    // Give select time to register tasks, then cancel
    try? await Task.sleep(nanoseconds: 50_000_000)
    selectTask.cancel()

    // After cancellation, the underlying tasks should be cancelled
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(task1.isCancelled)
    #expect(task2.isCancelled)
  }

  // MARK: - Task.timeout Tests

  @Test
  func timeoutSucceedsWhenJobCompletesInTime() async throws {
    let result = try await Task.timeout(nanoseconds: 1_000_000_000) {
      return 42
    }
    #expect(result == 42)
  }

  @Test
  func timeoutThrowsWhenJobExceedsTimeout() async {
    await #expect(throws: TaskTimeoutError.self) {
      try await Task.timeout(nanoseconds: 10_000_000) {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return 1
      }
    }
  }

  @Test
  func timeoutPropagatesJobError() async {
    struct JobError: Error {}
    await #expect(throws: JobError.self) {
      try await Task.timeout(nanoseconds: 1_000_000_000) {
        throw JobError()
      }
    }
  }

  // MARK: - TeardownContext Tests

  @Test
  func withAutocleanupCallsCleanupInLIFOOrder() async throws {
    var order: [Int] = []
    try await TeardownContext.withAutocleanup {
      try TeardownContext.current.addCleanup {
        order.append(1)
      }
      try TeardownContext.current.addCleanup {
        order.append(2)
      }
      try TeardownContext.current.addCleanup {
        order.append(3)
      }
    }
    #expect(order == [3, 2, 1])
  }

  @Test
  func emptyContextThrowsOnAddCleanup() async {
    let emptyContext = TeardownContext.current
    do {
      try emptyContext.addCleanup {}
      Issue.record("Expected emptyContext error")
    } catch let contextError as TeardownContextError {
      switch contextError {
      case .emptyContext:
        break
      case .cleanupAlreadyPerformed:
        Issue.record("Unexpected error case")
      }
    } catch {
      Issue.record("Expected TeardownContextError")
    }
  }

  @Test
  func emptyContextThrowsOnPerformCleanup() async {
    let emptyContext = TeardownContext.current
    await #expect(throws: TeardownContextError.self) {
      try await emptyContext.performCleanup()
    }
  }

  @Test
  func doubleCleanupThrows() async throws {
    var cleanupCount = 0
    await #expect(throws: TeardownContextError.self) {
      try await TeardownContext.withAutocleanup {
        let context = TeardownContext.current
        try context.addCleanup {
          cleanupCount += 1
        }
        // Manually perform cleanup before autocleanup triggers
        try await context.performCleanup()
      }
    }
    #expect(cleanupCount == 1)
  }

  @Test
  func addCleanupAfterCleanupPerformedThrows() async throws {
    var context: TeardownContext?
    try await TeardownContext.withAutocleanup {
      context = TeardownContext.current
    }
    // Context cleanup already performed by withAutocleanup
    let captured = try #require(context)
    #expect(throws: TeardownContextError.self) {
      try captured.addCleanup {}
    }
  }

  @Test
  func withAutocleanupReturnsValue() async throws {
    let result = try await TeardownContext.withAutocleanup {
      return 42
    }
    #expect(result == 42)
  }

  @Test
  func withAutocleanupPropagatesError() async {
    struct TestError: Error {}
    await #expect(throws: TestError.self) {
      try await TeardownContext.withAutocleanup {
        throw TestError()
      }
    }
  }
}
