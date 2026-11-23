/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

enum CodesignError: Error, LocalizedError {
  case signingFailed(exitCode: Int32, stdOut: String, stdErr: String)
  case cdHashCheckFailed(exitCode: Int32, stdOut: String, stdErr: String)
  case cdHashNotFound(output: String)

  public var errorDescription: String? {
    switch self {
    case let .signingFailed(exitCode, stdOut, stdErr):
      return "Codesigning failed with exit code \(exitCode), \(stdOut)\n\(stdErr)"
    case let .cdHashCheckFailed(exitCode, stdOut, stdErr):
      return "Checking CDHash of codesign execution failed \(exitCode), \(stdOut)\n\(stdErr)"
    case let .cdHashNotFound(output):
      return "Could not find 'CDHash' in output: \(output)"
    }
  }
}

public final class CodesignProvider {

  public let identityName: String
  private let logger: (any ControlCoreLogger)?

  /// Signs with the identity named `identityName`; `-` signs ad hoc.
  public init(identityName: String, logger: (any ControlCoreLogger)?) {
    self.identityName = identityName
    self.logger = logger
  }

  private func makeCodesignatureWritable(_ bundlePath: String) throws {
    let fileManager = FileManager.default
    let codeSignatureFile = bundlePath + "/_CodeSignature/CodeResources"
    guard fileManager.fileExists(atPath: codeSignatureFile) else {
      return
    }
    guard !fileManager.isWritableFile(atPath: codeSignatureFile) else {
      return
    }
    var attributes = try fileManager.attributesOfItem(atPath: codeSignatureFile)
    if let posixPermissions = attributes[.posixPermissions] as? NSNumber {
      let currentPermissions = posixPermissions.int16Value
      let newPermissions = currentPermissions | 0b010000000
      attributes[.posixPermissions] = NSNumber(value: newPermissions)
      try fileManager.setAttributes(attributes, ofItemAtPath: codeSignatureFile)
      logger?.log("Added user writable permission to code sign file")
    }
  }

  func signBundle(atPath bundlePath: String) async throws {
    try makeCodesignatureWritable(bundlePath)
    logger?.log("Signing bundle \(bundlePath) with identity \(identityName)")

    let result = try await Subprocess(
      executable: "/usr/bin/codesign",
      arguments: ["-s", identityName, "-f", bundlePath]
    )
    .run(exitPolicy: .any, logger: logger)
    try result.checkExitedCleanly { code in
      CodesignError.signingFailed(exitCode: code, stdOut: result.standardOutput, stdErr: result.standardError)
    }
    logger?.log("Successfully signed bundle \(result.standardError)")
  }

  public func cdHash(ofBundleAtPath bundlePath: String) async throws -> String {
    logger?.log("Obtaining CDHash for bundle at path \(bundlePath)")

    let result = try await Subprocess(
      executable: "/usr/bin/codesign",
      arguments: ["-dvvvv", bundlePath]
    )
    .run(exitPolicy: .any, logger: logger)
    try result.checkExitedCleanly { code in
      CodesignError.cdHashCheckFailed(exitCode: code, stdOut: result.standardOutput, stdErr: result.standardError)
    }

    // `codesign -dvvvv` writes its report, CDHash included, to stderr.
    let output = result.standardError
    guard let match = output.firstMatch(of: /CDHash=(.+)/) else {
      throw CodesignError.cdHashNotFound(output: output)
    }
    let cdHash = String(match.1)
    logger?.log("Successfully obtained hash \(cdHash) from bundle \(bundlePath)")
    return cdHash
  }
}
