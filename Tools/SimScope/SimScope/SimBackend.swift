/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import FBSimulatorAX
import FBSimulatorBridgeProtocol
import FBSimulatorControl
import FBSimulatorServices
import FBSimulatorVideo
import FBVideoCore
import Foundation
import IDBConcurrency
import IOSurface
import SimScopeProtocol

/// Errors surfaced to the UI when connecting to or driving a simulator.
enum SimScopeError: LocalizedError {
  case noBootedSimulator
  case udidNotFound(String)
  case notBooted(udid: String, state: String)

  var errorDescription: String? {
    switch self {
    case .noBootedSimulator:
      return "No booted iOS Simulator was found. Boot one (e.g. `xcrun simctl boot <udid>` or open Simulator.app) and relaunch SimScope."
    case let .udidNotFound(udid):
      return "No simulator with UDID \(udid) exists in any device set SimScope knows about."
    case let .notBooted(udid, state):
      return "Simulator \(udid) is not booted (state: \(state))."
    }
  }
}

/// One resolved accessibility element under the cursor: its frame in **simulator screen points**
/// (top-left origin) plus the descriptive attributes the axbridge read returned.
struct AXHit: Equatable {
  var frame: CGRect
  var label: String?
  var type: String?
  var identifier: String?

  /// A compact one-line description for the HUD, best-effort from whatever attributes are present.
  var hudTitle: String {
    var parts: [String] = []
    if let type, !type.isEmpty { parts.append(type) }
    if let label, !label.isEmpty { parts.append("“\(label)”") }
    if let identifier, !identifier.isEmpty { parts.append("#\(identifier)") }
    if parts.isEmpty { parts.append("element") }
    return parts.joined(separator: "  ")
  }

  /// A natural-language noun phrase for the action log, e.g. `Button “Continue” (id: continue_btn)`.
  var phrase: String {
    var phrase = type?.nonEmpty ?? "element"
    if let label, !label.isEmpty { phrase += " “\(label)”" }
    if let identifier, !identifier.isEmpty { phrase += " (id: \(identifier))" }
    return phrase
  }
}

/// Serializes HID event delivery so overlapping taps/gestures can never interleave on the wire.
private actor HIDSender {
  private let hid: SimulatorHID
  private let logger: any ControlCoreLogger

  init(hid: SimulatorHID, logger: any ControlCoreLogger) {
    self.hid = hid
    self.logger = logger
  }

  func send(_ event: SimulatorHIDEvent) async throws {
    try await hid.send(event: event, logger: logger)
  }
}

/// The bridge between SimScope's AppKit views and FBSimulatorControl.
///
/// Owns the resolved `Simulator`, the warm exclusive-axbridge reader (`UIAutomation`), and the
/// HID connection. Constructed synchronously (see `DeviceCatalog`); `prepare()` establishes the HID
/// connection before any input is delivered.
final class SimBackend: @unchecked Sendable {

  let simulator: Simulator
  let logger: any ControlCoreLogger

  /// Display geometry, derived once from the simulator's screen info.
  let pixelSize: CGSize
  let pointSize: CGSize
  let scale: CGFloat

  /// The exclusive axbridge reader: reads go over an in-simulator `accessibility serve` process
  /// reused across hit-tests (~20ms warm). The guest is on a socket nobody else can discover, because
  /// SimScope holds it for as long as its window is open and holding the shared one would make every
  /// other process on the machine wait.
  private var axReader: any UIAutomation

  /// `--frontmost center-point|window-server|runningboard`, when supplied.
  static var frontmostMethodArgument: AXBridgeFrontmostMethod? {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(of: "--frontmost"), i + 1 < args.count else { return nil }
    return AXBridgeFrontmostMethod(rawValue: args[i + 1])
  }

  /// `--traversal view-hierarchy|semantic`, when supplied.
  static var traversalStrategyArgument: AXTraversalStrategy? {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(of: "--traversal"), i + 1 < args.count else { return nil }
    return AXTraversalStrategy(rawValue: args[i + 1])
  }

  /// `--api ax|axbridge|axbridge-persistent|axbridge-exclusive|testmanagerd`, when supplied.
  static var backendNameArgument: UIAutomationBackendName? {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(of: "--api"), i + 1 < args.count else { return nil }
    return UIAutomationBackendName(rawValue: args[i + 1])
  }

  private var hidSender: HIDSender?

  // The most recent frontmost tree (nested), cached so hover/selection highlights can clip an
  // element's frame to its ancestor chain — some children (e.g. a widget's map image) report a frame
  // that overflows their clipping container. Written off-main by `readTree`, read on main by the view.
  private let treeLock = NSLock()
  private var lastNestedTree: [AccessibilityDocumentElement] = []

  init(simulator: Simulator, logger: any ControlCoreLogger) throws {
    self.simulator = simulator
    self.logger = logger
    // `.windowServer` resolves the frontmost app authoritatively (via the guest window server), unlike
    // `.centerPoint` which hit-tests the screen centre and fails when the centre is empty (e.g. the
    // home-screen wallpaper), which would make the whole frontmost tree dump fail.
    // Override the resolution method when diagnosing a mismatch between the tree and the display.
    let method = SimBackend.frontmostMethodArgument ?? .windowServer
    // `--api` exists because the backends disagree: against a presented sheet, `ax` returns the sheet
    // and `axbridge` returns the window underneath it. Being able to flip live is what makes that
    // comparable on one device rather than a claim about two runs.
    // Exclusive by default: SimScope holds its reader for as long as the window is open, and a private
    // guest means holding it costs no other process the shared bridge.
    let name = SimBackend.backendNameArgument ?? .axBridgeExclusive
    // `--automation-mode on|off` selects what a read asks the device's accessibility automation mode to
    // be. It exists so one binary shows both answers: with the mode off a container can serve cached
    // children naming a screen that is no longer displayed; with it on that cache is never consulted.
    self.readerName = name
    self.frontmostMethod = method
    self.automationMode = SimBackend.automationModeArgument
    self.axReader = try simulator.uiAutomation(
      backend: UIAutomationBackend(
        resolvedName: name, frontmostMethod: method,
        automationMode: SimBackend.automationModeArgument))

    let info = simulator.screenInfo
    let pxW = CGFloat(info?.widthPixels ?? 0)
    let pxH = CGFloat(info?.heightPixels ?? 0)
    let s = CGFloat(info?.scale ?? 2)
    self.scale = s > 0 ? s : 2
    self.pixelSize = CGSize(width: pxW, height: pxH)
    self.pointSize = CGSize(width: pxW / self.scale, height: pxH / self.scale)
  }

  /// Establishes the HID connection. Call once before delivering input.
  func prepare() async throws {
    let hid = try await simulator.hid.connect()
    hidSender = HIDSender(hid: hid, logger: logger)
  }

  // MARK: - Framebuffer

  /// Attaches to the simulator's main display surface. The returned attachment vends the initial
  /// IOSurface and an ordered event stream of surface swaps / frame ticks.
  func attachFramebuffer() throws -> FramebufferAttachment {
    let framebuffer = try Framebuffer.mainScreenSurface(for: simulator, logger: logger)
    return try framebuffer.attach()
  }

  // MARK: - Reads (exclusive axbridge)

  /// Resolves the accessibility element at a simulator screen point (points, top-left origin), or nil
  /// for empty space. One warm hit-test over the guest socket SimScope holds.
  func hitTest(atSimulatorPoint point: CGPoint) async throws -> AXHit? {
    let options = AccessibilityRequestOptions(format: .complete)
    guard let response = try await axReader.hitTest(at: point, options: options) else { return nil }
    guard case let .single(element) = response.elements else { return nil }
    guard
      let frameField = element.frame, let frame = frameField,
      let x = frame.x, let y = frame.y, let width = frame.width, let height = frame.height
    else {
      return nil
    }
    return AXHit(
      frame: CGRect(x: x, y: y, width: width, height: height),
      label: element.label.flatMap { $0 },
      type: element.type.flatMap { $0 },
      identifier: element.identifier.flatMap { $0 })
  }

  /// Reads the frontmost app's accessibility tree (bounded), flattened for a table. One warm axbridge
  /// frontmost read.
  ///
  /// The read itself is unfiltered (`.all`) so meaningful *non-interactable* content — labelled static
  /// text, value-bearing elements — is preserved (the serializer's `.interactable` filter would drop
  /// those). Pruning happens client-side: unless `includeAll`, nodes that provide nothing (no label,
  /// identifier, or value) are flattened out and their meaningful descendants hoisted up. See
  /// `AXNode.isMeaningful` / `AXNode.flatten`.
  func readTree(
    includeAll: Bool = false, traversal: AXTraversalStrategy? = nil
  ) async throws
    -> TreeSnapshot
  {
    // `interactable` is opt-in; without it every element comes back with no reported state and the
    // overlay falls back to guessing from the role.
    // Semantic traversal uses the accessibility translator's vocabulary rather than XCTest's.
    // It does not report `type`, so the state gutter uses the attributes the reader provides.
    let options = AccessibilityRequestOptions(
      format: .complete,
      keys: wantsReachability
        ? AXKeys.defaultSet.union([.interactable, .occludedBy]) : AXKeys.defaultSet,
      filter: .all,
      traversalStrategy: traversal ?? SimBackend.traversalStrategyArgument ?? .viewHierarchy)
    let response = try await axReader.describe(.frontmost, options: options)
    let elements = response.document.elements
    treeLock.withLock { lastNestedTree = elements }
    let displayRows = AXNode.flatten(elements, includeAll: includeAll)
    // Coverage is always measured over the meaningful set (independent of the display toggle).
    let meaningful = includeAll ? AXNode.flatten(elements, includeAll: false) : displayRows
    let coverage = Coverage.compute(nodes: meaningful, screen: pointSize)
    return TreeSnapshot(
      rows: displayRows, coverage: coverage, coverageNodes: meaningful,
      tree: AXOutlineNode.build(elements, includeAll: includeAll),
      cost: SimBackend.costSummary(response.profilingData))
  }

  /// Whether reads request reachability keys at launch. Off unless `--reachability` is supplied.
  static var reachabilityArgument: Bool {
    ProcessInfo.processInfo.arguments.contains("--reachability")
  }

  /// Whether reads request reachability keys, switchable from the window.
  /// These checks require app-side hit-testing for each node and can slow down repeated reads.
  var wantsReachability: Bool = SimBackend.reachabilityArgument

  /// What reads ask the device's accessibility automation mode to be, at launch.
  static var automationModeArgument: Bool? {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(of: "--automation-mode"), i + 1 < args.count else { return true }
    switch args[i + 1].lowercased() {
    case "off", "false", "no": return false
    case "observe", "nil", "none": return nil
    default: return true
    }
  }

  /// How the reader was built, so it can be rebuilt asking for a different automation mode.
  private let readerName: UIAutomationBackendName
  private let frontmostMethod: AXBridgeFrontmostMethod
  private(set) var automationMode: Bool?

  /// Rebuild the reader asking for a different automation mode.
  ///
  /// Rebuilt rather than mutated, because the mode is a payload of the backend case and is chosen when
  /// the reader is constructed. Worth switching at runtime because the mode is per-read and heals a
  /// faulted process in place: one window can show a container serving cached children that name a
  /// screen which has gone, then the same container reading correctly, with nothing relaunched.
  func setAutomationMode(_ mode: Bool?) throws {
    guard mode != automationMode else { return }
    axReader = try simulator.uiAutomation(
      backend: UIAutomationBackend(
        resolvedName: readerName, frontmostMethod: frontmostMethod, automationMode: mode))
    automationMode = mode
  }

  static func costSummary(_ profile: AccessibilityProfile?) -> String? {
    func ms(_ seconds: CFAbsoluteTime?) -> String? {
      guard let seconds else { return nil }
      return "\(Int((seconds * 1000).rounded()))"
    }
    switch profile {
    case let .guestBridge(p):
      var parts: [String] = []
      // Acquisition is split rather than rolled up: on the persistent transport a connect should be
      // milliseconds, so an acquire measured in seconds is either a spawn that should not be happening
      // or a bind being paid per read. Rolled up, those are indistinguishable from a slow connect.
      // Reported as "unattributed" rather than by the field's own name. `spawnDuration` and
      // `connectDuration` are the same underlying residual — round trip minus traverse — relabelled by
      // transport, so on a warm persistent read "connect" is not a connect: it is everything the host
      // could not attribute, which includes the guest's encode and the bytes crossing the socket.
      // Naming it for what it is stops the number being read as a phase it is not.
      if let acquire = ms(p.acquireDuration) { parts.append("unattributed \(acquire)") }
      if let bytes = p.responseBytes, bytes > 0 { parts.append("\(bytes / 1024) KiB") }
      // `readDuration` IS the guest's walk on this lane — the host builds it from `timings.traverse`.
      // Named for what it measures rather than for the field, so it stays comparable with the
      // translator lane's `read` without implying the two did the same work.
      if let traverse = ms(p.readDuration) { parts.append("traverse \(traverse)") }
      if let serialize = ms(p.serializeDuration) { parts.append("serialize \(serialize)") }
      if let decode = ms(p.hostDecodeDuration) { parts.append("host decode \(decode)") }
      if let trips = p.machRoundTrips { parts.append("\(trips) round trips") }
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
    case let .translator(p):
      var parts: [String] = []
      if let acquire = ms(p.acquireDuration) { parts.append("acquire \(acquire)") }
      if let read = ms(p.readDuration) { parts.append("read \(read)") }
      if let serialize = ms(p.serializeDuration) { parts.append("serialize \(serialize)") }
      parts.append("\(p.xpcCallCount) XPC calls")
      return parts.joined(separator: " · ")
    case nil:
      return nil
    @unknown default:
      return nil
    }
  }

  /// The on-screen *visible* rectangle for an element whose reported frame may overflow its clipping
  /// container (e.g. a widget's map image, which reports a screen-origin frame larger than the widget).
  ///
  /// A hit-tested leaf is often deeper than the depth-bounded `describe` tree, so we can't look up its
  /// ancestors directly. Instead we clip its frame to the **smallest tree element that encloses the
  /// anchor point and is meaningfully larger than it** — its nearest containing container — and to the
  /// screen. `anchor` is the point known to be inside the *visible* element (the cursor for hover); it
  /// matters because a badly-overflowing element's centre can fall outside its own container (a map
  /// image whose frame starts at the screen origin), whereas the cursor is always inside the widget.
  /// For a normal element the container encloses it fully, so the result equals its own frame.
  func clippedFrame(_ frame: CGRect, at anchor: CGPoint) -> CGRect {
    let tree = treeLock.withLock { lastNestedTree }

    let screen = CGRect(origin: .zero, size: pointSize)
    let frameArea = frame.width * frame.height

    var container: CGRect?
    Self.forEachFrame(in: tree) { candidate in
      guard candidate.contains(anchor) else { return }
      // Strictly larger than the element (so we pick a container, not the element itself or a child).
      guard candidate.width * candidate.height >= frameArea * 1.05 else { return }
      if let current = container {
        if candidate.width * candidate.height < current.width * current.height { container = candidate }
      } else {
        container = candidate
      }
    }

    let clipped = frame.intersection(container ?? screen).intersection(screen)
    return (clipped.isNull || clipped.isEmpty) ? frame.intersection(screen) : clipped
  }

  /// Clips using the frame's centre as the anchor (for callers with no cursor point, e.g. tree
  /// selection).
  func clippedFrame(_ frame: CGRect) -> CGRect {
    clippedFrame(frame, at: CGPoint(x: frame.midX, y: frame.midY))
  }

  private static func forEachFrame(in elements: [AccessibilityDocumentElement], _ body: (CGRect) -> Void) {
    for element in elements {
      if let frame = element.simFrame { body(frame) }
      forEachFrame(in: element.children ?? [], body)
    }
  }

  // MARK: - Input (HID)

  /// Taps at a simulator screen point (points). Atomic down+up.
  /// One touch report, as the digitizer sees it.
  ///
  /// There is no separate "move": iOS reads the position while the digitizer is down, so a move is
  /// another touch-down at a new coordinate. Modelled as a type anyway, because the caller's intent
  /// (begin a gesture / continue it / end it) is what decides whether a report may be coalesced away,
  /// and that distinction is invisible once everything is a touch-down.
  enum TouchReport {
    case down(CGPoint)
    case move(CGPoint)
    case up(CGPoint)
  }

  /// Delivers one touch report. Callers must send these in order; `hidSender` serializes the wire.
  func send(_ report: TouchReport) async throws {
    switch report {
    case let .down(point), let .move(point):
      try await hidSender?.send(.touch(direction: .down, x: Double(point.x), y: Double(point.y)))
    case let .up(point):
      try await hidSender?.send(.touch(direction: .up, x: Double(point.x), y: Double(point.y)))
    }
  }

  func tap(atSimulatorPoint point: CGPoint) async throws {
    try await hidSender?.send(.tapAt(x: Double(point.x), y: Double(point.y)))
  }

  /// Swipes between two simulator screen points (points) — a quick drag, e.g. to scroll.
  func swipe(fromSimulatorPoint start: CGPoint, to end: CGPoint, duration: Double = 0.25) async throws {
    let event = SimulatorHIDEvent.swipe(
      Double(start.x), yStart: Double(start.y), xEnd: Double(end.x), yEnd: Double(end.y),
      delta: SimulatorHIDEvent.defaultSwipeDelta, duration: duration)
    try await hidSender?.send(event)
  }

  /// Presses a hardware button (e.g. the Home button) as a short press.
  func pressButton(_ button: SimulatorHIDButton) async throws {
    try await hidSender?.send(.shortButtonPress(button))
  }

  func lockDevice() async throws {
    try await simulator.hardware.lock()
  }

  func shake() async throws {
    try await simulator.hardware.shake()
  }

  // MARK: - Video recording

  private var videoRecording: (any VideoRecording)?

  /// Starts recording the simulator screen to an mp4 at `path` (its parent directory must exist).
  func startVideoRecording(toFile path: String) async throws {
    guard videoRecording == nil else { return }
    videoRecording = try await simulator.videoRecording.start(toFile: path)
  }

  /// Stops recording, returning the written file URL (nil if not recording).
  @discardableResult
  func stopVideoRecording() async throws -> URL? {
    guard let recording = videoRecording else { return nil }
    videoRecording = nil
    return try await recording.stop()
  }

  /// Runs a named device action (the single mapping used by the toolbar/menu and by replay).
  func perform(deviceAction name: String) async throws {
    switch name {
    case "home": try await pressButton(.homeButton)
    case "side": try await pressButton(.sideButton)
    case "siri": try await pressButton(.siri)
    case "applePay": try await pressButton(.applePay)
    case "playPause": try await pressButton(.playPause)
    case "lock": try await lockDevice()
    case "shake": try await shake()
    default: break
    }
  }

  /// Sends a single key press (down/up) as a USB HID keyboard usage, wrapped in left-shift when
  /// `shift` is set. This is a hardware-keyboard event; whether the on-screen keyboard is shown is
  /// governed by `setHardwareKeyboard`.
  func sendKey(usage: UInt32, shift: Bool) async throws {
    var events: [SimulatorHIDEvent] = []
    if shift { events.append(.keyboard(direction: .down, keyCode: Keymap.Usage.leftShift)) }
    events.append(.keyboard(direction: .down, keyCode: usage))
    events.append(.keyboard(direction: .up, keyCode: usage))
    if shift { events.append(.keyboard(direction: .up, keyCode: Keymap.Usage.leftShift)) }
    try await hidSender?.send(.composite(events))
  }

  /// Types a string by sending each character as a USB HID keyboard press (US layout). Unmapped
  /// characters are skipped; `\n` becomes Return.
  func typeString(_ text: String) async throws {
    for character in text {
      if character == "\n" || character == "\r" {
        try await sendKey(usage: Keymap.Usage.returnKey, shift: false)
      } else if let key = Keymap.key(for: character) {
        try await sendKey(usage: key.usage, shift: key.shift)
      }
    }
  }

  /// Sends a named control key (return/tab/escape/space/delete).
  func sendKey(named name: String) async throws {
    let usage: UInt32
    switch name.lowercased() {
    case "return", "enter": usage = Keymap.Usage.returnKey
    case "tab": usage = Keymap.Usage.tab
    case "escape", "esc": usage = Keymap.Usage.escape
    case "space": usage = Keymap.Usage.space
    case "delete", "backspace": usage = Keymap.Usage.delete
    default: return
    }
    try await sendKey(usage: usage, shift: false)
  }

  /// Re-issues a structured `SessionAction` — the single dispatch used to replay recorded actions.
  func perform(_ action: SessionAction) async throws {
    switch action {
    case let .tap(x, y):
      try await tap(atSimulatorPoint: CGPoint(x: x, y: y))
    case let .swipe(fromX, fromY, toX, toY):
      try await swipe(fromSimulatorPoint: CGPoint(x: fromX, y: fromY), to: CGPoint(x: toX, y: toY))
    case let .type(text):
      try await typeString(text)
    case let .key(name):
      try await sendKey(named: name)
    case let .device(name):
      try await perform(deviceAction: name)
    case .chat, .note, .inject:
      break
    }
  }

  /// Toggles the simulator's "Connect Hardware Keyboard" state. When enabled, the on-screen software
  /// keyboard is suppressed and HID keyboard input goes to the focused field; when disabled, the
  /// software keyboard is shown (and can be tapped).
  func setHardwareKeyboard(_ enabled: Bool) async throws {
    try await simulator.preferences.apply(.hardwareKeyboard(enabled))
  }
}
