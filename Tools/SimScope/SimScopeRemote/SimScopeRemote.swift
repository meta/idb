/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

// patternlint-disable avoid-print-to-prevent-production-overhead

import ArgumentParser
import CoreGraphics
import Foundation
import SimScopeProtocol

/// Where to find SimScope, and how much of what it says to print.
struct Connection: ParsableArguments {
  @Option(name: .customLong("socket"), help: "the control socket of the SimScope to join")
  var socket: String = ControlSocket.defaultPath

  @Flag(name: .customLong("json"), help: "print the raw result instead of prose")
  var json = false

  /// `hold` is how long the command itself may legitimately take; the client waits that long plus slack.
  func channel(hold: TimeInterval = 0) throws -> Channel {
    try Channel(path: socket, timeout: hold + Channel.timeoutSlack)
  }

  func emit<Payload: Encodable>(_ payload: Payload, _ prose: (Payload) -> Void) throws {
    guard json else { return prose(payload) }
    print(String(decoding: try Render.encoder.encode(payload), as: UTF8.self))
  }
}

/// The caption the human reads in the Action Log. Mandatory on every command that moves the device,
/// which is why it is a required option rather than a courtesy.
struct Intent: ParsableArguments {
  @Option(
    name: [.short, .customLong("intent")],
    help: "why you are doing this, in the first person — the human reads it in the action log")
  var intent: String
}

@main
struct Remote: ParsableCommand {

  static let configuration = CommandConfiguration(
    commandName: "simscope-remote",
    abstract: "Join a running SimScope and drive the simulator alongside its human.",
    discussion: """
      SimScope must already be running against the simulator. Everything either party does lands on \
      one shared timeline: `watch` reads the human's half of it, and every mutating command writes \
      its intent into theirs.
      """,
    subcommands: [
      Status.self, Describe.self, HitTest.self, Tap.self, Swipe.self, TypeText.self, Key.self,
      Button.self, Inject.self, Say.self, Find.self, Scan.self, View.self, Screenshot.self, Record.self, Watch.self,
      WaitForNextMessage.self,
      Launch.self, Terminate.self, Cmd.self,
    ])
}

// MARK: - Observation

extension Remote {

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "the device, its screen size, and where the timeline has got to")

    @OptionGroup var connection: Connection

    func run() throws {
      let status: AgentStatus = try connection.channel().call(.status)
      try connection.emit(status, Render.status)
    }
  }

  struct Describe: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "the accessibility tree of what is on screen")

    @OptionGroup var connection: Connection

    @Flag(name: .customLong("all"), help: "include the elements normally filtered out as noise")
    var all = false

    /// Overrides traversal for this read; coverage can vary with the screen and its view hierarchy.
    @Option(help: "view-hierarchy or semantic, for this read only") var traversal: String?

    func run() throws {
      let tree: AgentTree = try connection.channel().call(
        .describe(includeAll: all, traversal: traversal))
      try connection.emit(tree) { tree in
        tree.elements.forEach { print(Render.element($0)) }
        print(tree.coverage)
      }
    }
  }

  struct HitTest: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "hittest", abstract: "the element under a screen point")

    @OptionGroup var connection: Connection

    @Argument(help: "screen point, in simulator points") var x: Double
    @Argument(help: "screen point, in simulator points") var y: Double

    func run() throws {
      let hit: AgentHit = try connection.channel().call(.hitTest(point: CGPoint(x: x, y: y)))
      try connection.emit(hit) { print($0.element.map(Render.element) ?? "nothing at that point") }
    }
  }

  /// Block until the human says something, print it, and exit — then be run again for the next one.
  ///
  /// `watch` is a tail for a person at a terminal: it never returns, which is the wrong shape for an
  /// agent whose shell caps a single command. Cursor arithmetic on top of `watch --once` is the other
  /// wrong shape — it makes every caller reimplement "what have I already seen", and getting it wrong
  /// silently drops a request or answers one twice.
  ///
  /// So the cursor lives in a file beside the socket and this command owns it. Consecutive runs deliver
  /// consecutive messages, and a run that is killed before it returns consumes nothing: the cursor only
  /// advances once a message has actually been handed over, so an agent harness cutting the command off
  /// mid-wait loses no request. It waits forever by default for the same reason — a quiet human is not
  /// an error, and an agent that exits on silence has to be nursed back up.
  ///
  /// What they *did* before they typed comes back with what they said. A person works the screen and
  /// then asks about it, so the request usually only makes sense against the actions in front of it —
  /// "now try it in dark mode" means nothing without the four taps that opened Display & Brightness.
  /// Those actions do not end the wait, though: only a message does. An action is context for the next
  /// request rather than a request itself, and returning on one would wake the agent every time the
  /// human moved.
  struct WaitForNextMessage: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "wait-for-next-message",
      abstract: "block until the human types a message, print what they did and said, and exit")

    @OptionGroup var connection: Connection

    @Option(help: "seconds to wait before giving up; 0 waits forever") var wait: Int = 0

    @Option(help: "where to remember what has been delivered — defaults to beside the socket")
    var cursor: String?

    /// One agent per socket by default. A second one wants its own file, or the two will consume each
    /// other's messages, which reads as requests going missing at random.
    private var cursorPath: String { cursor ?? (connection.socket + ".agent-cursor") }

    func run() throws {
      let channel = try connection.channel(hold: TimeInterval(Self.slice))
      var at = try startingCursor(channel)
      let deadline = wait > 0 ? Date().addingTimeInterval(TimeInterval(wait)) : Date.distantFuture
      // What they have done since the last delivery, banked poll by poll. Held rather than printed as
      // it arrives, because this command hands over exactly once, when a message makes the whole span
      // worth reading.
      var did: [SessionEvent] = []

      while Date() < deadline {
        let timeline: AgentTimeline = try channel.call(
          .events(since: at, waitMs: Self.slice * 1000))
        at = timeline.next
        // Only theirs. The agent's own actions and SimScope's replies to them are already in its
        // scrollback, and handing those back would bury the two lines it does not have.
        let theirs = timeline.events.filter { $0.source == .human }
        guard theirs.contains(where: { $0.action.isChat }) else {
          did.append(contentsOf: theirs)
          continue
        }
        // Written only now: a run cut short before this point has delivered nothing, so the next run
        // re-delivers rather than skipping. That covers the banked actions too — they are re-read from
        // the timeline on the next run rather than dying with this process.
        try? String(at).write(toFile: cursorPath, atomically: true, encoding: .utf8)
        for event in did + theirs {
          if connection.json {
            print(String(decoding: try Render.encoder.encode(event), as: UTF8.self))
          } else if case let .chat(text) = event.action {
            // Bare, and last of its span: the message is the request, and an agent that wants only
            // that can still read the untagged line.
            print(text)
          } else {
            print(Render.event(event))
          }
        }
        return
      }
      throw ExitCode(8) // nothing was said before the deadline
    }

    /// Where to resume. A first run starts from now rather than the beginning of the session: the
    /// command is for what the human says next, and replaying a whole session's chat as if it had just
    /// arrived would have an agent answering questions that were already answered.
    private func startingCursor(_ channel: Channel) throws -> Int {
      if let saved = try? String(contentsOfFile: cursorPath, encoding: .utf8),
        let at = Int(saved.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        return at
      }
      let status: AgentStatus = try channel.call(.status)
      return status.eventCount
    }

    /// How long each poll holds the socket open. The overall wait is built from these rather than one
    /// long hold, so a forever wait does not depend on either end tolerating an unbounded read.
    private static let slice = 25
  }

  struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "tail the shared timeline, including everything the human does")

    @OptionGroup var connection: Connection

    @Option(help: "cursor to resume from — omit for only what happens next, 0 for the whole session")
    var since: Int?

    @Option(help: "seconds to hold each poll open") var wait: Int = 30

    @Flag(help: "return after the first batch instead of tailing") var once = false

    func run() throws {
      let channel = try connection.channel(hold: TimeInterval(wait))
      var cursor: Int
      if let since {
        cursor = since
      } else {
        let status: AgentStatus = try channel.call(.status)
        cursor = status.eventCount
      }

      while true {
        let timeline: AgentTimeline = try channel.call(
          .events(since: cursor, waitMs: wait * 1000))
        for event in timeline.events {
          if connection.json {
            print(String(decoding: try Render.encoder.encode(event), as: UTF8.self))
          } else {
            print(Render.event(event))
          }
        }
        cursor = timeline.next
        // The caller is usually reading this through a pipe, where stdout is block-buffered and a
        // quiet simulator would hold a batch back until the next one filled the block.
        unsafe fflush(stdout)
        if once { return }
      }
    }
  }
}

// MARK: - Driving

extension Remote {

  struct Tap: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "tap an element, or a screen point")

    @OptionGroup var connection: Connection
    @OptionGroup var caption: Intent

    @Option(help: "the accessibility label to aim at") var label: String?
    @Option(help: "screen point, in simulator points") var x: Double?
    @Option(help: "screen point, in simulator points") var y: Double?
    @Option(help: "text that must appear in the tree afterwards, else this exits non-zero")
    var expect: String?
    @Flag(help: "exit non-zero if the tree is unchanged after the tap")
    var requireChange = false
    @Option(name: .customLong("wait"), help: "seconds to keep checking for the expected arrival")
    var waitSeconds: TimeInterval = 25

    /// Overrides traversal for label resolution and the before/after verification reads.
    @Option(help: "view-hierarchy or semantic, for resolving the label") var traversal: String?

    private var target: AgentTapTarget {
      get throws {
        switch (label, x, y) {
        case let (label?, nil, nil):
          return .label(label)
        case let (nil, x?, y?):
          return .point(CGPoint(x: x, y: y))
        case (nil, .some, nil), (nil, nil, .some):
          throw ValidationError("--x and --y go together")
        default:
          throw ValidationError("tap takes either --label or --x/--y")
        }
      }
    }

    func validate() throws {
      _ = try target
    }

    func run() throws {
      // A tap that dispatches is not a tap that did something. The screen is read either side so the
      // caller is told which happened, rather than inferring success from an exit code that only ever
      // reports whether the touch was delivered.
      let before = (requireChange || expect != nil) ? try? Self.treeText(connection, traversal: traversal) : nil
      let acted: AgentActed = try connection.channel().call(
        .tap(try target, traversal: traversal), intent: caption.intent)
      try connection.emit(acted) { print($0.prose) }

      guard requireChange || expect != nil else { return }
      // Poll rather than sleep a fixed interval: a screen that has already changed should cost nothing
      // to confirm, otherwise verification silently becomes the dominant cost of a scripted run and
      // any timing comparison measures the checking instead of the work.
      var after = ""
      // Allow for slow accessibility reads and screen transitions; stop once verification succeeds.
      let deadline = Date().addingTimeInterval(waitSeconds)
      repeat {
        after = (try? Self.treeText(connection, traversal: traversal)) ?? ""
        let satisfied =
          (expect.map { after.localizedCaseInsensitiveContains($0) } ?? true)
          && (!requireChange || before != after)
        if satisfied { break }
        Thread.sleep(forTimeInterval: 0.2)
      } while Date() < deadline

      if let expect, !after.localizedCaseInsensitiveContains(expect) {
        FileHandle.standardError.write(Data("tap did not produce \"\(expect)\": not in the tree afterwards\n".utf8))
        throw ExitCode(3)
      }
      if requireChange, let before, before == after {
        FileHandle.standardError.write(Data("tap changed nothing: the tree is byte-identical afterwards\n".utf8))
        throw ExitCode(4)
      }
    }

    /// The rendered tree, used as a cheap before/after fingerprint of the screen.
    /// Verification must use the tap's traversal strategy because different strategies can expose
    /// different elements on the same screen.
    private static func treeText(_ connection: Connection, traversal: String?) throws -> String {
      let tree: AgentTree = try connection.channel().call(
        .describe(includeAll: false, traversal: traversal))
      // Coverage plus every element's description: enough to tell one screen from another, and cheap
      // to compare, without depending on how any single element happens to render.
      let rows = tree.elements.map { e in
        [e.type, e.label, e.identifier, e.value].compactMap { $0 }.joined(separator: "|")
      }
      return tree.coverage + "\n" + rows.joined(separator: "\n")
    }
  }

  struct Swipe: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "drag between two screen points")

    @OptionGroup var connection: Connection
    @OptionGroup var caption: Intent

    @Argument var fromX: Double
    @Argument var fromY: Double
    @Argument var toX: Double
    @Argument var toY: Double

    func run() throws {
      let acted: AgentActed = try connection.channel().call(
        .swipe(from: CGPoint(x: fromX, y: fromY), to: CGPoint(x: toX, y: toY)),
        intent: caption.intent)
      try connection.emit(acted) { print($0.prose) }
    }
  }

  struct TypeText: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "type", abstract: "type text into whatever has focus")

    @OptionGroup var connection: Connection
    @OptionGroup var caption: Intent

    @Argument var text: String

    func run() throws {
      let acted: AgentActed = try connection.channel().call(.type(text), intent: caption.intent)
      try connection.emit(acted) { print($0.prose) }
    }
  }

  /// Bring an app up, optionally under a different environment.
  struct Launch: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "launch an app, optionally with environment overrides")

    @OptionGroup var connection: Connection
    @OptionGroup var caption: Intent

    @Argument(help: "bundle id, e.g. com.example.MyApp") var bundleID: String

    @Option(
      name: .customLong("env"), parsing: .upToNextOption,
      help: "KEY=VALUE, repeatable — passed to the app as its environment")
    var environment: [String] = []

    @Option(name: .customLong("arg"), parsing: .upToNextOption, help: "launch argument, repeatable")
    var arguments: [String] = []

    @Flag(inversion: .prefixedNo, help: "relaunch if already running (default), or fail instead")
    var relaunch = true

    func run() throws {
      // Values may contain `=`, so only the first occurrence separates the key and value.
      var env: [String: String] = [:]
      for pair in environment {
        guard let split = pair.firstIndex(of: "=") else {
          throw ValidationError("--env expects KEY=VALUE, got “\(pair)”")
        }
        env[String(pair[pair.startIndex..<split])] = String(pair[pair.index(after: split)...])
      }
      let acknowledgement: AgentAcknowledgement = try connection.channel().call(
        .launch(bundleID: bundleID, environment: env, arguments: arguments, relaunch: relaunch),
        intent: caption.intent)
      try connection.emit(acknowledgement) { _ in print("launched \(bundleID)") }
    }
  }

  /// Stop an app. Succeeds whether or not it was running, because "make sure this is not running" is
  /// what a scene is actually asking for.
  struct Terminate: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "terminate an app")

    @OptionGroup var connection: Connection
    @OptionGroup var caption: Intent

    @Argument(help: "bundle id") var bundleID: String

    func run() throws {
      let acknowledgement: AgentAcknowledgement = try connection.channel().call(
        .terminate(bundleID: bundleID), intent: caption.intent)
      try connection.emit(acknowledgement) { _ in print("terminated \(bundleID)") }
    }
  }

  struct Key: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "press a named key: return, tab, escape, delete, up, down, left, right")

    @OptionGroup var connection: Connection
    @OptionGroup var caption: Intent

    @Argument var name: String

    func run() throws {
      let acted: AgentActed = try connection.channel().call(.key(name), intent: caption.intent)
      try connection.emit(acted) { print($0.prose) }
    }
  }

  struct Button: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "press a device button: home, lock, side-button, siri, apple-pay, shake")

    @OptionGroup var connection: Connection
    @OptionGroup var caption: Intent

    @Argument var name: String

    func run() throws {
      let acted: AgentActed = try connection.channel().call(.button(name), intent: caption.intent)
      try connection.emit(acted) { print($0.prose) }
    }
  }

  struct Inject: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "compile Swift and run it inside the app on screen",
      discussion: """
        The snippet runs on the main thread unless --off-main-thread is passed. Its last expression \
        is the value printed back. A snippet that fails to compile is not an error here: the \
        compiler's diagnostic is the output, so you can iterate on it.
        """)

    /// Past SimScope's own watchdog on a snippet, so a slow first compile — which loads the app's
    /// debug symbols — reads as a compile taking its time rather than as a dropped connection.
    static let hold: TimeInterval = 210

    @OptionGroup var connection: Connection
    @OptionGroup var caption: Intent

    @Argument(help: "the snippet, if it is short enough to quote") var code: String?

    @Option(name: [.short, .customLong("file")], help: "read the snippet from a file, or - for stdin")
    var file: String?

    @Option(name: .customLong("bundle-id"), help: "the app to run in, if not SimScope's own")
    var bundleID: String?

    @Flag(name: .customLong("off-main-thread"), help: "do not wrap the snippet in a main-thread hop")
    var offMainThread = false

    /// Where the snippet comes from, resolved without reading it — so a missing snippet is rejected
    /// during validation without stdin being consumed to find that out.
    private enum Source {
      case standardInput
      case file(String)
      case literal(String)
    }

    private var source: Source {
      get throws {
        switch (file, code) {
        case ("-", _): return .standardInput
        case let (path?, _): return .file(path)
        case let (nil, code?): return .literal(code)
        case (nil, nil):
          throw ValidationError("inject needs a snippet: CODE, --file PATH, or --file -")
        }
      }
    }

    func validate() throws {
      _ = try source
    }

    func run() throws {
      let snippet: String
      switch try source {
      case .standardInput:
        snippet = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
      case let .file(path):
        snippet = try String(contentsOfFile: path, encoding: .utf8)
      case let .literal(code):
        snippet = code
      }

      let injection: AgentInjection = try connection.channel(hold: Self.hold).call(
        .inject(code: snippet, bundleID: bundleID, onMainThread: !offMainThread),
        intent: caption.intent)
      try connection.emit(injection) {
        print($0.output.nonEmpty ?? ($0.succeeded ? "(no value)" : "(no diagnostic)"))
      }
      guard injection.succeeded else { throw ExitCode.failure }
    }
  }
}

// MARK: - Talking to the human

extension Remote {

  struct Say: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "post a message into the human's action log")

    @OptionGroup var connection: Connection

    @Argument var text: String

    func run() throws {
      let acknowledgement: AgentAcknowledgement = try connection.channel().call(.say(text))
      try connection.emit(acknowledgement) { _ in print("said") }
    }
  }

  /// Ask SimScope whether something is on screen, and have SimScope be the one that says so.
  ///
  /// `say` states whatever the caller typed. This states what the rendered tree actually contains,
  /// written into the log by SimScope itself, and exits non-zero when there is no match — so a scene
  /// cannot narrate a finding it has not earned, and cannot continue past one it got wrong.
  struct Find: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "search the rendered tree; SimScope logs the result and exits non-zero if absent")

    @OptionGroup var connection: Connection

    @Argument var text: String

    @Flag(help: "invert: succeed only when the string is absent") var absent = false

    /// Present-and-reachable is a stronger claim than present, and on some screens only the weaker one
    /// is true. A scene that intends to act on what it found should assert the stronger one.
    @Flag(help: "require the match to have a position, not merely exist") var tappable = false

    @Option(help: "view-hierarchy or semantic, for this read only") var traversal: String?

    func run() throws {
      let tree: AgentTree = try connection.channel().call(
        .find(needle: text, traversal: traversal))
      let found = !tree.elements.isEmpty
      try connection.emit(tree) { t in
        for element in t.elements.prefix(10) { print(Render.element(element)) }
      }
      if found == absent {
        throw ExitCode(absent ? 5 : 6)
      }
      if tappable, !tree.elements.contains(where: { $0.tapX != nil && $0.tapY != nil }) {
        throw ExitCode(7)
      }
    }
  }

  /// Discover a screen the tree walk cannot see, by sweeping hit-tests down it.
  struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "sweep hit-tests down the screen; SimScope logs what it found")

    @OptionGroup var connection: Connection

    @Option var x: Double = 201
    @Option(name: .customLong("from")) var fromY: Double = 60
    @Option(name: .customLong("to")) var toY: Double = 800
    @Option var step: Double = 24
    @Option(help: "exit non-zero unless something matching this is found") var expect: String?

    func run() throws {
      let tree: AgentTree = try connection.channel().call(
        .scan(x: x, from: fromY, to: toY, step: step))
      try connection.emit(tree) { t in
        for element in t.elements { print(Render.element(element)) }
      }
      if let expect {
        let hit = tree.elements.contains {
          Render.element($0).localizedCaseInsensitiveContains(expect)
        }
        if !hit { throw ExitCode(7) }
      }
    }
  }

  /// Drive the window's own controls, so a session can SHOW that a screen reads differently
  /// depending on how it is asked instead of claiming it.
  struct View: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "change what the SimScope window shows: read strategy and screen overlay")

    @OptionGroup var connection: Connection

    @Option(help: "view-hierarchy or semantic") var traversal: String?
    @Option(help: "off, interactive or all") var overlay: String?

    func run() throws {
      let ack: AgentAcknowledgement = try connection.channel().call(
        .view(traversal: traversal, overlay: overlay))
      try connection.emit(ack) { _ in print("view updated") }
    }
  }

  /// Capture the screen as pixels — the representation that is always what is actually displayed,
  /// for when the tree cannot be trusted.
  struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "write the current screen to a PNG, and report the pixel-to-point scale")

    @OptionGroup var connection: Connection

    @Option(help: "where to write the PNG") var path: String?

    func run() throws {
      let ack: AgentAcknowledgement = try connection.channel().call(.screenshot(path: path))
      try connection.emit(ack) { _ in print(path ?? "/tmp/simscope-screen.png") }
    }
  }

  struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "start or stop recording the SimScope window to a movie")

    enum Action: String, ExpressibleByArgument, CaseIterable {
      case start, stop
    }

    @OptionGroup var connection: Connection

    @Argument var action: Action

    @Option(help: "where to write the movie — only meaningful with start") var path: String?

    func run() throws {
      let state: AgentRecordingState = try connection.channel().call(
        .record(action == .start ? .start(path: path) : .stop))
      try connection.emit(state, Render.recording)
    }
  }
}

// MARK: - Escape hatch

extension Remote {

  struct Cmd: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "send one raw JSON request and print the raw reply",
      discussion: """
        For requests this client does not model. The line is sent as written and the reply printed \
        as received, so a request that is malformed is answered by SimScope rather than rejected here.
        """)

    @OptionGroup var connection: Connection

    @Argument(help: "a single JSON object, e.g. '{\"method\": \"status\"}'") var request: String

    func validate() throws {
      do {
        _ = try JSONSerialization.jsonObject(with: Data(request.utf8))
      } catch {
        throw ValidationError("not valid JSON — \(error.localizedDescription)")
      }
    }

    func run() throws {
      let line = Data(request.utf8)
      let reply = try connection.channel(hold: Inject.hold).exchange(line)
      print(String(decoding: reply, as: UTF8.self))

      // Any reply decodes as an acknowledgement, whose payload ignores what it is given — all this
      // needs from the envelope is whether to exit non-zero.
      let envelope = try JSONDecoder().decode(AgentReply<AgentAcknowledgement>.self, from: reply)
      guard envelope.ok else { throw ExitCode.failure }
    }
  }
}
