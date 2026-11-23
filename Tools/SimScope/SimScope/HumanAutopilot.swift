/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit

/// One beat of a scripted human: what the person at the keyboard does next. Coordinates are simulator
/// screen points, the same ones the action log and the agent channel speak in.
enum DemoBeat: Decodable {
  case tap(x: Double, y: Double)
  case swipe(fromX: Double, fromY: Double, toX: Double, toY: Double)
  case say(String) // typed into the reply field
  case wait(seconds: Double)

  private enum Key: String, CodingKey {
    case act, x, y, fromX, fromY, toX, toY, text, seconds
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: Key.self)
    let act = try values.decode(String.self, forKey: .act)
    switch act {
    case "tap":
      self = .tap(x: try values.decode(Double.self, forKey: .x), y: try values.decode(Double.self, forKey: .y))
    case "swipe":
      self = .swipe(
        fromX: try values.decode(Double.self, forKey: .fromX),
        fromY: try values.decode(Double.self, forKey: .fromY),
        toX: try values.decode(Double.self, forKey: .toX),
        toY: try values.decode(Double.self, forKey: .toY))
    case "say":
      self = .say(try values.decode(String.self, forKey: .text))
    case "wait":
      self = .wait(seconds: try values.decode(Double.self, forKey: .seconds))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .act, in: values, debugDescription: "Unknown beat “\(act)” — expected tap, swipe, say or wait")
    }
  }
}

/// Plays a scripted human against SimScope's own UI, so a two-party session can be captured with
/// nobody at the keyboard.
///
/// The beats are delivered as real `NSEvent`s into the simulator view and as real keystrokes into the
/// reply field, rather than by calling the backend or the session bus directly. That is the whole point:
/// each one then takes the path a person's would — hit-test, `.human` attribution in the log, green
/// ripple — so what the agent reads back, and what the recording shows, is a human session and not a
/// simulation of one.
@MainActor
final class HumanAutopilot {

  private let window: NSWindow
  private let simulatorView: SimulatorView
  private let actionLog: ActionLog
  private let beats: [DemoBeat]

  /// Idle inserted after every beat, so the recording reads at a human pace without the script having
  /// to spell out a wait between each pair of actions.
  private static let beatGap = Duration.milliseconds(700)
  /// How long the pointer rests on a target before pressing it. A person looks before they touch, and
  /// the hover HUD needs a moment on screen to be readable in the recording.
  private static let aimPause = Duration.milliseconds(400)

  init(window: NSWindow, simulatorView: SimulatorView, actionLog: ActionLog, beats: [DemoBeat]) {
    self.window = window
    self.simulatorView = simulatorView
    self.actionLog = actionLog
    self.beats = beats
  }

  var beatCount: Int { beats.count }

  static func beats(fromFile path: String) throws -> [DemoBeat] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode([DemoBeat].self, from: data)
  }

  func play() async {
    for beat in beats {
      await perform(beat)
      try? await Task.sleep(for: Self.beatGap)
      // A real pointer keeps moving; a scripted one stops dead where the beat left it, and the hover
      // highlight left behind goes on labelling an element the screen has since navigated away from —
      // over a blank patch it resolves to the whole screen and washes the recording. A person takes
      // their hand off the phone between actions, so this one does too.
      simulatorView.clearHover()
    }
  }

  // MARK: - Private

  private func perform(_ beat: DemoBeat) async {
    switch beat {
    case let .wait(seconds):
      try? await Task.sleep(for: .seconds(seconds))
    case let .say(text):
      await actionLog.typeReply(text)
    case let .tap(x, y):
      let point = simulatorView.windowPoint(forSimulatorPoint: CGPoint(x: x, y: y))
      post(.mouseMoved, at: point)
      try? await Task.sleep(for: Self.aimPause)
      post(.leftMouseDown, at: point)
      try? await Task.sleep(for: .milliseconds(80))
      post(.leftMouseUp, at: point)
    case let .swipe(fromX, fromY, toX, toY):
      let start = simulatorView.windowPoint(forSimulatorPoint: CGPoint(x: fromX, y: fromY))
      let end = simulatorView.windowPoint(forSimulatorPoint: CGPoint(x: toX, y: toY))
      post(.leftMouseDown, at: start)
      let steps = 12
      for step in 1...steps {
        let fraction = CGFloat(step) / CGFloat(steps)
        post(
          .leftMouseDragged,
          at: CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction))
        try? await Task.sleep(for: .milliseconds(20))
      }
      post(.leftMouseUp, at: end)
    }
  }

  /// Hands the view a mouse event carrying a real window location, which is everything downstream of
  /// `mouseDown` reads: ripple, hit-test, HID, log narration — all identical to a person's click.
  ///
  /// Delivered to the view rather than through `NSWindow.sendEvent`, because a click into a window that
  /// is not key is spent activating it instead of reaching the view, and an unattended capture cannot
  /// count on winning focus from whatever launched it.
  private func post(_ type: NSEvent.EventType, at windowPoint: CGPoint) {
    guard
      let event = NSEvent.mouseEvent(
        with: type,
        location: windowPoint,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1)
    else { return }
    switch type {
    case .leftMouseDown: simulatorView.mouseDown(with: event)
    case .leftMouseDragged: simulatorView.mouseDragged(with: event)
    case .leftMouseUp: simulatorView.mouseUp(with: event)
    case .mouseMoved: simulatorView.mouseMoved(with: event)
    default: break
    }
  }
}
