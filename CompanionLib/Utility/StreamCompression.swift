/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBArtifactStaging
import FBControlCore
import Foundation
import IDBGRPCSwift

extension CompressionFormat {
  /// A compression the companion does not recognize is read as gzip, which is also what a stream without a compression frame uses.
  init(_ compression: Idb_Payload.Compression) {
    switch compression {
    case .gzip, .UNRECOGNIZED:
      self = .GZIP
    case .zstd:
      self = .ZSTD
    }
  }
}

extension Idb_Payload.Compression {
  init(_ format: CompressionFormat) {
    switch format {
    case .GZIP:
      self = .gzip
    case .ZSTD:
      self = .zstd
    }
  }
}

extension Idb_CompanionInfo {
  /// Every stream is decompressed in-process, so every compression is supported wherever the companion runs. A URL
  /// install can connect to an override.
  mutating func setStreamCapabilities() {
    supportedCompressions = [.gzip, .zstd]
    zstdZipStreams = true
    zipStreamDestinations = [.app, .xctest, .dsym, .framework]
    installConnectTo = true
    supportsNotificationServiceExtension = true
  }
}
