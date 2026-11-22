/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
@testable import FBSimulatorControl
import FBVideoCore
import Foundation
import Testing

@Suite
struct SimulatorFramebufferCommandsTests {

  private static func display(_ id: String) -> SimulatorDisplay {
    SimulatorDisplay(
      uniqueID: id, name: id, activity: .active, isPrimary: false,
      isIntegrated: true,
      bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 2, rotation: .upright)
  }

  private func framebuffer(
    _ display: DisplaySelection,
    displays: any DisplayCommands = DisplayCommandsDouble(.selected(display("inner"))),
    screens: FramebufferScreensDouble
  ) async throws -> FramebufferAttachment {
    try await SimulatorFramebufferCommands.framebuffer(display: display, displays: displays, screens: screens, logger: CapturingLogger()).attach()
  }

  @Test
  func theMainDisplayCapturesTheMainScreen() async throws {
    let screens = FramebufferScreensDouble("cover", "inner")
    let attachment = try await framebuffer(.main, screens: screens)
    defer { attachment.cancel() }

    #expect(screens.requested == [])
    #expect(screens.main.registeredTokens.count == 1)
  }

  @Test
  func aNamedDisplayCapturesItsScreen() async throws {
    let screens = FramebufferScreensDouble("cover", "inner")
    let attachment = try await framebuffer(.display(uniqueID: "inner"), screens: screens)
    defer { attachment.cancel() }

    #expect(screens.requested == ["inner"])
    #expect(screens.screens["inner"]?.registeredTokens.count == 1)
    #expect(screens.screens["cover"]?.registeredTokens.count == 0)
    #expect(screens.main.registeredTokens.count == 0)
  }

  @Test
  func aNamedDisplayAnnouncesTheConfiguration() async throws {
    let screens = FramebufferScreensDouble("cover", "inner")
    let attachment = try await framebuffer(.display(uniqueID: "cover"), screens: screens)
    defer { attachment.cancel() }

    let configuration = await firstConfiguration(of: attachment)
    #expect(configuration?.active == .identified(Self.display("inner")))
    #expect(screens.screens["inner"]?.registeredTokens.count == 0)
  }

  @Test
  func theActiveDisplayOfASoleDisplayAnnouncesTheConfiguration() async throws {
    let screens = FramebufferScreensDouble("lcd")
    let attachment = try await framebuffer(.active, displays: DisplayCommandsDouble(.sole(.identified(Self.display("lcd")))), screens: screens)
    defer { attachment.cancel() }

    let configuration = await firstConfiguration(of: attachment)
    #expect(configuration?.active == .identified(Self.display("lcd")))
  }

  @Test
  func aNamedDisplayIsCapturedWhileAnotherIsActive() async throws {
    let screens = FramebufferScreensDouble("cover", "inner")
    let attachment = try await framebuffer(.display(uniqueID: "cover"), screens: screens)
    defer { attachment.cancel() }

    #expect(screens.requested == ["cover"])
    #expect(screens.screens["cover"]?.registeredTokens.count == 1)
    #expect(screens.screens["inner"]?.registeredTokens.count == 0)
    #expect(screens.main.registeredTokens.count == 0)
  }

  @Test
  func aNamedDisplayWithNoScreenFails() async throws {
    let screens = FramebufferScreensDouble("cover")
    do {
      _ = try await framebuffer(.display(uniqueID: "inner"), screens: screens)
      Issue.record("Expected a named display with no screen to fail")
    } catch is FramebufferScreensDouble.NoScreen {}
    #expect(screens.main.registeredTokens.count == 0)
  }

  @Test
  func theActiveDisplayCapturesTheActiveOneOfSeveralScreens() async throws {
    let screens = FramebufferScreensDouble("cover", "inner")
    let attachment = try await framebuffer(.active, screens: screens)
    defer { attachment.cancel() }

    #expect(screens.requested == ["inner"])
    #expect(screens.screens["inner"]?.registeredTokens.count == 1)
    #expect(screens.main.registeredTokens.count == 0)
    let configuration = await firstConfiguration(of: attachment)
    #expect(configuration?.active == .identified(Self.display("inner")))
  }

  @Test
  func theActiveDisplayOfASoleDisplayCapturesTheMainScreen() async throws {
    let screens = FramebufferScreensDouble("lcd")
    let attachment = try await framebuffer(.active, displays: DisplayCommandsDouble(.sole(.identified(Self.display("lcd")))), screens: screens)
    defer { attachment.cancel() }

    #expect(screens.requested == [])
    #expect(screens.main.registeredTokens.count == 1)
  }

  @Test
  func theActiveDisplayCapturesTheMainScreenWhenTheDisplaysCannotBeRead() async throws {
    let screens = FramebufferScreensDouble("cover", "inner")
    let attachment = try await framebuffer(.active, displays: DisplayCommandsDouble([.success(.failed(.malformed("unreadable")))]), screens: screens)
    defer { attachment.cancel() }

    #expect(screens.main.registeredTokens.count == 1)
  }

  @Test
  func theActiveDisplayCapturesTheMainScreenWhenItHasNoScreen() async throws {
    let screens = FramebufferScreensDouble("cover")
    let attachment = try await framebuffer(.active, screens: screens)
    defer { attachment.cancel() }

    #expect(screens.requested == ["inner"])
    #expect(screens.main.registeredTokens.count == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func anActiveCaptureStartedOnTheMainScreenFollowsALaterPosture() async throws {
    let initialReports: [SimulatorDisplayReport] = [
      .failed(.unavailable("display service starting")),
      .transitioning(incoming: nil),
      .displays([]),
      .reporting(.sole(.identified(Self.display("cover")))),
    ]
    for initial in initialReports {
      let (pushes, push) = AsyncThrowingStream<SimulatorDisplayReport, any Error>.makeStream()
      let displays = DisplayCommandsDouble([.success(initial)], pushes: pushes)
      let screens = FramebufferScreensDouble("cover", "inner")
      screens.screens["inner"]?.immediateSurface = makeTestIOSurface(width: 20, height: 30)
      let attachment = try await framebuffer(.active, displays: displays, screens: screens)
      defer {
        attachment.cancel()
        push.finish()
      }

      #expect(screens.main.registeredTokens.count == 1)
      push.yield(.reporting(.selected(Self.display("inner"))))
      var announcedInner = false
      for await event in attachment.events {
        if case let .configurationChanged(configuration) = event {
          announcedInner = configuration.active == .identified(Self.display("inner"))
        }
        if case let .surfaceChanged(surface) = event {
          #expect(announcedInner, "The new display configuration must precede its frame")
          #expect(surface === screens.screens["inner"]?.immediateSurface)
          break
        }
      }
      #expect(screens.requested == ["inner"])
      #expect(screens.main.unregisteredTokens.count == 1)
      #expect(screens.screens["inner"]?.registeredTokens.count == 1)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSoleActiveDisplayWithTheSameIdentityDoesNotRebind() async throws {
    let (pushes, push) = AsyncThrowingStream<SimulatorDisplayReport, any Error>.makeStream()
    let cover = Self.display("cover")
    let displays = DisplayCommandsDouble([.success(.reporting(.sole(.identified(cover))))], pushes: pushes)
    let screens = FramebufferScreensDouble("cover")
    let attachment = try await framebuffer(.active, displays: displays, screens: screens)
    defer {
      attachment.cancel()
      push.finish()
    }
    _ = await firstConfiguration(of: attachment)

    let sameIdentity = SimulatorDisplay(
      uniqueID: cover.uniqueID, name: cover.name, activity: .active, isPrimary: true, isIntegrated: true,
      bounds: cover.bounds, scale: 3, rotation: .upright)
    push.yield(.reporting(.sole(.identified(sameIdentity))))
    var surfaceChanges = 0
    for await event in attachment.events {
      if case .surfaceChanged = event { surfaceChanges += 1 }
      if case let .configurationChanged(configuration) = event,
        configuration.active == .identified(sameIdentity)
      {
        break
      }
    }
    #expect(screens.requested.isEmpty)
    #expect(surfaceChanges == 0)
    #expect(screens.main.unregisteredTokens.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func aFallbackThatIdentifiesTheSameSurfaceDoesNotReportASurfaceSwap() async throws {
    let (pushes, push) = AsyncThrowingStream<SimulatorDisplayReport, any Error>.makeStream()
    let displays = DisplayCommandsDouble([.success(.failed(.unavailable("starting")))], pushes: pushes)
    let screens = FramebufferScreensDouble("lcd")
    let surface = makeTestIOSurface(width: 20, height: 30)
    screens.main.immediateSurface = surface
    screens.screens["lcd"]?.immediateSurface = surface
    let attachment = try await framebuffer(.active, displays: displays, screens: screens)
    defer {
      attachment.cancel()
      push.finish()
    }

    let lcd = Self.display("lcd")
    push.yield(.reporting(.sole(.identified(lcd))))
    _ = await firstConfiguration(of: attachment)
    let later = SimulatorDisplay(
      uniqueID: lcd.uniqueID, name: lcd.name, activity: .active, isPrimary: true, isIntegrated: true,
      bounds: lcd.bounds, scale: 3, rotation: .upright)
    push.yield(.reporting(.sole(.identified(later))))
    var surfaceChanges = 0
    for await event in attachment.events {
      if case .surfaceChanged = event { surfaceChanges += 1 }
      if case let .configurationChanged(configuration) = event, configuration.active == .identified(later) { break }
    }
    #expect(screens.requested == ["lcd"])
    #expect(screens.main.unregisteredTokens.count == 1)
    #expect(surfaceChanges == 0, "Identifying the mounted IOSurface must not trigger a video remount")
  }

  @Test
  func aConfigurationCapturesItsActiveDisplay() async throws {
    let screens = FramebufferScreensDouble("cover", "inner")
    let attachment = try await framebuffer(.configuration(generation: 1), screens: screens)
    defer { attachment.cancel() }

    #expect(screens.requested == ["inner"])
    #expect(screens.screens["inner"]?.registeredTokens.count == 1)
    #expect(screens.main.registeredTokens.count == 0)
  }

  @Test
  func aConfigurationEndsOnceItIsReplaced() async throws {
    let (pushes, push) = AsyncThrowingStream<SimulatorDisplayReport, any Error>.makeStream()
    let displays = DisplayCommandsDouble([.success(.reporting(.selected(Self.display("inner"))))], pushes: pushes)
    let attachment = try await framebuffer(.configuration(generation: 1), displays: displays, screens: FramebufferScreensDouble("cover", "inner"))
    defer { attachment.cancel() }

    var events: [FramebufferEvent] = []
    for await event in attachment.events {
      events.append(event)
      if events.count == 1 { push.yield(.reporting(.selected(Self.display("cover")))) }
    }
    guard events.count == 3, case let .configurationChanged(replacement) = events[1], case .ended(.changed) = events[2] else {
      Issue.record("Unexpected events \(events)")
      return
    }
    #expect(replacement.active == .identified(Self.display("cover")))
  }

  @Test
  func aReplacedConfigurationIsNotCaptured() async throws {
    let screens = FramebufferScreensDouble("cover", "inner")
    do {
      _ = try await framebuffer(.configuration(generation: 2), screens: screens)
      Issue.record("Expected a replaced configuration to fail")
    } catch SimulatorDisplayError.changed {}
    #expect(screens.requested == [])
  }

  @Test
  func theDisplayAVideoCapturesByDefault() async throws {
    let configuration = VideoStreamConfiguration(
      format: VideoStreamFormat.compressedVideo(withCodec: VideoStreamCodec.h264, transport: VideoStreamTransport.annexB),
      framesPerSecond: nil, rateControl: nil, scaleFactor: nil, keyFrameRate: nil)
    let screens = FramebufferScreensDouble("cover", "inner")
    let attachment = try await framebuffer(configuration.display, screens: screens)
    defer { attachment.cancel() }

    #expect(screens.requested == ["inner"])
    #expect(screens.screens["inner"]?.registeredTokens.count == 1)
    #expect(screens.main.registeredTokens.count == 0)
  }

  @Test
  func theDisplayAFramebufferCapturesByDefault() async throws {
    let screens = FramebufferScreensDouble("cover", "inner")
    let attachment = try await framebuffer(SimulatorFramebufferCommands.defaultDisplay, screens: screens)
    defer { attachment.cancel() }

    #expect(screens.requested == ["inner"])
    #expect(screens.screens["inner"]?.registeredTokens.count == 1)
    #expect(screens.main.registeredTokens.count == 0)
  }

  private func firstConfiguration(of attachment: FramebufferAttachment) async -> SimulatorDisplayConfiguration? {
    for await event in attachment.events {
      if case let .configurationChanged(configuration) = event { return configuration }
    }
    return nil
  }
}
