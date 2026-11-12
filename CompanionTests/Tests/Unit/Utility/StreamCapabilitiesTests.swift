/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import IDBGRPCSwift
import Testing

@Suite
struct StreamCapabilitiesTests {

  @Test
  func everyCompressionIsAdvertisedWhateverIsOnThePath() {
    var info = Idb_CompanionInfo()
    info.setStreamCapabilities()

    #expect(info.supportedCompressions == [.gzip, .zstd])
    #expect(info.zstdZipStreams)
  }

  @Test
  func everyArchiveDestinationReadsAZipStream() {
    var info = Idb_CompanionInfo()
    info.setStreamCapabilities()

    #expect(info.zipStreamDestinations == [.app, .xctest, .dsym, .framework])
  }

  @Test
  func aURLInstallCanConnectToAnOverride() {
    var info = Idb_CompanionInfo()
    info.setStreamCapabilities()

    #expect(info.installConnectTo)
  }

  @Test
  func theHidStreamTypesText() {
    var info = Idb_CompanionInfo()
    info.setStreamCapabilities()

    #expect(info.hidText)
  }
}
