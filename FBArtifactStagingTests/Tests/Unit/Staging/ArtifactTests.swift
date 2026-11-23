/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBArtifactStaging
@testable import FBControlCore
import Foundation
import Testing

/// Identifies artifacts in fixture directories laid out as staging leaves them.
@Suite
struct ArtifactTests {

  private let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtifactTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  // MARK: - Fixtures

  private func directory(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A loadable flat bundle, with a real Mach-O as its executable because reading a bundle parses the header.
  @discardableResult
  private func bundle(_ name: String, in parent: URL, identifier: String = "com.example.sample") throws -> URL {
    let url = parent.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let executable = url.deletingPathExtension().lastPathComponent
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url.appendingPathComponent(executable))
    let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": executable, "CFBundleName": executable]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Info.plist"))
    return url
  }

  @discardableResult
  private func file(_ name: String, in parent: URL) throws -> URL {
    let url = parent.appendingPathComponent(name)
    try Data("contents".utf8).write(to: url)
    return url
  }

  // MARK: - Applications

  @Test
  func anApplicationInPlaceIsItself() throws {
    let app = try bundle("Sample.app", in: directory("in-place"))
    guard case .application(let found) = try ArtifactKind.application.identify(in: .inPlace(app)) else {
      Issue.record("Not identified as an application")
      return
    }
    #expect(found.identifier == "com.example.sample")
  }

  @Test
  func anApplicationIsFoundUnderAnExtractedPayload() throws {
    let extracted = try directory("extracted")
    try bundle("Sample.app", in: extracted.appendingPathComponent("Payload"))
    guard case .application(let found) = try ArtifactKind.application.identify(in: .extracted(extracted)) else {
      Issue.record("Not identified as an application")
      return
    }
    #expect(found.name == "Sample")
  }

  @Test
  func anExtractionWithoutAnApplicationIsNotInstallable() throws {
    let extracted = try directory("extracted")
    try file("README", in: extracted)
    #expect {
      try ArtifactKind.application.identify(in: .extracted(extracted))
    } throws: { error in
      guard case InstallError.noInstallableBundle = error else {
        return false
      }
      return true
    }
  }

  // MARK: - Tests

  @Test
  func anXctestInPlaceIsATestBundle() throws {
    let xctest = try bundle("Sample.xctest", in: directory("in-place"))
    guard case .testBundle(let found) = try ArtifactKind.xctest.identify(in: .inPlace(xctest)) else {
      Issue.record("Not identified as a test bundle")
      return
    }
    #expect(found == xctest)
  }

  @Test
  func anXctestrunInPlaceIsATestRun() throws {
    let xctestrun = try file("Sample.xctestrun", in: directory("in-place"))
    guard case .testRun(let found) = try ArtifactKind.xctest.identify(in: .inPlace(xctestrun)) else {
      Issue.record("Not identified as a test run")
      return
    }
    #expect(found == xctestrun)
  }

  @Test
  func anotherExtensionInPlaceIsNotATest() throws {
    let item = try file("Sample.zip", in: directory("in-place"))
    #expect(throws: ArtifactError.self) {
      try ArtifactKind.xctest.identify(in: .inPlace(item))
    }
  }

  @Test
  func anExtractedTestBundleIsPreferredToATestRun() throws {
    let extracted = try directory("extracted")
    let xctest = try bundle("Sample.xctest", in: extracted)
    try file("Sample.xctestrun", in: extracted)
    guard case .testBundle(let found) = try ArtifactKind.xctest.identify(in: .extracted(extracted)) else {
      Issue.record("Not identified as a test bundle")
      return
    }
    #expect(found.standardizedFileURL == xctest.standardizedFileURL)
  }

  @Test
  func anExtractedTestRunIsATestRun() throws {
    let extracted = try directory("extracted")
    let xctestrun = try file("Sample.xctestrun", in: extracted)
    guard case .testRun(let found) = try ArtifactKind.xctest.identify(in: .extracted(extracted)) else {
      Issue.record("Not identified as a test run")
      return
    }
    #expect(found.standardizedFileURL == xctestrun.standardizedFileURL)
  }

  @Test
  func severalExtractedTestBundlesAreAmbiguous() throws {
    let extracted = try directory("extracted")
    try bundle("A.xctest", in: extracted)
    try bundle("B.xctest", in: extracted)
    #expect {
      try ArtifactKind.xctest.identify(in: .extracted(extracted))
    } throws: { error in
      guard case ArtifactError.multipleXctestFiles(let files) = error else {
        return false
      }
      return files.map(\.lastPathComponent) == ["A.xctest", "B.xctest"]
    }
  }

  @Test
  func anExtractionWithoutTestsIsRejected() throws {
    let extracted = try directory("extracted")
    try file("README", in: extracted)
    #expect {
      try ArtifactKind.xctest.identify(in: .extracted(extracted))
    } throws: { error in
      guard case ArtifactError.noTestArtifactsProvided = error else {
        return false
      }
      return true
    }
  }

  // MARK: - Frameworks

  @Test
  func anExtractedFrameworkIsItsOnlyItem() throws {
    let extracted = try directory("extracted")
    try bundle("Sample.framework", in: extracted, identifier: "com.example.framework")
    guard case .framework(let found) = try ArtifactKind.framework.identify(in: .extracted(extracted)) else {
      Issue.record("Not identified as a framework")
      return
    }
    #expect(found.identifier == "com.example.framework")
  }

  @Test
  func anExtractionOfSeveralItemsIsNotAFramework() throws {
    let extracted = try directory("extracted")
    try bundle("A.framework", in: extracted)
    try bundle("B.framework", in: extracted)
    #expect(throws: (any Error).self) {
      try ArtifactKind.framework.identify(in: .extracted(extracted))
    }
  }

  // MARK: - Dylibs

  @Test
  func aDecompressedDylibIsTheFile() throws {
    let dylib = try file("libSample.dylib", in: directory("staged"))
    guard case .dylib(let found) = try ArtifactKind.dylib(name: "libSample.dylib").identify(in: .file(dylib)) else {
      Issue.record("Not identified as a dylib")
      return
    }
    #expect(found == dylib)
  }

  @Test
  func anExtractedDylibIsItsOnlyItem() throws {
    let extracted = try directory("extracted")
    let dylib = try file("libSample.dylib", in: extracted)
    guard case .dylib(let found) = try ArtifactKind.dylib(name: "libSample.dylib").identify(in: .extracted(extracted)) else {
      Issue.record("Not identified as a dylib")
      return
    }
    #expect(found.standardizedFileURL == dylib.standardizedFileURL)
  }

  // MARK: - dSYMs

  @Test
  func anExtractedDsymIsItsOnlyItem() throws {
    let extracted = try directory("extracted")
    let dsym = try directory("extracted/Sample.dSYM")
    guard case .dsym(let found) = try ArtifactKind.dsym.identify(in: .extracted(extracted)) else {
      Issue.record("Not identified as a dSYM")
      return
    }
    #expect(found.standardizedFileURL == dsym.standardizedFileURL)
  }

  @Test
  func severalExtractedDsymsAreTheirDirectory() throws {
    let extracted = try directory("extracted")
    _ = try directory("extracted/A.dSYM")
    _ = try directory("extracted/B.dSYM")
    guard case .dsym(let found) = try ArtifactKind.dsym.identify(in: .extracted(extracted)) else {
      Issue.record("Not identified as a dSYM")
      return
    }
    #expect(found == extracted)
  }
}
