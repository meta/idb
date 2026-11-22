/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBArtifactStaging
import FBControlCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import Testing

@Suite
struct InstallHeaderTests {

  private static let destination = request { $0.destination = .dsym }
  private static let nameHint = request { $0.nameHint = "A" }
  private static let makeDebuggable = request { $0.makeDebuggable = true }
  private static let overrideModificationTime = request { $0.overrideModificationTime = true }
  private static let skipSigningBundles = request { $0.skipSigningBundles = true }
  private static let link = request { $0.linkDsymToBundle = .with { $0.bundleID = "com.example.app" } }
  private static let connectTo = request {
    $0.connectTo = .with {
      $0.host = "192.0.2.1"
      $0.port = 8443
    }
  }
  private static let zstd = request { $0.payload = .with { $0.compression = .zstd } }
  private static let data = request { $0.payload = .with { $0.data = Data([1, 2, 3]) } }

  private static func request(_ configure: (inout Idb_InstallRequest) -> Void) -> Idb_InstallRequest {
    Idb_InstallRequest.with(configure)
  }

  private func read(_ frames: [Idb_InstallRequest]) async throws -> InstallHeader {
    var remaining = frames[...]
    return try await InstallHeader.read {
      guard let frame = remaining.popFirst() else {
        throw RPCError(code: .invalidArgument, message: "Stream ended")
      }
      return frame
    }
  }

  private func assertRejected(_ frames: [Idb_InstallRequest], _ code: RPCError.Code, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
      _ = try await read(frames)
      Issue.record("Expected \(code)", sourceLocation: sourceLocation)
    } catch let error as RPCError {
      #expect(error.code == code, sourceLocation: sourceLocation)
      #expect(error.message == message, sourceLocation: sourceLocation)
    } catch {
      Issue.record("Expected an RPCError, got \(error)", sourceLocation: sourceLocation)
    }
  }

  @Test
  func everyOptionInTheOrderTheCompanionReads() async throws {
    let header = try await read([Self.destination, Self.nameHint, Self.makeDebuggable, Self.overrideModificationTime, Self.skipSigningBundles, Self.link, Self.zstd, Self.data])
    #expect(header.destination == .dsym)
    #expect(header.nameHint == "A")
    #expect(header.makeDebuggable)
    #expect(header.overrideModificationTime)
    #expect(header.skipSigningBundles)
    #expect(header.linkDsymToBundle?.bundleID == "com.example.app")
    #expect(header.compression == .ZSTD)
    #expect(header.payload.data == Data([1, 2, 3]))
  }

  @Test
  func anUndeclaredCompressionIsGzip() async throws {
    let header = try await read([Self.destination, Self.data])
    #expect(header.nameHint == nil)
    #expect(!header.makeDebuggable)
    #expect(header.linkDsymToBundle == nil)
    #expect(header.compression == .GZIP)
  }

  @Test
  func aStreamThatDoesNotStartWithADestination() async {
    await assertRejected([Self.nameHint, Self.destination, Self.data], .failedPrecondition, "Expected destination as first request in stream")
  }

  @Test
  func compressionBeforeTheLink() async throws {
    let header = try await read([Self.destination, Self.zstd, Self.link, Self.data])
    #expect(header.linkDsymToBundle?.bundleID == "com.example.app")
    #expect(header.compression == .ZSTD)
    #expect(header.payload.data == Data([1, 2, 3]))
  }

  @Test
  func optionsOutOfTheCompanionsOrder() async throws {
    var header = try await read([Self.destination, Self.link, Self.nameHint, Self.data])
    #expect(header.linkDsymToBundle?.bundleID == "com.example.app")
    #expect(header.nameHint == "A")
    header = try await read([Self.destination, Self.skipSigningBundles, Self.makeDebuggable, Self.data])
    #expect(header.skipSigningBundles)
    #expect(header.makeDebuggable)
  }

  @Test
  func aRepeatedOption() async {
    await assertRejected([Self.destination, Self.nameHint, Self.nameHint, Self.data], .invalidArgument, "Repeated name_hint in install request stream")
  }

  @Test
  func whereToConnectBeforeTheCompression() async throws {
    let header = try await read([Self.destination, Self.link, Self.connectTo, Self.zstd, Self.data])
    #expect(header.connectTo?.host == "192.0.2.1")
    #expect(header.connectTo?.port == 8443)
    #expect(header.compression == .ZSTD)
  }

  @Test
  func aRepeatedConnectTo() async {
    await assertRejected([Self.destination, Self.connectTo, Self.connectTo, Self.data], .invalidArgument, "Repeated connect_to in install request stream")
  }

  @Test
  func aRepeatedCompression() async {
    await assertRejected([Self.destination, Self.zstd, Self.zstd, Self.data], .invalidArgument, "Repeated compression in install request stream")
  }

  @Test
  func aStreamWithoutAPayload() async {
    await assertRejected([Self.destination, Self.nameHint], .invalidArgument, "Stream ended")
  }
}
