/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import FBSimulatorAX
import FBSimulatorControl
import Foundation
import SimScopeProtocol

/// A command the agent issued that SimScope could not carry out.
enum AgentDispatchError: Error, LocalizedError {
  case noElement(label: String)
  case elementNotTappable(label: String)
  case unknownButton(String)
  case unknownKey(String)
  case appIsClosing

  var errorDescription: String? {
    switch self {
    case .appIsClosing:
      return "SimScope is shutting down"
    case let .noElement(label):
      return "No accessibility element labelled “\(label)” is on screen"
    case let .elementNotTappable(label):
      return "The element labelled “\(label)” has no frame, so it cannot be tapped"
    case let .unknownButton(name):
      return "Unknown button “\(name)” — expected one of: \(DeviceAction.names)"
    case let .unknownKey(name):
      return "Unknown key “\(name)” — expected one of: return, tab, escape, space, delete"
    }
  }
}

/// The window recording as the dispatcher sees it: start a take, end one, and ask what is in flight.
///
/// Closures rather than a reference to the recorder, because who owns the take differs by mode — the
/// scripted demo opens one around the script, an operator's launch flag opens one for the whole run,
/// and here the agent opens one on request. The dispatcher only needs to ask.
@MainActor
struct WindowRecordingControl {
  /// The file a take in flight is being written to, or nil when nothing is recording.
  var currentURL: () -> URL?
  var start: (String?) async throws -> URL
  var stop: () async -> URL?
}

/// Executes agent commands against the same backend and session bus the human's UI drives.
///
/// Every mutating command is recorded on the `Session` *before* it is sent, tagged `.agent` and
/// narrated with the agent's own stated intent. That ordering is deliberate: the human sees what the
/// agent is about to do at the moment it happens, not after the screen has already changed under
/// them.
@MainActor
final class AgentDispatcher {

  private let backend: SimBackend
  private let session: Session
  /// Asked rather than stored, so `status` reports the recorder's live state without this type
  /// having to own or observe it.
  private let isRecording: () -> Bool
  private let windowRecording: WindowRecordingControl
  /// Shared with the operator's Swift console: one app process, and one narration of what ran in it,
  /// whichever party wrote the snippet.
  private let repl: SessionREPL

  /// How often a long-polling `events` call re-checks the timeline. Coarse enough to be free at
  /// idle, fine enough that an agent watching the human feels immediate.
  private static let eventPollInterval = Duration.milliseconds(100)

  init(
    backend: SimBackend, session: Session, isRecording: @escaping () -> Bool, repl: SessionREPL,
    windowRecording: WindowRecordingControl,
    viewControls: @escaping @MainActor (String?, String?) -> String,
    captureScreen: @escaping @MainActor (String) throws -> (pixels: CGSize, points: CGSize)
  ) {
    self.viewControls = viewControls
    self.captureScreen = captureScreen
    self.backend = backend
    self.session = session
    self.isRecording = isRecording
    self.windowRecording = windowRecording
    self.repl = repl
  }

  /// Applies a change to the window's own controls and returns a description of what changed.
  private let viewControls: @MainActor (String?, String?) -> String

  /// Writes the current frame to disk and reports pixel and point dimensions.
  private let captureScreen: @MainActor (String) throws -> (pixels: CGSize, points: CGSize)

  func handle(_ request: AgentRequest) async -> AgentResponse {
    do {
      guard let intent = request.intent else {
        guard !request.command.requiresIntent else {
          throw AgentRequestError.missingIntent(method: request.command.methodName)
        }
        return .success(id: request.id, try await perform(request.command, intent: nil))
      }
      return .success(id: request.id, try await perform(request.command, intent: intent))
    } catch {
      return .failure(id: request.id, error)
    }
  }

  // MARK: - Execution

  private func perform(_ command: AgentCommand, intent: String?) async throws -> AgentResult {
    switch command {
    case .status:
      return .status(
        AgentStatus(
          udid: backend.simulator.udid,
          device: backend.simulator.name,
          screenWidth: Double(backend.pointSize.width),
          screenHeight: Double(backend.pointSize.height),
          eventCount: session.events.count,
          recording: isRecording(),
          windowRecording: windowRecording.currentURL() != nil))

    case let .describe(includeAll, traversal):
      let snapshot = try await backend.readTree(
        includeAll: includeAll, traversal: traversal.flatMap { AXTraversalStrategy(rawValue: $0) })
      // Include timing with coverage so callers can diagnose slow reads without watching the UI.
      let coverage = snapshot.coverage.summary + (snapshot.cost.map { "  ·  \($0)" } ?? "")
      return .tree(
        AgentTree(
          elements: snapshot.rows.map(AgentElement.init(node:)), coverage: coverage))

    case let .hitTest(point):
      let hit = try await backend.hitTest(atSimulatorPoint: point)
      return .hit(AgentHit(element: hit.map(AgentElement.init(hit:))))

    case let .tap(target, traversal):
      let (point, hit) = try await resolve(target, traversal: traversal)
      // Check what is actually at the point before touching it. Reachability used to come back on every
      // element of every read, which meant paying the application to hit-test its whole tree once a
      // second; asking about the ONE element being acted on costs a single hit-test and answers the
      // question that actually matters. This is where "is it covered" belongs — at the interaction, not
      // in the frame.
      let occluder = try await occluderAt(point, intended: hit)
      let prose =
        Prose.tap(hit: hit, at: point)
        + (occluder.map { " A hit-test there finds \($0) instead." } ?? "")
      record(.tap(x: Double(point.x), y: Double(point.y)), prose: prose, intent: intent, element: hit?.phrase)
      try await backend.tap(atSimulatorPoint: point)
      return .acted(AgentActed(prose: prose, x: Double(point.x), y: Double(point.y)))

    case let .swipe(from, to):
      let hit = try? await backend.hitTest(atSimulatorPoint: from)
      let prose = Prose.swipe(from: from, to: to, startHit: hit ?? nil)
      record(
        .swipe(fromX: Double(from.x), fromY: Double(from.y), toX: Double(to.x), toY: Double(to.y)),
        prose: prose, intent: intent, element: (hit ?? nil)?.phrase)
      try await backend.swipe(fromSimulatorPoint: from, to: to)
      return .acted(AgentActed(prose: prose, x: Double(to.x), y: Double(to.y)))

    case let .type(text):
      let prose = "Typed “\(text)”."
      record(.type(text), prose: prose, intent: intent)
      try await backend.typeString(text)
      return .acted(AgentActed(prose: prose, x: 0, y: 0))

    case let .key(name):
      guard Self.knownKeys.contains(name.lowercased()) else { throw AgentDispatchError.unknownKey(name) }
      let prose = "Pressed \(name.capitalized)."
      record(.key(name), prose: prose, intent: intent)
      try await backend.sendKey(named: name)
      return .acted(AgentActed(prose: prose, x: 0, y: 0))

    case let .button(name):
      guard let action = DeviceAction.named(name) else { throw AgentDispatchError.unknownButton(name) }
      record(.device(action.name), prose: action.prose, intent: intent)
      try await backend.perform(deviceAction: action.name)
      return .acted(AgentActed(prose: action.prose, x: 0, y: 0))

    case let .say(text):
      session.recordChat(source: .agent, text)
      return .acknowledged

    case let .scan(x, from, to, step):
      // The point-query path resolves presented sheets that the tree walk misses entirely, so a
      // sweep of hit-tests is the only way to discover what is on such a screen. Deduped by phrase,
      // in the order encountered, and written to the log by SimScope so the caller cannot invent it.
      var seen: [String] = []
      var hits: [AXHit] = []
      var y = from
      while y <= to {
        if let hit = try await backend.hitTest(atSimulatorPoint: CGPoint(x: x, y: y)),
          !hit.phrase.isEmpty, !seen.contains(hit.phrase)
        {
          seen.append(hit.phrase)
          hits.append(hit)
        }
        y += step
      }
      session.recordNote(
        seen.isEmpty
          ? "Swept \(Int((to - from) / step) + 1) points down the screen — nothing resolved."
          : "Swept \(Int((to - from) / step) + 1) points down the screen — found \(seen.count): "
            + seen.joined(separator: ", "))
      return .tree(
        AgentTree(elements: hits.map(AgentElement.init(hit:)), coverage: "scan"))

    case let .screenshot(path):
      let target = path ?? NSTemporaryDirectory() + "simscope-screen.png"
      let size = try captureScreen(target)
      // Logged with the scale, because the number a caller needs is not the image but the divisor.
      session.recordNote(
        "Captured the screen to \(target) — \(Int(size.pixels.width))x\(Int(size.pixels.height)) pixels "
          + "at \(Int(size.points.width))x\(Int(size.points.height)) points, so divide pixel positions by "
          + "\(Int(size.pixels.width / max(1, size.points.width))) to tap.")
      return .acknowledged

    case let .view(traversal, overlay):
      let described = viewControls(traversal, overlay)
      session.recordNote(described)
      return .acknowledged

    case let .find(needle, traversal):
      let snapshot = try await backend.readTree(
        includeAll: false, traversal: traversal.flatMap { AXTraversalStrategy(rawValue: $0) })
      let matches = snapshot.rows.filter {
        $0.displayText.localizedCaseInsensitiveContains(needle)
      }
      // Written by SimScope from the tree it is rendering, not by the caller. A scene can therefore
      // report a finding without being able to state one the window disproves.
      let total = snapshot.rows.count
      // A match with no position is a distinct outcome from a match, and reporting it as a plain hit
      // invites a caller to tap something the reader gave it no way to reach.
      let locatable = matches.filter { $0.tapPoint != nil }
      let note: String
      if matches.isEmpty {
        note = "Searched the screen for \u{201C}\(needle)\u{201D} — no match among \(total) elements."
      } else if locatable.isEmpty {
        note =
          "Searched the screen for \u{201C}\(needle)\u{201D} — \(matches.count) of \(total) match, "
          + "but none of them have a position, so none can be tapped: "
          + matches.prefix(3).map(\.phrase).joined(separator: ", ")
      } else {
        note =
          "Searched the screen for \u{201C}\(needle)\u{201D} — \(matches.count) of \(total) match: "
          + matches.prefix(3).map(\.phrase).joined(separator: ", ")
      }
      session.recordNote(note)
      return .tree(
        AgentTree(
          elements: matches.map(AgentElement.init(node:)), coverage: snapshot.coverage.summary))

    case let .events(since, waitMs):
      return .timeline(
        AgentTimeline(events: await events(since: since, waitMs: waitMs), next: session.events.count))

    case let .record(action):
      return try await record(action)

    case let .inject(code, bundleID, onMainThread):
      // Narrated by the REPL rather than here, so the human reads an agent's snippet in the same
      // shape as one they typed themselves — and reads it before the compile, not after.
      let outcome = try await repl.run(
        code: code, bundleID: bundleID, onMainThread: onMainThread, source: .agent, intent: intent)
      return .injected(AgentInjection(succeeded: outcome.succeeded, output: outcome.output))

    case let .launch(bundleID, environment, arguments, relaunch):
      // `relaunchIfRunning` rather than terminate-then-launch: one call, and no window where the app
      // is gone and a read would fail for a reason that has nothing to do with the scene.
      let configuration = ApplicationLaunchConfiguration(
        bundleID: bundleID,
        bundleName: nil,
        arguments: arguments,
        environment: environment,
        waitForDebugger: false,
        launchMode: relaunch ? .relaunchIfRunning : .failIfRunning)
      _ = try await backend.simulator.application.launch(configuration)
      let described =
        environment.isEmpty
        ? "" : " with " + environment.keys.sorted().joined(separator: ", ")
      session.recordNote("Launched \(bundleID)\(described).")
      return .acknowledged

    case let .terminate(bundleID):
      try await backend.simulator.application.kill(bundleID: bundleID)
      session.recordNote("Terminated \(bundleID).")
      return .acknowledged
    }
  }

  // MARK: - Recording

  /// Starts or stops the recording of the whole SimScope window — the take an operator ends up with.
  ///
  /// Neither direction is silent: the recorder itself notes the file onto the session, whichever of the
  /// three ways it was started, so a take can never begin behind the person in front of the window.
  /// Starting one that is already running is not an error either — the agent gets back the file it is
  /// already being written to, so a retry after a dropped reply cannot cut the take in two.
  private func record(_ action: AgentRecordAction) async throws -> AgentResult {
    switch action {
    case let .start(path):
      if let inFlight = windowRecording.currentURL() {
        return .recording(AgentRecordingState(active: true, path: inFlight.path))
      }
      return .recording(AgentRecordingState(active: true, path: try await windowRecording.start(path).path))

    case .stop:
      return .recording(AgentRecordingState(active: false, path: await windowRecording.stop()?.path))
    }
  }

  /// The keys `SimBackend.sendKey(named:)` understands. Checked here so an unmapped name is an error
  /// the agent can see, rather than a silent no-op it would read as success.
  private static let knownKeys: Set<String> = ["return", "enter", "tab", "escape", "esc", "space", "delete", "backspace"]

  // MARK: - Timeline

  /// The events after `since`, waiting up to `waitMs` for one to arrive if there are none yet.
  ///
  /// The long poll is what lets an agent follow the human without spinning: it parks until the person
  /// does something, then returns their action already narrated.
  private func events(since: Int, waitMs: Int) async -> [SessionEvent] {
    let deadline = ContinuousClock.now + .milliseconds(max(0, waitMs))
    while session.events.count <= since, ContinuousClock.now < deadline {
      try? await Task.sleep(for: Self.eventPollInterval)
    }
    guard since < session.events.count else { return [] }
    return Array(session.events[max(0, since)...])
  }

  // MARK: - Helpers

  /// What a hit-test finds at a point, when that is not the element the caller aimed at.
  ///
  /// Nil when the point resolves to the intended element, or when there is nothing to compare against —
  /// a point tap names no expectation, so there is nothing it can disagree with. Matched on identifier
  /// where there is one and on label otherwise, because a label can be shared by a cell and the text
  /// inside it and that pair is not a disagreement worth reporting.
  private func occluderAt(_ point: CGPoint, intended: AXHit?) async throws -> String? {
    guard let intended, intended.label != nil || intended.identifier != nil else { return nil }
    guard let found = try? await backend.hitTest(atSimulatorPoint: point) ?? nil else { return nil }
    if let wanted = intended.identifier?.nonEmpty, let got = found.identifier?.nonEmpty {
      return wanted == got ? nil : found.phrase
    }
    if let wanted = intended.label?.nonEmpty, let got = found.label?.nonEmpty {
      // Containment either way: tapping a row often resolves to the label inside it, which is the same
      // element for any purpose the caller has.
      let related =
        wanted.localizedCaseInsensitiveContains(got) || got.localizedCaseInsensitiveContains(wanted)
      return related ? nil : found.phrase
    }
    return nil
  }

  private func resolve(
    _ target: AgentTapTarget, traversal: String? = nil
  ) async throws
    -> (CGPoint, AXHit?)
  {
    switch target {
    case let .point(point):
      return (point, try? await backend.hitTest(atSimulatorPoint: point) ?? nil)
    case let .label(label):
      let rows = try await backend.readTree(
        traversal: traversal.flatMap { AXTraversalStrategy(rawValue: $0) }
      ).rows
      let exact = rows.first { $0.label?.caseInsensitiveCompare(label) == .orderedSame }
      let partial = rows.first { $0.label?.localizedCaseInsensitiveContains(label) == true }
      guard let node = exact ?? partial else { throw AgentDispatchError.noElement(label: label) }
      guard let point = node.tapPoint else { throw AgentDispatchError.elementNotTappable(label: label) }
      return (point, AXHit(frame: node.frame ?? .zero, label: node.label, type: node.type, identifier: node.identifier))
    }
  }

  /// Records an agent action, appending its stated intent so the human reads *why* beside *what*.
  private func record(_ action: SessionAction, prose: String, intent: String?, element: String? = nil) {
    let narration = intent.map { "\(prose) — \($0)" } ?? prose
    session.record(source: .agent, action: action, prose: narration, element: element)
  }
}
