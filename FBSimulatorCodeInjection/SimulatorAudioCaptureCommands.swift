/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBControlCore
@preconcurrency import FBSimulatorControl
import Foundation
internal import ShimulatorAudioInjectionCore
internal import ShimulatorProtocol
import SimulatorIPC

/// Why capturing what a simulator's apps play failed.
public enum AudioCaptureError: Error, LocalizedError {
  case unsupportedPlatform(udid: String)
  case alreadyRunning(udid: String)
  case socketUnavailable(path: String, reason: String)
  case mixUnwritable(path: String, reason: String)
  case mixTooLong(frames: Int)
  case corruptCapture(path: String)

  public var errorDescription: String? {
    switch self {
    case let .unsupportedPlatform(udid):
      return
        "Audio capture supports iPhone and iPad simulators. Simulator \(udid) is neither, and the shim is built for the iOS simulator only."
    case let .alreadyRunning(udid):
      return "Another audio capture is already running on simulator \(udid). Stop it before starting another."
    case let .socketUnavailable(path, reason):
      return "Could not serve audio capture at \(path): \(reason)"
    case let .mixUnwritable(path, reason):
      return "Could not write the captured audio to \(path): \(reason)"
    case let .mixTooLong(frames):
      return "The captured audio is \(frames) frames long, more than one WAV file can hold"
    case let .corruptCapture(path):
      return "The audio captured in \(path) is placed at a time that is not a number, so it cannot be mixed"
    }
  }
}

/// Captures what apps on a simulator play, through the Shimulator shim microphone injection inserts
/// into their launch.
///
/// Only a process idb launched is captured: `SimulatorAudioInjectionCommands.appLaunchEnvironment(_:)`
/// arms it for capture with `IDB_AUDIO_CAPTURE`, and it captures nothing until a capture starts.
public struct SimulatorAudioCaptureCommands {

  let simulator: Simulator

  /// Starts keeping what every armed process plays, until the session is stopped.
  public func start() async throws -> AudioCaptureSession {
    guard [.iPhone, .iPad].contains(simulator.productFamily) else {
      throw AudioCaptureError.unsupportedPlatform(udid: simulator.udid)
    }
    let socketDirectory = ShimulatorWireProtocol.socketDirectory()
    do {
      try IPCSocket.requirePrivateDirectory(socketDirectory, creating: true)
    } catch {
      throw AudioCaptureError.socketUnavailable(path: socketDirectory, reason: String(describing: error))
    }
    let socketPath = ShimulatorWireProtocol.socketPath(
      capability: ShimulatorAudioCapture.capability, simulatorUDID: simulator.udid)
    let directory = (socketPath as NSString).deletingPathExtension + "-\(UUID().uuidString)"
    guard mkdir(directory, 0o700) == 0 else {
      throw AudioCaptureError.socketUnavailable(path: directory, reason: String(cString: strerror(errno)))
    }
    do {
      let session = try AudioCaptureSession(socketPath: socketPath, directory: directory, udid: simulator.udid)
      await session.beginPolling()
      return session
    } catch {
      try? FileManager.default.removeItem(atPath: directory)
      throw error
    }
  }
}

/// A running capture. Processes join it as they start playing, and `stop` mixes what they played.
public actor AudioCaptureSession {

  private static let pollInterval = Duration.milliseconds(50)
  /// How long a process that is still running has, once the capture lets go, to write what it has left.
  private static let finishTimeout = Duration.seconds(2)

  private let directory: String
  /// The only reference: clearing it disconnects every process, which ends each one's file.
  private var server: ShimulatorServer?
  private var processNames: [Int32: String] = [:]
  private var failures: [String] = []
  private var polling: Task<Void, Never>?

  init(socketPath: String, directory: String, udid: String) throws {
    let server: ShimulatorServer?
    do {
      server = try ShimulatorServer(path: socketPath, parameters: AudioCaptureParameters(directory: directory))
    } catch {
      throw AudioCaptureError.socketUnavailable(path: socketPath, reason: String(describing: error))
    }
    guard let server else {
      throw AudioCaptureError.alreadyRunning(udid: udid)
    }
    self.server = server
    self.directory = directory
  }

  deinit {
    try? FileManager.default.removeItem(atPath: directory)
  }

  func beginPolling() {
    polling = Task { [weak self] in
      while !Task.isCancelled, let self {
        await self.poll()
        try? await Task.sleep(for: Self.pollInterval)
      }
    }
  }

  /// Stops the capture and writes everything the armed processes played, mixed, to `mixPath`.
  public func stop(writingMixTo mixPath: String) async throws -> CapturedAudio {
    polling?.cancel()
    await polling?.value
    polling = nil
    poll()
    server = nil
    defer { try? FileManager.default.removeItem(atPath: directory) }
    await waitForRunningProcessesToFinish()
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    let sources = files.sorted().compactMap { file -> AudioCaptureMixer.Source? in
      guard file.hasSuffix(".\(AudioCaptureFile.pathExtension)") || file.hasSuffix(".\(AudioCaptureFile.partialPathExtension)")
      else {
        return nil
      }
      return AudioCaptureMixer.Source(
        path: (directory as NSString).appendingPathComponent(file),
        processName: Self.processIdentifier(of: file).flatMap { processNames[$0] } ?? "")
    }
    let failures = failures
    return try await Self.onThreadOfItsOwn { try AudioCaptureMixer.mix(sources, into: mixPath, failures: failures) }
  }

  /// Mixing reads every capture file and writes the mix with blocking calls, which would otherwise hold
  /// a cooperative thread for as long as they take.
  private static func onThreadOfItsOwn<Value: Sendable>(
    _ work: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      Thread.detachNewThread { continuation.resume(with: Result { try work() }) }
    }
  }

  private func poll() {
    for responder in server?.poll() ?? [] {
      if let error = responder.error {
        failures.append(error)
      }
      guard let response = responder.response else {
        continue
      }
      processNames[response.processIdentifier] = response.processName
      if response.state == .failed {
        failures.append("\(name(of: response.processIdentifier)): \(response.message ?? "failed")")
      }
    }
  }

  /// A process still running renames its file into place once it has written the rest. One that
  /// exited during the capture never will, and its file is read as it was left. So is the file of one
  /// still running at the deadline, which is named among the failures.
  private func waitForRunningProcessesToFinish() async {
    let deadline = ContinuousClock.now + Self.finishTimeout
    while case let writing = runningProcessesStillWriting(), !writing.isEmpty {
      guard ContinuousClock.now < deadline else {
        failures += writing.map { "\(name(of: $0)): still writing its audio when the capture stopped waiting; what it had written is mixed" }
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func runningProcessesStillWriting() -> [Int32] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    let writers = files.filter { $0.hasSuffix(".\(AudioCaptureFile.partialPathExtension)") }
      .compactMap(Self.processIdentifier(of:))
    return Set(writers).filter(Self.isRunning).sorted()
  }

  private func name(of processIdentifier: Int32) -> String {
    let name = processNames[processIdentifier] ?? ""
    return name.isEmpty ? "pid \(processIdentifier)" : name
  }

  /// Simulator processes are processes of the host, so their identifiers are the host's.
  private static func isRunning(_ processIdentifier: Int32) -> Bool {
    kill(processIdentifier, 0) == 0 || errno == EPERM
  }

  /// Each process names its file for itself: `<pid>-<unique>.idbcap`.
  private static func processIdentifier(of file: String) -> Int32? {
    file.split(separator: "-", maxSplits: 1).first.flatMap { Int32($0) }
  }
}

extension Simulator {

  /// Captures what the simulator's apps play.
  public var audioCapture: SimulatorAudioCaptureCommands {
    SimulatorAudioCaptureCommands(simulator: self)
  }
}
