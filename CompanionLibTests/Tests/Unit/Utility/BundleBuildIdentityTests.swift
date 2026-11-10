/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import Darwin
import Foundation
import Testing

@Suite
struct BundleBuildIdentityTests {
  private func withBundle(_ test: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("idb-build-info-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try test(directory)
  }

  @Test func readsBothBundleLayoutsAndRejectsMalformedIdentity() throws {
    try withBundle { directory in
      let resources = directory.appendingPathComponent("Contents/Resources")
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
      let file = resources.appendingPathComponent("BuildInfo.json")
      try Data(#"{"build_uuid":"mac-build"}"#.utf8).write(to: file)
      #expect(BundleBuildIdentity.buildUUID(inBundleAt: directory.path) == "mac-build")
      try Data(#"{"build_uuid":42}"#.utf8).write(to: file)
      #expect(BundleBuildIdentity.buildUUID(inBundleAt: directory.path) == nil)
      try Data("not JSON".utf8).write(to: file)
      #expect(BundleBuildIdentity.buildUUID(inBundleAt: directory.path) == nil)
    }
  }

  @Test func enforcesFileAndUUIDByteLimits() throws {
    try withBundle { directory in
      let file = directory.appendingPathComponent("BuildInfo.json")
      var bytes = Data(#"{"build_uuid":"build"}"#.utf8)
      bytes.append(Data(repeating: 0x20, count: 16 * 1024 - bytes.count))
      try bytes.write(to: file)
      #expect(BundleBuildIdentity.buildUUID(inBundleAt: directory.path) == "build")
      bytes.append(0x20)
      try bytes.write(to: file)
      #expect(BundleBuildIdentity.buildUUID(inBundleAt: directory.path) == nil)
      let oversizedUUID = String(repeating: "a", count: 129)
      try JSONSerialization.data(withJSONObject: ["build_uuid": oversizedUUID]).write(to: file)
      #expect(BundleBuildIdentity.buildUUID(inBundleAt: directory.path) == nil)
    }
  }

  @Test func refusesSymbolicLinks() throws {
    try withBundle { directory in
      let destination = directory.appendingPathComponent("other.json")
      try Data(#"{"build_uuid":"not-the-bundle-file"}"#.utf8).write(to: destination)
      try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("BuildInfo.json"), withDestinationURL: destination)
      #expect(BundleBuildIdentity.buildUUID(inBundleAt: directory.path) == nil)
    }
  }

  @Test(.timeLimit(.minutes(1))) func refusesDirectoriesAndPipesWithoutWaitingForAWriter() throws {
    try withBundle { directory in
      let file = directory.appendingPathComponent("BuildInfo.json")
      try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
      #expect(BundleBuildIdentity.buildUUID(inBundleAt: directory.path) == nil)
      try FileManager.default.removeItem(at: file)
      #expect(mkfifo(file.path, mode_t(0o600)) == 0)
      #expect(BundleBuildIdentity.buildUUID(inBundleAt: directory.path) == nil)
    }
  }
}
