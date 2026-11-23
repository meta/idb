/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBControlCore
import XCTest

final class CrashLogStoreTests: XCTestCase {

  private var directory: String!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("crash_store_\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory, FileManager.default.fileExists(atPath: directory) {
      try FileManager.default.removeItem(atPath: directory)
    }
    directory = nil
    try super.tearDownWithError()
  }

  // MARK: - Ingestion

  func testIngestCrashLogData_WhenDataIsParsable_WritesItIntoTheStoreDirectory() throws {
    let store = makeStore()

    let ingested = store.ingestCrashLogData(try assetsdCrashData(), name: "assetsd.crash")

    let ingestedCrashLog = try XCTUnwrap(ingested, "Parsable crash log data should be ingested")
    XCTAssertEqual(ingestedCrashLog.identifier, "assetsd")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent("assetsd.crash")),
      "Ingested crash log data should be written into the store's directory")
  }

  func testIngestCrashLogData_WhenNameWasAlreadyIngested_ReturnsNil() throws {
    let store = makeStore()
    let data = try assetsdCrashData()

    XCTAssertNotNil(store.ingestCrashLogData(data, name: "assetsd.crash"))

    XCTAssertNil(
      store.ingestCrashLogData(data, name: "assetsd.crash"),
      "Re-ingesting an already-ingested name should be a no-op")
  }

  // MARK: - Delivery

  func testNextCrashLog_WhenMatchingCrashLogIsIngested_DeliversIt() async throws {
    let store = makeStore()
    let next = Task { try await store.nextCrashLog(forMatchingPredicate: CrashLogPredicate.identifier("assetsd")) }
    defer { next.cancel() }

    let ingester = ingestRepeatedly(try assetsdCrashData(), named: "assetsd")
    defer { ingester.cancel() }

    let delivered = try await next.value

    XCTAssertEqual(delivered.identifier, "assetsd", "The delivered crash log should be the one matching the predicate")
  }

  func testNextCrashLog_WhenIngestedCrashLogDoesNotMatch_SkipsItAndWaitsForOneThatDoes() async throws {
    let store = makeStore()
    let next = Task { try await store.nextCrashLog(forMatchingPredicate: CrashLogPredicate.identifier("assetsd")) }
    defer { next.cancel() }

    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertNotNil(
      makeStore().ingestCrashLogData(try tableSearchCrashData(), name: "tablesearch.crash"),
      "The non-matching crash log should still be ingested")

    let ingester = ingestRepeatedly(try assetsdCrashData(), named: "assetsd")
    defer { ingester.cancel() }

    let delivered = try await next.value

    XCTAssertEqual(delivered.identifier, "assetsd", "A crash log not matching the predicate should not resolve the wait")
  }

  func testNextCrashLog_WhenCancelled_StopsWaiting() async throws {
    let store = makeStore()
    let returned = expectation(description: "The cancelled wait returns")
    let next = Task {
      defer { returned.fulfill() }
      _ = try await store.nextCrashLog(forMatchingPredicate: CrashLogPredicate.identifier("assetsd"))
    }

    try await Task.sleep(nanoseconds: 200_000_000)
    next.cancel()

    await fulfillment(of: [returned], timeout: 1)
  }

  // MARK: - Listening

  func testListener_WhenMatchingCrashLogIsIngestedBeforeAwaiting_DeliversIt() async throws {
    let store = makeStore()
    let listener = store.listenForNextCrashLog(matching: CrashLogPredicate.identifier("assetsd"))

    XCTAssertNotNil(store.ingestCrashLogData(try assetsdCrashData(), name: "assetsd.crash"))
    let delivered = try await listener.next()

    XCTAssertEqual(delivered.identifier, "assetsd", "A crash log ingested after listening started should be delivered")
  }

  func testListener_WhenNonMatchingCrashLogIsIngestedFirst_DeliversTheMatchingOne() async throws {
    let store = makeStore()
    let listener = store.listenForNextCrashLog(matching: CrashLogPredicate.identifier("assetsd"))

    XCTAssertNotNil(store.ingestCrashLogData(try tableSearchCrashData(), name: "tablesearch.crash"))
    XCTAssertNotNil(store.ingestCrashLogData(try assetsdCrashData(), name: "assetsd.crash"))
    let delivered = try await listener.next()

    XCTAssertEqual(delivered.identifier, "assetsd", "A crash log not matching the predicate should not be held")
  }

  func testListener_WhenSeveralMatchingCrashLogsAreIngested_DeliversTheFirst() async throws {
    let store = makeStore()
    let listener = store.listenForNextCrashLog(matching: CrashLogPredicate.identifier("assetsd"))
    let data = try assetsdCrashData()

    XCTAssertNotNil(store.ingestCrashLogData(data, name: "first.crash"))
    XCTAssertNotNil(store.ingestCrashLogData(data, name: "second.crash"))
    let delivered = try await listener.next()

    XCTAssertEqual(delivered.name, "first.crash")
  }

  func testListener_WhenCrashLogWasIngestedBeforeListening_DoesNotDeliverIt() async throws {
    let store = makeStore()
    XCTAssertNotNil(store.ingestCrashLogData(try assetsdCrashData(), name: "assetsd.crash"))
    let listener = store.listenForNextCrashLog(matching: CrashLogPredicate.identifier("assetsd"))

    let next = Task { try await listener.next() }
    try await Task.sleep(nanoseconds: 200_000_000)
    next.cancel()

    do {
      _ = try await next.value
      XCTFail("A crash log ingested before listening started should not be delivered")
    } catch is CancellationError {}
  }

  func testListener_WhenCancelledBeforeAwaiting_ThrowsCancellation() async throws {
    let store = makeStore()
    let listener = store.listenForNextCrashLog(matching: CrashLogPredicate.identifier("assetsd"))

    let next = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await listener.next()
    }

    do {
      _ = try await next.value
      XCTFail("A wait cancelled before it starts should not deliver")
    } catch is CancellationError {}
  }

  /// Ingests `data` repeatedly under distinct names, through a store of its own over the same
  /// directory, until cancelled. The store registers its notification observer asynchronously, so a
  /// single ingest can be posted before the observer exists and be missed; identical names are
  /// deduplicated and post nothing, so each retry needs a fresh name.
  private func ingestRepeatedly(_ data: Data, named name: String) -> Task<Void, Never> {
    let store = makeStore()
    return Task {
      for attempt in 0..<50 {
        if Task.isCancelled { return }
        _ = store.ingestCrashLogData(data, name: "\(name)_\(attempt).crash")
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
    }
  }

  private func makeStore() -> sending CrashLogStore {
    CrashLogStore(directories: [directory], logger: ControlCoreLoggerDouble())
  }

  private func assetsdCrashData() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: TestFixtures.assetsdCrashPathWithCustomDeviceSet))
  }

  private func tableSearchCrashData() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: TestFixtures.appCrashPathWithDefaultDeviceSet))
  }
}
