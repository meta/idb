/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBSimulatorCodeInjection
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import Testing
import os

@Suite
struct InjectVideoMethodHandlerTests {
  private typealias Requests = AsyncThrowingStream<Idb_InjectVideoRequest, any Error>

  @Test
  func mapsVideoFailuresToClientStatuses() {
    let unreadable = VideoInjectionError.inputUnreadable(path: "/tmp/missing.mov", reason: "No such file.")
    #expect(InjectVideoMethodHandler.rpcError(for: unreadable).code == .invalidArgument)
    #expect(InjectVideoMethodHandler.rpcError(for: .noVideoTrack(path: "/tmp/a.txt", reason: nil)).code == .invalidArgument)
    #expect(InjectVideoMethodHandler.rpcError(for: .alreadyRunning(udid: "simulator")).code == .failedPrecondition)
    #expect(
      InjectVideoMethodHandler.rpcError(for: .failedInGuest(udid: "simulator", process: "App", reason: nil)).code
        == .failedPrecondition)
    #expect(InjectVideoMethodHandler.rpcError(for: .stagingFailed(path: "/tmp/x", reason: "full")).code == .internalError)
    #expect(
      InjectVideoMethodHandler.rpcError(for: IDBCommandError.notASimulator(targetDescription: "physical device"))?.code
        == .failedPrecondition)
    #expect(InjectVideoMethodHandler.rpcError(for: IDBCommandError.invalidURL(urlString: "not a URL")) == nil)
  }

  @Test
  func stopEndsTheInjectionAfterItsUpdates() async throws {
    let (requests, continuation) = Requests.makeStream()
    continuation.yield(start(back: "/tmp/back.mov", front: "/tmp/front.mov", loop: true))
    let injection = RunningInjection()
    async let result: Void = InjectVideoMethodHandler.withVideoInjection(
      from: reader(requests), cancellation: .init(), send: injection.sent, injection.run)

    #expect(await injection.started.first { _ in true } == ["/tmp/back.mov", "/tmp/front.mov", "true"])
    continuation.yield(Idb_InjectVideoRequest.with { $0.stop = .init() })
    try await result
    #expect(await injection.cancelled.first { _ in true } == true)
    #expect(injection.updates == [[], ["Camera"]])
    continuation.finish()
  }

  @Test
  func endOfStreamEndsTheInjection() async throws {
    let (requests, continuation) = Requests.makeStream()
    continuation.yield(start(back: "/tmp/back.mov"))
    let injection = RunningInjection()
    async let result: Void = InjectVideoMethodHandler.withVideoInjection(
      from: reader(requests), cancellation: .init(), send: injection.sent, injection.run)

    #expect(await injection.started.first { _ in true } == ["/tmp/back.mov", "", "false"])
    continuation.finish()
    try await result
    #expect(await injection.cancelled.first { _ in true } == true)
  }

  @Test
  func rpcCancellationCancelsTheInjection() async throws {
    let (requests, continuation) = Requests.makeStream()
    continuation.yield(start(back: "/tmp/back.mov"))
    let cancellation = ServerContext.RPCCancellationHandle()
    let injection = RunningInjection()
    async let result: Void = InjectVideoMethodHandler.withVideoInjection(
      from: reader(requests), cancellation: cancellation, send: injection.sent, injection.run)

    _ = await injection.started.first { _ in true }
    cancellation.cancel()
    do {
      try await result
      Issue.record("RPC cancellation did not cancel the injection")
    } catch is CancellationError {
    }
    #expect(await injection.cancelled.first { _ in true } == true)
    continuation.finish()
  }

  @Test
  func returnsWhenTheInjectionEndsWithTheStreamStillOpen() async throws {
    let (requests, continuation) = Requests.makeStream()
    continuation.yield(start(back: "/tmp/back.mov"))
    try await InjectVideoMethodHandler.withVideoInjection(
      from: reader(requests), cancellation: .init(), send: { _ in }
    ) { _, onUpdate in
      try await onUpdate([])
    }
    continuation.finish()
  }

  @Test
  func requiresAStartWithABackPathFirst() async {
    let cases: [([Idb_InjectVideoRequest], RPCError.Code)] = [
      ([], .failedPrecondition),
      ([Idb_InjectVideoRequest.with { $0.stop = .init() }], .failedPrecondition),
      ([start(back: "")], .invalidArgument),
    ]
    for (requests, code) in cases {
      let (stream, continuation) = Requests.makeStream()
      requests.forEach { continuation.yield($0) }
      continuation.finish()
      let error = await #expect(throws: RPCError.self) {
        try await InjectVideoMethodHandler.withVideoInjection(
          from: reader(stream), cancellation: .init(), send: { _ in }
        ) { _, _ in
          Issue.record("An injection started without a valid start request")
        }
      }
      #expect(error?.code == code)
    }
  }

  @Test
  func injectionFailuresReachTheClient() async {
    let (requests, continuation) = Requests.makeStream()
    continuation.yield(start(back: "/tmp/notes.txt"))
    await #expect(throws: VideoInjectionError.self) {
      try await InjectVideoMethodHandler.withVideoInjection(
        from: reader(requests), cancellation: .init(), send: { _ in }
      ) { start, _ in
        throw VideoInjectionError.noVideoTrack(path: start.backPath, reason: nil)
      }
    }
    continuation.finish()
  }

  private func start(back: String, front: String = "", loop: Bool = false) -> Idb_InjectVideoRequest {
    Idb_InjectVideoRequest.with {
      $0.start = .with {
        $0.backPath = back
        $0.frontPath = front
        $0.loop = loop
      }
    }
  }

  private func reader(_ stream: Requests) -> RequestStreamReader<Idb_InjectVideoRequest> {
    RequestStreamReader(RPCAsyncSequence(wrapping: stream))
  }
}

/// An injection that sends two updates and then runs until it is cancelled.
private final class RunningInjection: Sendable {
  private let sentUpdates = OSAllocatedUnfairLock<[[String]]>(initialState: [])
  let started: AsyncStream<[String]>
  let cancelled: AsyncStream<Bool>
  private let startedContinuation: AsyncStream<[String]>.Continuation
  private let cancelledContinuation: AsyncStream<Bool>.Continuation

  init() {
    (started, startedContinuation) = AsyncStream.makeStream()
    (cancelled, cancelledContinuation) = AsyncStream.makeStream()
  }

  var updates: [[String]] {
    sentUpdates.withLock { $0 }
  }

  var sent: InjectVideoMethodHandler.Update {
    { [sentUpdates] processes in sentUpdates.withLock { $0.append(processes) } }
  }

  var run: @Sendable (Idb_InjectVideoRequest.Start, InjectVideoMethodHandler.Update) async throws -> Void {
    { [self] start, onUpdate in
      try await onUpdate([])
      try await onUpdate(["Camera"])
      startedContinuation.yield([start.backPath, start.frontPath, String(start.loop)])
      do {
        try await Task.sleep(for: .seconds(30))
      } catch is CancellationError {
        cancelledContinuation.yield(true)
        throw CancellationError()
      }
    }
  }
}
