/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBControlCore
import FBXCTestCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import Testing

private final class ShutdownLog: ControlCoreLogger {
  let requestStarted = AsyncEvent<Void>()
  let shutdownStarted = AsyncEvent<Void>()
  let serverClosed = AsyncEvent<Void>()

  var name: String? { nil }
  var level: ControlCoreLogLevel { .multiple }

  func log(_ message: String) -> any ControlCoreLogger {
    if message.hasPrefix("install called with:") { requestStarted.happen() }
    if message == "Shutting down swift server" { shutdownStarted.happen() }
    if message == "Server closed" { serverClosed.happen() }
    return self
  }

  func info() -> any ControlCoreLogger { self }
  func debug() -> any ControlCoreLogger { self }
  func error() -> any ControlCoreLogger { self }
  func withName(_ name: String) -> any ControlCoreLogger { self }
  func withDateFormatEnabled(_ enabled: Bool) -> any ControlCoreLogger { self }
}

@Suite("Companion server shutdown")
struct CompanionServerShutdownTests {
  @Test("Discovery survives cancellation while an RPC drains") @MainActor
  func cancellationWaitsForServerDrainBeforeReleasingDiscovery() async throws {
    let events = ShutdownLog()
    let logger = IDBLogger(loggers: [events])
    weak var discovery: TargetSetDouble?
    let released = AsyncEvent<Bool>()
    try await withCompanionTestSession(
      "shutdown-target",
      makingTargetSets: [
        {
          let set = TargetSetDouble(targets: ["shutdown-target": MacDevice(logger: logger)]) {
            released.happen(events.serverClosed.hasHappened)
          }
          discovery = set
          return set
        }
      ],
      logger: logger, idleShutdownTime: 3600
    ) { server in
      let finishRequest = AsyncEvent<Void>()
      let requestFinished = AsyncEvent<Void>()
      var options = CallOptions.defaults
      options.timeout = .seconds(20)
      let request = Task {
        defer { requestFinished.happen() }
        try await server.client.install(
          options: options,
          requestProducer: { writer in
            try await writer.write(.with { $0.destination = .app })
            try await finishRequest.waitIgnoringCancellation()
          },
          onResponse: { response in
            for try await _ in response.messages {}
          })
      }
      defer {
        finishRequest.happen()
        request.cancel()
      }
      try await events.requestStarted.wait(timeout: 10, waitingFor: "in-flight install request")
      try #require(!requestFinished.hasHappened)
      try #require(discovery != nil)

      server.task.cancel()
      try await events.shutdownStarted.wait(timeout: 5, waitingFor: "server graceful shutdown")
      let endedWhileRequestWasHeld: Bool
      do {
        endedWhileRequestWasHeld = try await server.stopped.wait(timeout: 0.5, waitingFor: "premature session completion")
      } catch is PollTimeoutError {
        endedWhileRequestWasHeld = false
      }
      #expect(!endedWhileRequestWasHeld)
      #expect(discovery != nil)
      #expect(!released.hasHappened)
      #expect(!requestFinished.hasHappened)
      #expect(!events.serverClosed.hasHappened)

      finishRequest.happen()
      _ = await request.result
      try await events.serverClosed.wait(timeout: 10, waitingFor: "server drain completion")
      _ = try await server.stopped.wait(timeout: 10, waitingFor: "companion session shutdown")
      let releasedAfterServerClosed = try await released.wait(timeout: 5, waitingFor: "discovery release")
      #expect(releasedAfterServerClosed)
      #expect(discovery == nil)
      let result = await server.task.result
      #expect(throws: CancellationError.self) { try result.get() }
    }
  }
}
