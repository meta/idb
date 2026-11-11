/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBArtifactStaging
import Foundation
import Testing

/// How long a response may be reused, from its caching headers.
@Suite
struct HTTPFreshnessTests {

  private func freshness(_ headers: [String: String]) -> TimeInterval? {
    HTTPFreshness { name in headers.first { $0.key.lowercased() == name.lowercased() }?.value }.lifetime
  }

  @Test
  func maxAgeLessTheResponsesAgeIsItsLifetime() {
    #expect(freshness(["Cache-Control": "max-age=1209600, no-transform", "Age": "4323"]) == TimeInterval(1_205_277))
  }

  @Test(arguments: ["no-store", "no-cache", "max-age=600, no-cache", "NO-STORE"])
  func aResponseThatForbidsReuseHasNoLifetime(cacheControl: String) {
    #expect(freshness(["Cache-Control": cacheControl]) == nil)
  }

  @Test
  func aResponseThatSaysNothingAboutItsLifetimeHasNone() {
    #expect(freshness(["Last-Modified": "Sat, 07 Nov 2026 19:43:45 GMT", "Content-Length": "609166767"]) == nil)
  }

  @Test
  func anAgePastMaxAgeLeavesNoLifetime() {
    #expect(freshness(["Cache-Control": "max-age=60", "Age": "61"]) == nil)
    #expect(freshness(["Cache-Control": "max-age=0"]) == nil)
  }

  @Test
  func repeatedAgeHeadersCountTheOldest() {
    #expect(freshness(["Cache-Control": "max-age=60", "Age": "5, 7"]) == 53)
    #expect(freshness(["Cache-Control": "max-age=60", "Age": "61, 5"]) == nil)
  }

  @Test
  func anUnreadableAgeGivesNoLifetime() {
    #expect(freshness(["Cache-Control": "max-age=60", "Age": "5, soon"]) == nil)
  }

  @Test
  func aRepeatedMaxAgeKeepsTheFirst() {
    #expect(freshness(["Cache-Control": "max-age=60, max-age=600"]) == 60)
  }

  @Test
  func expiresCountsFromTheServersDate() {
    #expect(freshness(["Expires": "Sun, 06 Nov 1994 09:49:37 GMT", "Date": "Sun, 06 Nov 1994 08:49:37 GMT"]) == 3600)
  }

  @Test
  func maxAgeTakesPrecedenceOverExpires() {
    #expect(freshness(["Cache-Control": "max-age=10", "Expires": "Sun, 06 Nov 1994 09:49:37 GMT", "Date": "Sun, 06 Nov 1994 08:49:37 GMT"]) == 10)
  }

  @Test
  func anUnreadableExpiresGivesNoLifetime() {
    #expect(freshness(["Expires": "0"]) == nil)
  }
}
