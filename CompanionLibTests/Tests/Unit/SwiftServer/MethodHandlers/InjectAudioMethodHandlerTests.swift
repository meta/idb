/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBControlCore
import FBSimulatorCodeInjection
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import ShimulatorAudioInjectionCore
import SwiftProtobuf
import Testing

@Suite
final class InjectAudioMethodHandlerTests {
  private let temporaryDirectory = TemporaryDirectory(logger: ControlCoreGlobalConfiguration.defaultLogger)

  deinit { temporaryDirectory.cleanOnExit() }

  @Test(arguments: [
    (
      AudioInjectionError.alreadyRunning(udid: "U"), RPCError.Code.failedPrecondition,
      "Another audio injection is already playing into simulator U. Injections mix into one microphone input, so they are played one at a time; wait for the first to finish."
    ),
    (.unreadable(path: "/a.wav"), .invalidArgument, "Could not read /a.wav as audio to inject. It must be a 16-bit PCM WAV file."),
    (
      .fileUnreadable(path: "/a.wav", reason: "gone"), .invalidArgument,
      "Could not open /a.wav: gone. Nothing was read, so this says nothing about whether the file is audio the simulator could play."
    ),
    (
      .fileTooLarge(path: "/a.wav", size: 9, maximum: 8), .invalidArgument,
      "Could not inject /a.wav because it is 9 bytes; the maximum audio payload is 8 bytes."
    ),
    (
      .shimMissing(item: "libShimulator-iOS.dylib"), .internalError,
      "The companion is missing libShimulator-iOS.dylib from its Resources directory, so audio injection cannot be prepared."
    ),
    (
      .unclaimed(udid: "U", preparationFailure: nil), .failedPrecondition,
      "Nothing in simulator U picked the audio up within 10 seconds. Launch the app under test through idb so microphone injection is prepared at process startup, have it start recording, and inject again. An already-running app cannot be armed without a relaunch."
    ),
    (
      .unclaimed(udid: "U", preparationFailure: "no shim"), .failedPrecondition,
      "Nothing in simulator U picked the audio up within 10 seconds. The last app launch through idb could not be prepared for microphone injection, so it could not hear injected audio: no shim. Launch the app under test through idb so microphone injection is prepared at process startup, have it start recording, and inject again. An already-running app cannot be armed without a relaunch."
    ),
    (
      .didNotFinish(udid: "U"), .failedPrecondition,
      "The audio injected into simulator U started playing but never finished. An app hears injected audio only while it is recording: if it stopped recording part-way through, the rest of the audio has nowhere to go."
    ),
    (.socketUnavailable(path: "/s.sock", reason: "busy"), .internalError, "Could not serve audio injection at /s.sock: busy"),
    (
      .unsupportedPlatform(udid: "U"), .failedPrecondition,
      "Audio injection supports iPhone and iPad simulators. Simulator U is neither, and the shim is built for the iOS simulator only."
    ),
    (
      .failedInGuest(udid: "U", process: "App", reason: "denied"), .failedPrecondition,
      "App in simulator U rejected the audio injection. Guest error: denied"
    ),
    (
      .armingFailed(udid: "U", stderr: "launchctl failed"), .internalError,
      "Could not prepare an app's microphone-injection environment on simulator U: launchctl failed"
    ),
  ])
  func everyInjectionFailureEndsTheRPCWithItsStatusAndMessage(_ error: AudioInjectionError, _ code: RPCError.Code, _ message: String) {
    let rpcError = InjectAudioMethodHandler.rpcError(for: error)
    #expect(rpcError.code == code)
    #expect(rpcError.message == message)
  }

  @Test
  func mapsExpectedAudioFailuresToClientStatuses() {
    #expect(InjectAudioMethodHandler.rpcError(for: .unreadable(path: "/tmp/not.wav")).code == .invalidArgument)
    #expect(InjectAudioMethodHandler.rpcError(for: .alreadyRunning(udid: "simulator")).code == .failedPrecondition)
    #expect(InjectAudioMethodHandler.rpcError(for: .shimMissing(item: "shim")).code == .internalError)
    #expect(
      InjectAudioMethodHandler.rpcError(for: IDBCommandError.notASimulator(targetDescription: "physical device"))?.code
        == .failedPrecondition)
    #expect(InjectAudioMethodHandler.rpcError(for: IDBCommandError.invalidURL(urlString: "not a URL")) == nil)
  }

  @Test
  func materializesRawAudioDataAsOneTemporaryFile() async throws {
    let observed = try await withAudioFile([.data(Data([0, 1])), .data(Data([2, 3]))]) { url in
      #expect(url.lastPathComponent == "input.wav")
      return try Data(contentsOf: url)
    }
    #expect(observed == Data([0, 1, 2, 3]))
  }

  @Test
  func acceptsExactlyOneLocalRegularFile() async throws {
    let file = try makeFile()
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(try await withAudioFile([.filePath(file.path)]) { $0 } == file)
  }

  @Test
  func rejectsAdditionalFramesAfterALocalPath() async throws {
    let file = try makeFile()
    defer { try? FileManager.default.removeItem(at: file) }

    let error = await #expect(throws: RPCError.self) {
      try await self.withAudioFile([.filePath(file.path), .filePath(file.path)]) { _ in }
    }
    #expect(error?.message == "Audio injection requires exactly one local file path")
  }

  @Test
  func rejectsNonDataFramesAndMissingFiles() async {
    for sources: [Idb_Payload.OneOf_Source] in [
      [.data(Data([0, 1])), .filePath("/tmp/input.wav")], [.filePath("/tmp/idb-inject-audio-missing.wav")],
    ] {
      await #expect(throws: RPCError.self) { try await self.withAudioFile(sources) { _ in } }
    }
  }

  @Test
  func rejectsRemoteAudioOverThePayloadLimit() async {
    let maximumBytes = ShimulatorAudioInjection.maximumPayloadBytes
    for frames in [[Data(count: maximumBytes + 1)], [Data(count: maximumBytes), Data([0])]] {
      await #expect(throws: RPCError.self) {
        try await self.withAudioFile(frames.map { .data($0) }) { _ in Issue.record("Audio over the limit was accepted") }
      }
    }
  }

  @Test
  func cancellationAfterRequestEOFJoinsInjectionAndRemovesTemporaryFile() async throws {
    let cancellation = ServerContext.RPCCancellationHandle()
    let (started, startContinuation) = AsyncStream<URL>.makeStream()
    let (finished, finishContinuation) = AsyncStream<Bool>.makeStream()
    let requests = requestStream([.data(Data([0, 1, 2, 3]))])
    let temporaryDirectory = temporaryDirectory
    async let result: Void = InjectAudioMethodHandler.withAudioInjection(
      from: requests,
      temporaryDirectory: temporaryDirectory, cancellation: cancellation
    ) { url in
      defer {
        finishContinuation.yield(true)
        finishContinuation.finish()
      }
      startContinuation.yield(url)
      startContinuation.finish()
      try await Task.sleep(nanoseconds: 30_000_000_000)
    }
    var starts = started.makeAsyncIterator()
    let url = try #require(await starts.next())
    #expect(FileManager.default.fileExists(atPath: url.path))
    cancellation.cancel()
    do {
      try await result
      Issue.record("RPC cancellation did not cancel injection")
    } catch is CancellationError {
    }
    var finishes = finished.makeAsyncIterator()
    #expect(await finishes.next() == true)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  private func withAudioFile<T>(
    _ sources: [Idb_Payload.OneOf_Source], _ body: (URL) async throws -> T
  ) async throws -> T {
    try await InjectAudioMethodHandler.withAudioFile(
      from: requestStream(sources), temporaryDirectory: temporaryDirectory, body)
  }

  private func makeFile() throws -> URL {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("idb-inject-audio-\(UUID().uuidString).wav")
    try Data([0, 1, 2, 3]).write(to: file)
    return file
  }

  private func requestStream(
    _ sources: [Idb_Payload.OneOf_Source]
  ) -> RequestStreamReader<Idb_InjectAudioRequest> {
    let stream = AsyncThrowingStream<Idb_InjectAudioRequest, any Error> { continuation in
      for source in sources {
        continuation.yield(
          Idb_InjectAudioRequest.with {
            $0.payload = Idb_Payload.with { $0.source = source }
          })
      }
      continuation.finish()
    }
    return RequestStreamReader(RPCAsyncSequence(wrapping: stream))
  }
}
