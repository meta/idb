/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBArtifactStaging
import FBControlCore
import FBXCTestCore
import Foundation
import Testing
import os

@Suite
struct IDBCommandExecutorInstallTests {

  @Test
  func aStreamedDylibIsStoredUnderItsName() async throws {
    let harness = try MacInstallHarness()
    let dylib = try harness.makeFile(named: "libSample.dylib")

    let artifact = try await harness.executor.install(.dylib(name: "libSample.dylib"), from: .stream(try await harness.gzipped(dylib)))

    #expect(artifact.name == "libSample.dylib")
    #expect(FileManager.default.contentsEqual(atPath: artifact.path.path, andPath: dylib.path))
  }

  @Test
  func aStreamedDylibLargerThanAPipeBufferIsStoredWhole() async throws {
    let harness = try MacInstallHarness()
    let dylib = try harness.makeFile(named: "libSample.dylib", padding: 8 << 20)

    let artifact = try await harness.executor.install(.dylib(name: "libSample.dylib"), from: .stream(try await harness.gzipped(dylib)))

    #expect(FileManager.default.contentsEqual(atPath: artifact.path.path, andPath: dylib.path))
  }

  @Test
  func aStreamedDylibThatIsNotAGzipFailsAsCorrupt() async throws {
    let harness = try MacInstallHarness()
    let input = ChunkSource(Data("not a gzip at all".utf8))

    let error = await #expect(throws: (any Error).self) {
      try await harness.executor.install(.dylib(name: "libSample.dylib"), from: .stream(input))
    }

    let description = error?.localizedDescription
    // Neither gzipped nor a Mach-O, so it is taken for an archive, which it isn't either.
    #expect(description?.hasPrefix("Could not extract the archive: ") == true, "\(String(describing: description))")
  }

  @Test
  func aStreamedFrameworkIsStoredUnderItsIdentifier() async throws {
    let harness = try MacInstallHarness()
    let framework = try harness.makeBundle(named: "Sample", extension: "framework", identifier: "com.example.sample")

    let artifact = try await harness.executor.install(.framework, from: .stream(try await harness.gzippedTar(of: framework)))

    #expect(artifact.name == "com.example.sample")
    #expect(artifact.path.lastPathComponent == "Sample.framework")
  }

  @Test
  func aStreamedFrameworkOutlivesItsStaging() async throws {
    let harness = try MacInstallHarness()
    let framework = try harness.makeBundle(named: "Sample", extension: "framework", identifier: "com.example.sample")

    let artifact = try await harness.executor.install(.framework, from: .stream(try await harness.gzippedTar(of: framework)))

    let type = try FileManager.default.attributesOfItem(atPath: artifact.path.path)[.type] as? FileAttributeType
    #expect(type == .typeDirectory)
    #expect(FileManager.default.fileExists(atPath: artifact.path.appendingPathComponent("Info.plist").path))
  }

  @Test
  func aFrameworkAtALocalPath() async throws {
    let harness = try MacInstallHarness()
    let framework = try harness.makeBundle(named: "Sample", extension: "framework", identifier: "com.example.sample")

    let artifact = try await harness.executor.install(.framework, from: .localPath(framework.path))

    #expect(artifact.name == "com.example.sample")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: artifact.path.path) == framework.path)
  }

  @Test
  func aStreamedAppIsInstalledUnderItsIdentifier() async throws {
    let harness = try MacInstallHarness()
    let app = try harness.makeBundle(named: "Sample", extension: "app", identifier: "com.example.sample")

    let artifact = try await harness.executor.install(.application(makeDebuggable: false), from: .stream(try await harness.gzippedTar(of: app)))

    #expect(artifact.name == "com.example.sample")
    #expect(harness.executor.storageManager.application.persistedBundleIDs == ["com.example.sample"])
  }

  @Test
  func aStreamedAppIsRegisteredWhereItWasPersisted() async throws {
    let harness = try MacInstallHarness()
    let app = try harness.makeBundle(named: "Sample", extension: "app", identifier: "com.example.sample")

    let artifact = try await harness.executor.install(.application(makeDebuggable: false), from: .stream(try await harness.gzippedTar(of: app)))

    #expect(FileManager.default.fileExists(atPath: artifact.path.path))
    #expect(try await harness.target.application.installed(bundleID: "com.example.sample").bundle.path == artifact.path.path)
  }

  @Test
  func aStreamedXctestIsStoredUnderItsIdentifier() async throws {
    let harness = try MacInstallHarness()
    let xctest = try harness.makeBundle(named: "SampleTests", extension: "xctest", identifier: "com.example.sampletests")

    let artifact = try await harness.executor.install(.xctest(skipSigningBundles: true), from: .stream(try await harness.gzippedTar(of: xctest)))

    #expect(artifact.name == "com.example.sampletests")
    #expect(try harness.executor.storageManager.xctest.testDescriptor(withID: "com.example.sampletests").url.lastPathComponent == "SampleTests.xctest")
  }

  @Test
  func anUncompressedTarStreamIsExtractedDespiteTheDeclaredGzip() async throws {
    let harness = try MacInstallHarness()
    let framework = try harness.makeBundle(named: "Sample", extension: "framework", identifier: "com.example.sample")

    let artifact = try await harness.executor.install(.framework, from: .stream(try harness.tar(of: framework)))

    #expect(artifact.name == "com.example.sample")
  }

  @Test
  func aZstdTarStreamedAppIsInstalled() async throws {
    let harness = try MacInstallHarness()
    let app = try harness.makeBundle(named: "Sample", extension: "app", identifier: "com.example.sample")
    let archive = MacInstallHarness.zstd(try harness.tarData(of: app))

    let artifact = try await harness.executor.install(.application(makeDebuggable: false), from: .stream(ChunkSource(archive)))

    #expect(artifact.name == "com.example.sample")
  }

  @Test
  func aZstdTarStreamedDsymIsStored() async throws {
    let harness = try MacInstallHarness()
    let dsym = try harness.makeBundle(named: "Sample", extension: "dSYM", identifier: "com.example.sample")
    let archive = MacInstallHarness.zstd(try harness.tarData(of: dsym))

    let artifact = try await harness.executor.install(.dsym(linkTo: nil), from: .stream(ChunkSource(archive)))

    #expect(artifact.name == "Sample.dSYM")
    #expect(FileManager.default.fileExists(atPath: artifact.path.appendingPathComponent("Info.plist").path))
  }

  @Test
  func aStreamedDsymIsStoredAsItsOnlyItem() async throws {
    let harness = try MacInstallHarness()
    let dsym = try harness.makeBundle(named: "Sample", extension: "dSYM", identifier: "com.example.sample")

    let artifact = try await harness.executor.install(.dsym(linkTo: nil), from: .stream(try await harness.gzippedTar(of: dsym)))

    #expect(artifact.name == "Sample.dSYM")
    #expect(artifact.path.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == harness.executor.storageManager.dsym.basePath.standardizedFileURL.path)
    #expect(FileManager.default.fileExists(atPath: artifact.path.appendingPathComponent("Info.plist").path))
  }

  @Test
  func aStreamedDsymOfSeveralItemsIsStoredAsTheirDirectory() async throws {
    let harness = try MacInstallHarness()
    let dsym = try harness.makeBundle(named: "Sample", extension: "dSYM", identifier: "com.example.sample")
    try FileManager.default.copyItem(at: dsym, to: dsym.deletingLastPathComponent().appendingPathComponent("Other.dSYM"))

    let artifact = try await harness.executor.install(.dsym(linkTo: nil), from: .stream(try await harness.gzippedTar(of: dsym)))

    let children = try FileManager.default.contentsOfDirectory(atPath: artifact.path.path).sorted()
    #expect(children == ["Other.dSYM", "Sample.dSYM"])
  }

  @Test
  func aStreamedDsymIsLinkedBesideTheAppItNames() async throws {
    let harness = try MacInstallHarness()
    let app = try harness.makeBundle(named: "Sample", extension: "app", identifier: "com.example.sample")
    let installed = try await harness.executor.install(.application(makeDebuggable: false), from: .stream(try await harness.gzippedTar(of: app)))
    let dsym = try harness.makeBundle(named: "Sample", extension: "dSYM", identifier: "com.example.sample")

    let artifact = try await harness.executor.install(.dsym(linkTo: DsymInstallLinkToBundle(bundleID: "com.example.sample", bundleType: .app)), from: .stream(try await harness.gzippedTar(of: dsym)))

    let link = installed.path.deletingLastPathComponent().appendingPathComponent("Sample.dSYM")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == artifact.path.path)
  }

  // MARK: - Progress

  private final class ProgressEvents: InstallEventObserving {
    private let events = OSAllocatedUnfairLock<[InstallProgressEvent]>(initialState: [])

    var all: [InstallProgressEvent] { events.withLock { $0 } }

    var stages: [String] { all.map { "\($0.stage.rawValue).\($0.phase.rawValue)" } }

    func observe(_ event: InstallEvent) {
      guard case .progress(let progress) = event else {
        return
      }
      events.withLock { $0.append(progress) }
    }
  }

  @Test
  func aStreamedFrameworkReportsItsExtractionThenItsInstall() async throws {
    let harness = try MacInstallHarness()
    let framework = try harness.makeBundle(named: "Sample", extension: "framework", identifier: "com.example.sample")
    let progress = ProgressEvents()

    let artifact = try await harness.executor.install(.framework, from: .stream(try await harness.gzippedTar(of: framework)), observer: progress)

    #expect(progress.stages == ["extract.started", "extract.completed", "install.started", "install.completed"])
    guard case .installCompleted(_, let artifactPath, let name)? = progress.all.last else {
      Issue.record("Expected the install to complete last, got \(progress.all)")
      return
    }
    #expect((artifactPath as NSString).lastPathComponent == "Sample.framework")
    #expect(name == artifact.name)
  }

  @Test
  func aFrameworkAtALocalPathReportsOnlyItsInstall() async throws {
    let harness = try MacInstallHarness()
    let framework = try harness.makeBundle(named: "Sample", extension: "framework", identifier: "com.example.sample")
    let progress = ProgressEvents()

    _ = try await harness.executor.install(.framework, from: .localPath(framework.path), observer: progress)

    #expect(progress.stages == ["install.started", "install.completed"])
  }

  @Test
  func aStreamedDylibReportsItsDecompressionAsExtraction() async throws {
    let harness = try MacInstallHarness()
    let dylib = try harness.makeFile(named: "libSample.dylib")
    let progress = ProgressEvents()

    _ = try await harness.executor.install(.dylib(name: "libSample.dylib"), from: .stream(try await harness.gzipped(dylib)), observer: progress)

    #expect(progress.stages == ["extract.started", "extract.completed", "install.started", "install.completed"])
  }

  @Test
  func aTarPushedToDylibStorageLandsAtTheDestination() async throws {
    let harness = try MacInstallHarness()
    let dylib = try harness.makeFile(named: "libSample.dylib")

    try await harness.executor.pushFileFromTar(try await harness.gzippedTarData(of: dylib), toPath: "nested", containerType: "dylib")

    let pushed = harness.executor.storageManager.dylib.basePath.appendingPathComponent("nested/libSample.dylib")
    #expect(FileManager.default.contentsEqual(atPath: pushed.path, andPath: dylib.path))
  }
}
