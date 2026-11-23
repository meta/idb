/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreVideo
import FBControlCore
@testable import FBSimulatorControl
import Foundation
import IOSurface

/// A fake `FramebufferSurface` that lets tests drive `Framebuffer` without the private
/// CoreSimulator renderable. Tests call `ioSurfaceChanged` / `frameRendered` to simulate callbacks.
final class FakeFramebufferSurface: FramebufferSurface {
  var immediateSurface: IOSurface?
  /// Reported to each registration as it registers, as a surface that knows its display configuration does.
  var configurationAtRegistration: SimulatorDisplayConfiguration?
  var registerError: Error?

  private(set) var ioSurfaceChanged: ((IOSurface?) -> Void)?
  private(set) var frameRendered: (() -> Void)?
  private(set) var configurationChanged: ((SimulatorDisplayConfiguration) -> Void)?
  private(set) var registeredTokens: [UUID] = []
  private(set) var unregisteredTokens: [UUID] = []

  func immediatelyAvailableSurface() -> IOSurface? {
    immediateSurface
  }

  func registerCallbacks(
    token: UUID,
    ioSurfaceChanged: @escaping (IOSurface?) -> Void,
    frameRendered: @escaping () -> Void,
    configurationChanged: @escaping (SimulatorDisplayConfiguration) -> Void
  ) throws {
    if let registerError {
      throw registerError
    }
    registeredTokens.append(token)
    self.ioSurfaceChanged = ioSurfaceChanged
    self.frameRendered = frameRendered
    self.configurationChanged = configurationChanged
    if let configurationAtRegistration {
      configurationChanged(configurationAtRegistration)
    }
  }

  func unregisterCallbacks(token: UUID) {
    unregisteredTokens.append(token)
  }

  /// Simulates the display surface letting go of the registered callback blocks (as the real
  /// CoreSimulator proxy does at its own teardown), dropping the callback-held references to the
  /// consumer so lifetime tests can observe what else still retains it.
  func releaseCallbacks() {
    ioSurfaceChanged = nil
    frameRendered = nil
  }
}

/// Screens keyed by display UUID, recording which were asked for. A display without one fails to locate.
// SAFETY: The requests are guarded by the lock; the screens are only read.
// patternlint-disable-next-line unchecked-sendable
final class FramebufferScreensDouble: FramebufferScreens, @unchecked Sendable {
  struct NoScreen: Error {}

  let main = FakeFramebufferSurface()
  let screens: [String: FakeFramebufferSurface]
  private let lock = NSLock()
  private var requests: [String] = []

  init(_ uniqueIDs: String...) {
    screens = Dictionary(uniqueKeysWithValues: uniqueIDs.map { ($0, FakeFramebufferSurface()) })
  }

  init(screens: [String: FakeFramebufferSurface]) {
    self.screens = screens
  }

  var requested: [String] { lock.withLock { requests } }

  func mainScreen() throws -> any FramebufferSurface {
    main
  }

  func screen(uniqueID: String) async throws -> any FramebufferSurface {
    lock.withLock { requests.append(uniqueID) }
    guard let screen = screens[uniqueID] else { throw NoScreen() }
    return screen
  }
}

/// Creates a small BGRA IOSurface for tests. The full BGRA property set (format, row alignment,
/// allocation size) makes the surface consumable by CoreImage and wrappable by
/// `CVPixelBufferCreateWithIOSurface` (which rejects a surface with no pixel format), not just
/// passable as a reference.
func makeTestIOSurface(width: Int = 16, height: Int = 16, pixelFormat: OSType = kCVPixelFormatType_32BGRA) -> IOSurface {
  let bytesPerElement = 4
  let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * bytesPerElement)
  let properties: [IOSurfacePropertyKey: Any] = [
    .width: width,
    .height: height,
    .bytesPerElement: bytesPerElement,
    .bytesPerRow: bytesPerRow,
    .pixelFormat: pixelFormat,
    .allocSize: bytesPerRow * height,
  ]
  guard let surface = IOSurface(properties: properties) else {
    fatalError("Failed to create test IOSurface")
  }
  return surface
}

/// Creates a test IOSurface whose contents come from `pixel`, called with top-left coordinates and
/// returning BGRA components. A pattern that varies along both axes lets a test catch an image that
/// has been flipped or transposed, not just one that is the wrong size.
func makeTestIOSurface(
  width: Int,
  height: Int,
  pixel: (_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)
) throws -> IOSurface {
  let surface = makeTestIOSurface(width: width, height: height)
  try surface.lock(options: [], seed: nil)
  defer { try? surface.unlock(options: [], seed: nil) }
  let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
  let bytesPerRow = surface.bytesPerRow
  for y in 0..<height {
    for x in 0..<width {
      let offset = y * bytesPerRow + x * 4
      let components = pixel(x, y)
      base[offset] = components.b
      base[offset + 1] = components.g
      base[offset + 2] = components.r
      base[offset + 3] = components.a
    }
  }
  return surface
}
