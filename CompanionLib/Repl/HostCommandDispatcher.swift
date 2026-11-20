/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import FBSimulatorControl
import FBVideoCore
import Foundation
import ReplProtocol

/// An error raised while handling a host command (e.g. an invalid argument). Its
/// `description` is the message that reaches the REPL client.
enum HostCommandError: Error, CustomStringConvertible {
  case message(String)

  var description: String {
    switch self {
    case .message(let message):
      return message
    }
  }
}

/// Per-REPL-session state shared across host commands within one `repl` stream:
/// where captured screenshots are staged, and the per-run screenshot filename
/// counter. Screen recordings are *not* held here -- they can outlive the stream,
/// so `ReplRecordingCoordinator` owns them.
///
/// `@unchecked Sendable`: host commands are serviced one at a time within a
/// session (each execute is awaited before the next), so these mutable fields are
/// never accessed concurrently.
final class ReplHostCommandState: @unchecked Sendable {

  /// The directory captured files are written to (a per-session subdirectory of
  /// the target's auxillary directory).
  let stagingDirectory: URL

  /// The path of `stagingDirectory` relative to the AUXILLARY file-container root
  /// (the target's auxillary directory), used to pull artifacts back over gRPC.
  let containerRelativeBase: String

  /// Files captured during the current execute, reported to the driver so it can
  /// retrieve them.
  private(set) var runArtifacts: [ReplArtifact] = []

  private var runIndex = 0
  private var screenshotIndex = 0

  init(stagingDirectory: URL, containerRelativeBase: String) {
    self.stagingDirectory = stagingDirectory
    self.containerRelativeBase = containerRelativeBase
  }

  func beginRun(index: Int) {
    runIndex = index
    screenshotIndex = 0
    runArtifacts = []
  }

  func nextScreenshotPath() -> String {
    screenshotIndex += 1
    let name = "screenshot_\(runIndex)_\(screenshotIndex).png"
    return stagingDirectory.appendingPathComponent(name).path
  }

  func recordScreenshot(hostPath: String) {
    let filename = (hostPath as NSString).lastPathComponent
    runArtifacts.append(ReplArtifact(hostPath: hostPath, containerPath: containerRelativeBase + "/" + filename))
  }

  /// Records an already-formed artifact (e.g. a recording retrieved from the
  /// `ReplRecordingCoordinator`, whose container path is not under `stagingDirectory`).
  func recordArtifact(_ artifact: ReplArtifact) {
    runArtifacts.append(artifact)
  }
}

/// A file captured on the companion during an execute, to be retrieved by the
/// driver. `hostPath` is absolute (for a same-filesystem move); `containerPath` is
/// relative to the AUXILLARY container root (for a gRPC pull).
struct ReplArtifact {
  let hostPath: String
  let containerPath: String
}

/// Maps a decoded `ReplCommand` -- sent by injected REPL code while it runs -- to an
/// `IDBCommandExecutor` call. `resultValue(for:)` produces the value; `run` serializes it and maps
/// a thrown error to `.failure`.
struct HostCommandDispatcher: Sendable {

  let commandExecutor: IDBCommandExecutor
  let state: ReplHostCommandState
  /// Owns the in-progress screen recording, which can outlive this stream.
  let recordingCoordinator: ReplRecordingCoordinator
  /// The bundle id of the app hosting this REPL (app context only), used to drop a
  /// recording if the app exits before it is stopped. Nil for the test/simulator
  /// contexts, where the disposable host is dropped at stream teardown instead.
  let appBundleID: String?

  /// The result a command produces, before serialization to the wire.
  private enum ResultValue {
    /// Already-serialized bytes, returned to injected code verbatim (e.g. an
    /// encoded image). Avoids re-wrapping the payload in a property list.
    case raw(Data)
    /// A `Codable` value; encoded as a binary property list.
    case encodable(any Encodable)
    /// A Foundation property-list object (e.g. the accessibility tree), already in
    /// a form `PropertyListSerialization` accepts.
    case propertyList(Any)
  }

  func run(_ command: ReplCommand) async -> Result<Data, any Error> {
    do {
      switch try await resultValue(for: command) {
      case nil:
        return .success(Data())
      case .raw(let data):
        return .success(data)
      case .encodable(let value):
        return .success(try Self.propertyListData(encoding: value))
      case .propertyList(let object):
        return .success(try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0))
      }
    } catch {
      return .failure(error)
    }
  }

  private func resultValue(for command: ReplCommand) async throws -> ResultValue? {
    switch command {
    case .tap(let point):
      try await commandExecutor.hid(.tapAt(x: point.x, y: point.y))
      return nil

    case .tapMarker(let marker):
      try await commandExecutor.accessibility.accessibilityTap(label: marker)
      return nil

    case .swipe(let from, let to, let duration, let delta):
      try await commandExecutor.hid(.swipe(from.x, yStart: from.y, xEnd: to.x, yEnd: to.y, delta: delta, duration: duration))
      return nil

    case .pinch(let center, let scale, let duration, let radius):
      try await commandExecutor.hid(.pinchAt(x: center.x, y: center.y, scale: scale, duration: duration, radius: radius))
      return nil

    case .button(let name):
      let normalized = name.replacingOccurrences(of: "-", with: "_").lowercased()
      guard let button = SimulatorHIDButton.allCases.first(where: { $0.name == normalized }) else {
        let valid = SimulatorHIDButton.allCases.map(\.name).joined(separator: ", ")
        throw HostCommandError.message("button: unknown button '\(name)' (expected one of: \(valid))")
      }
      try await commandExecutor.hid(.shortButtonPress(button))
      return nil

    case .text(let text):
      do {
        try await commandExecutor.hid(text: text)
      } catch SimulatorHIDError.characterNotOnKeyboardLayout(let offset, let layout) {
        // The error leaves the character out, as it can reach logs. This message goes to the REPL's own user.
        let character = text.precomposedStringWithCanonicalMapping.dropFirst(offset).first.map { "'\($0)'" } ?? "at offset \(offset)"
        throw HostCommandError.message("text: unsupported character \(character) on the \(layout) keyboard layout")
      }
      return nil

    // touch-move uses the same `.down` primitive as touch-down at a new point;
    // a sequence of down -> move(s) -> up forms a held drag (the HID connection
    // is cached on the simulator, so it persists across these commands).
    case .touchDown(let point), .touchMove(let point):
      try await commandExecutor.hid(.touch(direction: .down, x: point.x, y: point.y))
      return nil

    case .touchUp(let point):
      try await commandExecutor.hid(.touch(direction: .up, x: point.x, y: point.y))
      return nil

    case .describeAll:
      let response = try await commandExecutor.accessibility.accessibilityInfoAtPoint(nil, format: .nested)
      let tree = Self.replAccessibilityTree(from: response.elements.legacyFoundationObject) ?? [String: Any]()
      return .propertyList(tree)

    case .screenshot(let area, let output):
      let rect = try await cropRect(for: area)
      switch output {
      case .data:
        let data = try await commandExecutor.replScreenshot(cropRect: rect, asPNG: false)
        return .raw(data)
      case .file:
        let data = try await commandExecutor.replScreenshot(cropRect: rect, asPNG: true)
        let path = state.nextScreenshotPath()
        try data.write(to: URL(fileURLWithPath: path))
        state.recordScreenshot(hostPath: path)
        return .raw(Data(path.utf8))
      }

    case .startRecording:
      // One recording at a time: an empty result signals "already recording" (false).
      guard let path = recordingCoordinator.reserveRecordingPath() else {
        return .raw(Data())
      }
      let recording: any VideoRecording
      do {
        recording = try await commandExecutor.replStartRecording(toFile: path)
      } catch {
        recordingCoordinator.cancelReservation()
        throw error
      }
      let id = recordingCoordinator.activate(recording: recording, hostPath: path)
      // App context: the recording outlives this stream, so drop it if the app exits before it is stopped.
      // The watcher is not cancelled on stop; the id check makes a late fire a no-op.
      if let appBundleID {
        let coordinator = recordingCoordinator
        let executor = commandExecutor
        Task {
          try? await executor.replWaitForAppTermination(bundleID: appBundleID)
          await coordinator.dropRecording(id: id)
        }
      }
      return .raw(Data(path.utf8))

    case .stopRecording:
      guard let stopped = try await recordingCoordinator.stopRecording() else {
        throw HostCommandError.message("stopRecording: no recording is in progress")
      }
      state.recordArtifact(ReplArtifact(hostPath: stopped.hostPath, containerPath: stopped.containerPath))
      return .raw(Data(stopped.hostPath.utf8))
    }
  }

  private func cropRect(for area: ScreenshotArea) async throws -> CGRect? {
    switch area {
    case .full:
      return nil
    case .rect(let rect):
      return rect
    case .element(let label):
      return try await commandExecutor.accessibility.replAccessibilityFrame(label: label)
    }
  }

  /// Encodes a `Codable` value as a binary property list. Generic so the
  /// existential from `ResultValue.encodable` is opened to a concrete type, which
  /// `PropertyListEncoder.encode` requires.
  private static func propertyListData<Value: Encodable>(encoding value: Value) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(value)
  }

  /// Adapts the shared serializer's accessibility tree for the REPL client: drops
  /// the `NSNull`s it emits for absent attributes (a property list has no null type,
  /// and `AXElement`'s fields are optional so a missing key reads as nil), and
  /// renders each node's `AXValue` as a String, so the client decodes a plain
  /// optional String rather than a string/number/bool union.
  private static func replAccessibilityTree(from value: Any) -> Any? {
    if value is NSNull {
      return nil
    }
    if var dictionary = value as? [String: Any] {
      dictionary = dictionary.compactMapValues(replAccessibilityTree(from:))
      if let axValue = dictionary["AXValue"] {
        dictionary["AXValue"] = Self.stringForAXValue(axValue)
      }
      return dictionary
    }
    if let array = value as? [Any] {
      return array.compactMap(replAccessibilityTree(from:))
    }
    return value
  }

  /// Renders an `AXValue` as a String, preserving boolean semantics
  /// (`"true"`/`"false"`) rather than letting a property-list Boolean become "1"/"0".
  private static func stringForAXValue(_ value: Any) -> String {
    if CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID() {
      return (value as? Bool ?? false) ? "true" : "false"
    }
    return String(describing: value)
  }
}
