/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@testable import FBSimulatorControl
import Foundation
import Testing

private let inner = SimulatorDisplay(
  uniqueID: "inner", name: "inner", activity: .active, isPrimary: false, isIntegrated: true,
  bounds: CGRect(x: 0, y: 0, width: 1206, height: 2622), scale: 3, rotation: .upright)

private struct Failure: Error {}

private func capture(
  resolveDisplay: () async throws -> SimulatorDisplayResolution = { .target(.selected(inner)) },
  display: (SimulatorDisplay) async throws -> String = { "display \($0.uniqueID)" },
  mainScreen: () async throws -> String = { "main screen" },
  logger: CapturingLogger = CapturingLogger()
) async throws -> String {
  try await SimulatorScreenshotCommands.capture(resolveDisplay: resolveDisplay, display: display, mainScreen: mainScreen, logger: logger)
}

@Suite
struct SimulatorScreenshotCommandsTests {
  @Test
  func activeDisplayIsCaptured() async throws {
    let captured = try await capture()
    #expect(captured == "display inner")
  }

  @Test
  func activeDisplayFailures() async throws {
    let logger = CapturingLogger()
    let unselected = try await capture(resolveDisplay: { throw Failure() }, logger: logger)
    #expect(unselected == "main screen")
    let uncaptured = try await capture(display: { _ in throw Failure() }, logger: logger)
    #expect(uncaptured == "main screen")
    #expect(logger.messages.count == 2)
  }

  @Test
  func onlyAnIdentifiedActiveDisplayIsCaptured() async throws {
    let lcd = SimulatorDisplay(
      uniqueID: "lcd", name: "lcd", activity: .inactive, isPrimary: true, isIntegrated: true, bounds: inner.bounds, scale: 3,
      rotation: .upright)
    let resolutions: [(SimulatorDisplayResolution, String)] = [
      (.target(.sole(.identified(inner))), "display inner"),
      (.target(.sole(.identified(lcd))), "main screen"),
      (.target(.sole(.legacy(inner.geometry))), "main screen"),
      (.fallback(.noActiveIntegratedDisplay), "main screen"),
      (.transitioning, "main screen"),
    ]
    for (resolution, expected) in resolutions {
      let captured = try await capture(resolveDisplay: { resolution })
      #expect(captured == expected, "\(resolution)")
    }
  }

  @Test
  func theDisplayIsResolvedOnceATransitionSettles() async throws {
    let displays = DisplayCommandsDouble([.success(.transitioning(incoming: nil)), .success(.reporting(.selected(inner)))])
    let resolved = try await SimulatorScreenshotCommands.resolution(of: displays)
    #expect(resolved == .target(.selected(inner)))
  }

  @Test
  func cancellationIsNotAFallback() async {
    do {
      _ = try await capture(resolveDisplay: { throw CancellationError() })
      Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
  }

  @Test
  func mainScreenFailureFailsTheScreenshot() async {
    do {
      _ = try await capture(resolveDisplay: { throw Failure() }, mainScreen: { throw Failure() })
      Issue.record("Expected the main screen failure")
    } catch { #expect(error is Failure) }
  }
}
