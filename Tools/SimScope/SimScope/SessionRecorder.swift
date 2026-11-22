/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import Foundation
import SimScopeProtocol

/// Records a session to a shareable bundle: a `<timestamp>.simscope` folder containing `video.mp4`
/// (the simulator screen), `transcript.jsonl` (one `SessionEvent` per line, written live), and
/// `metadata.json`. Observes the `Session` bus, so it captures whatever the human and (later) the
/// agent do, in order.
@MainActor
final class SessionRecorder {

  private let backend: SimBackend
  private let session: Session

  private(set) var isRecording = false
  private(set) var bundleURL: URL?
  private var transcript: FileHandle?
  private var startDate: Date?
  private var eventCount = 0

  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  init(backend: SimBackend, session: Session) {
    self.backend = backend
    self.session = session
    session.observe { [weak self] event in self?.write(event) }
  }

  /// The directory recordings are written to. Defaults to `~/Library/Application Support/SimScope/
  /// Recordings`; overridable via the `SIMSCOPE_RECORDINGS_DIR` environment variable.
  static var recordingsDirectory: URL {
    if let override = ProcessInfo.processInfo.environment["SIMSCOPE_RECORDINGS_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("SimScope/Recordings", isDirectory: true)
  }

  @discardableResult
  func start() async throws -> URL {
    if isRecording, let bundleURL { return bundleURL }

    let stamp = Self.folderFormatter.string(from: Date())
    let bundle = Self.recordingsDirectory.appendingPathComponent("\(stamp).simscope", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

    let transcriptURL = bundle.appendingPathComponent("transcript.jsonl")
    FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
    transcript = try FileHandle(forWritingTo: transcriptURL)

    startDate = Date()
    eventCount = 0
    bundleURL = bundle
    isRecording = true

    writeMetadata(ended: nil)
    try await backend.startVideoRecording(toFile: bundle.appendingPathComponent("video.mp4").path)

    session.recordNote("Recording started → \(bundle.lastPathComponent)")
    return bundle
  }

  @discardableResult
  func stop() async -> URL? {
    guard isRecording, let bundle = bundleURL else { return nil }
    isRecording = false
    session.recordNote("Recording stopped (\(eventCount) events).")
    _ = try? await backend.stopVideoRecording()
    try? transcript?.close()
    transcript = nil
    writeMetadata(ended: Date())
    return bundle
  }

  // MARK: - Private

  private func write(_ event: SessionEvent) {
    guard isRecording, let transcript, var line = try? encoder.encode(event) else { return }
    line.append(0x0A) // newline
    transcript.write(line)
    eventCount += 1
  }

  private func writeMetadata(ended: Date?) {
    guard let bundle = bundleURL, let startDate else { return }
    let iso = ISO8601DateFormatter()
    let metadata: [String: Any] = [
      "udid": backend.simulator.udid,
      "device": backend.simulator.name,
      "screenWidthPoints": backend.pointSize.width,
      "screenHeightPoints": backend.pointSize.height,
      "startedAt": iso.string(from: startDate),
      "endedAt": ended.map { iso.string(from: $0) } as Any,
      "eventCount": eventCount,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted]) {
      try? data.write(to: bundle.appendingPathComponent("metadata.json"))
    }
  }

  private static let folderFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return formatter
  }()
}
