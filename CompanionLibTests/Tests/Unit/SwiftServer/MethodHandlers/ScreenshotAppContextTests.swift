/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBControlCore
import Foundation
import IDBGRPCSwift
import Testing

@Suite
struct ScreenshotAppContextTests {
  private func image(displayID: String? = "screen") -> ScreenshotResult {
    ScreenshotResult(
      imageData: Data([1, 2, 3]), format: .png, size: CGSize(width: 2, height: 3),
      sourceSize: CGSize(width: 4, height: 6), screenScale: 2, displayID: displayID)
  }

  private func sample(at timestamp: Int64, displayID: String = "screen", pid: UInt64 = 42, bundleID: String = "app", uuid: String = "build") -> ScreenshotAppSample {
    ScreenshotAppSample(
      displayID: displayID,
      observation: .with {
        $0.appName = "Application"
        $0.bundleID = bundleID
        $0.installedBuildUuid = uuid
        $0.processID = pid
        $0.observedAtMs = timestamp
      })
  }

  private func capture(before: ScreenshotAppSample, after: ScreenshotAppSample, displayID: String? = "screen") async throws -> Idb_ScreenshotResponse {
    var observations = [before, after]
    var timestamps: [Int64] = [101, 102]
    return try await ScreenshotAppContextCapture.take(
      includeAppContext: true, targetUDID: "target",
      observe: { observations.removeFirst() },
      capture: { image(displayID: displayID) }, now: { timestamps.removeFirst() })
  }

  @Test func unsetRequestPreservesTheOldPathAndBytes() async throws {
    let response = try await ScreenshotAppContextCapture.take(
      includeAppContext: false, targetUDID: "target",
      observe: {
        Issue.record("An unset request must not observe the app")
        return sample(at: 100)
      },
      capture: { image() },
      now: {
        Issue.record("An unset request must not read the clock")
        return 0
      })
    #expect(!response.hasAppContext)
    #expect(response.imageData == Data([1, 2, 3]))
    #expect(response.destination.width == 2)
    #expect(response.source.height == 6)
    #expect(response.screenScale == 2)
  }

  @Test func observationsBracketOnlyThisCaptureAttempt() async throws {
    var calls: [String] = []
    var samples = [sample(at: 100), sample(at: 103)]
    var timestamps: [Int64] = [101, 102]
    let response = try await ScreenshotAppContextCapture.take(
      includeAppContext: true, targetUDID: "target",
      observe: {
        calls.append("observe")
        return samples.removeFirst()
      },
      capture: {
        calls.append("capture")
        return image()
      }, now: { timestamps.removeFirst() })
    #expect(calls == ["observe", "capture", "observe"])
    #expect(response.appContext.state == .matchingObservations)
    #expect(response.appContext.reason.isEmpty)
    #expect(response.appContext.targetUdid == "target")
    #expect(response.appContext.displayID == "screen")
    #expect(response.appContext.captureStartedAtMs == 101)
    #expect(response.appContext.captureFinishedAtMs == 102)
    #expect(response.appContext.before.observedAtMs == 100)
    #expect(response.appContext.after.observedAtMs == 103)
    #expect(response.imageData == Data([1, 2, 3]))
  }

  @Test func unsupportedTargetsStillReturnPixels() async throws {
    let response = try await ScreenshotAppContextCapture.take(
      includeAppContext: true, targetUDID: "device", observe: nil, capture: { image(displayID: nil) })
    #expect(response.appContext.state == .unavailable)
    #expect(response.appContext.reason == "unsupported_target")
    #expect(!response.appContext.hasBefore)
    #expect(!response.appContext.hasAfter)
    #expect(response.imageData == Data([1, 2, 3]))
  }

  @Test(arguments: [ScreenshotAppContextFailure.foregroundUnavailable, .appUnavailable, .displayUnavailable])
  func failedObservationsDoNotFailTheScreenshot(_ failure: ScreenshotAppContextFailure) async throws {
    let response = try await ScreenshotAppContextCapture.take(
      includeAppContext: true, targetUDID: "target", observe: { throw failure }, capture: { image() })
    #expect(response.appContext.state == .unavailable)
    #expect(response.appContext.reason == failure.rawValue)
    #expect(response.imageData == Data([1, 2, 3]))
  }

  @Test func changedContextsAndInvalidClocksAreNotMatchingObservations() async throws {
    let changed = [
      sample(at: 103, displayID: "other"),
      sample(at: 103, pid: 43),
      sample(at: 103, bundleID: "other"),
      sample(at: 103, uuid: "other"),
      sample(at: 100),
    ]
    for after in changed {
      let response = try await capture(before: sample(at: 100), after: after)
      #expect(response.appContext.state == .unavailable)
      #expect(response.appContext.reason == "context_changed")
    }
    let lateBefore = try await capture(before: sample(at: 102), after: sample(at: 103))
    #expect(lateBefore.appContext.reason == "context_changed")
  }

  @Test func missingCaptureDisplayOrBuildLeavesContextUnavailable() async throws {
    let noDisplay = try await capture(before: sample(at: 100), after: sample(at: 103), displayID: nil)
    #expect(noDisplay.appContext.reason == "display_unavailable")
    let noBuild = try await capture(before: sample(at: 100, uuid: ""), after: sample(at: 103, uuid: ""))
    #expect(noBuild.appContext.reason == "build_unavailable")
  }

  @Test func cancellationStopsCaptureRatherThanBecomingUnavailable() async {
    do {
      _ = try await ScreenshotAppContextCapture.take(
        includeAppContext: true, targetUDID: "target", observe: { throw CancellationError() },
        capture: {
          Issue.record("Cancellation must stop capture")
          return image()
        })
      Issue.record("Expected cancellation")
    } catch {
      #expect(error is CancellationError)
    }
  }

  @Test func screenshotFailuresPropagateWithoutAnAfterObservation() async {
    var observations = 0
    do {
      _ = try await ScreenshotAppContextCapture.take(
        includeAppContext: true, targetUDID: "target",
        observe: {
          observations += 1
          return sample(at: 100)
        },
        capture: { throw ScreenshotRenderError.unreadableImageData })
      Issue.record("Expected the screenshot failure")
    } catch {
      guard case ScreenshotRenderError.unreadableImageData = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(observations == 1)
    }
  }

  @Test func processMappingRequiresExactlyOneNamedBundle() throws {
    #expect(try ScreenshotAppObserver.bundleID(for: 42, in: ["app": 42, "background": 43]) == "app")
    #expect(throws: ScreenshotAppContextFailure.self) { try ScreenshotAppObserver.bundleID(for: 42, in: [:]) }
    #expect(throws: ScreenshotAppContextFailure.self) { try ScreenshotAppObserver.bundleID(for: 42, in: ["a": 42, "b": 42]) }
    #expect(throws: ScreenshotAppContextFailure.self) { try ScreenshotAppObserver.bundleID(for: 0, in: ["app": 0]) }
  }

  @Test func screenshotContextUsesAdditiveWireFields() throws {
    #expect(try Idb_ScreenshotRequest().serializedData().isEmpty)
    let request = Idb_ScreenshotRequest.with { $0.includeAppContext = true }
    #expect(try request.serializedData() == Data([0x38, 0x01]))
    let response = Idb_ScreenshotResponse.with { $0.appContext = .with { $0.version = 1 } }
    #expect(try response.serializedData() == Data([0x32, 0x02, 0x08, 0x01]))
    #expect(!Idb_CompanionInfo().screenshotAppContext)
  }
}
