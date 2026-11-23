/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

internal import CoreSimulator
import Darwin
import FBControlCore
import FBControlCoreObjC
import FBSimulatorControl
import Foundation
internal import ShimulatorAudioInjectionCore
internal import ShimulatorProtocol
import SimulatorIPC

/// Plays audio into the microphone input of apps on a Simulator, through the Shimulator shim
/// injected into their launch: the second way this library injects into a Simulator's processes,
/// beside the REPL shim `codeInjection` injects.
public struct SimulatorAudioInjectionCommands {

  let simulator: Simulator

  init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Microphone injection

  public static let injectionShimName = "libShimulator-iOS.dylib"

  private static let injectionPollInterval = Duration.milliseconds(50)

  /// Only a process launched after arming claims audio, so nothing may ever claim it.
  static let injectionClaimTimeout = Duration.seconds(10)

  /// A process that recorded earlier can claim audio and then never render it.
  private static let injectionPlaybackGrace = Duration.seconds(30)

  /// Pins a regular file and copies at most the payload limit plus one byte before decoding it.
  static func wav(
    of url: URL,
    read: (Int32, UnsafeMutableRawPointer, Int) throws -> Int = { unsafe Darwin.read($0, $1, $2) }
  ) throws -> (duration: Duration, data: Data)? {
    func unreadable(_ reason: String) -> AudioInjectionError {
      .fileUnreadable(path: url.path, reason: reason)
    }
    func readFailure() -> AudioInjectionError {
      unreadable(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)
    }
    guard url.isFileURL else {
      throw unreadable("Audio input must be a local regular file.")
    }
    // Nonblocking at open prevents waiting for a FIFO writer before descriptor validation.
    // Follow symlinks, as before; validate the opened target, not an earlier pathname stat.
    let descriptor = unsafe open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw readFailure()
    }
    defer { close(descriptor) }
    var metadata = stat()
    guard unsafe fstat(descriptor, &metadata) == 0 else {
      throw readFailure()
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else {
      throw unreadable("Audio input must be a regular file.")
    }
    let maximum = ShimulatorAudioInjection.maximumPayloadBytes
    guard metadata.st_size <= off_t(maximum) else {
      throw AudioInjectionError.fileTooLarge(
        path: url.path, size: Int(clamping: metadata.st_size), maximum: maximum)
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count <= maximum {
      let requested = min(buffer.count, maximum + 1 - data.count)
      let count = try buffer.withUnsafeMutableBytes { buffer in
        guard let address = buffer.baseAddress else {
          throw unreadable("Audio read buffer is unavailable.")
        }
        return unsafe try read(descriptor, address, requested)
      }
      if count < 0 {
        if errno == EINTR {
          continue
        }
        throw readFailure()
      }
      if count == 0 {
        break
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard data.count <= maximum else {
      // A growing file's size is only an observation; the prefix proves at least maximum + 1.
      let observed = unsafe fstat(descriptor, &metadata) == 0 ? Int(clamping: metadata.st_size) : data.count
      throw AudioInjectionError.fileTooLarge(
        path: url.path, size: max(data.count, observed), maximum: maximum)
    }
    return WAVAudio(data: data).map { (.seconds(Double($0.samples.count) / $0.sampleRate), data) }
  }

  private var injectionSocketPath: String {
    ShimulatorWireProtocol.socketPath(capability: ShimulatorAudioInjection.capability, simulatorUDID: simulator.udid)
  }

  /// Prepares only the launched app to accept microphone playback and to have what it plays captured,
  /// without changing guest launchd.
  ///
  /// A launch that cannot be prepared still goes ahead, unarmed; `inject` then names the reason.
  public func appLaunchEnvironment(_ environment: [String: String]) async -> [String: String] {
    guard [.iPhone, .iPad].contains(simulator.productFamily) else {
      return environment
    }
    return await Self.appLaunchEnvironment(
      environment,
      recordingIn: preparation,
      log: { simulator.logger.log($0) },
      prepare: { try await preparedAppLaunchEnvironment(environment) })
  }

  static func appLaunchEnvironment(
    _ environment: [String: String],
    recordingIn preparation: AudioInjectionPreparation,
    log: (String) -> Void,
    prepare: () async throws -> [String: String]
  ) async -> [String: String] {
    do {
      let prepared = try await prepare()
      preparation.record(failure: nil)
      return prepared
    } catch {
      let reason = error.localizedDescription
      log("Launching the app without microphone injection: \(reason)")
      preparation.record(failure: reason)
      return environment
    }
  }

  private var preparation: AudioInjectionPreparation {
    simulator.commandCache.resolve { AudioInjectionPreparation() }
  }

  private func preparedAppLaunchEnvironment(_ environment: [String: String]) async throws -> [String: String] {
    guard let shimPath = BundledResources.path(forItem: Self.injectionShimName) else {
      throw AudioInjectionError.shimMissing(item: Self.injectionShimName)
    }
    let directory = ShimulatorWireProtocol.socketDirectory()
    do {
      try IPCSocket.requirePrivateDirectory(directory, creating: true)
    } catch {
      throw AudioInjectionError.socketUnavailable(path: directory, reason: String(describing: error))
    }
    let inherited =
      if environment[Self.insertLibrariesVariable] != nil {
        ""
      } else {
        try await launchdValue(Self.insertLibrariesVariable, reader: .selected(by: ProcessInfo.processInfo.environment))
      }
    return Self.appLaunchEnvironment(environment, shimPath: shimPath, inheritedLibraries: inherited)
  }

  /// How a launch reads what the Simulator's launchd would have the app inherit.
  enum LaunchdEnvironmentReader: String {
    /// The runtime's own `launchctl getenv`, run in the Simulator.
    case launchctl
    /// CoreSimulator's `getenv`, which starts no process in the Simulator.
    case coreSimulator = "coresimulator"

    /// Selects the reader by name in the companion's environment.
    static let environmentVariable = "IDB_LAUNCHD_GETENV"

    static func selected(by environment: [String: String]) -> Self {
      environment[environmentVariable].flatMap(Self.init(rawValue:)) ?? .coreSimulator
    }
  }

  /// The value of `name` in the Simulator launchd's environment, empty when it is unset.
  private func launchdValue(_ name: String, reader: LaunchdEnvironmentReader) async throws -> String {
    switch reader {
    case .launchctl:
      return try await launchctl("getenv", name)
    case .coreSimulator:
      do {
        return try FBObjCExceptionGuard.guarded { try simulator.device.getenv(name) }
      } catch let error as POSIXError where error.code == .ENOENT {
        // CoreSimulator reports a variable launchd does not have as ENOENT.
        return ""
      } catch {
        let underlying = error as NSError
        throw AudioInjectionError.armingFailed(
          udid: simulator.udid,
          stderr: "CoreSimulator getenv \(name) failed (\(underlying.domain) \(underlying.code)): \(underlying.localizedDescription)")
      }
    }
  }

  static func appLaunchEnvironment(
    _ environment: [String: String], shimPath: String, inheritedLibraries: String
  ) -> [String: String] {
    let libraries = environment[Self.insertLibrariesVariable] ?? inheritedLibraries
    let others = libraries.split(separator: ":").map(String.init).filter {
      ($0 as NSString).lastPathComponent != Self.injectionShimName
    }
    var prepared = environment
    prepared[Self.insertLibrariesVariable] = (others + [shimPath]).joined(separator: ":")
    prepared[ShimulatorAudioInjection.armedEnvironmentVariable] =
      environment[ShimulatorAudioInjection.armedEnvironmentVariable] ?? "1"
    prepared[ShimulatorAudioCapture.armedEnvironmentVariable] =
      environment[ShimulatorAudioCapture.armedEnvironmentVariable] ?? "1"
    return prepared
  }

  private func requireInjectableProductFamily() throws {
    guard [.iPhone, .iPad].contains(simulator.productFamily) else {
      throw AudioInjectionError.unsupportedPlatform(udid: simulator.udid)
    }
  }

  private static let insertLibrariesVariable = "DYLD_INSERT_LIBRARIES"

  /// Runs the runtime's own `launchctl`; `launchctl getenv` exits zero and prints nothing when unset.
  private func launchctl(_ arguments: String...) async throws -> String {
    let output = try await simulator.runtimeTools.run(
      hostExecutable: try SimulatorLaunchCtlCommands.launchCtlLaunchPath(for: simulator), arguments: arguments)
    guard output.exitCode == 0, let stdout = String(data: output.stdout, encoding: .utf8) else {
      throw AudioInjectionError.armingFailed(
        udid: simulator.udid,
        stderr: "launchctl \(arguments.joined(separator: " ")) exited \(output.exitCode): \(String(decoding: output.stderr, as: UTF8.self))")
    }
    return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Plays WAV audio into apps prepared by an idb launch, returning when playback finishes.
  public func inject(from audioFileURL: URL) async throws {
    try requireInjectableProductFamily()
    guard let audio = unsafe try Self.wav(of: audioFileURL) else {
      throw AudioInjectionError.unreadable(path: audioFileURL.path)
    }
    guard BundledResources.path(forItem: Self.injectionShimName) != nil else {
      throw AudioInjectionError.shimMissing(item: Self.injectionShimName)
    }
    if audio.duration == .zero {
      return
    }
    let socketPath = injectionSocketPath
    let audioPath = (socketPath as NSString).deletingPathExtension + ".wav"
    let bound: ShimulatorServer?
    do {
      bound = try ShimulatorServer(path: socketPath, parameters: AudioInjectionParameters(path: audioPath))
    } catch {
      throw AudioInjectionError.socketUnavailable(path: socketPath, reason: String(describing: error))
    }
    guard let server = bound else {
      throw AudioInjectionError.alreadyRunning(udid: simulator.udid)
    }
    defer { try? FileManager.default.removeItem(atPath: audioPath) }
    do {
      try audio.data.write(to: URL(fileURLWithPath: audioPath), options: .atomic)
    } catch {
      throw AudioInjectionError.socketUnavailable(path: audioPath, reason: error.localizedDescription)
    }

    var claimed = false
    var departed: [InjectionReport] = []
    var confirmingCompletion = false
    let claimDeadline = ContinuousClock.now + Self.injectionClaimTimeout
    let playbackDeadline =
      ContinuousClock.now + Self.injectionClaimTimeout + audio.duration
      + Self.injectionPlaybackGrace
    while true {
      let polled = server.poll()
      departed += polled.filter { !$0.connected }.compactMap(Self.report)
      let reports = departed + polled.filter(\.connected).compactMap(Self.report)
      if reports.contains(where: { $0.state == .finished }) {
        server.stopAdmitting()
      }
      let progress = Self.injectionProgress(
        reports: reports,
        claimed: claimed,
        confirmingCompletion: confirmingCompletion,
        claimExpired: ContinuousClock.now > claimDeadline,
        playbackExpired: ContinuousClock.now > playbackDeadline)
      claimed = progress.claimed
      confirmingCompletion = progress.confirmingCompletion
      switch progress.decision {
      case .wait:
        try await Task.sleep(for: Self.injectionPollInterval)
      case .completed:
        return
      case let .failed(process, message):
        throw AudioInjectionError.failedInGuest(
          udid: simulator.udid,
          process: process,
          reason: message)
      case .unclaimed:
        throw AudioInjectionError.unclaimed(
          udid: simulator.udid, preparationFailure: preparation.lastFailure)
      case .didNotFinish:
        throw AudioInjectionError.didNotFinish(udid: simulator.udid)
      }
    }
  }

  private static func report(_ responder: ShimulatorResponder) -> InjectionReport? {
    if let error = responder.error {
      return InjectionReport(state: .failed, process: "a process in the simulator", message: error)
    }
    guard let response = responder.response else {
      return nil
    }
    let state: InjectionState =
      switch response.state {
      case .accepted: .playing
      case .completed: .finished
      case .failed: .failed
      }
    return InjectionReport(
      state: state,
      process: response.processName.isEmpty ? "pid \(response.processIdentifier)" : response.processName,
      message: response.message,
      processIsAlive: responder.connected)
  }

  struct InjectionProgress: Equatable {
    enum Decision: Equatable {
      case wait
      case completed
      case failed(process: String, message: String?)
      case unclaimed
      case didNotFinish
    }

    let decision: Decision
    let claimed: Bool
    let confirmingCompletion: Bool
  }

  static func injectionProgress(
    reports: [InjectionReport],
    claimed: Bool,
    confirmingCompletion: Bool,
    claimExpired: Bool,
    playbackExpired: Bool
  ) -> InjectionProgress {
    let states = reports.map(\.state)
    let isPlaying = reports.contains { $0.state == .playing && $0.processIsAlive }
    let isFinished = states.contains(.finished)
    let updatedClaimed = claimed || isPlaying || isFinished

    if !isPlaying, !isFinished,
      let failure = reports.first(where: { $0.state == .failed })
    {
      return InjectionProgress(
        decision: claimed || claimExpired ? .failed(process: failure.process, message: failure.message) : .wait,
        claimed: updatedClaimed,
        confirmingCompletion: false)
    }
    if isFinished, !isPlaying {
      return InjectionProgress(
        decision: confirmingCompletion ? .completed : .wait,
        claimed: updatedClaimed,
        confirmingCompletion: true)
    }
    if !updatedClaimed, claimExpired {
      return InjectionProgress(
        decision: .unclaimed,
        claimed: false,
        confirmingCompletion: false)
    }
    if playbackExpired {
      return InjectionProgress(
        decision: .didNotFinish,
        claimed: updatedClaimed,
        confirmingCompletion: false)
    }
    return InjectionProgress(
      decision: .wait,
      claimed: updatedClaimed,
      confirmingCompletion: false)
  }

  struct InjectionReport: Equatable {
    let state: InjectionState
    let process: String
    let message: String?
    var processIsAlive = true
  }

  enum InjectionState: String {
    case playing
    case finished
    case failed
  }
}

/// Why the simulator's last idb app launch could not be prepared for microphone injection.
final class AudioInjectionPreparation: @unchecked Sendable {
  private let lock = NSLock()
  private var failure: String?

  /// Nil once a launch has been prepared, until one fails again.
  var lastFailure: String? {
    lock.withLock { failure }
  }

  func record(failure: String?) {
    lock.withLock { self.failure = failure }
  }
}

/// Why playing audio into a Simulator's microphone input failed.
public enum AudioInjectionError: Error, LocalizedError {
  case alreadyRunning(udid: String)
  case unreadable(path: String)
  case fileUnreadable(path: String, reason: String)
  case fileTooLarge(path: String, size: Int, maximum: Int)
  case shimMissing(item: String)
  /// `preparationFailure` is why the last idb app launch went ahead without the shim, if it did.
  case unclaimed(udid: String, preparationFailure: String?)
  case didNotFinish(udid: String)
  case socketUnavailable(path: String, reason: String)
  case unsupportedPlatform(udid: String)
  case failedInGuest(
    udid: String,
    process: String,
    reason: String?
  )
  case armingFailed(udid: String, stderr: String)

  public var errorDescription: String? {
    switch self {
    case let .alreadyRunning(udid):
      return
        "Another audio injection is already playing into simulator \(udid). Injections mix into one microphone input, so they are played one at a time; wait for the first to finish."
    case let .unreadable(path):
      return "Could not read \(path) as audio to inject. It must be a 16-bit PCM WAV file."
    case let .fileUnreadable(path, reason):
      return
        "Could not open \(path): \(reason). Nothing was read, so this says nothing about whether the file is audio the simulator could play."
    case let .fileTooLarge(path, size, maximum):
      return
        "Could not inject \(path) because it is \(size) bytes; the maximum audio payload is \(maximum) bytes."
    case let .shimMissing(item):
      return "The companion is missing \(item) from its Resources directory, so audio injection cannot be prepared."
    case let .armingFailed(udid, stderr):
      return "Could not prepare an app's microphone-injection environment on simulator \(udid): \(stderr)"
    case let .failedInGuest(udid, process, reason):
      let detail = reason.map { " Guest error: \($0)" } ?? ""
      return "\(process) in simulator \(udid) rejected the audio injection.\(detail)"
    case let .unsupportedPlatform(udid):
      return
        "Audio injection supports iPhone and iPad simulators. Simulator \(udid) is neither, and the shim is built for the iOS simulator only."
    case let .socketUnavailable(path, reason):
      return "Could not serve audio injection at \(path): \(reason)"
    case let .didNotFinish(udid):
      return
        "The audio injected into simulator \(udid) started playing but never finished. An app hears injected audio only while it is recording: if it stopped recording part-way through, the rest of the audio has nowhere to go."
    case let .unclaimed(udid, preparationFailure):
      let unprepared =
        preparationFailure.map {
          " The last app launch through idb could not be prepared for microphone injection, so it could not hear injected audio: \($0)."
        } ?? ""
      return
        "Nothing in simulator \(udid) picked the audio up within \(SimulatorAudioInjectionCommands.injectionClaimTimeout.components.seconds) seconds.\(unprepared) Launch the app under test through idb so microphone injection is prepared at process startup, have it start recording, and inject again. An already-running app cannot be armed without a relaunch."
    }
  }
}

extension Simulator {

  /// Plays audio into the microphone input of the Simulator's apps.
  public var audioInjection: SimulatorAudioInjectionCommands {
    SimulatorAudioInjectionCommands(simulator: self)
  }
}
