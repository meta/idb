/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
import ShimulatorProtocol

public enum ShimulatorAudioCapture {
  public static let capability = "audio-capture"
  /// Set to `1` in a process's launch environment. The shim captures nothing in a process without it.
  public static let armedEnvironmentVariable = "IDB_AUDIO_CAPTURE"
}

public struct AudioCaptureParameters: Codable, Equatable, Sendable {
  /// A directory only this user can reach. Each captured process writes one file into it.
  public let directory: String

  public init(directory: String) {
    self.directory = directory
  }
}

public protocol AudioCaptureEngine {
  /// Starts keeping what every IO proc writes to its output, and discards anything kept before.
  func begin()
  /// Hands over what was kept since the last call, each stream's chunks in order, and returns the
  /// frames this capture has dropped so far.
  func drain(_ body: (AudioCaptureChunk) -> Void) -> UInt64
  /// Stops keeping output once the callbacks already writing have finished. What they kept waits
  /// for one more `drain`.
  func end()
}

/// Writes what the process plays into a file in the companion's directory, for as long as the
/// companion stays connected.
public final class AudioCaptureController: ShimulatorMethodHandler {
  public typealias Admission = AudioCaptureFileWriter

  private let engine: any AudioCaptureEngine
  private let processIdentifier: Int32

  public init(engine: any AudioCaptureEngine, processIdentifier: Int32 = getpid()) {
    self.engine = engine
    self.processIdentifier = processIdentifier
  }

  public func start(_ parameters: AudioCaptureParameters) throws -> AudioCaptureFileWriter {
    let writer = try AudioCaptureFileWriter(directory: parameters.directory, processIdentifier: processIdentifier)
    engine.begin()
    return writer
  }

  public func stop(_ writer: AudioCaptureFileWriter) {
    _ = drain(into: writer)
    engine.end()
    writer.finish(droppedFrames: drain(into: writer))
  }

  /// Accepted once the process has written audio, so the companion knows who played.
  public func poll(_ writer: AudioCaptureFileWriter) -> ShimulatorMethodUpdate? {
    _ = drain(into: writer)
    if let failure = writer.failure {
      return ShimulatorMethodUpdate(.failed, message: failure)
    }
    return writer.framesWritten > 0 ? ShimulatorMethodUpdate(.accepted) : nil
  }

  private func drain(into writer: AudioCaptureFileWriter) -> UInt64 {
    engine.drain { writer.append($0) }
  }
}
