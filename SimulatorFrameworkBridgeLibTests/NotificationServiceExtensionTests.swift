/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import Testing

@Suite struct NotificationServiceExtensionTests {
  private struct Result: Sendable {
    let status: Int?
    let body: String?
    let error: String?
    let lookups: Int?
    let mutations: Int?
    let insertions: Int?
    let cleanups: Int?
    let cleanupsAtReturn: Int?
    let loopExitedDuringCleanup: Bool?

    init(_ values: NSDictionary) {
      status = values["status"] as? Int
      body = values["body"] as? String
      error = values["error"] as? String
      lookups = values["lookups"] as? Int
      mutations = values["mutations"] as? Int
      insertions = values["insertions"] as? Int
      cleanups = values["cleanups"] as? Int
      cleanupsAtReturn = values["cleanupsAtReturn"] as? Int
      loopExitedDuringCleanup = values["loopExitedDuringCleanup"] as? Bool
    }
  }

  private func run(_ scenario: String) async -> Result {
    await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        let result = Result(FBNotificationServiceExtensionTestRun(scenario) as NSDictionary)
        continuation.resume(returning: result)
      }
    }
  }

  @Test func postsOnlyTheContentReturnedByTheNSE() async {
    let result = await run("delivered")
    #expect(result.status == 0)
    #expect(result.body == "Changed by the NSE")
    #expect(result.mutations == 1)
    #expect(result.insertions == 1)
    #expect(result.cleanups == 1)
  }

  @Test func doesNotPostSuppressedContent() async {
    let result = await run("suppressed")
    #expect(result.status == 1)
    #expect(result.insertions == 0)
    #expect(result.cleanups == 1)
  }

  @Test func anAsynchronousInsertionFinishesCleanupBeforeReturning() async {
    let result = await run("asynchronous-insertion")
    #expect(result.status == 0)
    #expect(result.insertions == 1)
    #expect(result.cleanupsAtReturn == 1)
    #expect(result.loopExitedDuringCleanup == false)
  }

  @Test func cleanupCannotChangeConfirmedInsertionSuccess() async {
    let result = await run("cleanup-raise")
    #expect(result.status == 0)
    #expect(result.body == "Changed by the NSE")
    #expect(result.insertions == 1)
    #expect(result.cleanups == 1)
    #expect(result.error == "")
  }

  @Test func cleanupCannotReplaceTheInsertionError() async {
    let result = await run("cleanup-raise-insertion-error")
    #expect(result.status == 2)
    #expect(result.error == "insertion refused")
    #expect(result.cleanups == 1)
  }

  @Test(arguments: ["expired-before-insertion", "synchronous-completion", "insertion-in-flight"])
  func insertionAndExpiryHaveOneTerminalOrder(_ scenario: String) {
    let result = FBNotificationServiceExtensionDeadlineTestRun(scenario) as NSDictionary
    #expect(result["restarted"] as? Bool == false)
    if scenario == "expired-before-insertion" {
      #expect(result["started"] as? Bool == false)
      #expect(result["insertions"] as? Int == 0)
      #expect(result["status"] as? Int == 2)
      #expect((result["error"] as? String ?? "").contains("insertion was not started"))
    } else if scenario == "synchronous-completion" {
      #expect(result["started"] as? Bool == true)
      #expect(result["insertions"] as? Int == 1)
      #expect(result["status"] as? Int == 0)
    } else {
      #expect(result["started"] as? Bool == true)
      #expect(result["insertions"] as? Int == 1)
      #expect(result["status"] as? Int == 2)
      #expect((result["error"] as? String ?? "").contains("outcome may be unknown"))
    }
  }

  @Test(arguments: ["invalid", "nonmutable", "oversized"])
  func rejectsPayloadsBeforeLookingUpTheExtension(_ scenario: String) async {
    let result = await run(scenario)
    #expect(result.status == 2)
    #expect(result.lookups == 0)
    #expect(result.insertions == 0)
  }

  @Test(arguments: ["missing", "error", "raise", "insertion-error", "timeout"])
  func reportsFailuresWithoutPostingTheOriginal(_ scenario: String) async {
    let result = await run(scenario)
    #expect(result.status == 2)
    #expect(!(result.error ?? "").isEmpty)
    if scenario == "insertion-error" {
      #expect(result.insertions == 1)
      #expect(result.body == "Changed by the NSE")
    } else {
      #expect(result.insertions == 0)
    }
    #expect(result.cleanups == (scenario == "missing" ? 0 : 1))
  }
}
