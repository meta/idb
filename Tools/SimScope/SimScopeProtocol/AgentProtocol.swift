/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation

// The control channel's wire format, shared by the SimScope app that serves it and the
// `simscope-remote` CLI that speaks it. Both sides read every request and reply shape out of this
// one file, so neither can drift from the other without failing to compile.

extension String {
  /// `nil` for the empty string, so an absent and a blank field collapse onto the same `?? fallback`.
  public var nonEmpty: String? { isEmpty ? nil : self }
}

/// Where a tap is aimed: at a named accessibility element, or at a raw screen point.
@frozen public enum AgentTapTarget: Equatable, Sendable {
  case label(String)
  case point(CGPoint)
}

/// What the agent asked of the window recording: begin a take, naming the file or taking the default,
/// or end the one in flight.
@frozen public enum AgentRecordAction: Equatable, Sendable {
  case start(path: String?)
  case stop
}

/// What the agent asked SimScope to do.
///
/// A closed enum rather than a method string beside a bag of optional parameters, so a `tap` with no
/// target — or a `swipe` with half a path — cannot exist once decoding has succeeded. Everything
/// downstream switches exhaustively and never re-validates.
@frozen public enum AgentCommand: Equatable, Sendable {
  case status
  case describe(includeAll: Bool, traversal: String?)
  case hitTest(point: CGPoint)
  case tap(AgentTapTarget, traversal: String?)
  case swipe(from: CGPoint, to: CGPoint)
  case type(String)
  case key(String)
  case button(String)
  case say(String)
  /// Search the rendered tree for a string. SimScope computes the answer and writes it to the log
  /// itself, so a finding cannot be authored by the caller.
  case find(needle: String, traversal: String?)
  /// Change what the SimScope window itself is showing — the read strategy and the on-screen overlay.
  /// Distinct from passing `traversal` to a single read: this moves the control the human is looking
  /// at, so a recorded session can demonstrate that the same screen reads differently depending on
  /// how it is asked, rather than asserting it.
  case view(traversal: String?, overlay: String?)
  /// Write the current screen to a PNG and report where it landed, with the pixel-to-point scale.
  ///
  /// The fallback when the tree cannot be trusted: pixels are the one representation that is always
  /// what is actually on screen. The scale is part of the answer because a caller measuring a feature
  /// in the image has to divide by it before tapping, and getting that wrong is the characteristic
  /// failure of working from screenshots.
  case screenshot(path: String?)
  /// Sweep a vertical column of hit-tests and report the distinct elements found. The point-query
  /// path resolves presented sheets that the tree walk does not, so this is how an agent discovers
  /// what is on a screen `describe` cannot see.
  case scan(x: Double, from: Double, to: Double, step: Double)
  case events(since: Int, waitMs: Int)
  case record(AgentRecordAction)
  /// Compile Swift and run it inside the app on screen. `bundleID` falls back to the one SimScope was
  /// launched with; `onMainThread` wraps the snippet in a main-thread barrier, which is what keeps a
  /// line of UIKit from killing the app out from under both parties.
  case inject(code: String, bundleID: String?, onMainThread: Bool)
  /// Launch an app on the simulator, optionally with environment overrides.
  ///
  /// `relaunch` terminates a running instance before launching with the supplied configuration.
  case launch(bundleID: String, environment: [String: String], arguments: [String], relaunch: Bool)
  /// Terminate an app on the simulator. Succeeds whether or not it was running, because "make sure
  /// this is not running" is the thing a scene actually wants.
  case terminate(bundleID: String)

  /// Whether this command changes the simulator's state, and so has to say why.
  ///
  /// The intent caption is what the human reads in the Action Log. Requiring it on exactly the
  /// mutating commands means the log records a collaborator's reasoning rather than a coordinate
  /// stream, while leaving observation (`describe`, `events`) free to run as often as it likes.
  ///
  /// `record` is exempt because it does not touch the device — but it is not silent either: the
  /// dispatcher always writes a note naming the file, so a take can never start behind the human.
  public var requiresIntent: Bool {
    switch self {
    case .tap, .swipe, .type, .key, .button, .inject, .launch, .terminate:
      return true
    case .status, .describe, .hitTest, .say, .find, .scan, .events, .record, .view, .screenshot:
      return false
    }
  }

  /// The method name this command decodes from, for diagnostics.
  public var methodName: String {
    switch self {
    case .status: return "status"
    case .describe: return "describe"
    case .hitTest: return "hittest"
    case .tap: return "tap"
    case .swipe: return "swipe"
    case .type: return "type"
    case .key: return "key"
    case .button: return "button"
    case .say: return "say"
    case .find: return "find"
    case .view: return "view"
    case .screenshot: return "screenshot"
    case .scan: return "scan"
    case .events: return "events"
    case .record: return "record"
    case .inject: return "inject"
    case .launch: return "launch"
    case .terminate: return "terminate"
    }
  }
}

/// A malformed request, reported back to the agent instead of closing the connection — a typo in one
/// command should not cost the agent its session.
public enum AgentRequestError: Error, LocalizedError, Sendable {
  case unknownMethod(String)
  case missingParameter(method: String, parameter: String)
  case unexpectedValue(method: String, parameter: String, value: String, expected: String)
  case ambiguousTapTarget
  case missingIntent(method: String)

  public var errorDescription: String? {
    switch self {
    case let .unknownMethod(method):
      return "Unknown method “\(method)”"
    case let .missingParameter(method, parameter):
      return "“\(method)” requires the “\(parameter)” parameter"
    case let .unexpectedValue(method, parameter, value, expected):
      return "“\(method)” got “\(value)” for “\(parameter)” — expected \(expected)"
    case .ambiguousTapTarget:
      return "“tap” takes either “label” or “x”/“y”, not both"
    case let .missingIntent(method):
      return
        "“\(method)” requires an “intent” describing why — it is shown to the human in the action log"
    }
  }
}

/// One line of the control channel, in either direction.
public struct AgentRequest: Sendable {
  /// Echoed back on the response so a client can match replies to requests. Absent for fire-and-forget.
  public let id: Int?
  /// Why the agent is doing this, in the first person. Required for the mutating commands.
  public let intent: String?
  public let command: AgentCommand

  public init(id: Int?, intent: String?, command: AgentCommand) {
    self.id = id
    self.intent = intent
    self.command = command
  }
}

extension AgentRequest: Decodable {

  private enum CodingKeys: String, CodingKey {
    case id, method, intent, params
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeIfPresent(Int.self, forKey: .id)
    self.intent = try container.decodeIfPresent(String.self, forKey: .intent)?.nonEmpty
    let method = try container.decode(String.self, forKey: .method).lowercased()

    // A method with no parameters may omit `params` entirely; give the parameter decoder an empty
    // container in that case so each case below reads uniformly.
    let params = try container.decodeIfPresent(AgentParameters.self, forKey: .params) ?? AgentParameters()

    func required<T>(_ value: T?, _ name: String) throws -> T {
      guard let value else { throw AgentRequestError.missingParameter(method: method, parameter: name) }
      return value
    }

    switch method {
    case "status":
      self.command = .status
    case "describe":
      self.command = .describe(includeAll: params.includeAll ?? false, traversal: params.traversal)
    case "hittest":
      self.command = .hitTest(
        point: CGPoint(x: try required(params.x, "x"), y: try required(params.y, "y")))
    case "tap":
      switch (params.label?.nonEmpty, params.x, params.y) {
      case let (label?, nil, nil):
        self.command = .tap(.label(label), traversal: params.traversal)
      case let (nil, x?, y?):
        self.command = .tap(.point(CGPoint(x: x, y: y)), traversal: params.traversal)
      case (nil, nil, nil):
        throw AgentRequestError.missingParameter(method: method, parameter: "label” or “x”/“y")
      default:
        throw AgentRequestError.ambiguousTapTarget
      }
    case "swipe":
      self.command = .swipe(
        from: CGPoint(x: try required(params.fromX, "fromX"), y: try required(params.fromY, "fromY")),
        to: CGPoint(x: try required(params.toX, "toX"), y: try required(params.toY, "toY")))
    case "type":
      self.command = .type(try required(params.text?.nonEmpty, "text"))
    case "key":
      self.command = .key(try required(params.name?.nonEmpty, "name"))
    case "button":
      self.command = .button(try required(params.name?.nonEmpty, "name"))
    case "say":
      self.command = .say(try required(params.text?.nonEmpty, "text"))
    case "find":
      self.command = .find(
        needle: try required(params.text?.nonEmpty, "text"), traversal: params.traversal)
    case "screenshot":
      self.command = .screenshot(path: params.path)
    case "view":
      self.command = .view(traversal: params.traversal, overlay: params.name)
    case "scan":
      self.command = .scan(
        x: params.x ?? 201, from: params.fromY ?? 60, to: params.toY ?? 800,
        step: params.step ?? 24)
    case "events":
      self.command = .events(since: params.since ?? 0, waitMs: params.waitMs ?? 0)
    case "record":
      switch try required(params.action?.nonEmpty, "action").lowercased() {
      case "start":
        self.command = .record(.start(path: params.path?.nonEmpty))
      case "stop":
        self.command = .record(.stop)
      case let other:
        throw AgentRequestError.unexpectedValue(
          method: method, parameter: "action", value: other, expected: "“start” or “stop”")
      }
    case "inject":
      // Main-thread wrapping defaults to on: a snippet that touches UIKit from the REPL's worker
      // thread does not fail, it takes the app down, and an agent's first snippet almost always
      // touches UIKit.
      self.command = .inject(
        code: try required(params.code?.nonEmpty, "code"),
        bundleID: params.bundleId?.nonEmpty,
        onMainThread: params.mainThread ?? true)
    case "launch":
      self.command = .launch(
        bundleID: try required(params.bundleId?.nonEmpty, "bundleId"),
        environment: params.environment ?? [:],
        arguments: params.arguments ?? [],
        relaunch: params.relaunch ?? true)
    case "terminate":
      self.command = .terminate(bundleID: try required(params.bundleId?.nonEmpty, "bundleId"))
    default:
      throw AgentRequestError.unknownMethod(method)
    }
  }

  /// The union of every command's parameters. Only the coders see this shape; the enum above is
  /// what the rest of the app works with.
  private struct AgentParameters: Codable {
    var environment: [String: String]?
    var arguments: [String]?
    var relaunch: Bool?
    var includeAll: Bool?
    var label: String?
    var x: Double?
    var y: Double?
    var fromX: Double?
    var fromY: Double?
    var toX: Double?
    var toY: Double?
    var text: String?
    var name: String?
    var since: Int?
    var waitMs: Int?
    var step: Double?
    var traversal: String?
    var action: String?
    var path: String?
    var code: String?
    var bundleId: String?
    var mainThread: Bool?

    init() {}

    /// The parameters a command travels with. The inverse of the switch above, and the reason a
    /// client cannot invent a parameter name the server does not read.
    init(_ command: AgentCommand) {
      switch command {
      case .status:
        break
      case let .describe(includeAll, traversal):
        (self.includeAll, self.traversal) = (includeAll, traversal)
      case let .hitTest(point):
        (x, y) = (point.x, point.y)
      case let .tap(.label(label), traversal):
        (self.label, self.traversal) = (label, traversal)
      case let .tap(.point(point), traversal):
        (x, y, self.traversal) = (point.x, point.y, traversal)
      case let .swipe(from, to):
        (fromX, fromY, toX, toY) = (from.x, from.y, to.x, to.y)
      case let .type(text):
        self.text = text
      case let .key(name):
        self.name = name
      case let .button(name):
        self.name = name
      case let .say(text):
        self.text = text
      case let .find(needle, traversal):
        (self.text, self.traversal) = (needle, traversal)
      case let .view(traversal, overlay):
        (self.traversal, self.name) = (traversal, overlay)
      case let .screenshot(path):
        self.path = path
      case let .scan(x, from, to, step):
        (self.x, self.fromY, self.toY, self.step) = (x, from, to, step)
      case let .events(since, waitMs):
        (self.since, self.waitMs) = (since, waitMs)
      case let .record(.start(path)):
        (action, self.path) = ("start", path)
      case .record(.stop):
        action = "stop"
      case let .inject(code, bundleID, onMainThread):
        (self.code, bundleId, mainThread) = (code, bundleID, onMainThread)
      case let .launch(bundleID, environment, arguments, relaunch):
        bundleId = bundleID
        self.environment = environment.isEmpty ? nil : environment
        self.arguments = arguments.isEmpty ? nil : arguments
        self.relaunch = relaunch
      case let .terminate(bundleID):
        bundleId = bundleID
      }
    }
  }
}

extension AgentRequest: Encodable {

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(id, forKey: .id)
    try container.encode(command.methodName, forKey: .method)
    try container.encodeIfPresent(intent, forKey: .intent)
    try container.encode(AgentParameters(command), forKey: .params)
  }
}

// MARK: - Responses

/// A described accessibility element, as the agent sees it.
public struct AgentElement: Codable, Sendable {
  public let depth: Int
  public let type: String?
  public let label: String?
  public let identifier: String?
  public let value: String?
  public let x: Double?
  public let y: Double?
  public let width: Double?
  public let height: Double?
  /// Where a tap on this element lands, so the agent can act on a described element without
  /// recomputing geometry.
  public let tapX: Double?
  public let tapY: Double?

  public init(
    depth: Int, type: String?, label: String?, identifier: String?, value: String?, x: Double?,
    y: Double?, width: Double?, height: Double?, tapX: Double?, tapY: Double?
  ) {
    self.depth = depth
    self.type = type
    self.label = label
    self.identifier = identifier
    self.value = value
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.tapX = tapX
    self.tapY = tapY
  }
}

/// The session's vital signs, so a freshly-attached agent can orient itself in one call.
public struct AgentStatus: Codable, Sendable {
  public let udid: String
  public let device: String
  public let screenWidth: Double
  public let screenHeight: Double
  /// The number of events on the timeline — the `since` cursor a new agent should start from if it
  /// only cares about what happens next.
  public let eventCount: Int
  /// A session bundle — the simulator's video stream plus the transcript — is being written.
  public let recording: Bool
  /// The SimScope window itself is being recorded to a movie, which is the artifact a demo take
  /// produces. Distinct from `recording`: this one has both parties' halves of the session in frame.
  public let windowRecording: Bool

  public init(
    udid: String, device: String, screenWidth: Double, screenHeight: Double, eventCount: Int,
    recording: Bool, windowRecording: Bool
  ) {
    self.udid = udid
    self.device = device
    self.screenWidth = screenWidth
    self.screenHeight = screenHeight
    self.eventCount = eventCount
    self.recording = recording
    self.windowRecording = windowRecording
  }
}

/// The described tree, and how much of it survived filtering.
public struct AgentTree: Codable, Sendable {
  public let elements: [AgentElement]
  public let coverage: String

  public init(elements: [AgentElement], coverage: String) {
    self.elements = elements
    self.coverage = coverage
  }
}

/// What a `hittest` found, if anything.
public struct AgentHit: Codable, Sendable {
  public let element: AgentElement?

  public init(element: AgentElement?) {
    self.element = element
  }
}

/// An action that landed, narrated the same way the human's log narrates it, and where it landed.
public struct AgentActed: Codable, Sendable {
  public let prose: String
  public let x: Double
  public let y: Double

  public init(prose: String, x: Double, y: Double) {
    self.prose = prose
    self.x = x
    self.y = y
  }
}

/// A slice of the session timeline, plus the cursor to ask from next.
public struct AgentTimeline: Codable, Sendable {
  public let events: [SessionEvent]
  public let next: Int

  public init(events: [SessionEvent], next: Int) {
    self.events = events
    self.next = next
  }
}

/// Whether a window recording is in flight, and the file it is going to or landed in.
public struct AgentRecordingState: Codable, Sendable {
  public let active: Bool
  public let path: String?

  public init(active: Bool, path: String?) {
    self.active = active
    self.path = path
  }
}

/// A snippet that reached the app. `succeeded` is false when it did not compile, in which case
/// `output` is the compiler's diagnostic — an ordinary reply, not an error, because that is the
/// reply an agent iterating on a snippet needs to read.
public struct AgentInjection: Codable, Sendable {
  public let succeeded: Bool
  public let output: String

  public init(succeeded: Bool, output: String) {
    self.succeeded = succeeded
    self.output = output
  }
}

/// A reply with nothing in it — the commands whose whole effect is on the human's log. Encoded as
/// `{}` so a client that decodes every reply uniformly has something to decode.
public struct AgentAcknowledgement: Codable, Sendable {
  public init() {}

  public init(from decoder: any Decoder) throws {
    self.init()
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode([String: String]())
  }
}

/// What SimScope sends back. Each case carries only the payload its command produces, so a `tap`
/// reply never has to nil out a tree it was never going to return.
///
/// The payload is encoded unwrapped, in place of the whole result — the case is the tag, and the
/// client already knows which command it sent.
public enum AgentResult: Encodable, Sendable {
  case acknowledged
  case status(AgentStatus)
  case tree(AgentTree)
  case hit(AgentHit)
  case acted(AgentActed)
  case timeline(AgentTimeline)
  case recording(AgentRecordingState)
  case injected(AgentInjection)

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .acknowledged: try AgentAcknowledgement().encode(to: encoder)
    case let .status(payload): try payload.encode(to: encoder)
    case let .tree(payload): try payload.encode(to: encoder)
    case let .hit(payload): try payload.encode(to: encoder)
    case let .acted(payload): try payload.encode(to: encoder)
    case let .timeline(payload): try payload.encode(to: encoder)
    case let .recording(payload): try payload.encode(to: encoder)
    case let .injected(payload): try payload.encode(to: encoder)
    }
  }
}

/// One line back to the agent.
public struct AgentResponse: Encodable, Sendable {
  public let id: Int?
  public let ok: Bool
  public let result: AgentResult?
  public let error: String?

  public static func success(id: Int?, _ result: AgentResult) -> AgentResponse {
    AgentResponse(id: id, ok: true, result: result, error: nil)
  }

  public static func failure(id: Int?, _ error: any Error) -> AgentResponse {
    AgentResponse(
      id: id, ok: false, result: nil,
      error: (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
  }
}

/// The same line `AgentResponse` wrote, read from the client's end.
///
/// Generic over the payload rather than over `AgentResult`, because the client already knows which
/// command it sent: it names the one reply shape it expects, and a server that answered with
/// something else fails to decode instead of being silently misread.
public struct AgentReply<Payload: Decodable>: Decodable {
  public let id: Int?
  public let ok: Bool
  public let result: Payload?
  public let error: String?
}
