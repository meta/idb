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
import GRPCCore
import IDBGRPCSwift
import XCTest

private final class ScriptedQuiescenceExecutor: AccessibilityQuiescenceStreaming {
  private(set) var queries: [AccessibilityElementQuery] = []
  private(set) var parameters: [QuiescenceParameters] = []
  private(set) var backends: [UIAutomationBackend] = []
  /// The queries sent to the shimulator backend, which takes no `UIAutomationBackend`.
  private(set) var shimulatorQueries: [AccessibilityElementQuery] = []
  let events: [QuiescenceEvent]
  let holdsOpen: Bool
  let shimulatorError: IdleSyncError?
  let streamError: QuiescenceError?
  let onTermination: @Sendable () -> Void

  /// The stream yields `events`, then ends, throwing `streamError` if it is set, or with `holdsOpen` stays open
  /// until its consumer stops. The shimulator backend throws `shimulatorError` instead, if it is set.
  init(
    events: [QuiescenceEvent] = [], holdsOpen: Bool = false, shimulatorError: IdleSyncError? = nil,
    streamError: QuiescenceError? = nil, onTermination: @escaping @Sendable () -> Void = {}
  ) {
    self.events = events
    self.holdsOpen = holdsOpen
    self.shimulatorError = shimulatorError
    self.streamError = streamError
    self.onTermination = onTermination
  }

  func accessibilityQuiescence(
    query: AccessibilityElementQuery,
    parameters: QuiescenceParameters,
    backend: UIAutomationBackend
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, Error> {
    queries.append(query)
    self.parameters.append(parameters)
    backends.append(backend)
    return scripted()
  }

  func shimulatorQuiescence(
    query: AccessibilityElementQuery,
    parameters: QuiescenceParameters
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, Error> {
    if let shimulatorError {
      throw shimulatorError
    }
    shimulatorQueries.append(query)
    self.parameters.append(parameters)
    return scripted()
  }

  private func scripted() -> AsyncThrowingStream<QuiescenceEvent, Error> {
    let (events, holdsOpen, streamError, onTermination) = (events, holdsOpen, streamError, onTermination)
    return AsyncThrowingStream { continuation in
      continuation.onTermination = { _ in onTermination() }
      events.forEach { continuation.yield($0) }
      if !holdsOpen {
        continuation.finish(throwing: streamError)
      }
    }
  }

  func processId(forBundleID bundleID: String) async throws -> pid_t {
    XCTAssertEqual(bundleID, "com.example.app")
    return 77
  }
}

final class AccessibilityQuiescenceMethodHandlerTests: XCTestCase {

  private func stream(_ request: Idb_AccessibilityQuiescenceRequest, using executor: ScriptedQuiescenceExecutor) async throws -> [Idb_AccessibilityQuiescenceResponse] {
    var responses: [Idb_AccessibilityQuiescenceResponse] = []
    try await AccessibilityQuiescenceMethodHandler.stream(request, using: executor, cancellation: ServerContext.RPCCancellationHandle()) { responses.append($0) }
    return responses
  }

  func testNoTargetFollowsTheFrontmostApplicationOnTheExclusiveBridge() async throws {
    let executor = ScriptedQuiescenceExecutor()
    _ = try await stream(Idb_AccessibilityQuiescenceRequest(), using: executor)
    XCTAssertEqual(executor.queries, [.frontmost])
    XCTAssertEqual(executor.parameters, [QuiescenceParameters()])
    XCTAssertEqual(executor.backends, [UIAutomationBackend(resolvedName: .axBridgeExclusive)])
  }

  func testAPidOrBundleIDNamesTheApplication() async throws {
    let executor = ScriptedQuiescenceExecutor()
    _ = try await stream(.with { $0.pid = 42 }, using: executor)
    _ = try await stream(.with { $0.bundleID = "com.example.app" }, using: executor)
    XCTAssertEqual(executor.queries, [.application(pid: 42), .application(pid: 77)])
  }

  func testAPidOutOfRangeIsAnInvalidArgument() async throws {
    let executor = ScriptedQuiescenceExecutor()
    for pid: UInt64 in [0, UInt64(Int32.max) + 1] {
      do {
        _ = try await stream(.with { $0.pid = pid }, using: executor)
        XCTFail("\(pid) was accepted")
      } catch let error as RPCError {
        XCTAssertEqual(error.code, .invalidArgument)
      }
    }
    XCTAssertEqual(executor.queries, [])
  }

  func testATunableIsSentOnlyWhenSetAndZeroIsKept() async throws {
    let executor = ScriptedQuiescenceExecutor()
    _ = try await stream(.with { $0.quietWindowMs = 0 }, using: executor)
    _ = try await stream(.with { $0.busyThresholdMs = 1500 }, using: executor)
    XCTAssertEqual(executor.parameters, [QuiescenceParameters(quietWindow: 0), QuiescenceParameters(busyThreshold: 1.5)])
  }

  func testEveryEventIsForwardedInOrder() async throws {
    let executor = ScriptedQuiescenceExecutor(events: [
      .state(.busy([.runLoopIdle, .animationsInactive]), pid: 42),
      .touchesCompleted(pid: 42),
      .state(.settling, pid: 42),
      .targetChanged(pid: 43),
      .state(.quiet, pid: 43),
      .targetExited(pid: 43),
    ])
    let responses = try await stream(Idb_AccessibilityQuiescenceRequest(), using: executor)
    XCTAssertEqual(
      responses,
      [
        .with {
          $0.backend = .axbridge
          $0.pid = 42
          $0.state = .with {
            $0.state = .busy
            $0.busySignals = [.animationsInactive, .runLoopIdle]
          }
        },
        .with {
          $0.backend = .axbridge
          $0.pid = 42
          $0.touchesCompleted = .init()
        },
        .with {
          $0.backend = .axbridge
          $0.pid = 42
          $0.state = .with { $0.state = .settling }
        },
        .with {
          $0.backend = .axbridge
          $0.pid = 43
          $0.targetChanged = .init()
        },
        .with {
          $0.backend = .axbridge
          $0.pid = 43
          $0.state = .with { $0.state = .quiet }
        },
        .with {
          $0.backend = .axbridge
          $0.pid = 43
          $0.targetExited = .init()
        },
      ])
  }

  func testTheShimulatorBackendMeasuresInTheAppAndSaysSo() async throws {
    let executor = ScriptedQuiescenceExecutor(events: [.state(.busy([.runLoopIdle]), pid: 77), .state(.quiet, pid: 77)])
    let responses = try await stream(
      .with {
        $0.backend = .shimulator
        $0.bundleID = "com.example.app"
        $0.busyThresholdMs = 32
        $0.quietWindowMs = 250
      }, using: executor)
    XCTAssertEqual(executor.shimulatorQueries, [.application(pid: 77)])
    XCTAssertEqual(executor.queries, [], "the accessibility backend was not opened")
    XCTAssertEqual(executor.parameters, [QuiescenceParameters(busyThreshold: 0.032, quietWindow: 0.25)])
    XCTAssertEqual(
      responses,
      [
        .with {
          $0.backend = .shimulator
          $0.pid = 77
          $0.state = .with {
            $0.state = .busy
            $0.busySignals = [.runLoopIdle]
          }
        },
        .with {
          $0.backend = .shimulator
          $0.pid = 77
          $0.state = .with { $0.state = .quiet }
        },
      ])
  }

  func testAShimulatorFailureIsAStatusTheClientCanActOn() async throws {
    let cases: [(IdleSyncError, RPCError.Code)] = [
      (.notAnApplication, .invalidArgument),
      (.notConnected(pid: 77, path: "/tmp/idle.sock", waited: 1), .failedPrecondition),
      (.severalApplications(pids: [7, 8]), .failedPrecondition),
      (.socketUnavailable(path: "/tmp/idle.sock", reason: "EACCES"), .internalError),
      (.busyThresholdInUse(path: "/tmp/idle.sock", current: 32, requested: 16), .failedPrecondition),
      (.unreadableState(pid: 77, reason: "dataCorrupted"), .failedPrecondition),
    ]
    for (failure, code) in cases {
      do {
        _ = try await stream(.with { $0.backend = .shimulator }, using: ScriptedQuiescenceExecutor(shimulatorError: failure))
        XCTFail("\(failure) was not thrown")
      } catch let error as RPCError {
        XCTAssertEqual(error.code, code, "\(failure)")
        XCTAssertEqual(error.message, failure.localizedDescription)
      }
    }
  }

  func testAStreamThatEndsWithoutAnswerIsAStatusTooOnEitherBackend() async throws {
    for backend in [Idb_AccessibilityQuiescenceRequest.Backend.shimulator, .axbridge] {
      do {
        _ = try await stream(
          .with { $0.backend = backend },
          using: ScriptedQuiescenceExecutor(events: [.state(.settling, pid: 42)], streamError: .streamEnded))
        XCTFail("the end of the stream was not thrown")
      } catch let error as RPCError {
        XCTAssertEqual(error.code, .unavailable, "\(backend)")
        XCTAssertEqual(error.message, QuiescenceError.streamEnded.localizedDescription)
      }
    }
  }

  // Cancelling the handler's task must close the stream behind it.
  func testCancellingTheCallClosesTheStream() async throws {
    let forwarded = expectation(description: "the first event is forwarded")
    let closed = expectation(description: "the stream is closed")
    let executor = ScriptedQuiescenceExecutor(events: [.state(.settling, pid: 42)], holdsOpen: true) { closed.fulfill() }
    let call = Task {
      try await AccessibilityQuiescenceMethodHandler.stream(
        Idb_AccessibilityQuiescenceRequest(), using: executor, cancellation: ServerContext.RPCCancellationHandle()
      ) { _ in forwarded.fulfill() }
    }
    await fulfillment(of: [forwarded], timeout: 5)
    call.cancel()
    await fulfillment(of: [closed], timeout: 5)
    _ = await call.result
  }

  // gRPC reports a client going away through the RPC's cancellation handle, not by cancelling the
  // handler's task.
  func testAClientGoingAwayClosesTheStream() async throws {
    let forwarded = expectation(description: "the first event is forwarded")
    let closed = expectation(description: "the stream is closed")
    let executor = ScriptedQuiescenceExecutor(events: [.state(.settling, pid: 42)], holdsOpen: true) { closed.fulfill() }
    let cancellation = ServerContext.RPCCancellationHandle()
    let call = Task {
      try await AccessibilityQuiescenceMethodHandler.stream(Idb_AccessibilityQuiescenceRequest(), using: executor, cancellation: cancellation) { _ in
        forwarded.fulfill()
      }
    }
    await fulfillment(of: [forwarded], timeout: 5)
    cancellation.cancel()
    await fulfillment(of: [closed], timeout: 1)
    do {
      try await call.value
      XCTFail("the call outlived its cancellation")
    } catch is CancellationError {}
  }
}
