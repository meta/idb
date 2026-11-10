/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import IDBGRPCSwift

/// What identifies the build of the app a REPL session serves, read the way the Apple prelude
/// records it: the `build_uuid` in the bundle's `BuildInfo.json`, written when the bundle is built
/// with `include_build_info_file`, and the LC_UUID of the main executable.
struct ReplAppIdentity: Equatable {
  /// The `build_uuid` of `BuildInfo.json`, nil when the bundle has no readable one.
  var buildUUID: String?
  /// The main executable's Mach-O UUID, nil when it could not be read.
  var executableUUID: String?

  init(buildUUID: String?, executableUUID: String?) {
    self.buildUUID = buildUUID
    self.executableUUID = executableUUID
  }

  /// The identity of the bundle at `bundlePath`, whose main executable has `executableUUID`.
  init(bundlePath: String, executableUUID: UUID?) {
    self.init(buildUUID: Self.buildUUID(inBundleAt: bundlePath), executableUUID: executableUUID?.uuidString)
  }

  /// `BuildInfo.json` sits at the bundle root on iOS and under `Contents/Resources` on macOS.
  static func buildUUID(inBundleAt bundlePath: String) -> String? {
    BundleBuildIdentity.buildUUID(inBundleAt: bundlePath)
  }
}

/// The build an `Execute` says the app must be; an empty field is no expectation.
struct ReplBuildExpectation: Equatable {
  var buildUUID: String
  var executableUUID: String

  init(buildUUID: String = "", executableUUID: String = "") {
    self.buildUUID = buildUUID
    self.executableUUID = executableUUID
  }

  init(_ execute: Idb_ReplRequest.Execute) {
    self.init(buildUUID: execute.expectedBuildUuid, executableUUID: execute.expectedExecutableUuid)
  }

  var isEmpty: Bool { buildUUID.isEmpty && executableUUID.isEmpty }
}

enum ReplBuildVerdict: Equatable {
  case accepted
  case rejected(Idb_ReplResponse.Result.Rejection, message: String)
}

/// Decides whether a dylib may be loaded into the app a session serves. Every way the expectation
/// cannot be confirmed is a rejection: the driver asked for a guarantee, so the absence of the
/// evidence is not a pass.
enum ReplBuildIdentityCheck {
  /// `identity` is nil when the session serves no app (the simulator and test contexts).
  static func verify(_ expectation: ReplBuildExpectation, against identity: ReplAppIdentity?, bundleID: String?) -> ReplBuildVerdict {
    guard let identity, let bundleID else {
      return .rejected(.unsupportedContext, message: "this REPL session serves no app bundle, so an expected build UUID cannot be checked")
    }
    if !expectation.buildUUID.isEmpty {
      guard let actual = identity.buildUUID else {
        return .rejected(
          .buildUuidUnavailable,
          message: "\(bundleID) has no BuildInfo.json with a build_uuid; build the app with include_build_info_file to check its build")
      }
      guard actual.caseInsensitiveCompare(expectation.buildUUID) == .orderedSame else {
        return .rejected(
          .buildUuidMismatch,
          message: "\(bundleID) is build \(actual), the dylib expects build \(expectation.buildUUID); reinstall the app or rebuild the dylib")
      }
    }
    if !expectation.executableUUID.isEmpty {
      guard let actual = identity.executableUUID else {
        return .rejected(.executableUuidUnavailable, message: "the main executable UUID of \(bundleID) could not be read")
      }
      guard actual.caseInsensitiveCompare(expectation.executableUUID) == .orderedSame else {
        return .rejected(
          .executableUuidMismatch,
          message: "the main executable of \(bundleID) is \(actual), the dylib expects \(expectation.executableUUID); reinstall the app or rebuild the dylib")
      }
    }
    return .accepted
  }
}
