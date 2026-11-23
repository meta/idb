/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import Testing

/// Hands one cache to several threads at once.
// SAFETY: The box only forwards to `TargetCommandCache`, which serializes every access under its lock; that
// serialization is what the concurrent test checks.
// patternlint-disable-next-line unchecked-sendable
private final class SharedCache: @unchecked Sendable {
  let cache: TargetCommandCache

  init(_ cache: TargetCommandCache) {
    self.cache = cache
  }
}

/// Counts how many times a slot's `build` closure ran, across threads.
private final class BuildCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    defer { lock.unlock() }
    count += 1
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

private final class StubCommand {
  let identifier: Int
  init(identifier: Int = 0) {
    self.identifier = identifier
  }
}

private final class OtherStubCommand {}

private struct StubValueCommand: Equatable {
  var identifier: Int
}

@Suite("TargetCommandCache")
struct TargetCommandCacheTests {

  @Test("A resolved command is cached, so a second resolve returns the same instance")
  func resolveReturnsTheSameInstance() {
    let cache = TargetCommandCache()
    let first = cache.resolve(StubCommand.self) { StubCommand(identifier: 1) }
    let second = cache.resolve(StubCommand.self) { StubCommand(identifier: 2) }

    // The second build closure never runs, so the identifier stays at the first.
    #expect(first === second)
    #expect(second.identifier == 1)
  }

  @Test("Registering pre-populates the slot, so resolve does not build")
  func registerPrePopulatesTheSlot() {
    let cache = TargetCommandCache()
    let registered = StubCommand(identifier: 7)
    cache.register(registered, as: StubCommand.self)

    let resolved = cache.resolve(StubCommand.self) { StubCommand(identifier: 8) }
    #expect(resolved === registered)
  }

  @Test("Each type gets its own slot")
  func distinctTypesGetDistinctSlots() {
    let cache = TargetCommandCache()
    let command = cache.resolve(StubCommand.self) { StubCommand(identifier: 1) }
    let other = cache.resolve(OtherStubCommand.self) { OtherStubCommand() }

    #expect(cache.resolve(StubCommand.self) { StubCommand(identifier: 2) } === command)
    #expect(cache.resolve(OtherStubCommand.self) { OtherStubCommand() } === other)
  }

  /// What `resolve` hands back is a copy, so a command that mutates its own state must be a
  /// reference type.
  @Test("Mutating a resolved value command does not write back to the cache")
  func mutatingAResolvedValueDoesNotWriteBack() {
    let cache = TargetCommandCache()
    var resolved = cache.resolve(StubValueCommand.self) { StubValueCommand(identifier: 1) }
    resolved.identifier = 99

    let next = cache.resolve(StubValueCommand.self) { StubValueCommand(identifier: 2) }
    #expect(next.identifier == 1)
  }

  @Test("Concurrent first access builds the command exactly once")
  func concurrentFirstAccessBuildsOnce() {
    let cache = SharedCache(TargetCommandCache())
    let counter = BuildCounter()

    DispatchQueue.concurrentPerform(iterations: 64) { _ in
      _ = cache.cache.resolve(StubCommand.self) {
        counter.increment()
        return StubCommand(identifier: 1)
      }
    }

    #expect(counter.value == 1)
  }
}
