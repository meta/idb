/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBArtifactStaging
@testable import FBControlCore
import Foundation
import Network
import Testing
import os

/// A download whose connection goes to a `ConnectionOverride`. The URLs name a host under `.invalid`, which never
/// resolves, so a download that arrives at all went to the override.
@Suite
struct NetworkDownloadInputTests {

  private let logger = ControlCoreLoggerDouble()
  private let body = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })

  private func override(_ server: ScriptedHTTPServer) -> ConnectionOverride {
    ConnectionOverride(host: "127.0.0.1", port: server.port)
  }

  /// Downloads `url` over `server`, returning what the spool held and the report, or throwing what the download did.
  private func download(
    _ url: String, over server: ScriptedHTTPServer, idleTimeout: TimeInterval = 60,
    onEvent: (@Sendable (DataDownloadEvent) -> Void)? = nil
  ) async throws -> (body: Data, report: DownloadReport) {
    // swiftlint:disable:next force_unwrapping
    let download = NetworkDownloadInput(url: URL(string: url)!, connectingTo: override(server), idleTimeout: idleTimeout, logger: logger, onEvent: onEvent)
    async let spooled = download.spool.reading { source in
      let source = HandedOver(source)
      return try await offCooperativePool { try source.value.readAll() }.get()
    }
    let report = try await download.completed()
    return (try await spooled, report)
  }

  @Test
  func theReportCarriesHowLongTheResponseMayBeReused() async throws {
    let head = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nCache-Control: max-age=1209600, no-transform\r\nAge: 4323\r\nConnection: close\r\n\r\n"
    let server = try await ScriptedHTTPServer.serving(ScriptedHTTPServer.Reply(parts: [Data(head.utf8), Data("hello".utf8)]))
    defer { server.stop() }

    let (_, report) = try await download("http://download.invalid/handle", over: server)

    #expect(report.freshness == HTTPFreshness(lifetime: 1_205_277))
  }

  @Test
  func theBodyComesFromTheOverrideAskingForTheURLsHost() async throws {
    let server = try await ScriptedHTTPServer.serving(body: body)
    defer { server.stop() }
    let events = OSAllocatedUnfairLock<(expected: Int64?, received: Int)>(initialState: (nil, 0))

    let (received, report) = try await download("http://download.invalid/apps/A.ipa?v=2", over: server) { event in
      switch event {
      case .response(let expectedContentLength):
        events.withLock { $0.expected = expectedContentLength }
      case .data(let byteCount):
        events.withLock { $0.received += byteCount }
      }
    }

    #expect(received == body)
    #expect(server.requests.first?.hasPrefix("GET /apps/A.ipa?v=2 HTTP/1.1\r\n") == true)
    #expect(server.requests.first?.contains("\r\nHost: download.invalid\r\n") == true)
    #expect(report.receivedBytes == Int64(body.count))
    #expect(report.remoteAddress == "127.0.0.1")
    #expect(report.proxied == false)
    #expect(report.timeToFirstByte != nil)
    #expect(events.withLock { $0.expected } == Int64(body.count))
    #expect(events.withLock { $0.received } == body.count)
  }

  @Test
  func aBodyOfItsLengthCompletesWhileTheServerHoldsTheConnectionOpen() async throws {
    let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n"
    let server = try await ScriptedHTTPServer.serving(.init(parts: [Data(head.utf8), body], closes: false))
    defer { server.stop() }

    let (received, report) = try await download("http://download.invalid/A.ipa", over: server, idleTimeout: 5)

    #expect(received == body)
    #expect(report.receivedBytes == Int64(body.count))
    #expect(server.requests.first?.lowercased().contains("\r\nconnection: close\r\n") == false)
  }

  @Test
  func aPortInTheURLIsPartOfTheHostAskedFor() async throws {
    let server = try await ScriptedHTTPServer.serving(body: Data("ok".utf8))
    defer { server.stop() }

    _ = try await download("http://download.invalid:8443/A.ipa", over: server)

    #expect(server.requests.first?.contains("\r\nHost: download.invalid:8443\r\n") == true)
  }

  @Test
  func aChunkedBodyIsSpooledWithoutItsFraming() async throws {
    let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    let server = try await ScriptedHTTPServer.serving(
      .init(parts: [Data(head.utf8), Data("5\r\nhello\r\n".utf8), Data("6\r\n world\r\n0\r\n\r\n".utf8)]))
    defer { server.stop() }

    let (received, report) = try await download("http://download.invalid/A.ipa", over: server)

    #expect(received == Data("hello world".utf8))
    #expect(report.receivedBytes == 11)
  }

  @Test
  func aRejectedRequestFailsWithItsStatus() async throws {
    let server = try await ScriptedHTTPServer.serving(statusCode: 404, body: Data("not found".utf8))
    defer { server.stop() }
    // swiftlint:disable:next force_unwrapping
    let url = URL(string: "http://download.invalid/A.ipa")!
    let download = NetworkDownloadInput(url: url, connectingTo: override(server), logger: logger)

    await #expect {
      try await download.completed()
    } throws: { error in
      guard case .httpStatus(let failedURL, let statusCode)? = error as? InstallError else {
        return false
      }
      return failedURL == url && statusCode == 404
    }
    #expect(download.failedOnItsOwn)
    let spooled = try await download.spool.reading { try $0.readAll() }
    #expect(spooled.isEmpty, "the error page must not reach the extractor")
  }

  @Test
  func aBodyCutShortFailsAsALostConnection() async throws {
    let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n"
    let server = try await ScriptedHTTPServer.serving(.init(parts: [Data(head.utf8), body.prefix(1000)]))
    defer { server.stop() }

    await #expect {
      try await download("http://download.invalid/A.ipa", over: server)
    } throws: { error in
      guard case .transferFailed(_, let underlying, let report)? = error as? InstallError else {
        return false
      }
      return (underlying as? URLError)?.code == .networkConnectionLost && report.receivedBytes == 1000
    }
  }

  @Test(
    arguments: [
      (true, nil, true),
      (false, nil, false),
      (true, NWError.tls(errSSLClosedGraceful), true),
      (false, NWError.tls(errSSLClosedGraceful), true),
      (true, NWError.tls(errSSLClosedAbort), false),
      (false, NWError.posix(.ECONNRESET), false),
    ] as [(Bool, NWError?, Bool)])
  func aTLSCloseNotifyEndsTheConnectionCleanly(isComplete: Bool, error: NWError?, endedCleanly: Bool) {
    #expect(NetworkDownloadInput.endedCleanly(isComplete: isComplete, error: error) == endedCleanly)
  }

  @Test
  func aReceiveThatCutsTheBodyShortStillReadsTheBytesThatCameWithTheClose() throws {
    let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n"
    var reader = HTTPResponseReader()

    let read = try NetworkDownloadInput.read(Data(head.utf8) + body.prefix(1000), endingTheStream: true, with: &reader)

    #expect(read.events == [.head(statusCode: 200, contentLength: Int64(body.count)), .body(body.prefix(1000))])
    #expect((read.cutShort as? URLError)?.code == .networkConnectionLost)
  }

  @Test
  func aReceiveThatEndsABodyDelimitedByTheCloseCompletesIt() throws {
    var reader = HTTPResponseReader()

    let read = try NetworkDownloadInput.read(
      Data("HTTP/1.1 200 OK\r\n\r\n".utf8) + body.prefix(1000), endingTheStream: true, with: &reader)

    #expect(read.events == [.head(statusCode: 200, contentLength: nil), .body(body.prefix(1000)), .end])
    #expect(read.cutShort == nil)
    #expect(reader.isComplete)
  }

  @Test
  func nothingListeningAtTheOverrideFailsTheTransfer() async throws {
    let server = try await ScriptedHTTPServer.serving(body: body)
    let port = server.port
    server.stop()
    // swiftlint:disable:next force_unwrapping
    let url = URL(string: "http://download.invalid/A.ipa")!
    let download = NetworkDownloadInput(url: url, connectingTo: ConnectionOverride(host: "127.0.0.1", port: port), logger: logger)

    await #expect {
      try await download.completed()
    } throws: { error in
      guard case .transferFailed(let failedURL, _, let report)? = error as? InstallError else {
        return false
      }
      return failedURL == url && report.receivedBytes == 0
    }
    #expect(download.failedOnItsOwn)
  }

  @Test
  func aServerThatGoesQuietTimesOut() async throws {
    let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n"
    let server = try await ScriptedHTTPServer.serving(.init(parts: [Data(head.utf8)], closes: false))
    defer { server.stop() }

    await #expect {
      try await download("http://download.invalid/A.ipa", over: server, idleTimeout: 0.5)
    } throws: { error in
      guard case .transferFailed(_, let underlying, _)? = error as? InstallError else {
        return false
      }
      return (underlying as? URLError)?.code == .timedOut
    }
  }

  @Test
  func cancellingIsNotTheDownloadsOwnFailure() async throws {
    let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n"
    let server = try await ScriptedHTTPServer.serving(.init(parts: [Data(head.utf8)], closes: false))
    defer { server.stop() }
    let responded = AsyncEvent<Void>()
    // swiftlint:disable:next force_unwrapping
    let url = URL(string: "http://download.invalid/A.ipa")!
    let download = NetworkDownloadInput(url: url, connectingTo: override(server), logger: logger) { event in
      if case .response = event {
        responded.happen()
      }
    }

    try await responded.wait()
    download.cancel()

    await #expect(throws: InstallError.self) { try await download.completed() }
    #expect(!download.failedOnItsOwn)
  }

  @Test
  func aURLThatIsNotHTTPFailsWithoutConnecting() async throws {
    // swiftlint:disable:next force_unwrapping
    let download = NetworkDownloadInput(url: URL(string: "ftp://download.invalid/A.ipa")!, connectingTo: ConnectionOverride(host: "127.0.0.1", port: 9), logger: logger)

    await #expect {
      try await download.completed()
    } throws: { error in
      guard case .transferFailed(_, let underlying, _)? = error as? InstallError else {
        return false
      }
      return (underlying as? URLError)?.code == .unsupportedURL
    }
  }

  /// The override reaches staging: a remote source connecting elsewhere is downloaded from there and extracted.
  @Test
  func stagingDownloadsARemoteSourceFromItsOverride() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("payload".utf8)
    let server = try await ScriptedHTTPServer.serving(body: try GzippingSource(DataSource(payload)).readAll())
    defer { server.stop() }

    let staged = try await Staging.withMaterialized(
      // swiftlint:disable:next force_unwrapping
      .remoteURL(URL(string: "http://download.invalid/libSample.dylib.gz")!, connectingTo: override(server)),
      as: .dylib(name: "libSample.dylib"),
      temporaryDirectory: TemporaryDirectory(rootDirectory: root, logger: logger),
      logger: logger
    ) { tree in
      try Data(contentsOf: tree.url)
    }

    #expect(staged == payload)
  }
}
