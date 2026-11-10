/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Dispatch
import FBControlCore
import FBSimulatorAX
import FBSimulatorControl
import Foundation
import IDBGRPCSwift

struct ScreenshotAppSample: Sendable {
  let displayID: String
  let observation: Idb_ScreenshotAppObservation
}

enum ScreenshotAppContextFailure: String, Error, LocalizedError {
  case unsupportedTarget = "unsupported_target"
  case displayUnavailable = "display_unavailable"
  case foregroundUnavailable = "foreground_unavailable"
  case appUnavailable = "app_unavailable"
  case buildUnavailable = "build_unavailable"
  case contextChanged = "context_changed"

  var errorDescription: String? { "Screenshot app context is unavailable: \(rawValue)" }
}

/// Samples the companion's simulator, never a caller's app name or checkout.
enum ScreenshotAppObserver {
  static func observe(_ simulator: Simulator) async throws -> ScreenshotAppSample {
    let foreground: FrontmostApplicationObservation
    do {
      foreground = try await simulator.observeFrontmostApplication(
        timing: SimulatorAccessibilityTiming(elementTimeout: 1, queryTimeout: 2))
    } catch {
      try Task.checkCancellation()
      if error is CancellationError { throw error }
      throw error is SimulatorDisplayError ? ScreenshotAppContextFailure.displayUnavailable : ScreenshotAppContextFailure.foregroundUnavailable
    }
    let app: InstalledApplication
    do {
      let running = try await simulator.application.running()
      let bundleID = try bundleID(for: foreground.processIdentifier, in: running)
      app = try await simulator.application.installed(bundleID: bundleID)
    } catch {
      try Task.checkCancellation()
      if error is CancellationError { throw error }
      throw ScreenshotAppContextFailure.appUnavailable
    }
    let uuid = await DispatchQueue.global(qos: .utility).perform {
      BundleBuildIdentity.buildUUID(inBundleAt: app.bundle.path)
    }
    try Task.checkCancellation()
    return ScreenshotAppSample(
      displayID: foreground.displayID,
      observation: .with {
        $0.appName = app.bundle.name
        $0.bundleID = app.bundle.identifier
        $0.installedBuildUuid = uuid ?? ""
        $0.processID = UInt64(foreground.processIdentifier)
        $0.observedAtMs = ScreenshotAppContextCapture.nowMilliseconds()
      })
  }

  static func bundleID(for pid: pid_t, in running: [String: pid_t]) throws -> String {
    let matches = running.filter { $0.value == pid }.map(\.key)
    guard pid > 0, matches.count == 1, let bundleID = matches.first, !bundleID.isEmpty else {
      throw ScreenshotAppContextFailure.appUnavailable
    }
    return bundleID
  }
}

/// The observations belong to this capture attempt. Agreement is descriptive, not atomic provenance.
enum ScreenshotAppContextCapture {
  typealias Observe = () async throws -> ScreenshotAppSample

  static func nowMilliseconds() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
  }

  static func take(
    includeAppContext: Bool,
    targetUDID: String,
    observe: Observe?,
    capture: () async throws -> ScreenshotResult,
    now: () -> Int64 = nowMilliseconds
  ) async throws -> Idb_ScreenshotResponse {
    guard includeAppContext else {
      return ScreenshotRequestTranslation.response(from: try await capture())
    }
    let before = try await sample(using: observe)
    let started = now()
    let result = try await capture()
    try Task.checkCancellation()
    let finished = now()
    let after = try await sample(using: observe)
    var response = ScreenshotRequestTranslation.response(from: result)
    response.appContext = .with {
      $0.version = 1
      $0.targetUdid = targetUDID
      $0.displayID = result.displayID ?? ""
      $0.captureStartedAtMs = started
      $0.captureFinishedAtMs = finished
      if case let .success(sample) = before { $0.before = sample.observation }
      if case let .success(sample) = after { $0.after = sample.observation }
      if let failure = failure(before: before, after: after, result: result, started: started, finished: finished) {
        $0.state = .unavailable
        $0.reason = failure.rawValue
      } else {
        $0.state = .matchingObservations
      }
    }
    return response
  }

  private static func sample(using observe: Observe?) async throws -> Result<ScreenshotAppSample, ScreenshotAppContextFailure> {
    try Task.checkCancellation()
    guard let observe else { return .failure(.unsupportedTarget) }
    do {
      let sample = try await observe()
      try Task.checkCancellation()
      return .success(sample)
    } catch {
      try Task.checkCancellation()
      if error is CancellationError { throw error }
      return .failure(error as? ScreenshotAppContextFailure ?? .foregroundUnavailable)
    }
  }

  private static func failure(
    before: Result<ScreenshotAppSample, ScreenshotAppContextFailure>,
    after: Result<ScreenshotAppSample, ScreenshotAppContextFailure>,
    result: ScreenshotResult, started: Int64, finished: Int64
  ) -> ScreenshotAppContextFailure? {
    guard case let .success(first) = before else {
      if case let .failure(reason) = before { return reason }
      return .foregroundUnavailable
    }
    guard case let .success(last) = after else {
      if case let .failure(reason) = after { return reason }
      return .foregroundUnavailable
    }
    guard let display = result.displayID, !display.isEmpty else { return .displayUnavailable }
    let a = first.observation
    let b = last.observation
    guard first.displayID == display, last.displayID == display,
      a.processID > 0, a.processID == b.processID,
      !a.bundleID.isEmpty, a.bundleID == b.bundleID, a.appName == b.appName,
      a.observedAtMs > 0, a.observedAtMs <= started, started <= finished, finished <= b.observedAtMs
    else { return .contextChanged }
    guard !a.installedBuildUuid.isEmpty, !b.installedBuildUuid.isEmpty else { return .buildUnavailable }
    guard a.installedBuildUuid == b.installedBuildUuid else { return .contextChanged }
    return nil
  }
}
