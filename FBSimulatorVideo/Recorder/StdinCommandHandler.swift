/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreVideo
import FBControlCore
import FBSimulatorControl
import Foundation

/// A JSON command received on stdin, as the closed set of things a line can mean.
enum StdinCommand: Decodable {
  case overlay([OverlayShape])
  case screenshot(index: Int)
  case chapter(text: String)
  case bar(position: String, content: BarContentSpec, fit: Bool?)
  /// The deprecated `bottomStatus` / `topStatus` aliases: a bar fixed to one position, carrying
  /// only text and never a `fit`.
  case deprecatedStatus(position: String, content: BarContent)
  case forceKeyframe
  case shutdown
  /// A recognized method whose required field is absent. Distinct from a decode failure, which
  /// rejects a line before it can be classified at all.
  case incomplete(Incomplete)
  case unrecognized(method: String)

  enum Incomplete {
    case barMissingPosition
    case chapterMissingText
  }

  /// The `bar` command's `content` selector folded together with its `text`. An unrecognized
  /// selector stays a value rather than becoming a decode failure, because it leaves the bar
  /// untouched instead of invalidating the line it arrived on.
  enum BarContentSpec: Equatable {
    case resolved(BarContent)
    case unrecognized(String)

    init(content: String?, text: String?) {
      switch content {
      case "text":
        self = .resolved(.text(text ?? ""))
      case "stats":
        self = .resolved(.stats)
      case nil, .some(""):
        self = .resolved(.hidden)
      case .some(let unknown):
        self = .unrecognized(unknown)
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case method
    case params
  }

  /// Every command's fields on the wire, in one container. Decoding it whole is load-bearing: the
  /// protocol rejects a line with a malformed field even when the method it names never reads that
  /// field, so classification has to happen after the container is decoded, not instead of it.
  private struct Params: Decodable {
    var overlays: [OverlayShape]?
    var index: Int?
    var text: String?
    var position: String?
    var content: String?
    var fit: Bool?
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let method = try container.decode(String.self, forKey: .method)
    let params = try container.decodeIfPresent(Params.self, forKey: .params) ?? Params()

    switch method {
    case "overlay":
      self = .overlay(params.overlays ?? [])
    case "screenshot":
      self = .screenshot(index: params.index ?? 0)
    case "chapter":
      guard let text = params.text, !text.isEmpty else {
        self = .incomplete(.chapterMissingText)
        return
      }
      self = .chapter(text: text)
    case "bar":
      guard let position = params.position else {
        self = .incomplete(.barMissingPosition)
        return
      }
      self = .bar(
        position: position,
        content: BarContentSpec(content: params.content, text: params.text),
        fit: params.fit
      )
    case "bottomStatus":
      self = .deprecatedStatus(position: "bottom", content: params.text.map(BarContent.text) ?? .hidden)
    case "topStatus":
      self = .deprecatedStatus(position: "top", content: params.text.map(BarContent.text) ?? .hidden)
    case "force_keyframe":
      self = .forceKeyframe
    case "shutdown":
      self = .shutdown
    default:
      self = .unrecognized(method: method)
    }
  }
}

/// Handles fire-and-forget JSON commands from stdin for the video-stream subcommand.
///
/// Commands are one JSON object per line. No responses are sent — stdin is a one-way pipe.
/// stdout is unused (or available for video data). stderr carries logs.
@MainActor
public final class StdinCommandHandler {
  public let renderer: OverlayRenderer
  let screenshotDir: String?
  let logger: any ControlCoreLogger

  public private(set) var shutdownRequested = false
  private var shutdownContinuation: CheckedContinuation<Void, Never>?

  /// Weak reference to the video stream for overlay updates and timed metadata.
  /// Set by the caller after stream creation.
  public weak var videoStream: SimulatorVideoStream?

  public init(
    renderer: OverlayRenderer,
    screenshotDir: String?,
    logger: any ControlCoreLogger
  ) {
    self.renderer = renderer
    self.screenshotDir = screenshotDir
    self.logger = logger
  }

  /// Process a single JSON line from stdin. Async so command effects on the video-stream actor are
  /// awaited, preserving strict per-line ordering (a screenshot observes every prior overlay update).
  public func handleLine(_ line: String) async {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard let data = trimmed.data(using: .utf8) else { return }

    let command: StdinCommand
    do {
      command = try JSONDecoder().decode(StdinCommand.self, from: data)
    } catch {
      logger.log("Failed to decode stdin command: \(error)")
      return
    }

    switch command {
    case .overlay(let overlays):
      await handleOverlay(overlays)
    case .screenshot(let index):
      await handleScreenshot(index: index)
    case .chapter(let text):
      await handleChapter(text)
    case .bar(let position, let content, let fit):
      await handleBar(position: position, content: content, fit: fit)
    case .deprecatedStatus(let position, let content):
      logger.log("\(position)Status is deprecated; use {method:\"bar\", params:{position:\"\(position)\", ...}}")
      await setBar(content, position: position, fit: nil)
    case .forceKeyframe:
      handleForceKeyframe()
    case .shutdown:
      handleShutdown()
    case .incomplete(.barMissingPosition):
      logger.log("bar command missing position")
    case .incomplete(.chapterMissingText):
      logger.log("Chapter command missing text")
    case .unrecognized(let method):
      logger.log("Unknown stdin command: \(method)")
    }
  }

  /// `{"method":"force_keyframe"}` — the next encoded frame is an IDR. A consumer that has just
  /// joined a stream (or lost frames) can decode immediately instead of waiting for the next
  /// periodic keyframe; the same command the WebRTC streamer accepts, so callers need one spelling.
  private func handleForceKeyframe() {
    guard let videoStream else {
      logger.log("force_keyframe requested but no video stream available")
      return
    }
    videoStream.requestKeyFrame()
    logger.log("Forwarded force_keyframe to video stream")
  }

  /// Wait for a shutdown command. Returns when "shutdown" is received or stdin closes.
  public func waitForShutdown() async {
    if shutdownRequested { return }
    await withCheckedContinuation { continuation in
      self.shutdownContinuation = continuation
    }
  }

  // MARK: - Command Handlers

  private func handleOverlay(_ overlays: [OverlayShape]) async {
    if overlays.isEmpty {
      renderer.clear()
      // Re-render bars if any are active, since clear() wipes the buffer.
      let hasBarContent = renderer.barContent.values.contains(where: { $0 != .hidden })
      if hasBarContent {
        renderer.renderToBuffer()
        await updateStreamOverlay(renderer.buffer)
      } else {
        await updateStreamOverlay(nil)
      }
      logger.log("Overlay cleared")
    } else {
      renderer.render(overlays: overlays)
      await updateStreamOverlay(renderer.buffer)
      logger.log("Overlay updated with \(overlays.count) shapes")

      // Start effect timer if any shapes have animations. The refresh is fire-and-forget: animation
      // frames have no ordering contract with stdin commands.
      renderer.startEffectTimer { [weak self] in
        Task { [weak self] in
          await self?.updateStreamOverlay(self?.renderer.buffer)
        }
      }
    }
  }

  /// Push the renderer's buffer to the video-stream actor.
  private func updateStreamOverlay(_ buffer: CVPixelBuffer?) async {
    guard let videoStream else { return }
    // The overlay CVPixelBuffer is produced by the renderer and only read by the stream's
    // compositor; the renderer serializes its own mutations.
    // patternlint-disable-next-line swift-nonisolated-unsafe
    nonisolated(unsafe) let buffer = buffer
    unsafe await videoStream.updateOverlayBuffer(buffer)
  }

  private func handleScreenshot(index: Int) async {
    guard let dir = screenshotDir else {
      logger.log("Screenshot requested but no --screenshot-dir configured")
      return
    }
    guard let videoStream else {
      logger.log("Screenshot requested but no video stream available")
      return
    }

    let tmpPath = (dir as NSString).appendingPathComponent("screenshot_\(index).tmp.png")
    let finalPath = (dir as NSString).appendingPathComponent("screenshot_\(index).png")

    logger.log("Screenshot \(index) requested (writing to \(finalPath))")

    let pngData: Data
    do {
      pngData = try await videoStream.captureCompositedScreenshot()
    } catch {
      logger.log("Screenshot \(index) failed: \(error.localizedDescription)")
      return
    }

    // Atomic rename: write to .tmp first, then rename.
    if FileManager.default.fileExists(atPath: tmpPath) {
      try? FileManager.default.removeItem(atPath: tmpPath)
    }
    guard FileManager.default.createFile(atPath: tmpPath, contents: pngData) else {
      logger.log("Screenshot \(index) failed: could not create file at \(tmpPath)")
      return
    }
    guard unsafe rename(tmpPath, finalPath) == 0 else {
      logger.log("Screenshot \(index) failed: could not rename \(tmpPath) to \(finalPath) (errno=\(errno))")
      return
    }
    logger.log("Screenshot \(index) written to \(finalPath) (\(pngData.count) bytes)")
  }

  private func handleBar(position: String, content: StdinCommand.BarContentSpec, fit: Bool?) async {
    switch content {
    case .resolved(let barContent):
      await setBar(barContent, position: position, fit: fit)
    case .unrecognized(let unknown):
      logger.log("bar command unknown content type: \(unknown)")
    }
  }

  private func setBar(_ barContent: BarContent, position: String, fit: Bool?) async {
    // `fit` is a per-bar setting: when provided it overrides; when omitted the previous value is
    // retained. It applies to whatever the bar currently displays (text or stats) so callers can
    // set it once and have subsequent stats updates inherit the shrink-to-fit behaviour.
    if let fit {
      renderer.setBarFit(fit, position: position)
    }
    renderer.setBarContent(barContent, position: position)
    await updateStreamOverlay(renderer.buffer)
    logger.log("bar \(position) set to \(barContent) (fit=\(renderer.barFit[position] ?? false))")
  }

  private func handleChapter(_ text: String) async {
    guard let videoStream else {
      logger.log("Chapter command received but no video stream available")
      return
    }
    await videoStream.writeTimedMetadata(text)
    logger.log("Chapter marker emitted: \(text)")
  }

  private func handleShutdown() {
    logger.log("Shutdown requested via stdin")
    shutdownRequested = true
    shutdownContinuation?.resume()
    shutdownContinuation = nil
  }
}

// MARK: - Signal-driven stdin loop

extension StdinCommandHandler {

  /// Drive this handler's stdin command loop until it ends (stdin EOF or a `shutdown` command) or a
  /// termination signal (SIGINT/SIGTERM) arrives — whichever comes first — then return so the caller
  /// can finalize recording/streaming. Mirrors
  /// `LaunchedApplication.waitForAppToExitOrSignal`: the signal/lifecycle handling lives in the layer
  /// the command calls, so `video-stream`/`record` stay signal-agnostic.
  ///
  /// Uses `stdinLines`, whose read ends on cancellation, so a signal genuinely stops the loop instead
  /// of wedging on an uninterruptible read. Both task-group children are non-isolated (matching
  /// `waitForAppToExitOrSignal`), hopping to the main actor only to touch this `@MainActor` handler —
  /// the Swift 6 region checker rejects an actor-isolated child task in the group.
  public nonisolated func driveUntilStoppedOrSignal(waitForSignal: @escaping @Sendable () async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await line in stdinLines() {
          await self.handleLine(line)
          if await self.shutdownRequested { break }
        }
        // Natural end (EOF / `shutdown`): synthesize a shutdown so the handler stops the stream
        // cleanly. On cancellation (a signal won the race) skip it — the caller finalizes directly.
        if !Task.isCancelled {
          if await !self.shutdownRequested {
            await self.handleLine("{\"method\":\"shutdown\"}")
          }
        }
      }
      group.addTask { await waitForSignal() }
      _ = await group.next()
      group.cancelAll()
    }
  }
}
