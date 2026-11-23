/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// Everything that can go wrong between being told where an application is and
/// having a bundle to install.
///
/// A caller deciding what to do about a failure -- retry the fetch, report a bad
/// URL, tell the user their archive is empty -- matches on a case rather than on
/// the text of a message.
public enum InstallError: Error, CustomStringConvertible {

  case httpStatus(url: URL?, statusCode: Int)

  /// The transfer did not finish. `report` is what the connection said about itself before it failed.
  case transferFailed(url: URL?, underlying: any Error, report: DownloadReport = DownloadReport())

  /// The response was not HTTP at all, so there is no status to report.
  case notAnHTTPResponse(url: URL)

  /// The extractor rejected the archive, or failed part way through it.
  case extractionFailed(underlying: any Error)

  /// The archive was unpacked, and did not hold exactly one loadable application.
  case noInstallableBundle(inDirectory: String, underlying: any Error)

  /// What was staged held no artifact of `kind` that could be identified: no test bundle, framework, dylib or dSYM.
  case unidentifiable(kind: ArtifactKind, underlying: any Error)

  public var description: String {
    switch self {
    case .httpStatus(let url, let statusCode):
      let target = url.map { " of \($0.absoluteString)" } ?? ""
      return "Download\(target) failed with HTTP status \(statusCode)"
    case .transferFailed(let url, let underlying, _):
      let target = url.map { " of \($0.absoluteString)" } ?? ""
      return "Download\(target) did not complete: \(underlying)"
    case .notAnHTTPResponse(let url):
      return "Download of \(url.absoluteString) got a non-HTTP response"
    case .extractionFailed(let underlying):
      return "Could not extract the archive: \(underlying.localizedDescription)"
    case .noInstallableBundle(let directory, let underlying):
      return "No installable application in \(directory): \(underlying)"
    case .unidentifiable(let kind, let underlying):
      return "No \(kind) to install: \(underlying)"
    }
  }
}

// MARK: - Bridging

extension InstallError: CustomNSError {

  public static var errorDomain: String { "com.facebook.FBArtifactStaging.install" }

  /// Carries the description across the Objective-C and gRPC boundaries, both of
  /// which report `localizedDescription` rather than the Swift error.
  public var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: description]
  }
}
