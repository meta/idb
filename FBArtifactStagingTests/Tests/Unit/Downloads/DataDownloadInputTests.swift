/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency @testable import FBArtifactStaging
@preconcurrency @testable import FBControlCore
import XCTest

/// Download piped straight into extraction, as the URL install path wires it: the
/// download's spool is the extractor's input.
final class DataDownloadInputTests: XCTestCase {

  private var logger: ControlCoreLogger!
  private var tempDirectory: String!

  override func setUp() {
    super.setUp()
    logger = DownloadTestLogger()
    tempDirectory = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(
      atPath: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    StubURLProtocol.behaviour = .none
    try? FileManager.default.removeItem(atPath: tempDirectory)
    super.tearDown()
  }

  // MARK: - Fixtures

  private static let payloadContents = "payload-contents"

  /// Real gzip bytes for a directory holding a single known file. `padding` adds
  /// incompressible bytes, so that a half-sized prefix of the result is
  /// unambiguously a truncated gzip stream rather than a plausible short one.
  private func makeArchiveData(padding: Int = 0) async throws -> Data {
    let source = (tempDirectory as NSString).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
    try Self.payloadContents.write(
      toFile: (source as NSString).appendingPathComponent("payload.txt"),
      atomically: true,
      encoding: .utf8)
    if padding > 0 {
      var random = Data(count: padding)
      random.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        arc4random_buf(base, padding)
      }
      try random.write(
        to: URL(fileURLWithPath: (source as NSString).appendingPathComponent("padding.bin")))
    }
    return try await ArchiveOperations.createGzippedTarData(forPath: source, logger: logger)
  }

  @discardableResult
  private func downloadAndExtract(
    onEvent: (@Sendable (DataDownloadEvent) -> Void)? = nil
  ) async throws -> (destination: String, report: DownloadReport) {
    let destination = (tempDirectory as NSString).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      atPath: destination, withIntermediateDirectories: true)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    // swiftlint:disable:next force_unwrapping
    let url = URL(string: "https://example.invalid/app.ipa")!
    let logger: ControlCoreLogger = self.logger
    let download = DataDownloadInput(
      url: url,
      configuration: configuration,
      logger: logger,
      onEvent: onEvent)
    async let extraction: Void = download.spool.reading {
      try await BSDTarExtractor().extract(from: $0, to: destination, options: ArchiveExtractOptions(), logger: logger)
    }
    // A data consumer carries only bytes and an end of file, so a failed download
    // reaches the extractor as nothing more than a short stream. Its outcome has
    // to be consulted alongside the extraction's.
    let report = try await download.completed()
    try await extraction
    return (destination, report)
  }

  private func assertThrows(_ inspect: (Error) -> Void) async {
    do {
      try await downloadAndExtract()
      XCTFail("Expected the download to fail")
    } catch {
      inspect(error)
    }
  }

  // MARK: - Spool

  /// The file the download is written to can't be created, so nothing that arrives is kept.
  func testDownload_WhenTheSpoolCannotBeCreated_KeepsNothing() async throws {
    let body = Data(repeating: 0x42, count: 64 << 10)
    StubURLProtocol.behaviour = .respond(statusCode: 200, body: body)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    // swiftlint:disable:next force_unwrapping
    let url = URL(string: "https://example.invalid/app.ipa")!
    let download = DataDownloadInput(
      url: url, configuration: configuration, logger: logger,
      spoolDirectory: URL(fileURLWithPath: tempDirectory).appendingPathComponent("missing"))

    do {
      try await download.completed()
      XCTFail("Expected the download to fail")
    } catch {
      guard case .transferFailed(_, let underlying, let report)? = error as? InstallError else {
        return XCTFail("Expected a transfer failure, got \(error)")
      }
      XCTAssertEqual((underlying as? POSIXError)?.code, .ENOENT)
      XCTAssertEqual(report.receivedBytes, 0)
    }
  }

  // MARK: - Success

  func testDownload_WhenResponseIsOK_ExtractsTheDownloadedArchive() async throws {
    StubURLProtocol.behaviour = .respond(statusCode: 200, body: try await makeArchiveData())

    let destination = try await downloadAndExtract().destination

    XCTAssertEqual(
      try String(
        contentsOfFile: (destination as NSString).appendingPathComponent("payload.txt"),
        encoding: .utf8),
      Self.payloadContents)
  }

  func testDownload_WhenResponseIsOK_ReportsTheResponseThenEveryByte() async throws {
    let archive = try await makeArchiveData(padding: 256 * 1024)
    StubURLProtocol.behaviour = .respond(statusCode: 200, body: archive)
    let recorder = DownloadEventRecorder()

    try await downloadAndExtract(onEvent: recorder.record)

    let events = recorder.events
    guard case .response(let expectedContentLength)? = events.first else {
      XCTFail("Expected the response first, got: \(events)")
      return
    }
    XCTAssertEqual(expectedContentLength, Int64(archive.count))
    let chunks = events.dropFirst().map { event -> Int in
      guard case .data(let byteCount) = event else {
        XCTFail("Expected only data after the response, got: \(event)")
        return 0
      }
      return byteCount
    }
    XCTAssertEqual(chunks.reduce(0, +), archive.count)
  }

  func testDownload_WhenResponseIsOK_ReportsEveryByteAndWhenTheResponseArrived() async throws {
    let archive = try await makeArchiveData()
    StubURLProtocol.behaviour = .respond(statusCode: 200, body: archive)
    let start = Date()

    let report = try await downloadAndExtract().report

    XCTAssertEqual(report.receivedBytes, Int64(archive.count))
    let timeToFirstByte = try XCTUnwrap(report.timeToFirstByte)
    XCTAssertGreaterThanOrEqual(timeToFirstByte, 0)
    XCTAssertLessThanOrEqual(timeToFirstByte, Date().timeIntervalSince(start))
  }

  func testDownload_WhenResponseIsNotFound_ReportsNoEvents() async throws {
    StubURLProtocol.behaviour = .respond(statusCode: 404, body: Data("not found".utf8))
    let recorder = DownloadEventRecorder()

    do {
      try await downloadAndExtract(onEvent: recorder.record)
      XCTFail("Expected the download to fail")
    } catch {
      XCTAssertEqual(recorder.events.count, 0, "Got: \(recorder.events)")
    }
  }

  func testDownload_WhenCompleted_IsReleased() async throws {
    StubURLProtocol.behaviour = .respond(statusCode: 200, body: Data("payload".utf8))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    // swiftlint:disable:next force_unwrapping
    let url = URL(string: "https://example.invalid/app.ipa")!
    weak var released: DataDownloadInput?
    do {
      let download = DataDownloadInput(url: url, configuration: configuration, logger: logger)
      released = download
      try await download.completed()
    }

    let deadline = Date().addingTimeInterval(1)
    while released != nil, Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertNil(released)
  }

  // MARK: - HTTP errors

  func testDownload_WhenResponseIsNotFound_FailsWithTheHTTPStatus() async throws {
    let errorPage = Data("<html><title>404 Not Found</title></html>".utf8)
    StubURLProtocol.behaviour = .respond(statusCode: 404, body: errorPage)

    await assertThrows { error in
      guard case .httpStatus(_, let statusCode)? = error as? InstallError else {
        XCTFail("Expected an HTTP status failure, got: \(error)")
        return
      }
      XCTAssertEqual(statusCode, 404)
      XCTAssertTrue(
        (error as NSError).localizedDescription.localizedCaseInsensitiveContains("404"),
        "The description carries the status across the ObjC boundary too")
    }
  }

  /// An empty body is a valid empty archive to the extractor, so only the status check
  /// distinguishes a rejected request from an empty one.
  func testDownload_WhenResponseIsNotFoundWithNoBody_FailsWithTheHTTPStatus() async throws {
    StubURLProtocol.behaviour = .respond(statusCode: 404, body: Data())

    await assertThrows { error in
      guard case .httpStatus(_, let statusCode)? = error as? InstallError else {
        XCTFail("Expected an HTTP status failure, got: \(error)")
        return
      }
      XCTAssertEqual(statusCode, 404)
    }
  }

  // MARK: - Transport errors

  /// A truncated archive only makes the extractor exit non-zero, which says nothing
  /// about the cause; the transport error is what the caller needs.
  func testDownload_WhenTransportFailsMidStream_FailsWithTheNetworkError() async throws {
    let archive = try await makeArchiveData(padding: 512 * 1024)
    StubURLProtocol.behaviour = .truncate(
      statusCode: 200, body: archive, bytesBeforeFailure: archive.count / 2)

    await assertThrows { error in
      guard case .transferFailed(_, let underlying, _)? = error as? InstallError else {
        XCTFail("Expected a transfer failure, got: \(error)")
        return
      }
      let nsError = underlying as NSError
      XCTAssertEqual(nsError.domain, NSURLErrorDomain)
      XCTAssertEqual(nsError.code, URLError.Code.networkConnectionLost.rawValue)
    }
  }

  func testDownload_WhenTransportFailsMidStream_ReportsWhatArrivedBeforeIt() async throws {
    let archive = try await makeArchiveData(padding: 512 * 1024)
    StubURLProtocol.behaviour = .truncate(
      statusCode: 200, body: archive, bytesBeforeFailure: archive.count / 2)

    await assertThrows { error in
      guard case .transferFailed(_, _, let report)? = error as? InstallError else {
        XCTFail("Expected a transfer failure, got: \(error)")
        return
      }
      XCTAssertEqual(report.receivedBytes, Int64(archive.count / 2))
      XCTAssertNil(report.trust)
    }
  }
}

// MARK: - Doubles

// SAFETY: every access holds `lock`.
// patternlint-disable-next-line unchecked-sendable
private final class DownloadEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [DataDownloadEvent] = []

  var events: [DataDownloadEvent] {
    lock.withLock { recorded }
  }

  @Sendable func record(_ event: DataDownloadEvent) {
    lock.withLock { recorded.append(event) }
  }
}

// SAFETY: stateless no-op.
private final class DownloadTestLogger: ControlCoreLogger, @unchecked Sendable {
  var name: String? { nil }
  var level: ControlCoreLogLevel { .multiple }

  func log(_ message: String) -> any ControlCoreLogger { self }
  func info() -> any ControlCoreLogger { self }
  func debug() -> any ControlCoreLogger { self }
  func error() -> any ControlCoreLogger { self }
  func withName(_ name: String) -> any ControlCoreLogger { self }
  func withDateFormatEnabled(_ enabled: Bool) -> any ControlCoreLogger { self }
}
