/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBControlCore
import FBXCTestCore
import Foundation
import Testing

private enum LifetimeTestError: Error, Equatable {
  case bodyFailed
  case discoveryFailed
}

@MainActor
private final class LifetimeProbe {
  weak var first: TargetSetDouble?
  weak var matching: TargetSetDouble?
  let firstReleased = AsyncEvent<Void>()
  let matchingReleased = AsyncEvent<Void>()

  func makers(target: any TargetInfo) -> [TargetSetMaker] {
    [
      {
        let set = TargetSetDouble(targets: [:], onRelease: self.firstReleased.happen)
        self.first = set
        return set
      },
      {
        let set = TargetSetDouble(targets: ["device": target], onRelease: self.matchingReleased.happen)
        self.matching = set
        return set
      },
    ]
  }

  func expectAlive() {
    #expect(first != nil)
    #expect(matching != nil)
    #expect(!firstReleased.hasHappened)
    #expect(!matchingReleased.hasHappened)
  }

  func expectReleased() {
    #expect(first == nil)
    #expect(matching == nil)
    #expect(firstReleased.hasHappened)
    #expect(matchingReleased.hasHappened)
  }
}

@Suite("TargetProvider discovery lifetime")
struct TargetProviderLifetimeTests {
  private let logger = ControlCoreGlobalConfiguration.systemLogger(writingToStderr: false, debugLogging: false)

  enum Exit: CaseIterable, Sendable {
    case success
    case failure
    case cancellation
  }

  @Test("D128054638: discovery spans suspension and cleanup", arguments: Exit.allCases) @MainActor
  func releasesDiscoveryAfterOperationAndCleanup(exit: Exit) async throws {
    let target = MacDevice(logger: logger)
    let probe = LifetimeProbe()
    let entered = AsyncEvent<Void>()
    let resume = AsyncEvent<Void>()
    let cleanupEntered = AsyncEvent<Void>()
    let finishCleanup = AsyncEvent<Void>()
    let operation = Task { @MainActor in
      do {
        try await TargetProvider.withTarget(
          withUDID: "device", makingTargetSets: probe.makers(target: target),
          warmUp: false, logger: logger
        ) { resolved in
          #expect(resolved === target)
          probe.expectAlive()
          entered.happen()
          defer { probe.expectAlive() }
          var failure: Error?
          do {
            try await resume.wait()
            if case .failure = exit { throw LifetimeTestError.bodyFailed }
          } catch {
            failure = error
          }
          probe.expectAlive()
          cleanupEntered.happen()
          try await finishCleanup.waitIgnoringCancellation()
          if let failure { throw failure }
        }
      } catch {
        entered.fail(error)
        cleanupEntered.fail(error)
        throw error
      }
    }
    defer {
      resume.happen()
      finishCleanup.happen()
      operation.cancel()
    }

    try await entered.wait(timeout: 5, waitingFor: "target operation suspension")
    probe.expectAlive()
    if case .cancellation = exit {
      operation.cancel()
    } else {
      resume.happen()
    }
    try await cleanupEntered.wait(timeout: 5, waitingFor: "target operation cleanup")
    probe.expectAlive()
    finishCleanup.happen()
    let result = await operation.result
    switch exit {
    case .success:
      try result.get()
    case .failure:
      #expect(throws: LifetimeTestError.bodyFailed) { try result.get() }
    case .cancellation:
      #expect(throws: CancellationError.self) { try result.get() }
    }
    probe.expectReleased()
  }

  @Test @MainActor
  func failedLookupReleasesDiscoveryWithoutStartingOperation() async {
    let target = MacDevice(logger: logger)
    let probe = LifetimeProbe()
    await #expect(throws: TargetProviderError.self) {
      try await TargetProvider.withTarget(
        withUDID: "unknown", makingTargetSets: probe.makers(target: target),
        warmUp: false, logger: logger
      ) { _ in Issue.record("Operation started after failed lookup") }
    }
    probe.expectReleased()
  }

  @Test @MainActor
  func failedDiscoveryReleasesPreviouslyCreatedSet() async {
    let target = MacDevice(logger: logger)
    let probe = LifetimeProbe()
    let makers: [TargetSetMaker] = [
      probe.makers(target: target)[0],
      {
        #expect(probe.first != nil)
        #expect(!probe.firstReleased.hasHappened)
        throw LifetimeTestError.discoveryFailed
      },
    ]
    await #expect(throws: LifetimeTestError.discoveryFailed) {
      try await TargetProvider.withTarget(
        withUDID: "device", makingTargetSets: makers, warmUp: false, logger: logger
      ) { _ in Issue.record("Operation started after failed discovery") }
    }
    #expect(probe.first == nil)
    #expect(probe.firstReleased.hasHappened)
  }
}
