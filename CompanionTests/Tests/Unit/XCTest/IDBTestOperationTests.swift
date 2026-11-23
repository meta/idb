/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBControlCore
import FBXCTestCore
import GRPCCore
import IDBGRPCSwift
import XCTest

private struct RunFailed: Error {}

private struct DiscardingWriter: RPCWriterProtocol {
  func write(_ element: Idb_XctestRunResponse) async throws {}
  func write(contentsOf elements: some Sequence<Idb_XctestRunResponse>) async throws {}
}

final class IDBTestOperationTests: XCTestCase {

  func testAFailedRunIsThrownFromAwaitingCompletion() async throws {
    let operation = makeOperation(completion: Task { throw RunFailed() })

    do {
      try await operation.awaitCompletion()
      XCTFail("The run's failure was swallowed")
    } catch is RunFailed {}
  }

  func testCancellingTheWaitStopsTheRun() async throws {
    let started = expectation(description: "the run starts")
    let stopped = expectation(description: "the run stops")
    let operation = makeOperation(
      completion: Task {
        started.fulfill()
        do {
          try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
          stopped.fulfill()
          throw error
        }
      })
    let wait = Task { try await operation.awaitCompletion() }
    await fulfillment(of: [started], timeout: 5)

    wait.cancel()

    await fulfillment(of: [stopped], timeout: 5)
  }

  private func makeOperation(completion: Task<Void, Error>) -> sending IDBTestOperation {
    let logger = IDBLogger(loggers: [ControlCoreGlobalConfiguration.systemLogger(writingToStderr: true, debugLogging: false)])
    return IDBTestOperation(
      configuration: .logic(
        LogicTestConfiguration(
          environment: [:],
          workingDirectory: NSTemporaryDirectory(),
          testBundlePath: "/tmp/Fake.xctest",
          waitForDebugger: false,
          timeout: 0,
          testFilter: nil,
          mirroring: [],
          coverageConfiguration: nil,
          binaryPath: nil,
          logDirectoryPath: nil,
          architectures: [])),
      reporterConfiguration: XCTestReporterConfiguration(resultBundlePath: nil, coverageConfiguration: nil, logDirectoryPath: nil, binariesPaths: [], reportAttachments: false, reportResultBundle: false),
      reporter: IDBXCTestReporter(responseStream: RPCWriter(wrapping: DiscardingWriter()), logger: logger),
      logger: logger,
      completion: completion,
      queue: DispatchQueue(label: "com.facebook.idb.tests.testoperation"))
  }
}
