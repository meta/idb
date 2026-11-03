/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorAX
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift

/// Seam over the `CompanionAccessibility` calls this handler drives, so the request-to-stream wiring can be
/// tested against a double.
protocol AccessibilityQuiescenceStreaming {
  func accessibilityQuiescence(
    query: AccessibilityElementQuery,
    parameters: QuiescenceParameters,
    backend: UIAutomationBackend
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, Error>

  func shimulatorQuiescence(
    query: AccessibilityElementQuery,
    parameters: QuiescenceParameters
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, Error>

  func processId(forBundleID bundleID: String) async throws -> pid_t
}

struct AccessibilityQuiescenceMethodHandler {

  let commandExecutor: IDBCommandExecutor

  func handle(request: Idb_AccessibilityQuiescenceRequest, responseStream: RPCWriter<Idb_AccessibilityQuiescenceResponse>, context: ServerContext) async throws {
    try await Self.stream(request, using: commandExecutor.accessibility, cancellation: context.cancellation) { try await responseStream.send($0) }
  }

  /// Forwards every event until the stream ends, the task is cancelled, or `cancellation` reports the RPC
  /// cancelled, as it does when the client goes away. Each closes the stream and the guest measuring it.
  static func stream(
    _ request: Idb_AccessibilityQuiescenceRequest,
    using commandExecutor: any AccessibilityQuiescenceStreaming,
    cancellation: ServerContext.RPCCancellationHandle,
    send: (Idb_AccessibilityQuiescenceResponse) async throws -> Void
  ) async throws {
    let query: AccessibilityElementQuery
    switch request.target {
    case let .pid(pid):
      guard let pid = pid_t(exactly: pid), pid > 0 else {
        throw RPCError(code: .invalidArgument, message: "\(pid) is not a pid")
      }
      query = .application(pid: pid)
    case let .bundleID(bundleID):
      query = .application(pid: try await commandExecutor.processId(forBundleID: bundleID))
    case nil:
      query = .frontmost
    }
    do {
      let backend: Idb_AccessibilityQuiescenceRequest.Backend
      let events: AsyncThrowingStream<QuiescenceEvent, Error>
      switch request.backend {
      case .shimulator:
        backend = .shimulator
        events = try await commandExecutor.shimulatorQuiescence(query: query, parameters: parameters(from: request))
      case .unspecified, .axbridge, .UNRECOGNIZED:
        backend = .axbridge
        // The companion owns its simulator for its whole run, so it holds its own bridge, as reads do.
        events = try await commandExecutor.accessibilityQuiescence(
          query: query, parameters: parameters(from: request), backend: UIAutomationBackend(resolvedName: .axBridgeExclusive))
      }
      for try await event in Self.events(events, until: cancellation) {
        try await send(response(for: event, backend: backend))
      }
    } catch let error as IdleSyncError {
      throw rpcError(for: error)
    } catch let error as QuiescenceError {
      throw rpcError(for: error)
    }
  }

  static func rpcError(for error: IdleSyncError) -> RPCError {
    let code: RPCError.Code
    switch error {
    case .notAnApplication:
      code = .invalidArgument
    case .unsupportedPlatform, .socketInUse, .notConnected, .severalApplications, .busyThresholdInUse, .unreadableState:
      code = .failedPrecondition
    case .socketUnavailable:
      code = .internalError
    }
    return RPCError(code: code, message: error.localizedDescription)
  }

  static func rpcError(for error: QuiescenceError) -> RPCError {
    let code: RPCError.Code
    switch error {
    case .timedOut:
      code = .deadlineExceeded
    case .targetExited:
      code = .failedPrecondition
    case .streamEnded:
      code = .unavailable
    }
    return RPCError(code: code, message: error.localizedDescription)
  }

  /// gRPC signals a client going away through `cancellation` rather than by cancelling the handler's task,
  /// so without this a stream that writes only on a change runs until its next write fails.
  private static func events(
    _ events: AsyncThrowingStream<QuiescenceEvent, Error>,
    until cancellation: ServerContext.RPCCancellationHandle
  ) -> AsyncThrowingStream<QuiescenceEvent, Error> {
    AsyncThrowingStream { continuation in
      let relay = Task {
        do {
          for try await event in events {
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      let watch = Task {
        try? await cancellation.cancelled
        guard cancellation.isCancelled else { return }
        continuation.finish(throwing: CancellationError())
      }
      continuation.onTermination = { _ in
        relay.cancel()
        watch.cancel()
      }
    }
  }

  static func parameters(from request: Idb_AccessibilityQuiescenceRequest) -> QuiescenceParameters {
    var parameters = QuiescenceParameters()
    if case let .busyThresholdMs(milliseconds) = request.busyThreshold {
      parameters.busyThreshold = TimeInterval(milliseconds) / 1000
    }
    if case let .quietWindowMs(milliseconds) = request.quietWindow {
      parameters.quietWindow = TimeInterval(milliseconds) / 1000
    }
    return parameters
  }

  static func response(
    for event: QuiescenceEvent, backend: Idb_AccessibilityQuiescenceRequest.Backend
  ) -> Idb_AccessibilityQuiescenceResponse {
    var response = response(for: event)
    response.backend = backend
    return response
  }

  private static func response(for event: QuiescenceEvent) -> Idb_AccessibilityQuiescenceResponse {
    switch event {
    case let .state(state, pid):
      return .with {
        $0.pid = UInt64(pid)
        $0.state = .with {
          switch state {
          case let .busy(signals):
            $0.state = .busy
            $0.busySignals = signals.sorted { $0.rawValue < $1.rawValue }.map(signal)
          case .settling:
            $0.state = .settling
          case .quiet:
            $0.state = .quiet
          }
        }
      }
    case let .touchesCompleted(pid):
      return .with {
        $0.pid = UInt64(pid)
        $0.touchesCompleted = .init()
      }
    case let .targetChanged(pid):
      return .with {
        $0.pid = UInt64(pid)
        $0.targetChanged = .init()
      }
    case let .targetExited(pid):
      return .with {
        $0.pid = UInt64(pid)
        $0.targetExited = .init()
      }
    }
  }

  private static func signal(_ signal: QuiescenceSignal) -> Idb_AccessibilityQuiescenceResponse.Signal {
    switch signal {
    case .runLoopIdle: .runLoopIdle
    case .animationsInactive: .animationsInactive
    case .scrollIdle: .scrollIdle
    }
  }
}
