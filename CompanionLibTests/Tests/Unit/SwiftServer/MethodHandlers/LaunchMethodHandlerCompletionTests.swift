/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBControlCore
import FBDeviceControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import Testing

@Suite
struct LaunchMethodHandlerCompletionTests {

  @Test(.timeLimit(.minutes(1)))
  func cancellingTheRPCCancelsALaunchThatHasNotFinished() async throws {
    let cancellation = ServerContext.RPCCancellationHandle()
    let started = AsyncEvent<Void>()
    let launchCancelled = AsyncEvent<Void>()
    let session = Task {
      _ = try await LaunchMethodHandler.launch(cancellation: cancellation) {
        started.happen()
        do {
          try await Task.sleep(nanoseconds: 600_000_000_000)
        } catch {
          launchCancelled.happen()
          throw error
        }
        return ControlledLaunchedApplication()
      }
    }
    try await started.wait()

    cancellation.cancel()

    await #expect(throws: CancellationError.self) {
      try await session.value
    }
    #expect(launchCancelled.hasHappened)
  }

  @Test(.timeLimit(.minutes(1)))
  func naturalExitEndsTheSessionWithoutStopAndCancelsTheRequestWait() async throws {
    let application = ControlledLaunchedApplication()
    let (requests, client) = clientStream()
    let requestCancelled = AsyncEvent<Void>()
    client.onTermination = { termination in
      if case .cancelled = termination {
        requestCancelled.happen()
      }
    }
    let session = Task {
      try await LaunchMethodHandler.waitForCompletion(
        application: application,
        requestStream: requests,
        consumers: [],
        cancellation: .init())
    }
    defer {
      session.cancel()
      application.exited.happen()
      client.finish()
    }
    try await application.observing.wait()

    application.exited.happen()
    try await session.value

    #expect(await application.stopCalls == 0)
    #expect(application.observationFinished.hasHappened)
    #expect(requestCancelled.hasHappened)
  }

  @Test(.timeLimit(.minutes(1)))
  func stopEndsTheSessionAndJoinsTheExitWaitBeforeTerminating() async throws {
    let application = ControlledLaunchedApplication()
    let (requests, client) = clientStream()
    defer { client.finish() }
    client.yield(.with { $0.stop = .init() })

    try await LaunchMethodHandler.waitForCompletion(
      application: application,
      requestStream: requests,
      consumers: [],
      cancellation: .init())

    #expect(await application.stopCalls == 1)
    #expect(await application.observationFinishedBeforeStop)
    #expect(application.exited.hasHappened)
  }

  @Test(.timeLimit(.minutes(1)))
  func stopAndNaturalExitReadyTogetherEndTheSession() async throws {
    let application = ControlledLaunchedApplication()
    let (requests, client) = clientStream()
    defer { client.finish() }
    application.exited.happen()
    client.yield(.with { $0.stop = .init() })

    try await LaunchMethodHandler.waitForCompletion(
      application: application,
      requestStream: requests,
      consumers: [],
      cancellation: .init())

    #expect(await application.stopCalls <= 1)
    #expect(application.observationFinished.hasHappened)
  }

  @Test(.timeLimit(.minutes(1)))
  func completionWaitsForBothOutputsToFinishForwarding() async throws {
    let application = ControlledLaunchedApplication()
    let (requests, client) = clientStream()
    let stdout = ConsumableBuffer()
    let stderr = ConsumableBuffer()
    let stdoutConsumer = LaunchMethodHandler.pipeOutput(interface: .stdout) { stdout.consumeData($0.output.data) }
    let stderrConsumer = LaunchMethodHandler.pipeOutput(interface: .stderr) { stderr.consumeData($0.output.data) }
    let stdoutCompletion = ObservedOutputCompletion(consumer: stdoutConsumer)
    let stderrCompletion = ObservedOutputCompletion(consumer: stderrConsumer)
    let sessionFinished = AsyncEvent<Void>()
    let session = Task {
      try await LaunchMethodHandler.waitForCompletion(
        application: application,
        requestStream: requests,
        consumers: [stdoutCompletion, stderrCompletion],
        cancellation: .init())
      sessionFinished.happen()
    }
    defer {
      session.cancel()
      application.exited.happen()
      stdoutConsumer.consumeEndOfFile()
      stderrConsumer.consumeEndOfFile()
      client.finish()
    }
    application.exited.happen()
    try await stdoutCompletion.observing.wait()
    try await stderrCompletion.observing.wait()
    #expect(!sessionFinished.hasHappened)

    stdoutConsumer.consumeData(Data("final stdout".utf8))
    stderrConsumer.consumeData(Data("final stderr".utf8))
    stdoutConsumer.consumeEndOfFile()
    try await stdoutConsumer.awaitFinishedConsuming()
    #expect(!sessionFinished.hasHappened)
    stderrConsumer.consumeEndOfFile()
    try await session.value

    #expect(stdout.data() == Data("final stdout".utf8))
    #expect(stderr.data() == Data("final stderr".utf8))
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      DeviceApplicationError.awaitingTerminationUnsupported as any Error,
      CancellationError(),
    ])
  func anObserverThatReportsNoExitKeepsWaitingForStop(observerError: any Error) async throws {
    let application = ControlledLaunchedApplication(observerError: observerError)
    let (requests, client) = clientStream()
    let sessionFinished = AsyncEvent<Void>()
    let session = Task {
      try await LaunchMethodHandler.waitForCompletion(
        application: application,
        requestStream: requests,
        consumers: [],
        cancellation: .init())
      sessionFinished.happen()
    }
    defer {
      session.cancel()
      client.finish()
    }
    try await application.observationFinished.wait()
    #expect(!sessionFinished.hasHappened)

    client.yield(.with { $0.stop = .init() })
    try await session.value

    #expect(await application.stopCalls == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func rpcCancellationJoinsTheExitAndRequestWaitsWithoutStoppingTheApp() async throws {
    let application = ControlledLaunchedApplication()
    let (requests, client) = clientStream()
    let cancellation = ServerContext.RPCCancellationHandle()
    let requestCancelled = AsyncEvent<Void>()
    client.onTermination = { termination in
      if case .cancelled = termination {
        requestCancelled.happen()
      }
    }
    let session = Task {
      try await LaunchMethodHandler.waitForCompletion(
        application: application,
        requestStream: requests,
        consumers: [],
        cancellation: cancellation)
    }
    defer {
      session.cancel()
      application.exited.happen()
      client.finish()
    }
    try await application.observing.wait()

    cancellation.cancel()
    await #expect(throws: CancellationError.self) { try await session.value }

    #expect(application.observationFinished.hasHappened)
    #expect(requestCancelled.hasHappened)
    #expect(await application.stopCalls == 0)
    #expect(!application.exited.hasHappened)
  }

  @Test(.timeLimit(.minutes(1)))
  func aFailedStopJoinsTheExitWaitAndPreservesTheFailure() async throws {
    let application = ControlledLaunchedApplication(stopError: LaunchFailure.stop)
    let (requests, client) = clientStream()
    defer { client.finish() }
    client.yield(.with { $0.stop = .init() })

    let error = await #expect(throws: LaunchFailure.self) {
      try await LaunchMethodHandler.waitForCompletion(
        application: application,
        requestStream: requests,
        consumers: [],
        cancellation: .init())
    }

    #expect(error == .stop)
    #expect(application.observationFinished.hasHappened)
    #expect(!application.exited.hasHappened)
  }

  @Test(.timeLimit(.minutes(1)))
  func anInvalidControlJoinsTheExitWaitAndFails() async throws {
    let application = ControlledLaunchedApplication()
    let (requests, client) = clientStream()
    defer { client.finish() }
    client.yield(.with { $0.start = .init() })

    let error = await #expect(throws: RPCError.self) {
      try await LaunchMethodHandler.waitForCompletion(
        application: application,
        requestStream: requests,
        consumers: [],
        cancellation: .init())
    }

    #expect(error?.code == .failedPrecondition)
    #expect(await application.stopCalls == 0)
    #expect(application.observationFinished.hasHappened)
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      DeviceApplicationError.applicationLookupMalformed,
      DeviceApplicationError.noProcessID(bundleID: "com.example.launch"),
    ])
  func deviceObserverErrorsOtherThanUnsupportedAreReported(failure: DeviceApplicationError) async throws {
    let application = ControlledLaunchedApplication(observerError: failure)
    let (requests, client) = clientStream()
    defer { client.finish() }

    let error = await #expect(throws: DeviceApplicationError.self) {
      try await LaunchMethodHandler.waitForCompletion(
        application: application,
        requestStream: requests,
        consumers: [],
        cancellation: .init())
    }

    #expect(String(describing: error) == String(describing: Optional(failure)))
    #expect(await application.stopCalls == 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func rpcCancellationArrivingWithStopStillStopsTheApp() async throws {
    // The stop suspends until released, and would give up if it were cancelled.
    let release = AsyncEvent<Void>()
    let application = ControlledLaunchedApplication(stopRelease: release)
    let cancellation = ServerContext.RPCCancellationHandle()
    let requests = RequestStreamReader(RPCAsyncSequence(wrapping: StopThenCancellation(cancellation: cancellation)))
    let session = Task {
      try await LaunchMethodHandler.waitForCompletion(
        application: application,
        requestStream: requests,
        consumers: [],
        cancellation: cancellation)
    }
    try await application.stopStarted.wait()
    #expect(cancellation.isCancelled)

    release.happen()
    _ = try? await session.value

    #expect(await application.stopCalls == 1)
    #expect(application.stopCompleted.hasHappened)
  }
}

private actor ControlledLaunchedApplication: LaunchedApplication {
  let bundleID = "com.example.launch"
  let processIdentifier: pid_t = 123
  let exited = AsyncEvent<Void>()
  let observing = AsyncEvent<Void>()
  let observationFinished = AsyncEvent<Void>()
  private let observerError: (any Error)?
  private let stopError: (any Error)?
  private let stopRelease: AsyncEvent<Void>?
  let stopStarted = AsyncEvent<Void>()
  let stopCompleted = AsyncEvent<Void>()
  private(set) var stopCalls = 0
  private(set) var observationFinishedBeforeStop = false

  init(observerError: (any Error)? = nil, stopError: (any Error)? = nil, stopRelease: AsyncEvent<Void>? = nil) {
    self.observerError = observerError
    self.stopError = stopError
    self.stopRelease = stopRelease
  }

  func waitForTermination() async throws {
    observing.happen()
    defer { observationFinished.happen() }
    if let observerError {
      throw observerError
    }
    try await exited.wait()
  }

  func terminate() async throws {
    stopCalls += 1
    observationFinishedBeforeStop = observationFinished.hasHappened
    if let stopError {
      throw stopError
    }
    stopStarted.happen()
    try await stopRelease?.wait()
    stopCompleted.happen()
    exited.happen()
  }
}

/// Opens `observing` when the handler starts waiting for the wrapped consumer to finish forwarding.
private struct ObservedOutputCompletion: DataConsumerLifecycle {
  let consumer: ResponseForwardingConsumer
  let observing = AsyncEvent<Void>()

  var finishedConsuming: AsyncEvent<Void> {
    observing.happen()
    return consumer.finishedConsuming
  }
}

private enum LaunchFailure: Error {
  case stop
}

/// Cancels the RPC as it delivers Stop, like a client that disconnects right after sending it.
private struct StopThenCancellation: AsyncSequence, Sendable {
  let cancellation: ServerContext.RPCCancellationHandle

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(cancellation: cancellation)
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    typealias Failure = any Error

    let cancellation: ServerContext.RPCCancellationHandle

    mutating func next() async throws -> Idb_LaunchRequest? {
      cancellation.cancel()
      return .with { $0.stop = .init() }
    }
  }
}

private func clientStream() -> (RequestStreamReader<Idb_LaunchRequest>, AsyncThrowingStream<Idb_LaunchRequest, any Error>.Continuation) {
  let (stream, continuation) = AsyncThrowingStream.makeStream(of: Idb_LaunchRequest.self, throwing: (any Error).self)
  return (RequestStreamReader(RPCAsyncSequence(wrapping: stream)), continuation)
}
