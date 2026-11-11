/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import Network
import Security
import os

/// Downloads a URL over a connection opened to a `ConnectionOverride` instead of the address its host resolves to,
/// writing the body to a spool as it arrives. TLS verifies the server against the URL's host and the request asks for
/// that host, so only where the connection goes differs from `DataDownloadInput`.
///
/// `URLSession` only connects to the address a host resolves to, so this speaks HTTP/1.1 itself over a Network
/// framework connection. It does not follow redirects: a redirect fails as its status, since following one would leave
/// the override behind.
final class NetworkDownloadInput: Sendable {

  /// The downloaded bytes, written as they arrive and ended when the transfer ends.
  let spool: DownloadSpool

  private struct State: Sendable {
    var report = DownloadReport()
    var reader = HTTPResponseReader()
    var failure: (any Error)?
    var failedBeforeCancel = false
    var cancelRequested = false
    var lastActivity = Date()
    /// The server's certificate chain, when TLS did not trust it.
    var untrusted: DownloadReport.Trust?
  }

  private let url: URL
  private let connection: Result<(NWConnection, request: Data), any Error>
  // Every callback runs here, one at a time, so the transfer's events reach `onEvent` in order.
  private let queue: DispatchQueue
  private let state: OSAllocatedUnfairLock<State>
  private let finished = AsyncEvent<Void>()
  // The download starts as soon as it is made.
  private let requestStart = Date()
  private let idleTimeout: TimeInterval
  private let onEvent: (@Sendable (DataDownloadEvent) -> Void)?
  private let logger: ControlCoreLogger

  /// Starts downloading `url` over a connection to `override`. `idleTimeout` bounds how long the transfer may go
  /// without connecting or receiving anything, as `URLSessionConfiguration.timeoutIntervalForRequest` does.
  ///
  /// `onEvent` reports the response and how many bytes have arrived, while the bytes themselves go only to `spool`.
  /// The spool is a file in `spoolDirectory`, unlinked once open.
  init(
    url: URL,
    connectingTo override: ConnectionOverride,
    idleTimeout: TimeInterval = 60,
    logger: ControlCoreLogger,
    onEvent: (@Sendable (DataDownloadEvent) -> Void)? = nil,
    spoolDirectory: URL = FileManager.default.temporaryDirectory
  ) {
    let queue = DispatchQueue(label: "FBArtifactStaging.NetworkDownloadInput")
    let state = OSAllocatedUnfairLock(initialState: State())
    spool = DownloadSpool(directory: spoolDirectory)
    self.url = url
    self.queue = queue
    self.state = state
    self.idleTimeout = idleTimeout
    self.logger = logger
    self.onEvent = onEvent
    connection = Result { try Self.makeConnection(for: url, to: override, queue: queue, state: state) }
    start()
  }

  /// Waits for the transfer to finish, throwing if the server rejected the request or the connection failed. `spool`
  /// alone cannot distinguish a failed download from a short one.
  @discardableResult
  func completed() async throws -> DownloadReport {
    try await finished.wait()
    let (failure, report) = state.withLock { ($0.failure, $0.report) }
    if let failure {
      throw failure
    }
    return report
  }

  /// Stops the transfer, which then completes failed and ends `spool`. For a reader that has no use for the rest.
  func cancel() {
    state.withLock { $0.cancelRequested = true }
    if case .success(let (connection, _)) = connection {
      connection.cancel()
    }
  }

  /// Whether the download failed for a reason of its own, rather than because `cancel` stopped it. Read after
  /// `completed()` throws.
  var failedOnItsOwn: Bool {
    state.withLock { $0.failedBeforeCancel }
  }

  // MARK: - Transfer

  private func start() {
    if let error = spool.creationFailure {
      // Nothing that arrived could be kept, so nothing is fetched.
      fail(InstallError.transferFailed(url: url, underlying: error))
      return
    }
    switch connection {
    case .failure(let error):
      fail(InstallError.transferFailed(url: url, underlying: error))
      spool.end()
    case .success(let (connection, request)):
      connection.stateUpdateHandler = { [weak self] connectionState in
        self?.connectionChanged(connectionState, connection: connection, request: request)
      }
      connection.start(queue: queue)
      scheduleIdleCheck(after: idleTimeout)
    }
  }

  private func connectionChanged(_ connectionState: NWConnection.State, connection: NWConnection, request: Data) {
    switch connectionState {
    case .ready:
      let address = Self.address(of: connection.currentPath?.remoteEndpoint)
      state.withLock {
        $0.report.remoteAddress = address
        $0.report.proxied = false
        $0.lastActivity = Date()
      }
      connection.send(
        content: request,
        completion: .contentProcessed { [weak self] error in
          if let error {
            self?.transferFailed(error)
          }
        })
      receive(on: connection)
    case .waiting(let error), .failed(let error):
      // A connection that is waiting has failed to connect, and would otherwise retry until the path changes.
      transferFailed(error)
    case .cancelled:
      transferFailed(URLError(.cancelled))
    case .setup, .preparing:
      break
    @unknown default:
      break
    }
  }

  private func receive(on connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
      self?.received(data, isComplete: isComplete, error: error, on: connection)
    }
  }

  private func received(_ data: Data?, isComplete: Bool, error: NWError?, on connection: NWConnection) {
    guard !finished.hasHappened else {
      return
    }
    let endedCleanly = Self.endedCleanly(isComplete: isComplete, error: error)
    let read: (events: [HTTPResponseReader.Event], cutShort: (any Error)?)
    do {
      read = try state.withLock { state in
        state.lastActivity = Date()
        return try Self.read(data, endingTheStream: endedCleanly, with: &state.reader)
      }
    } catch {
      transferFailed(error)
      return
    }
    for event in read.events {
      guard handle(event) else {
        return
      }
    }
    // A whole response completes the download, even when the receive that delivered its last bytes also reports the
    // connection ending.
    if state.withLock({ $0.reader.isComplete }) {
      complete()
    } else if let cutShort = read.cutShort {
      transferFailed(cutShort)
    } else if let error, !endedCleanly {
      transferFailed(error)
    } else {
      receive(on: connection)
    }
  }

  /// The events of the bytes one receive delivered, then, when the same receive ended the stream, the end of the
  /// response or, for a response cut short, why it is incomplete. The bytes are read before the end, so a response
  /// cut short is still reported with every byte that arrived, including those that came with the close.
  static func read(
    _ data: Data?, endingTheStream ended: Bool, with reader: inout HTTPResponseReader
  ) throws -> (events: [HTTPResponseReader.Event], cutShort: (any Error)?) {
    let events = try data.map { try reader.consume($0) } ?? []
    guard ended, !reader.isComplete else {
      return (events, nil)
    }
    do {
      return (events + (try reader.finish()), nil)
    } catch {
      return (events, error)
    }
  }

  /// Whether a receive reports the connection ending without a failure: at the end of the stream, or at a TLS
  /// close_notify, which Network reports as `errSSLClosedGraceful` when a server sends one before closing.
  static func endedCleanly(isComplete: Bool, error: NWError?) -> Bool {
    switch error {
    case nil:
      return isComplete
    case .tls(let status):
      return status == errSSLClosedGraceful
    default:
      return false
    }
  }

  /// Whether the transfer goes on after `event`.
  private func handle(_ event: HTTPResponseReader.Event) -> Bool {
    switch event {
    case .head(let statusCode, let contentLength):
      let timeToFirstByte = Date().timeIntervalSince(requestStart)
      state.withLock { state in
        state.report.timeToFirstByte = timeToFirstByte
        let headers = state.reader.headers
        state.report.freshness = HTTPFreshness { headers[$0.lowercased()] }
      }
      guard statusCode == 200 else {
        // Without this the body of an error page is piped onward as though it were the payload, and the caller is told
        // it has a malformed archive.
        let error = InstallError.httpStatus(url: url, statusCode: statusCode)
        logger.error().log(error.description)
        end(failing: error)
        return false
      }
      onEvent?(.response(expectedContentLength: contentLength ?? -1))
    case .body(let data):
      do {
        try spool.append(data)
      } catch {
        // The download is the failure, recorded before the spool's reader can see it, rather than the extraction that
        // reads a spool cut short.
        let report = state.withLock { $0.report }
        end(failing: InstallError.transferFailed(url: url, underlying: error, report: report), spoolFailure: error)
        return false
      }
      state.withLock { $0.report.receivedBytes += Int64(data.count) }
      onEvent?(.data(byteCount: data.count))
    case .end:
      break
    }
    return true
  }

  private func complete() {
    finished.happen()
    spool.end()
    if case .success(let (connection, _)) = connection {
      connection.cancel()
    }
  }

  private func transferFailed(_ error: any Error) {
    guard !finished.hasHappened else {
      return
    }
    let report = state.withLock { state in
      if let untrusted = state.untrusted {
        state.report.trust = untrusted
      }
      return state.report
    }
    logger.error().log("Download of \(url) failed with error \(error)")
    end(failing: InstallError.transferFailed(url: url, underlying: error, report: report))
  }

  /// Records `failure` as the download's, stops the connection and ends the spool, with `spoolFailure` for its reader.
  private func end(failing failure: InstallError, spoolFailure: (any Error)? = nil) {
    fail(failure)
    spool.end(failing: spoolFailure)
    if case .success(let (connection, _)) = connection {
      connection.cancel()
    }
  }

  // The first failure wins, so a cancellation triggered by a rejected response does not displace the HTTP status that
  // caused it.
  private func fail(_ error: any Error) {
    guard !finished.hasHappened else {
      return
    }
    state.withLock {
      $0.failure = error
      $0.failedBeforeCancel = !$0.cancelRequested
    }
    finished.happen()
  }

  private func scheduleIdleCheck(after delay: TimeInterval) {
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      self?.checkIdle()
    }
  }

  private func checkIdle() {
    guard !finished.hasHappened else {
      return
    }
    let idle = Date().timeIntervalSince(state.withLock { $0.lastActivity })
    if idle >= idleTimeout {
      transferFailed(URLError(.timedOut))
    } else {
      scheduleIdleCheck(after: idleTimeout - idle)
    }
  }

  // MARK: - Connection

  /// A connection to `override` that verifies TLS against `url`'s host, and the request for `url` to send over it.
  private static func makeConnection(
    for url: URL, to override: ConnectionOverride, queue: DispatchQueue, state: OSAllocatedUnfairLock<State>
  ) throws -> (NWConnection, request: Data) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
      let host = components.host.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }), !host.isEmpty
    else {
      throw URLError(.unsupportedURL)
    }
    guard !override.host.isEmpty, override.port != 0, let port = NWEndpoint.Port(rawValue: override.port) else {
      throw URLError(.badURL)
    }
    let parameters: NWParameters
    if scheme == "https" {
      let tls = NWProtocolTLS.Options()
      let security = tls.securityProtocolOptions
      sec_protocol_options_set_tls_server_name(security, host)
      sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
      // The same evaluation `URLSession` makes, against the URL's host rather than the address connected to, keeping
      // the chain of a server that fails it for the download's report.
      sec_protocol_options_set_verify_block(
        security,
        { _, trust, complete in
          let trust = sec_trust_copy_ref(trust).takeRetainedValue()
          SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
          let trusted = SecTrustEvaluateWithError(trust, nil)
          if !trusted {
            let untrusted = DownloadReport.Trust(evaluating: trust)
            state.withLock { $0.untrusted = untrusted }
          }
          complete(trusted)
        }, queue)
      parameters = NWParameters(tls: tls)
    } else {
      parameters = .tcp
    }
    let connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(override.host), port: port), using: parameters)

    var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    if let query = components.percentEncodedQuery {
      target += "?\(query)"
    }
    var hostField = host.contains(":") ? "[\(host)]" : host
    if let urlPort = components.port {
      hostField += ":\(urlPort)"
    }
    // Identity, since a compressed body would reach the extractor still compressed. No `Connection: close`: the
    // download ends at the response's length and closes the connection itself, because Network can report a server's
    // close before it has delivered the bytes that came ahead of it.
    let request = "GET \(target) HTTP/1.1\r\nHost: \(hostField)\r\nAccept: */*\r\nAccept-Encoding: identity\r\n\r\n"
    return (connection, Data(request.utf8))
  }

  private static func address(of endpoint: NWEndpoint?) -> String? {
    guard case .hostPort(let host, _)? = endpoint else {
      return nil
    }
    switch host {
    case .ipv4(let address):
      return "\(address)"
    case .ipv6(let address):
      return "\(address)"
    case .name(let name, _):
      return name
    @unknown default:
      return nil
    }
  }
}

// MARK: - DownloadInput

extension NetworkDownloadInput: DownloadInput {}
