/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import ShimulatorProtocol

public struct VideoInjectionProgress: Equatable, Sendable {
  public let generation: Int64
  public let started: Bool
  public let finished: Bool
  public let failed: Bool

  public init(generation: Int64, started: Bool, finished: Bool, failed: Bool) {
    self.generation = generation
    self.started = started
    self.finished = finished
    self.failed = failed
  }
}

/// The virtual camera the controller drives; the shim's is `VirtualCamera`.
public protocol VideoInjectionEngine {
  /// Plays `fileURL` on the back camera, and on the front one unless `frontFileURL` is given.
  /// Throws when a file holds no playable video.
  func play(fileURL: URL, frontFileURL: URL?, loops: Bool, generation: Int64) throws
  /// Returns the camera to its idle pattern.
  func clear()
  func pollProgress() -> VideoInjectionProgress
}

public final class VideoInjectionController: ShimulatorMethodHandler {
  public struct Admission: Sendable {
    let generation: Int64
  }

  private let engine: any VideoInjectionEngine
  private var nextGeneration: Int64 = 0
  private var activeGeneration: Int64?

  public init(engine: any VideoInjectionEngine) {
    self.engine = engine
  }

  public func start(_ parameters: VideoInjectionParameters) throws -> Admission {
    let generation = nextGeneration
    nextGeneration += 1
    try engine.play(
      fileURL: URL(fileURLWithPath: parameters.path), frontFileURL: parameters.frontPath.map { URL(fileURLWithPath: $0) },
      loops: parameters.loop, generation: generation)
    activeGeneration = generation
    return Admission(generation: generation)
  }

  /// A stop for an injection that a later one has replaced leaves the later one playing.
  public func stop(_ admission: Admission) {
    guard admission.generation == activeGeneration else { return }
    engine.clear()
    activeGeneration = nil
  }

  public func poll(_ admission: Admission) -> ShimulatorMethodUpdate? {
    let progress = engine.pollProgress()
    guard progress.generation == admission.generation else { return nil }
    if progress.failed {
      return ShimulatorMethodUpdate(.failed, message: "The injected video stopped decoding")
    }
    if progress.finished {
      return ShimulatorMethodUpdate(.completed)
    }
    return progress.started ? ShimulatorMethodUpdate(.accepted) : nil
  }
}
