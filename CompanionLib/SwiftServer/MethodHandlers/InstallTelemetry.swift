/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBArtifactStaging
import FBControlCore
import Foundation
import Synchronization

/// How the client handed over what it wants installed.
enum InstallPayloadKind: String {
  /// Bytes streamed over the RPC.
  case data
  /// A URL for the companion to fetch.
  case url
  /// A path already on the companion's host.
  case filePath = "file_path"
}

extension ArchiveFormat {

  /// The `stream_format` column's name for an archive told apart by its first bytes.
  var streamFormatName: String {
    switch self {
    case .zip:
      "zip"
    case .zstdZip:
      "zip_zstd"
    case .gzip:
      "tar_gzip"
    case .zstd:
      "tar_zstd"
    case .other:
      "tar"
    case .undetermined:
      "undetermined"
    }
  }
}

/// Where an install was when it failed: in one of its stages, or receiving a streamed payload before
/// any stage began.
enum InstallFailureStage: Equatable {
  case stage(InstallStage)
  case receive
  /// Between staging and installing, finding the artifact in what was staged.
  case identify

  var name: String {
    switch self {
    case .stage(let stage):
      stage.rawValue
    case .receive:
      "receive"
    case .identify:
      "identify"
    }
  }
}

/// Accumulates what one install did into the columns its event reports.
///
/// `receive_ms` and `size` describe getting the payload onto the companion's host: streamed over the
/// RPC for `data`, downloaded for `url`. Stage durations come from each stage's completion, so a stage
/// that never finished has none.
final class InstallTelemetry: Sendable {

  private struct Failure {
    var stage: InstallFailureStage?
    var kind: String
    var cancelled: Bool
  }

  private struct State {
    var route: ExtractionRoute?
    var timeToFirstByte: TimeInterval?
    var receivedBytes: Int64?
    var receiveMs: Int64?
    var receiving = false
    var stagesInFlight: Set<InstallStage> = []
    var stageMs: [InstallStage: Int64] = [:]
    var failure: Failure?
    var downloadFailure: DownloadFailureDetail?
  }

  private let payloadKind: InstallPayloadKind
  private let state = Mutex(State())

  init(payloadKind: InstallPayloadKind) {
    self.payloadKind = payloadKind
  }

  func observe(_ event: InstallEvent) {
    switch event {
    case .progress(let progress):
      observe(progress)
    case .route(let route):
      state.withLock { $0.route = route }
    case .download(let report):
      state.withLock { $0.timeToFirstByte = report.timeToFirstByte }
    case .cache:
      break
    }
  }

  /// Measures `body` receiving the streamed payload, reporting what it received whether or not it
  /// completes. A receive that throws is left in progress, so the failure is attributed to it.
  func receive<T>(_ body: (inout InstallReceive) async throws -> T) async rethrows -> T {
    state.withLock { $0.receiving = true }
    var receive = InstallReceive(telemetry: self)
    do {
      let result = try await body(&receive)
      receive.finish(completed: true)
      return result
    } catch {
      receive.finish(completed: false)
      throw error
    }
  }

  fileprivate func received(bytes: Int64, elapsedMs: Int64, completed: Bool) {
    state.withLock { state in
      state.receiving = !completed
      state.receivedBytes = bytes
      state.receiveMs = elapsedMs
    }
  }

  func observe(_ event: InstallProgressEvent) {
    state.withLock { state in
      switch event {
      case .downloadStarted, .extractStarted, .installStarted:
        state.stagesInFlight.insert(event.stage)
      case .downloadProgress:
        break
      case .downloadCompleted(let timing, let totalBytes):
        state.stagesInFlight.remove(.download)
        state.receivedBytes = totalBytes
        state.receiveMs = timing.elapsedMs
      case .extractCompleted, .installCompleted:
        state.stagesInFlight.remove(event.stage)
        state.stageMs[event.stage] = event.elapsedMs
      }
    }
  }

  /// Download and extraction overlap, and a failed download also fails the extraction reading it, so
  /// the failure belongs to the earliest stage still running. A streamed payload that fails before any
  /// stage starts failed while being received.
  ///
  /// A failure once the RPC or the call's task is cancelled was brought on by the client going away,
  /// whatever error it surfaced as. gRPC marks the RPC cancelled without cancelling the task, so
  /// callers pass what the RPC's cancellation handle says.
  func failed(_ error: Error, rpcCancelled: Bool = false) {
    let cancelled = rpcCancelled || Task.isCancelled
    let kind = Self.kind(of: error)
    state.withLock { state in
      let stage =
        [InstallStage.download, .extract, .install].first(where: state.stagesInFlight.contains).map(InstallFailureStage.stage)
        ?? (state.receiving ? .receive : nil)
        ?? (Self.isIdentification(error) ? .identify : nil)
      state.failure = Failure(stage: stage, kind: kind, cancelled: cancelled)
      if case .transferFailed(_, let underlying, let report) = error as? InstallError {
        // A download that fails never completes, so what it received is only known from here.
        state.receivedBytes = report.receivedBytes
        state.timeToFirstByte = report.timeToFirstByte
        state.downloadFailure = DownloadFailureDetail(underlying: underlying, report: report)
      }
    }
  }

  func record(into call: CallTelemetry) {
    let state = self.state.withLock { $0 }
    call.setNormal(payloadKind.rawValue, forKey: "payload_kind")
    if let streamFormat = state.route?.format.streamFormatName {
      call.setNormal(streamFormat, forKey: "stream_format")
    }
    if let route = state.route {
      call.setNormal(route.extractor.rawValue, forKey: "extractor")
      switch route.extractor {
      case .zipStream, .zipSpool:
        call.setInt(route.extractor == .zipSpool ? 1 : 0, forKey: "zip_spool_fallback")
      case .inProcessTar, .bsdTar:
        break
      }
    }
    if let receivedBytes = state.receivedBytes {
      call.setSize(receivedBytes)
    }
    if let timeToFirstByte = state.timeToFirstByte {
      call.setInt(Int((timeToFirstByte * 1000).rounded()), forKey: "ttfb_ms")
    }
    if let receiveMs = state.receiveMs {
      call.setInt(Int(receiveMs), forKey: "receive_ms")
    }
    if let extractMs = state.stageMs[.extract] {
      call.setInt(Int(extractMs), forKey: "extract_ms")
    }
    if let installMs = state.stageMs[.install] {
      call.setInt(Int(installMs), forKey: "install_ms")
    }
    if let failure = state.failure {
      if let stage = failure.stage {
        call.setNormal(stage.name, forKey: "failure_stage")
      }
      call.setNormal(failure.kind, forKey: "failure_kind")
      if failure.cancelled {
        call.setNormal("client", forKey: "cancel_source")
      }
    }
    state.downloadFailure?.record(into: call)
  }

  /// An `InstallError` is named by its case, so failures group by cause. Anything else is named by its
  /// type, which at least separates a target refusing the install from a transport failure.
  static func kind(of error: Error) -> String {
    guard let error = error as? InstallError else {
      return String(describing: type(of: error))
    }
    switch error {
    case .httpStatus:
      return "http_status"
    case .transferFailed:
      return "transfer_failed"
    case .notAnHTTPResponse:
      return "not_an_http_response"
    case .extractionFailed:
      return "extraction_failed"
    case .noInstallableBundle:
      return "no_installable_bundle"
    case .unidentifiable:
      return "unidentifiable"
    }
  }

  /// A failure to find the artifact in what was staged, which happens with no stage in flight.
  private static func isIdentification(_ error: Error) -> Bool {
    switch error as? InstallError {
    case .noInstallableBundle, .unidentifiable:
      return true
    case .httpStatus, .transferFailed, .notAnHTTPResponse, .extractionFailed, nil:
      return false
    }
  }
}

/// Counts a streamed payload's bytes and time for `InstallTelemetry.receive`.
struct InstallReceive {
  private let telemetry: InstallTelemetry
  private let start = Date()
  private var bytes: Int64 = 0

  fileprivate init(telemetry: InstallTelemetry) {
    self.telemetry = telemetry
  }

  mutating func count(_ data: Data) {
    bytes += Int64(data.count)
  }

  fileprivate func finish(completed: Bool) {
    telemetry.received(bytes: bytes, elapsedMs: Int64(Date().timeIntervalSince(start) * 1000), completed: completed)
  }
}

/// Why a download failed, in columns that tell a host's trust store apart from the certificate a server
/// presented or the path the request took. Nothing from the URL is recorded, as its query carries signatures.
struct DownloadFailureDetail: Equatable {

  let errorCode: String
  let underlyingError: String?
  let streamErrorCode: Int?
  let report: DownloadReport

  init(underlying: Error, report: DownloadReport) {
    let error = underlying as NSError
    let cause = error.userInfo[NSUnderlyingErrorKey] as? NSError
    errorCode = Self.name(error)
    underlyingError = cause.map(Self.name)
    streamErrorCode = (error.userInfo["_kCFStreamErrorCodeKey"] ?? cause?.userInfo["_kCFStreamErrorCodeKey"]) as? Int
    self.report = report
  }

  func record(into call: CallTelemetry) {
    call.setNormal(errorCode, forKey: "ns_error_code")
    if let underlyingError {
      call.setNormal(underlyingError, forKey: "ns_underlying_error")
    }
    if let streamErrorCode {
      call.setInt(streamErrorCode, forKey: "cf_stream_error_code")
    }
    if let remoteAddress = report.remoteAddress {
      call.setNormal(remoteAddress, forKey: "remote_address")
    }
    if let proxied = report.proxied {
      call.setInt(proxied ? 1 : 0, forKey: "proxy_used")
    }
    guard let trust = report.trust else {
      return
    }
    if let error = trust.error {
      call.setNormal(error, forKey: "tls_trust_error")
    }
    call.setNormal(Self.chainDescription(trust.chain), forKey: "tls_chain")
  }

  private static func name(_ error: NSError) -> String {
    "\(error.domain):\(error.code)"
  }

  /// A JSON array, leaf first, so the chain can be queried without splitting on names that contain separators.
  static func chainDescription(_ chain: [DownloadReport.Certificate]) -> String {
    let formatter = ISO8601DateFormatter()
    let certificates = chain.map { certificate in
      var fields: [String: String] = [:]
      fields["subject"] = certificate.subject
      fields["issuer"] = certificate.issuer
      fields["not_after"] = certificate.notAfter.map(formatter.string(from:))
      return fields
    }
    guard let data = try? JSONSerialization.data(withJSONObject: certificates, options: [.sortedKeys, .withoutEscapingSlashes]) else {
      return "[]"
    }
    return String(decoding: data, as: UTF8.self)
  }
}
