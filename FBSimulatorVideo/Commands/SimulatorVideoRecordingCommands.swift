/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBControlCore
import FBSimulatorControl
import FBVideoCore
import Foundation
import os

/// Why a recording of a simulator's screen was refused.
enum SimulatorVideoRecordingError: Error, LocalizedError {
  case recordingLimitReached(limit: Int, recording: [String])
  case outputAlreadyBeingWritten(path: String)

  var errorDescription: String? {
    switch self {
    case let .recordingLimitReached(limit, recording):
      return
        "Cannot create a new video recording session: the simulator already records \(limit) (\(recording.joined(separator: ", "))), the most it records at once"
    case let .outputAlreadyBeingWritten(path):
      return "Cannot record to \(path): a recording is already writing to it"
    }
  }
}

/// The files that recordings started through `SimulatorVideoRecordingCommands` in this process are
/// writing, keyed by `resolved(_:)`. A recording's writer replaces whatever is at its path when its
/// first frame arrives, so a second recording into the same file would delete the first's.
final class RecordingOutputPaths: Sendable {

  static let shared = RecordingOutputPaths()

  private let paths = OSAllocatedUnfairLock<Set<String>>(initialState: [])

  /// The directory entry `path` names, as a key two spellings of one entry share. The path is made
  /// absolute against the working directory, the writers' own, with `.` and `..` removed. Its
  /// directory is keyed by device and inode, so symbolic links, `/private` and the case of the
  /// directory's name do not matter. The name is compared as the volume compares it: always without
  /// regard to Unicode normalization, and without regard to case on a volume that ignores case. A
  /// symbolic link at the name is not followed: a writer replaces the link, not the file it names.
  static func resolved(_ path: String) -> String {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let directory = url.deletingLastPathComponent().path
    var status = stat()
    guard unsafe stat(directory, &status) == 0 else {
      return url.path
    }
    let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
    let ignoresCase = unsafe pathconf(directory, _PC_CASE_SENSITIVE) == 0
    return "\(status.st_dev):\(status.st_ino)/\(ignoresCase ? name.folding(options: .caseInsensitive, locale: nil) : name)"
  }

  /// Claims the file `path` resolves to, returning the claimed path for `release`, or throws when a
  /// recording already writes to it.
  func claim(_ path: String) throws -> String {
    let resolved = Self.resolved(path)
    try paths.withLock { paths in
      guard paths.insert(resolved).inserted else {
        throw SimulatorVideoRecordingError.outputAlreadyBeingWritten(path: path)
      }
    }
    return resolved
  }

  func release(_ resolved: String) {
    _ = paths.withLock { $0.remove(resolved) }
  }
}

/// The recordings of one simulator that are running, by the file each writes.
final class ActiveSimulatorRecordings: Sendable {

  /// The most recordings of one simulator that run at once. Each has an encoder of its own.
  static let limit = 2

  private let recordings = OSAllocatedUnfairLock<[UUID: String]>(initialState: [:])
  private let outputPaths: RecordingOutputPaths

  init(outputPaths: RecordingOutputPaths = .shared) {
    self.outputPaths = outputPaths
  }

  /// A running recording's place: its token here and the output path it claimed.
  struct Reservation: Sendable {
    let token: UUID
    let resolvedPath: String
  }

  /// Counts a recording into `filePath` as running and claims its file, returning its reservation and
  /// the files of the recordings of this simulator already running. Refuses a file another recording
  /// writes to, and a recording beyond `limit`.
  func reserve(filePath: String) throws -> (reservation: Reservation, others: [String]) {
    let resolvedPath = try outputPaths.claim(filePath)
    let token = UUID()
    do {
      let others = try recordings.withLock { recordings in
        guard recordings.count < Self.limit else {
          throw SimulatorVideoRecordingError.recordingLimitReached(limit: Self.limit, recording: recordings.values.sorted())
        }
        let others = recordings.values.sorted()
        recordings[token] = filePath
        return others
      }
      return (Reservation(token: token, resolvedPath: resolvedPath), others)
    } catch {
      outputPaths.release(resolvedPath)
      throw error
    }
  }

  /// Gives back a recording's place and its file. Releasing a reservation twice releases nothing the
  /// second time.
  func release(_ reservation: Reservation) {
    let removed = recordings.withLock { $0.removeValue(forKey: reservation.token) }
    if removed != nil {
      outputPaths.release(reservation.resolvedPath)
    }
  }

  /// Reserves a recording into `filePath`, then starts it with `start`, giving the reservation back if
  /// the start fails.
  func start<Recording>(
    filePath: String, logger: any ControlCoreLogger, _ start: () async throws -> Recording
  ) async throws -> (reservation: Reservation, recording: Recording) {
    let (reservation, others) = try reserve(filePath: filePath)
    do {
      let recording = try await start()
      if !others.isEmpty {
        logger.log("Recording to \(filePath) alongside \(others.joined(separator: ", ")), each with an encoder of its own")
      }
      return (reservation, recording)
    } catch {
      release(reservation)
      throw error
    }
  }
}

/// Starts recordings of a simulator's screen. Each recording reads the framebuffer through a connection
/// of its own and writes a file of its own; at most `ActiveSimulatorRecordings.limit` run at once, and
/// none starts into a file another recording is writing.
public final class SimulatorVideoRecordingCommands: VideoRecordingCommands {

  private weak let simulator: Simulator?
  let active = ActiveSimulatorRecordings()

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  /// The default configuration for in-process recording when the caller supplies none: H264 at a
  /// constant frame rate (eager cadence), clean frames, default quality. The transport is irrelevant —
  /// recording muxes encoded samples to a file rather than byte-framing them.
  /// `RecordMethodHandler` mirrors the frame rate here as the meaning of an unset `fps` on the wire.
  private static var recordingConfiguration: VideoStreamConfiguration {
    VideoStreamConfiguration(
      format: VideoStreamFormat.compressedVideo(withCodec: .h264, transport: .annexB),
      framesPerSecond: 30,
      rateControl: nil,
      scaleFactor: nil,
      keyFrameRate: nil)
  }

  /// Simulator recording goes through `SimulatorVideo`, which reads the configuration it is
  /// handed rather than imposing a fixed one.
  public var honorsRecordingConfiguration: Bool { true }

  /// These commands record into an MP4, which `SimulatorVideo` can add an audio track to.
  public var acceptsAudio: Bool { true }

  public func start(toFile filePath: String) async throws -> any VideoRecording {
    try await start(toFile: filePath, configuration: Self.recordingConfiguration)
  }

  public func start(toFile filePath: String, configuration: VideoStreamConfiguration) async throws -> any VideoRecording {
    guard let simulator = self.simulator else {
      throw WeakTargetError.simulator
    }
    let (reservation, video) = try await active.start(filePath: filePath, logger: simulator.logger) {
      let framebuffer = try await simulator.framebuffer.connect(display: configuration.display)
      let video = SimulatorVideo(framebuffer: framebuffer, configuration: configuration, filePath: filePath, logger: simulator.logger)
      try await video.startRecording()
      return video
    }
    return SimulatorVideoRecording(commands: self, simulator: simulator, reservation: reservation, video: video)
  }
}

private struct SimulatorVideoRecording: VideoRecording {
  let commands: SimulatorVideoRecordingCommands
  // The running recordings are counted on `commands`, which its `Simulator` memoizes but only
  // weakly points back to. Holding the simulator keeps it the device's live instance while the
  // recording can be stopped, so a later start is counted against these commands rather than fresh
  // ones that know nothing of this recording.
  let simulator: Simulator
  let reservation: ActiveSimulatorRecordings.Reservation
  let video: SimulatorVideo

  func stop() async throws -> URL {
    // Counted, and its file claimed, until `stop()` returns, whether or not the file finalizes.
    defer { commands.active.release(reservation) }
    return try await video.stop()
  }

  func addAudio(fromWAV path: String, startingAtHostTime hostTime: UInt64) async throws -> AudioTrackPlacement {
    try await video.addAudio(fromWAV: path, startingAtHostTime: hostTime)
  }
}
