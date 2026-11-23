/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@preconcurrency import CoreSimulator
import Foundation

/**
 The simulated device's audio settings, as its apps and the host audio device see them.

 The guest owns this. `SBVolumeControl` holds the level in memory and, whenever it changes, publishes
 it as an integer percentage on the `com.apple.springboard.volumestate` Darwin notification;
 `CoreSimulatorBridge` observes that and writes the value into the settings file. A guest app's
 `AVAudioSession.outputVolume` reads the same number back, and the host CoreAudio process-volume
 scalar is set from it.

 The host can read the settings-file mirror; native streams read Darwin notification state.

 Two consequences of the guest's bookkeeping are worth knowing, because they are surprising:

 - **It is a mirror, not the source of truth.** SpringBoard publishes to the file and never reads it
   back. Writing to it does not move SpringBoard's own level, and the next button press overwrites it
   from that untouched level.
 - **It resets to 60 when SpringBoard restarts**, because `SBVolumeControl` initialises its level to
   `0.6` and publishes that initial notification state.
 */
public struct SimulatorAudioSettings: Equatable, Sendable {

  /// Path of the settings file, relative to the simulator's data directory. The guest reaches the
  /// same file through its `SIMULATOR_AUDIO_SETTINGS_PATH` environment variable.
  public static let relativePath = "var/run/simulatoraudio/audiosettings.plist"

  /// The Darwin notification carrying the volume, as an integer percentage. SpringBoard publishes it
  /// on every button press and `CoreSimulatorBridge` mirrors it into `sim_volume`.
  public static let volumeNotificationName = "com.apple.springboard.volumestate"

  /// The Darwin notification carrying the ringer state, mirrored into `sim_ringer_state`.
  public static let ringerNotificationName = "com.apple.springboard.ringerstate"

  /// The output volume, `0...1`. Stored in the file as an integer percentage; one hardware
  /// volume-button press moves it a sixteenth — 6.25 points — and the guest clamps at both ends.
  public let volume: Double

  /// Whether the ringer is unmuted.
  public let ringerEnabled: Bool

  public init(volume: Double, ringerEnabled: Bool) {
    self.volume = volume
    self.ringerEnabled = ringerEnabled
  }

  /// Parses the settings from the file's deserialized contents.
  ///
  /// A missing or non-numeric `sim_volume` is an error rather than a default. Every value this could
  /// substitute — 0, 0.6, 1 — is itself a plausible real volume, so a default would be indistinguishable
  /// from a reading, and a caller checking whether a button press moved the level would be told a
  /// number the device is not at. `sim_ringer_state` does default, to enabled, because the ringer is
  /// unmuted until something mutes it.
  public static func settings(fromPropertyList plist: [String: Any]) throws -> SimulatorAudioSettings {
    guard let percentage = plist["sim_volume"] as? NSNumber else {
      throw SimulatorAudioError.volumeMissing(keys: plist.keys.sorted())
    }
    return SimulatorAudioSettings(
      volume: min(max(percentage.doubleValue / 100, 0), 1),
      ringerEnabled: (plist["sim_ringer_state"] as? NSNumber)?.boolValue ?? true)
  }

  /// The value to publish on `volumeNotificationName` for `volume`.
  ///
  /// An out-of-range volume is an error rather than a clamp. Reading clamps, because the guest is
  /// reporting its own state; writing does not, because a caller asking for 1.5 has a bug, and
  /// quietly setting 1.0 would hide it behind a plausible-looking readback.
  public static func volumeNotificationState(for volume: Double) throws -> UInt64 {
    guard (0...1).contains(volume) else {
      throw SimulatorAudioError.volumeOutOfRange(volume: volume)
    }
    return UInt64((volume * 100).rounded())
  }

  /// Reads and parses the settings file at `path`.
  public static func settings(atPath path: String) throws -> SimulatorAudioSettings {
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw SimulatorAudioError.unreadable(path: path, underlying: error)
    }
    let deserialized = try? PropertyListSerialization.propertyList(from: data, format: nil)
    guard let plist = deserialized as? [String: Any] else {
      throw SimulatorAudioError.malformed(path: path)
    }
    return try settings(fromPropertyList: plist)
  }
}

/**
 A change to the simulated device's audio state.

 Each field is published on its own Darwin notification, so a `nil` field is left alone rather than
 written back at its current value — republishing a field the caller did not ask to change would move
 the guest's own bookkeeping for it.
 */
public struct SimulatorAudioSettingsUpdate: Equatable, Sendable {

  /// The output volume to move to, `0...1`, or `nil` to leave it alone.
  public let volume: Double?

  /// The ringer state to move to, or `nil` to leave it alone.
  public let ringerEnabled: Bool?

  public init(volume: Double? = nil, ringerEnabled: Bool? = nil) {
    self.volume = volume
    self.ringerEnabled = ringerEnabled
  }

  /// Whether the update carries no fields at all.
  public var isEmpty: Bool {
    volume == nil && ringerEnabled == nil
  }
}

/// The failures of reading the simulated device's audio settings.
public enum SimulatorAudioError: Error, LocalizedError {
  /// The simulator reported no data directory to look in.
  case noDataDirectory
  /// The settings file could not be read. The guest writes it while booting, so it is absent on a
  /// simulator that has never been booted.
  case unreadable(path: String, underlying: any Error)
  /// The file is not a property list dictionary.
  case malformed(path: String)
  /// The file parsed but carries no volume.
  case volumeMissing(keys: [String])
  /// A volume outside `0...1` was asked for.
  case volumeOutOfRange(volume: Double)

  public var errorDescription: String? {
    switch self {
    case .noDataDirectory:
      return "The simulator reported no data directory, so its audio settings cannot be located"
    case let .unreadable(path, underlying):
      return
        "Could not read the simulator's audio settings at \(path): \(underlying.localizedDescription). The guest writes this file while booting, so it is absent on a simulator that has never booted."
    case let .malformed(path):
      return "The simulator's audio settings at \(path) are not a property list dictionary"
    case let .volumeMissing(keys):
      let present = keys.isEmpty ? "none" : keys.joined(separator: ", ")
      return "The simulator's audio settings carry no sim_volume; keys present: \(present)"
    case let .volumeOutOfRange(volume):
      return "A volume of \(volume) is outside the permitted range of 0 to 1"
    }
  }
}

/// Reads and moves the simulated device's audio state.
public struct SimulatorAudioCommands {

  let simulator: Simulator

  // MARK: - Initializers

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  // MARK: - Settings

  /// The path of the simulator's audio settings file.
  var settingsPath: String? {
    simulator.dataDirectory.map { ($0 as NSString).appendingPathComponent(SimulatorAudioSettings.relativePath) }
  }

  /// The simulated device's current audio settings.
  public func settings() async throws -> SimulatorAudioSettings {
    guard let path = settingsPath else {
      throw SimulatorAudioError.noDataDirectory
    }
    return try SimulatorAudioSettings.settings(atPath: path)
  }

  /// Publishes the current ringer state and subsequent native changes.
  public func ringerChanges() async throws -> AsyncThrowingStream<Bool, any Error> {
    let simulator = self.simulator
    let name = SimulatorAudioSettings.ringerNotificationName
    let subscription = try await SimulatorDarwinNotificationObserver.subscribe(on: simulator, name: name)
    return SimulatorDarwinNotificationObserver.values(subscription: subscription) { _ in
      try SimulatorDarwinNotificationObserver.state(on: simulator, name: name) != 0
    }
  }

  /// Publishes the current volume and subsequent native changes as a fraction from zero to one.
  public func volumeChanges() async throws -> AsyncThrowingStream<Double, any Error> {
    let simulator = self.simulator
    let name = SimulatorAudioSettings.volumeNotificationName
    let subscription = try await SimulatorDarwinNotificationObserver.subscribe(on: simulator, name: name)
    return SimulatorDarwinNotificationObserver.values(subscription: subscription) { _ in
      min(Double(try SimulatorDarwinNotificationObserver.state(on: simulator, name: name)) / 100, 1)
    }
  }

  /// Applies `update` to the simulated device, leaving any field it does not carry alone.
  ///
  /// The volume is the absolute counterpart to the `volumeUp` and `volumeDown` hardware buttons, which
  /// only step by a sixteenth.
  ///
  /// Do not mix the two: SpringBoard never reads back the level it publishes, so the next hardware
  /// button press steps from SpringBoard's stale level and overwrites what was set here. Control
  /// Center's slider is stale for the same reason, and the ringer behaves alike. An absolute set is
  /// reliable on its own.
  ///
  /// The update is published on the Darwin notifications the guest owns, the same edge a hardware
  /// button press drives. Writing the settings file directly would not do: `CoreSimulatorBridge` is its only writer, and a
  /// guest app watches the *containing directory* for entry changes rather than the file itself, so
  /// only the bridge's atomic replace makes an already-running app re-read it.
  public func updateSettings(_ update: SimulatorAudioSettingsUpdate) async throws {
    if let volume = update.volume {
      try publish(
        state: try SimulatorAudioSettings.volumeNotificationState(for: volume),
        on: SimulatorAudioSettings.volumeNotificationName)
    }
    if let ringerEnabled = update.ringerEnabled {
      try publish(
        state: ringerEnabled ? 1 : 0,
        on: SimulatorAudioSettings.ringerNotificationName)
    }
  }

  private func publish(state: UInt64, on notificationName: String) throws {
    try simulator.device.darwinNotificationSetState(state, name: notificationName)
    try simulator.device.postDarwinNotification(notificationName)
  }

}
