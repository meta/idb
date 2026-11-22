/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBControlCore
import FBSimulatorAX
import FBSimulatorControl
import Foundation
import GRPCCore
import GRPCNIOTransportCore
import GRPCProtobuf
import IDBGRPCSwift
import IDBTelemetry
import SwiftProtobuf
import Testing

@Suite
struct IDBTransientTests {

  // MARK: - FileContainerTranslation Tests

  @Test
  func fileContainerMapsAllKnownKinds() {
    let mappings: [(Idb_FileContainer.Kind, FileContainerKind)] = [
      (.root, .root),
      (.media, .media),
      (.crashes, .crashes),
      (.provisioningProfiles, .provisioningProfiles),
      (.mdmProfiles, .mdmProfiles),
      (.springboardIcons, .springboardIcons),
      (.wallpaper, .wallpaper),
      (.diskImages, .diskImages),
      (.groupContainer, .group),
      (.applicationContainer, .application),
      (.auxillary, .auxillary),
      (.xctest, .xctest),
      (.dylib, .dylib),
      (.dsym, .dsym),
      (.framework, .framework),
      (.symbols, .symbols),
    ]
    for (protoKind, expectedKind) in mappings {
      let result = FileContainerTranslation.fileContainer(from: protoKind)
      #expect(result?.rawValue == expectedKind.rawValue, "Mapping failed for \(protoKind)")
    }
  }

  @Test
  func fileContainerReturnsNilForApplicationKind() {
    #expect((FileContainerTranslation.fileContainer(from: .application)) == nil)
  }

  @Test
  func fileContainerReturnsNilForNoneKind() {
    #expect((FileContainerTranslation.fileContainer(from: .none)) == nil)
  }

  @Test
  func rawFileContainerReturnsRawValueForKnownKind() {
    var container = Idb_FileContainer()
    container.kind = .root
    let result = FileContainerTranslation.rawFileContainer(from: container)
    #expect((result) == (FileContainerKind.root.rawValue))
  }

  @Test
  func rawFileContainerReturnsBundleIDForUnmappedKind() {
    var container = Idb_FileContainer()
    container.kind = .application
    container.bundleID = "com.example.app"
    let result = FileContainerTranslation.rawFileContainer(from: container)
    #expect((result) == ("com.example.app"))
  }

  // MARK: - PayloadExtractable Tests

  @Test
  func installRequestExtractsPayload() {
    let payload = Idb_Payload.with { $0.source = .data(Data([1, 2, 3])) }
    var request = Idb_InstallRequest()
    request.value = .payload(payload)
    #expect((request.extractPayload()) != nil)
  }

  @Test
  func installRequestReturnsNilWithoutPayload() {
    let request = Idb_InstallRequest()
    #expect((request.extractPayload()) == nil)
  }

  @Test
  func pushRequestExtractsPayload() {
    let payload = Idb_Payload.with { $0.source = .data(Data([4, 5])) }
    var request = Idb_PushRequest()
    request.value = .payload(payload)
    #expect((request.extractPayload()) != nil)
  }

  @Test
  func pushRequestReturnsNilWithoutPayload() {
    let request = Idb_PushRequest()
    #expect((request.extractPayload()) == nil)
  }

  @Test
  func addMediaRequestExtractsPayload() {
    var request = Idb_AddMediaRequest()
    request.payload = Idb_Payload.with { $0.source = .data(Data([7, 8])) }
    #expect((request.extractPayload()) != nil)
  }

  @Test
  func addMediaRequestReturnsNilWithoutPayload() {
    let request = Idb_AddMediaRequest()
    #expect((request.extractPayload()) == nil)
  }

  @Test
  func injectAudioRequestExtractsPayload() {
    var request = Idb_InjectAudioRequest()
    request.payload = Idb_Payload.with { $0.source = .data(Data([9, 10])) }
    #expect((request.extractPayload()) != nil)
  }

  @Test
  func injectAudioRequestReturnsNilWithoutPayload() {
    let request = Idb_InjectAudioRequest()
    #expect((request.extractPayload()) == nil)
  }

  @Test
  func payloadExtractsDataFrame() {
    let testData = Data([10, 20, 30])
    let payload = Idb_Payload.with { $0.source = .data(testData) }
    #expect((payload.extractDataFrame()) == (testData))
  }

  @Test
  func payloadReturnsNilDataFrameForFilePath() {
    let payload = Idb_Payload.with { $0.source = .filePath("/tmp/file") }
    #expect((payload.extractDataFrame()) == nil)
  }

  @Test
  func payloadExtractableChainExtractsData() {
    let testData = Data([1, 2, 3, 4])
    let payload = Idb_Payload.with { $0.source = .data(testData) }
    var request = Idb_InstallRequest()
    request.value = .payload(payload)
    #expect((request.extractDataFrame()) == (testData))
  }

  @Test
  func payloadExtractableChainReturnsNilWithoutPayload() {
    let request = Idb_InstallRequest()
    #expect((request.extractDataFrame()) == nil)
  }

  // MARK: - IDBPortsConfiguration Tests

  @Test
  func defaultDebugserverPort() {
    let (defaults, cleanup) = makeTestDefaults()
    defer { cleanup() }
    let config = IDBPortsConfiguration(arguments: defaults)
    #expect((config.debugserverPort) == (10881))
  }

  @Test
  func customDebugserverPort() {
    let (defaults, cleanup) = makeTestDefaults()
    defer { cleanup() }
    defaults.set("12345", forKey: "-debug-port")
    let config = IDBPortsConfiguration(arguments: defaults)
    #expect((config.debugserverPort) == (12345))
  }

  @Test
  func swiftServerTargetDefaultsToTcpPort() {
    let (defaults, cleanup) = makeTestDefaults()
    defer { cleanup() }
    let config = IDBPortsConfiguration(arguments: defaults)
    if case .tcpPort(let port) = config.swiftServerTarget {
      #expect((port) == (10882))
    } else {
      Issue.record("Expected TCP port target")
    }
  }

  @Test
  func swiftServerTargetUsesCustomGrpcPort() {
    let (defaults, cleanup) = makeTestDefaults()
    defer { cleanup() }
    defaults.set("9999", forKey: "-grpc-port")
    let config = IDBPortsConfiguration(arguments: defaults)
    if case .tcpPort(let port) = config.swiftServerTarget {
      #expect((port) == (9999))
    } else {
      Issue.record("Expected TCP port target")
    }
  }

  @Test
  func swiftServerTargetPrefersUnixDomainSocket() {
    let (defaults, cleanup) = makeTestDefaults()
    defer { cleanup() }
    defaults.set("/tmp/test.sock", forKey: "-grpc-domain-sock")
    defaults.set("9999", forKey: "-grpc-port")
    let config = IDBPortsConfiguration(arguments: defaults)
    if case .unixDomainSocket(let path) = config.swiftServerTarget {
      #expect((path) == ("/tmp/test.sock"))
    } else {
      Issue.record("Expected Unix domain socket target")
    }
  }

  @Test
  func tlsCertPathFromDefaults() {
    let (defaults, cleanup) = makeTestDefaults()
    defer { cleanup() }
    defaults.set("/path/to/cert.pem", forKey: "-tls-cert-path")
    let config = IDBPortsConfiguration(arguments: defaults)
    #expect((config.tlsCertPath) == ("/path/to/cert.pem"))
  }

  @Test
  func tlsCertPathDefaultsToNil() {
    let (defaults, cleanup) = makeTestDefaults()
    defer { cleanup() }
    let config = IDBPortsConfiguration(arguments: defaults)
    #expect((config.tlsCertPath) == nil)
  }

  // MARK: - GRPCConnectionTarget Tests

  @Test
  func tcpPortDescription() {
    let target = GRPCConnectionTarget.tcpPort(port: 8080)
    #expect((target.description) == ("tcp port 8080"))
  }

  @Test
  func unixDomainSocketDescription() {
    let target = GRPCConnectionTarget.unixDomainSocket("/tmp/test.sock")
    #expect((target.description) == ("unix socket /tmp/test.sock"))
  }

  @Test
  func tcpPortSupportsTLS() {
    #expect((GRPCConnectionTarget.tcpPort(port: 443).supportsTLSCert))
  }

  @Test
  func unixDomainSocketDoesNotSupportTLS() {
    #expect(!(GRPCConnectionTarget.unixDomainSocket("/tmp/s").supportsTLSCert))
  }

  @Test
  func outputDescriptionThrowsForMismatchedAddress() {
    let target = GRPCConnectionTarget.tcpPort(port: 8080)
    do {
      _ = try target.outputDescription(for: .unixDomainSocket(path: "/tmp/idb.sock"))
      Issue.record("expected an ExtractionError")
    } catch {
      #expect(error is GRPCConnectionTarget.ExtractionError)
    }
  }

  // MARK: - CrashLogQueryTranslation Tests

  @Test
  func emptyQueryMatchesEveryCrashLog() {
    let predicate = CrashLogQueryTranslation.predicate(from: Idb_CrashLogQuery())
    #expect(predicate.description == "all")
  }

  @Test
  func queryWithSinceSelectsNewerCrashLogs() {
    var query = Idb_CrashLogQuery()
    query.since = 1000
    let predicate = CrashLogQueryTranslation.predicate(from: query)
    #expect(predicate.description == "date > \(Date(timeIntervalSince1970: 1000))")
  }

  @Test
  func queryWithBeforeSelectsOlderCrashLogs() {
    var query = Idb_CrashLogQuery()
    query.before = 2000
    let predicate = CrashLogQueryTranslation.predicate(from: query)
    #expect(predicate.description == "!(date > \(Date(timeIntervalSince1970: 2000)))")
  }

  @Test
  func queryWithNameSelectsByName() {
    var query = Idb_CrashLogQuery()
    query.name = "MyCrash"
    let predicate = CrashLogQueryTranslation.predicate(from: query)
    #expect(predicate.description == "name == MyCrash")
  }

  @Test
  func queryWithBundleIDSelectsByIdentifier() {
    var query = Idb_CrashLogQuery()
    query.bundleID = "com.example.app"
    let predicate = CrashLogQueryTranslation.predicate(from: query)
    #expect(predicate.description == "identifier == com.example.app")
  }

  @Test
  func queryWithMultipleFiltersRequiresAllOfThem() {
    var query = Idb_CrashLogQuery()
    query.since = 1000
    query.before = 2000
    query.name = "Crash"
    let predicate = CrashLogQueryTranslation.predicate(from: query)
    #expect(predicate.description.components(separatedBy: " && ").count == 3)
  }

  // MARK: - ErrorMapping Tests

  @Test
  func errorMappingKeepsRPCErrors() {
    let thrown = RPCError(code: .invalidArgument, message: "bad request")
    let mapped = ErrorMapping.rpcError(from: thrown)
    #expect(mapped.code == .invalidArgument)
    #expect(mapped.message == "bad request")
  }

  @Test
  func errorMappingUnwrapsLegacyNSErrorDescriptions() {
    let thrown = NSError(
      domain: "com.example", code: 7,
      userInfo: [NSLocalizedDescriptionKey: "Application com.example.app isn't installed", "bundle": "com.example.app"])
    let mapped = ErrorMapping.rpcError(from: thrown)
    #expect(mapped.code == .internalError)
    #expect(mapped.message.hasPrefix("Application com.example.app isn't installed"))
    #expect(mapped.message.contains("bundle"))
  }

  @Test
  func errorMappingUnwrapsALegacyNSErrorBeneathAnUnconfirmedWrite() {
    let underlying = NSError(
      domain: "com.example", code: 7,
      userInfo: [NSLocalizedDescriptionKey: "The socket closed", "socket": "/tmp/axbridge.sock"])
    let thrown = UIAutomationError.writeUnconfirmed(backend: .accessibility, idempotent: false, underlying: underlying)
    let mapped = ErrorMapping.rpcError(from: thrown)
    #expect(mapped.message.hasPrefix("The socket closed"))
    #expect(mapped.message.contains("/tmp/axbridge.sock"))
  }

  @Test
  func errorMappingCarriesTheRetryVerdictOfAUIAutomationFailure() throws {
    let thrown = UIAutomationError.writeUnconfirmed(
      backend: .accessibility, idempotent: false, underlying: AXBridgeError.applicationNotResponding(pid: 4321))
    let mapped = ErrorMapping.rpcError(from: thrown)
    #expect(mapped.code == .internalError)
    #expect(mapped.message == thrown.localizedDescription)
    let status = try #require(try mapped.unpackGoogleRPCStatus())
    #expect(status.code == .internalError)
    #expect(status.message == thrown.localizedDescription)
    #expect(
      status.details == [
        .errorInfo(
          reason: "UI_AUTOMATION_FAILURE", domain: "idb",
          metadata: ["retry": "unsafe", "retry_reason": "outcome_unknown"])
      ])
  }

  @Test
  func errorMappingCarriesTheRetryVerdictOfABridgeFailure() throws {
    let mapped = ErrorMapping.rpcError(from: AXBridgeError.applicationNotResponding(pid: 4321))
    #expect(mapped.code == .internalError)
    let status = try #require(try mapped.unpackGoogleRPCStatus())
    #expect(
      status.details == [
        .errorInfo(
          reason: "UI_AUTOMATION_FAILURE", domain: "idb",
          metadata: ["retry": "safe", "retry_reason": "nothing_written"])
      ])
  }

  @Test
  func errorMappingLeavesOtherFailuresWithoutARetryVerdict() throws {
    let mapped = ErrorMapping.rpcError(from: NSError(domain: "com.example", code: 7))
    #expect(try mapped.unpackGoogleRPCStatus() == nil)
  }

  // MARK: - StreamReadError Tests

  @Test
  func streamReadErrorMakesFailedPreconditionStatus() {
    let error = StreamReadError<String>.nextElementNotProduced
    let status = error.rpcError
    #expect((status.code) == (.failedPrecondition))
    #expect(status.message.contains("String"))
  }

  @Test
  func defaultEventReporterIsEmptyReporter() {
    #expect((IDBConfiguration.eventReporter is EmptyEventReporter))
  }

  // MARK: - Helpers

  private func makeTestDefaults() -> (UserDefaults, () -> Void) {
    let suiteName = "IDBTransientTests_\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let cleanup = { defaults.removePersistentDomain(forName: suiteName) }
    return (defaults, cleanup)
  }
}
