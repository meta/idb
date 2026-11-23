/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import SimScopeProtocol

/// Why a snippet never reached the app.
///
/// A snippet that reached it and failed to compile is deliberately not one of these: the diagnostics
/// are a result the author needs to read, not a transport failure.
enum CodeInjectionError: Error, LocalizedError {
  case toolMissing(searched: [String])
  case noBundleID
  case timedOut(seconds: Int)
  case unreadableOutput(stderr: String)

  var errorDescription: String? {
    switch self {
    case let .toolMissing(searched):
      return
        "idb-repl is not installed — looked in \(searched.joined(separator: ", ")). "
        + "Set SIMSCOPE_IDB_REPL to point at it."
    case .noBundleID:
      return
        "No app to run in — pass a bundle id, or start SimScope with --repl-bundle-id <id>"
    case let .timedOut(seconds):
      return "idb-repl did not finish within \(seconds)s"
    case let .unreadableOutput(stderr):
      return "idb-repl said nothing this run could be read from\(stderr.isEmpty ? "" : " — \(stderr)")"
    }
  }
}

/// What one run produced.
struct CodeInjectionOutcome: Sendable {
  /// Whether the snippet compiled and ran to completion. One that did not is an ordinary outcome, not
  /// an error — an author iterating on a snippet spends most of their runs here.
  let succeeded: Bool
  /// The value the snippet returned, or the compiler diagnostic that stopped it.
  let output: String
}

/// Compiles Swift and runs it inside a live process on the simulator, through `idb-repl`.
///
/// One short-lived process per run rather than a persistent child on a pipe. `idb-repl` reattaches to
/// the REPL session it already opened for a bundle id, so a value stashed by one run is still there
/// for the next — which is the REPL behaviour worth having, without a long-lived pipe to keep alive,
/// drain, and recover.
///
/// Shelling out rather than loading the shim directly: the tool owns toolchain selection, the launch
/// hook, session reattach, and the report format. SimScope's contribution to an injection is the
/// narration around it, not the compilation.
struct CodeInjector: Sendable {

  /// The simulator to run against — the one in the window, so a snippet cannot land on a device the
  /// operator is not looking at.
  let udid: String
  /// The app used when a caller does not name one, from `--repl-bundle-id` or `SIMSCOPE_REPL_BUNDLE_ID`.
  let defaultBundleID: String?
  /// Where `idb-repl` accumulates this session's Markdown report. Every run appends to the one file,
  /// so the session as a whole replays with `idb-repl replay <file>`.
  let reportURL: URL

  /// Generous, because the first run against a cold app pays for the launch, the hook, and a compile.
  private static let timeoutSeconds = 180

  private static var toolSearchPaths: [String] {
    let bundled = Bundle.main.executableURL?.deletingLastPathComponent()
      .appendingPathComponent("idb-repl").path
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return [bundled].compactMap { $0 }
      + path.split(separator: ":").map { String($0) + "/idb-repl" }
      + ["/opt/homebrew/bin/idb-repl", "/usr/local/bin/idb-repl"]
  }

  /// The app a run will land in, resolved before anything is announced so a missing bundle id is an
  /// error rather than a timeline entry for an injection that never happened.
  func resolvedBundleID(_ requested: String?) throws -> String {
    guard let target = requested?.nonEmpty ?? defaultBundleID?.nonEmpty else {
      throw CodeInjectionError.noBundleID
    }
    return target
  }

  /// Runs `code` inside `bundleID`, launching the app if it is not up yet.
  ///
  /// `reason` is passed through to `idb-repl`, which asks agents to say why they are injecting. It is
  /// the same caption the human reads in the action log, so the report and the log agree on the point
  /// of every run.
  func run(
    code: String, in bundleID: String, onMainThread: Bool, reason: String
  ) async throws -> CodeInjectionOutcome {
    let tool = try Self.locateTool()
    let companion = tool.deletingLastPathComponent().appendingPathComponent("idb_companion")
    let companionArguments =
      FileManager.default.isExecutableFile(atPath: companion.path)
      ? ["--idb-companion-binary", companion.path] : []
    try? FileManager.default.createDirectory(
      at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let result = try await Self.execute(
      tool,
      [
        "--reason", reason,
        "app",
      ] + companionArguments + [
        "--udid", udid,
        "--bundle-id", bundleID,
        "--report-path", reportURL.path,
        // A report that omits the runs that did not compile is not a transcript of the session.
        "--report-failures",
        onMainThread ? Self.wrappedForMainThread(code) : code,
      ])
    return try Self.outcome(stdout: result.stdout, stderr: result.stderr)
  }

  // MARK: - Running on the app's main thread

  /// Rewrites a snippet so its body runs on the app's main thread.
  ///
  /// Injected code runs on a REPL worker thread, and UIKit reached from there does not raise — it kills
  /// the app, and the session with it. Leading `import` lines are hoisted out because they are only
  /// legal at file scope; everything from the first real statement on goes inside the barrier.
  ///
  /// The wrapper names no result type on purpose: multi-statement closure inference reads it off the
  /// snippet's own `return`s, so one that yields a `String` and one that yields an `Int` both compile
  /// unchanged. The cost is that a diagnostic's line number counts the wrapper's lines too, which is
  /// the reason a caller can turn this off.
  static func wrappedForMainThread(_ code: String) -> String {
    let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
    let firstStatement =
      lines.firstIndex {
        let trimmed = $0.trimmingCharacters(in: .whitespaces)
        return !(trimmed.isEmpty || trimmed.hasPrefix("import ") || trimmed.hasPrefix("//"))
      } ?? lines.endIndex
    let preamble = lines[..<firstStatement].joined(separator: "\n")
    let body = lines[firstStatement...].joined(separator: "\n")
    return """
      \(preamble)
      return DispatchQueue.main.sync {
      \(body)
      }
      """
  }

  // MARK: - Reading what idb-repl said

  /// `idb-repl` exits 0 whether or not the snippet compiled, so the outcome is read from stdout, where
  /// `Result:` heads a success and `Error:` a failure. Progress chatter goes to stderr and only matters
  /// when neither marker turns up.
  private static func outcome(stdout: String, stderr: String) throws -> CodeInjectionOutcome {
    let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    for (marker, succeeded) in [("Result:", true), ("Error:", false), ("Exception:", false)] where text.hasPrefix(marker) {
      return CodeInjectionOutcome(
        succeeded: succeeded,
        output: String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    throw CodeInjectionError.unreadableOutput(
      stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func locateTool() throws -> URL {
    let candidates =
      [ProcessInfo.processInfo.environment["SIMSCOPE_IDB_REPL"]?.nonEmpty].compactMap { $0 }
      + toolSearchPaths
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    throw CodeInjectionError.toolMissing(searched: candidates)
  }

  // MARK: - Subprocess

  private static func execute(
    _ tool: URL, _ arguments: [String]
  ) async throws -> (stdout: String, stderr: String) {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try runToCompletion(tool, arguments) })
      }
    }
  }

  /// Runs the tool on the calling thread and returns what it wrote.
  ///
  /// Output goes to temporary files rather than pipes: a compile diagnostic easily outgrows a pipe's
  /// buffer, and a child that fills one nobody is draining stops there — with `waitUntilExit` below
  /// waiting for an exit that can no longer come.
  private static func runToCompletion(
    _ tool: URL, _ arguments: [String]
  ) throws -> (stdout: String, stderr: String) {
    let directory = FileManager.default.temporaryDirectory
    let stem = "simscope-repl-\(UUID().uuidString)"
    let outURL = directory.appendingPathComponent("\(stem).out")
    let errorURL = directory.appendingPathComponent("\(stem).err")
    defer {
      try? FileManager.default.removeItem(at: outURL)
      try? FileManager.default.removeItem(at: errorURL)
    }
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    let outHandle = try FileHandle(forWritingTo: outURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)

    let process = Process()
    process.executableURL = tool
    process.arguments = arguments
    process.standardOutput = outHandle
    process.standardError = errorHandle
    process.standardInput = FileHandle.nullDevice

    let started = Date()
    try process.run()
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: watchdog)
    process.waitUntilExit()
    watchdog.cancel()
    try? outHandle.close()
    try? errorHandle.close()

    // Inferred from the clock rather than tracked in a flag shared with the watchdog: the only signal
    // that arrives after the timeout has elapsed is the one the watchdog sent.
    if process.terminationReason == .uncaughtSignal,
      Date().timeIntervalSince(started) >= Double(timeoutSeconds)
    {
      throw CodeInjectionError.timedOut(seconds: timeoutSeconds)
    }
    return (try Self.read(outURL), try Self.read(errorURL))
  }

  private static func read(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}

/// The session's Swift REPL: one app process, both parties, one timeline.
///
/// Human and agent go through here rather than each reaching for a `CodeInjector`, so a snippet is
/// narrated identically whoever wrote it — and so the other party reads it off the event bus with the
/// intent attached, exactly the way they read a tap.
@MainActor
final class SessionREPL {

  private let injector: CodeInjector
  private let session: Session

  init(injector: CodeInjector, session: Session) {
    self.injector = injector
    self.session = session
  }

  /// The app a run lands in when the caller does not name one — shown to the operator so the console
  /// says what it is about to write into.
  var defaultBundleID: String? { injector.defaultBundleID }

  var reportURL: URL { injector.reportURL }

  /// Runs `code` in the app, announcing it on the timeline first and its outcome after.
  ///
  /// Announced before it runs, in the order the dispatcher uses for touches: a compile takes seconds,
  /// and the person watching the screen change should already know whose code changed it.
  @discardableResult
  func run(
    code: String, bundleID: String?, onMainThread: Bool, source: EventSource, intent: String?
  ) async throws -> CodeInjectionOutcome {
    let target = try injector.resolvedBundleID(bundleID)
    session.record(
      source: source, action: .inject(code: code, bundleID: target),
      prose: Self.prose(code: code, bundleID: target, intent: intent))
    do {
      let outcome = try await injector.run(
        code: code, in: target, onMainThread: onMainThread,
        reason: intent ?? "a SimScope session on \(target)")
      session.recordNote(outcome.succeeded ? "→ \(outcome.output)" : "→ it did not compile:\n\(outcome.output)")
      return outcome
    } catch {
      session.recordNote("→ \((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)")
      throw error
    }
  }

  private static func prose(code: String, bundleID: String, intent: String?) -> String {
    let lines = code.split(separator: "\n").count
    let sentence = "Ran \(lines) line\(lines == 1 ? "" : "s") of Swift inside \(bundleID)."
    return intent.map { "\(sentence) — \($0)" } ?? sentence
  }
}
