/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBControlCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import Testing

private actor PausedScreenshotObservation {
  let entered = AsyncEvent<Void>()
  let finished = AsyncEvent<Void>()
  private let never = AsyncEvent<Void>()
  private let pauseAt: Int
  private(set) var calls = 0

  init(pauseAt: Int) { self.pauseAt = pauseAt }

  func observe() async throws -> ScreenshotAppSample {
    calls += 1
    if calls == pauseAt {
      entered.happen()
      defer { finished.happen() }
      try await never.wait()
    }
    return ScreenshotAppSample(
      displayID: "screen",
      observation: .with {
        $0.processID = 42
        $0.bundleID = "app"
        $0.installedBuildUuid = "build"
        $0.observedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
      })
  }
}

@Suite
struct ScreenshotRPCCancellationTests {
  private func image() -> ScreenshotResult {
    ScreenshotResult(
      imageData: Data([1]), format: .png, size: CGSize(width: 1, height: 1),
      sourceSize: CGSize(width: 1, height: 1), screenScale: 1, displayID: "screen")
  }

  @Test func anAlreadyCancelledRPCDoesNotStartCapture() async {
    let cancellation = ServerContext.RPCCancellationHandle()
    cancellation.cancel()
    await #expect(throws: CancellationError.self) {
      try await ScreenshotMethodHandler.takeScreenshot(
        includeAppContext: true, targetUDID: "target", cancellation: cancellation,
        observe: {
          Issue.record("A cancelled RPC started observation")
          return try await PausedScreenshotObservation(pauseAt: 2).observe()
        },
        capture: {
          Issue.record("A cancelled RPC started capture")
          return image()
        })
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [1, 2])
  func rpcCancellationJoinsBeforeAndAfterObservation(_ pauseAt: Int) async throws {
    let cancellation = ServerContext.RPCCancellationHandle()
    let observation = PausedScreenshotObservation(pauseAt: pauseAt)
    let captured = AsyncEvent<Void>()
    let pixels = image()
    let operation = Task {
      try await ScreenshotMethodHandler.takeScreenshot(
        includeAppContext: true, targetUDID: "target", cancellation: cancellation,
        observe: { try await observation.observe() },
        capture: {
          captured.happen()
          return pixels
        })
    }
    defer { operation.cancel() }
    try await observation.entered.wait()
    #expect(captured.hasHappened == (pauseAt == 2))
    cancellation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(observation.finished.hasHappened, "The cancelled observation completed cleanup before the handler returned")
    #expect(await observation.calls == pauseAt)
  }
}
