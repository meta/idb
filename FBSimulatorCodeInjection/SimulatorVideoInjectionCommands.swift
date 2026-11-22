/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import AVFoundation
import FBControlCore
@preconcurrency import FBSimulatorControl
import Foundation
internal import ShimulatorProtocol
internal import ShimulatorVideoInjectionCore
import SimulatorIPC
import os

/// The failures of playing a video into a simulator's cameras.
public enum VideoInjectionError: Error, LocalizedError {
  case unsupportedPlatform(udid: String)
  case inputUnreadable(path: String, reason: String)
  case noVideoTrack(path: String, reason: String?)
  case alreadyRunning(udid: String)
  case socketUnavailable(path: String, reason: String)
  case stagingFailed(path: String, reason: String)
  case failedInGuest(udid: String, process: String, reason: String?)

  public var errorDescription: String? {
    switch self {
    case let .unsupportedPlatform(udid):
      return
        "Camera injection supports iPhone and iPad simulators. Simulator \(udid) is neither, and the shim is built for the iOS simulator only."
    case let .inputUnreadable(path, reason):
      return "Could not use \(path) as a video to inject: \(reason)"
    case let .noVideoTrack(path, reason):
      let detail = reason.map { ": \($0)" } ?? "."
      return "\(path) holds no playable video track\(detail)"
    case let .alreadyRunning(udid):
      return
        "Another camera injection is already running on simulator \(udid). Its cameras show one video at a time; stop the first injection before starting another."
    case let .socketUnavailable(path, reason):
      return "Could not serve camera injection at \(path): \(reason)"
    case let .stagingFailed(path, reason):
      return "Could not copy the video to \(path), where the simulator's apps read it: \(reason)"
    case let .failedInGuest(udid, process, reason):
      let detail = reason.map { " Guest error: \($0)" } ?? ""
      return "\(process) in simulator \(udid) could not play the injected video.\(detail)"
    }
  }
}

/// Plays video files into the cameras of the simulator's apps, through the Shimulator shim that
/// microphone injection inserts into their launch.
///
/// Only an app launched through idb while an injection runs is armed: its environment tells the shim
/// to replace the camera.
public struct SimulatorVideoInjectionCommands {

  let simulator: Simulator

  init(simulator: Simulator) {
    self.simulator = simulator
  }

  private static let pollInterval = Duration.milliseconds(50)
  private static let insertLibrariesVariable = "DYLD_INSERT_LIBRARIES"

  private var injection: VideoInjectionState {
    simulator.commandCache.resolve { VideoInjectionState() }
  }

  // MARK: - App launch

  /// Arms an app launched while an injection runs. A launch that cannot be armed still goes ahead.
  public func appLaunchEnvironment(_ environment: [String: String]) -> [String: String] {
    guard [.iPhone, .iPad].contains(simulator.productFamily) else {
      return environment
    }
    let (prepared, skipped) = Self.appLaunchEnvironment(environment, injecting: injection.isRunning)
    if let skipped {
      simulator.logger.log("Launching the app without camera injection: \(skipped)")
    }
    return prepared
  }

  /// Returns the environment to launch with, and why it could not be armed, if it could not.
  static func appLaunchEnvironment(
    _ environment: [String: String], injecting: Bool
  ) -> (environment: [String: String], skipped: String?) {
    let variable = ShimulatorVideoInjection.armedEnvironmentVariable
    guard injecting, environment[variable] == nil else {
      return (environment, nil)
    }
    let libraries = environment[insertLibrariesVariable] ?? ""
    let shimName = SimulatorAudioInjectionCommands.injectionShimName
    guard libraries.split(separator: ":").contains(where: { (String($0) as NSString).lastPathComponent == shimName }) else {
      return (environment, "\(shimName) is not in \(insertLibrariesVariable)")
    }
    var prepared = environment
    prepared[variable] = "1"
    return (prepared, nil)
  }

  // MARK: - Injecting

  /// Shows `back` on the back camera, and `front` (or `back`) on the front one, of every app launched
  /// through idb while this runs.
  ///
  /// `onUpdate` is called once the simulator is armed, then whenever the processes showing the video
  /// change. Returns once a process has shown the whole video, unless `loop`; runs until cancelled
  /// otherwise. Leaving disconnects every app, so their cameras go back to idle.
  public func inject(
    back: URL, front: URL?, loop: Bool, onUpdate: ([String]) async throws -> Void
  ) async throws {
    guard [.iPhone, .iPad].contains(simulator.productFamily) else {
      throw VideoInjectionError.unsupportedPlatform(udid: simulator.udid)
    }
    try await Self.requireVideo(back)
    if let front {
      try await Self.requireVideo(front)
    }
    let directory = ShimulatorWireProtocol.socketDirectory()
    do {
      try IPCSocket.requirePrivateDirectory(directory, creating: true)
    } catch {
      throw VideoInjectionError.socketUnavailable(path: directory, reason: String(describing: error))
    }
    let socketPath = ShimulatorWireProtocol.socketPath(
      capability: ShimulatorVideoInjection.capability, simulatorUDID: simulator.udid)
    let stem = (socketPath as NSString).deletingPathExtension
    var copies = [(source: back, destination: Self.copyPath(stem: stem, camera: "back", of: back))]
    if let front {
      copies.append((front, Self.copyPath(stem: stem, camera: "front", of: front)))
    }
    let parameters = VideoInjectionParameters(
      path: copies[0].destination, frontPath: copies.count > 1 ? copies[1].destination : nil, loop: loop)
    // The only reference: clearing it closes the apps' connections.
    var server: ShimulatorServer?
    do {
      server = try ShimulatorServer(path: socketPath, parameters: parameters)
    } catch {
      throw VideoInjectionError.socketUnavailable(path: socketPath, reason: String(describing: error))
    }
    guard server != nil else {
      throw VideoInjectionError.alreadyRunning(udid: simulator.udid)
    }
    // Run in reverse: unarm, then disconnect the apps, then delete the files they were reading.
    defer {
      for copy in copies {
        try? FileManager.default.removeItem(atPath: copy.destination)
      }
    }
    defer { server = nil }

    // A process that connects before this is copied waits unanswered: nothing is accepted until the
    // first poll.
    for copy in copies {
      try? FileManager.default.removeItem(atPath: copy.destination)
      do {
        try FileManager.default.copyItem(
          at: copy.source.resolvingSymlinksInPath(), to: URL(fileURLWithPath: copy.destination))
      } catch {
        throw VideoInjectionError.stagingFailed(path: copy.destination, reason: error.localizedDescription)
      }
    }

    injection.set(running: true)
    defer { injection.set(running: false) }
    try await onUpdate([])
    var showing: [String] = []
    while true {
      let reports = (server?.poll() ?? []).compactMap(Self.report)
      switch Self.progress(of: reports, loop: loop) {
      case let .failed(process, message):
        throw VideoInjectionError.failedInGuest(udid: simulator.udid, process: process, reason: message)
      case .completed:
        return
      case let .showing(processes):
        if processes != showing {
          showing = processes
          try await onUpdate(processes)
        }
      }
      try await Task.sleep(for: Self.pollInterval)
    }
  }

  /// Guest apps read the copy, so the caller may delete its file once the injection has started.
  static func copyPath(stem: String, camera: String, of source: URL) -> String {
    let path = "\(stem)-\(camera)"
    return source.pathExtension.isEmpty ? path : "\(path).\(source.pathExtension)"
  }

  static func requireVideo(_ url: URL) async throws {
    func unreadable(_ reason: String) -> VideoInjectionError {
      .inputUnreadable(path: url.path, reason: reason)
    }
    guard url.isFileURL else {
      throw unreadable("Video input must be a local file.")
    }
    let resolved = url.resolvingSymlinksInPath()
    guard FileManager.default.fileExists(atPath: resolved.path) else {
      throw unreadable("No such file.")
    }
    guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
      throw unreadable("Video input must be a regular file.")
    }
    let tracks: [AVAssetTrack]
    do {
      tracks = try await AVURLAsset(url: resolved).loadTracks(withMediaType: .video)
    } catch {
      throw VideoInjectionError.noVideoTrack(path: url.path, reason: error.localizedDescription)
    }
    guard !tracks.isEmpty else {
      throw VideoInjectionError.noVideoTrack(path: url.path, reason: nil)
    }
  }

  // MARK: - Progress

  struct InjectionReport: Equatable {
    enum State: Equatable {
      case showing
      case completed
      case failed
    }

    let state: State
    let process: String
    var message: String?
    var connected = true
  }

  enum InjectionProgress: Equatable {
    /// The processes, sorted, whose cameras are showing the video.
    case showing([String])
    case completed
    case failed(process: String, message: String?)
  }

  static func progress(of reports: [InjectionReport], loop: Bool) -> InjectionProgress {
    if let failure = reports.first(where: { $0.state == .failed }) {
      return .failed(process: failure.process, message: failure.message)
    }
    if !loop, reports.contains(where: { $0.state == .completed }) {
      return .completed
    }
    return .showing(reports.filter { $0.connected && $0.state == .showing }.map(\.process).sorted())
  }

  private static func report(_ responder: ShimulatorResponder) -> InjectionReport? {
    if let error = responder.error {
      return InjectionReport(state: .failed, process: "a process in the simulator", message: error, connected: false)
    }
    guard let response = responder.response else {
      return nil
    }
    let state: InjectionReport.State =
      switch response.state {
      case .accepted: .showing
      case .completed: .completed
      case .failed: .failed
      }
    return InjectionReport(
      state: state,
      process: response.processName.isEmpty ? "pid \(response.processIdentifier)" : response.processName,
      message: response.message,
      connected: responder.connected)
  }
}

/// Whether a camera injection is running on the simulator, so that idb arms the apps it launches.
final class VideoInjectionState: Sendable {
  private let running = OSAllocatedUnfairLock(initialState: false)

  var isRunning: Bool {
    running.withLock { $0 }
  }

  func set(running: Bool) {
    self.running.withLock { $0 = running }
  }
}

extension Simulator {

  /// Plays video files into the cameras of the Simulator's apps.
  public var videoInjection: SimulatorVideoInjectionCommands {
    SimulatorVideoInjectionCommands(simulator: self)
  }
}
