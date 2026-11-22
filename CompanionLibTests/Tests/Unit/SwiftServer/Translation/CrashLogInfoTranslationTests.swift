/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency @testable import CompanionLib
@preconcurrency import FBControlCore
import Foundation
import IDBGRPCSwift
import Testing

@Suite
struct CrashLogInfoTranslationTests {

  @Test
  func responseCarriesTheReportsFields() {
    let crash = CrashLogInfo(
      crashPath: "/tmp/ReplHost-2026-09-30-102328.ips",
      executablePath: "/Volumes/VOLUME/*/ReplHost.app/ReplHost",
      identifier: "com.facebook.idb.replhost",
      processName: "ReplHost",
      processIdentifier: 45264,
      parentProcessName: "launchd_sim",
      parentProcessIdentifier: 43138,
      date: Date(timeIntervalSince1970: 1_790_789_007),
      processType: .application,
      exceptionDescription: nil,
      crashedThreadDescription: nil)

    let response = CrashLogInfoTranslation.responseCrashLogInfo(from: crash)

    #expect(response.name == "ReplHost-2026-09-30-102328.ips")
    #expect(response.processName == "ReplHost")
    #expect(response.parentProcessName == "launchd_sim")
    #expect(response.processIdentifier == 45264)
    #expect(response.parentProcessIdentifier == 43138)
    #expect(response.timestamp == 1_790_789_007)
    #expect(response.bundleID == "com.facebook.idb.replhost")
  }
}
