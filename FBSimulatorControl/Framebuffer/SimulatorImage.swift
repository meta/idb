/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreImage
import FBControlCore
import Foundation
import IOSurface

public actor SimulatorImage {

  private let logger: (any ControlCoreLogger)?
  private let imageGenerator: SurfaceImageGenerator
  private let framebuffer: Framebuffer
  private var attachment: FramebufferAttachment?
  private var eventTask: Task<Void, Never>?

  public init(framebuffer: Framebuffer, logger: (any ControlCoreLogger)?) {
    self.framebuffer = framebuffer
    self.logger = logger
    self.imageGenerator = SurfaceImageGenerator(purpose: "simulator_image", logger: logger)
  }

  deinit {
    // Finishing the stream ends the event task, which releases the attachment.
    attachment?.cancel()
    eventTask?.cancel()
  }

  public func image() throws -> CGImage? {
    try attachIfNeeded()
    return try imageGenerator.image()
  }

  /// Renders the current surface with `configuration` applied during the render rather than after
  /// it. See `SurfaceImageGenerator.image(configuration:screenScale:)`.
  public func image(configuration: ScreenshotConfiguration, screenScale: Double?, display: SimulatorDisplay? = nil) throws -> SurfaceImage? {
    try attachIfNeeded()
    return try imageGenerator.image(configuration: configuration, screenScale: screenScale, display: display)
  }

  /// One-time lazy attach; actor isolation makes this attach-exactly-once regardless of caller
  /// threading. The generator's surface is seeded synchronously from `initialSurface`, then kept
  /// current by a task consuming the attachment's ordered event stream.
  private func attachIfNeeded() throws {
    guard attachment == nil else {
      return
    }
    logger?.log("Image Generator \(imageGenerator) not attached, attaching")
    let attachment = try framebuffer.attach()
    self.attachment = attachment
    if let surface = attachment.initialSurface {
      logger?.log("Surface \(surface) immediately available, adding to Image Generator \(imageGenerator)")
      imageGenerator.updateSurface(surface)
    } else {
      logger?.log("Surface for ImageGenerator not immediately available")
    }
    eventTask = Task { [weak self] in
      for await event in attachment.events {
        guard case let .surfaceChanged(surface) = event else {
          continue
        }
        await self?.applySurface(surface)
      }
    }
  }

  private func applySurface(_ surface: IOSurface?) {
    imageGenerator.updateSurface(surface)
  }
}
