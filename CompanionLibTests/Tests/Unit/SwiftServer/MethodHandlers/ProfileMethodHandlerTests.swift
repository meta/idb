/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBControlCore
import FBProfilingCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import SwiftProtobuf
import Testing

private let logger = ControlCoreGlobalConfiguration.systemLogger(writingToStderr: false, debugLogging: false)

/// A request stream the test controls: it yields what the test sends and only ends when the test finishes it.
private func clientStream() -> (RequestStreamReader<Idb_ProfileRequest>, AsyncThrowingStream<Idb_ProfileRequest, any Error>.Continuation) {
  let (stream, continuation) = AsyncThrowingStream.makeStream(of: Idb_ProfileRequest.self, throwing: (any Error).self)
  return (RequestStreamReader(RPCAsyncSequence(wrapping: stream)), continuation)
}

private let stopRequest = Idb_ProfileRequest.with { $0.stop = .init() }

private func sample(elapsedMs: Int64) -> ResourceSample {
  ResourceSample(
    pid: 42, processName: "Probe", timestampMs: 1000 + elapsedMs, elapsedMs: elapsedMs, cpuPct: nil, footprintBytes: 1, residentBytes: 2,
    instructions: 3, cycles: 4, diskBytesRead: 5, diskBytesWritten: 6, interruptWakeups: 7, packageIdleWakeups: 8, billedEnergyNanoJoules: 9)
}

/// A profiler that runs for `duration`, or until stopped, and reports which happened in its tool output.
private func operation(running duration: Duration, samples: [ResourceSample] = []) -> ProfileOperation {
  let (stream, continuation) = AsyncStream.makeStream(of: ResourceSample.self)
  return ProfileOperation(samples: stream) { stop in
    defer { continuation.finish() }
    for sample in samples {
      continuation.yield(sample)
    }
    let ending = try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        try await Task.sleep(for: duration)
        return "finished"
      }
      group.addTask {
        try await stop.wait()
        return "stopped"
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
    return ProfileResult(report: nil, toolOutput: Data(ending.utf8), artifact: nil)
  }
}

private func ending(of result: ProfileResult) -> String {
  String(decoding: result.toolOutput, as: UTF8.self)
}

@Suite
struct ProfileMethodHandlerTests {

  @Test
  func stopFromTheClientStopsTheProfiler() async throws {
    let (requests, client) = clientStream()
    client.yield(stopRequest)
    let collector = CollectingWriter<Idb_ProfileResponse>()

    let result = try await ProfileMethodHandler.profileUntilFinished(operation: operation(running: .seconds(3600)), requestStream: requests, responseStream: RPCWriter(wrapping: collector))

    #expect(ending(of: result) == "stopped")
  }

  @Test
  func closingTheRequestStreamLetsTheProfilerFinish() async throws {
    let (requests, client) = clientStream()
    client.finish()
    let collector = CollectingWriter<Idb_ProfileResponse>()

    let result = try await ProfileMethodHandler.profileUntilFinished(operation: operation(running: .milliseconds(200)), requestStream: requests, responseStream: RPCWriter(wrapping: collector))

    #expect(ending(of: result) == "finished")
  }

  @Test
  func aFailingProfilerEndsTheSessionWithoutAStop() async throws {
    let (requests, _) = clientStream()
    let collector = CollectingWriter<Idb_ProfileResponse>()
    let failing = ProfileOperation { throw ProfileError.toolFailed(tool: "leaks", exitCode: 1, stderr: "cannot examine process") }

    await #expect(throws: ProfileError.toolFailed(tool: "leaks", exitCode: 1, stderr: "cannot examine process")) {
      try await ProfileMethodHandler.profileUntilFinished(operation: failing, requestStream: requests, responseStream: RPCWriter(wrapping: collector))
    }
  }

  @Test
  func samplesAreStreamedAsTheyAreTaken() async throws {
    let (requests, client) = clientStream()
    client.finish()
    let collector = CollectingWriter<Idb_ProfileResponse>()

    _ = try await ProfileMethodHandler.profileUntilFinished(
      operation: operation(running: .milliseconds(10), samples: [sample(elapsedMs: 0), sample(elapsedMs: 100)]),
      requestStream: requests, responseStream: RPCWriter(wrapping: collector))

    #expect(collector.elements.map(\.sample.elapsedMs) == [0, 100])
    #expect(collector.elements.allSatisfy { !$0.sample.hasCpuPct })
  }

  @Test
  func aRequestOtherThanStopIsRejected() async throws {
    let (requests, client) = clientStream()
    client.yield(.with { $0.start = .init() })
    let collector = CollectingWriter<Idb_ProfileResponse>()

    await #expect(throws: RPCError.self) {
      try await ProfileMethodHandler.profileUntilFinished(operation: operation(running: .seconds(3600)), requestStream: requests, responseStream: RPCWriter(wrapping: collector))
    }
  }

  @Test
  func theArtifactIsSentAsASingleArchive() async throws {
    let artifact = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("profile-send-\(UUID().uuidString).memgraph")
    defer { try? FileManager.default.removeItem(at: artifact) }
    try Data(repeating: 0xAB, count: 64 * 1024).write(to: artifact)
    let collector = CollectingWriter<Idb_ProfileResponse>()

    try await ProfileMethodHandler.sendArtifact(atPath: artifact.path, responseStream: RPCWriter(wrapping: collector), logger: logger)

    let received = collector.elements.reduce(into: Data()) { $0.append($1.artifact.data) }
    #expect(gzipMembers(in: received) == 1)
  }
}
