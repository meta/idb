/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
import FBControlCore
import FBSimulatorControl
import IOSurface
import ImageIO
import QuartzCore
import SimScopeProtocol
import UniformTypeIdentifiers

/// What the simulator overlay visualizes. `.off` is the default hover-only behavior; the others draw a
/// coverage heatmap of the meaningful elements' frames. Interactive is the primary ("meaningful")
/// category.
enum OverlayMode: Int, CaseIterable {
  /// Tri-state. There was a fourth, "Non-interactive", and it drew nothing: the reader never reports
  /// an element AS non-interactive — the verdict is reachable, covered, handled-by, or absent — so the
  /// layer it selected was empty by construction and the coverage line read 0% every time. A control
  /// with a state that cannot occur is worse than no control, because it invites the viewer to
  /// conclude the overlay is broken rather than the option meaningless.
  case off, interactive, all

  var title: String {
    switch self {
    case .off: return "Off"
    case .interactive: return "Reachable"
    case .all: return "Everything"
    }
  }
}

/// A layer-backed view that:
///  - hosts the booted simulator's live IOSurface (aspect-fit, letterboxed inside its pane),
///  - tracks the mouse and asks the persistent axbridge what element is under the cursor,
///  - draws a native CoreAnimation overlay highlighting that element (green) plus, independently, a
///    tree-selected element (blue),
///  - forwards clicks (tap) and quick drags (swipe) to the simulator over HID.
@MainActor
final class SimulatorView: NSView {

  private let backend: SimBackend
  private let session: Session

  /// Whether the hover highlight + HUD are shown. When off, no hit-testing runs on move and any hover
  /// highlight is cleared. Taps/swipes (and their action-log narration) are unaffected.
  var isOverlayEnabled: Bool = true {
    didSet {
      guard oldValue != isOverlayEnabled else { return }
      if isOverlayEnabled {
        if let window = unsafe window, window.isKeyWindow {
          requestHover(atViewPoint: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
      } else {
        pendingHoverPoint = nil
        applyHover(nil, rect: nil)
      }
    }
  }

  // Coverage visualization.
  private let coverageNonInteractiveLayer = CAShapeLayer() // meaningful, non-interactive (orange)
  private let coverageInteractiveLayer = CAShapeLayer() // meaningful, interactive (green)
  /// Controls the reader says cannot be acted on at their centre — drawn yellow, over the green, so the
  /// reason a midpoint tap misses is visible rather than inferred.
  private let coverageBlockedLayer = CAShapeLayer()
  /// True between an action being dispatched and the next tree read landing, so the absence of boxes
  /// reads as "not read yet" rather than "nothing here".
  private(set) var coverageIsStale = false
  private var coverageNodes: [AXNode] = []
  /// The current coverage-visualization mode; `.off` shows only the hover highlight.
  var overlayMode: OverlayMode = .off {
    didSet {
      guard oldValue != overlayMode else { return }
      redrawCoverage()
    }
  }

  // Layers, back to front.
  private let screenLayer = CALayer() // the simulator display (the IOSurface itself)
  private let selectionLayer = CAShapeLayer() // tree-selected element (blue)
  private let highlightLayer = CAShapeLayer() // hovered element (green)
  private let hudLayer = CALayer() // HUD chip background
  private let hudText = CATextLayer() // HUD chip text

  // Framebuffer plumbing.
  private var attachment: FramebufferAttachment?
  private var eventsTask: Task<Void, Never>?
  /// Kept for stills only (`writeScreenshot`), no longer on the per-frame path.
  private let imageGenerator: SurfaceImageGenerator
  /// The display surface currently mounted on `screenLayer`.
  private var currentSurface: IOSurface?

  // Hover coalescing: at most one axbridge hit-test in flight; the latest point wins.
  private var trackingArea: NSTrackingArea?
  private var pendingHoverPoint: CGPoint?
  private var hoverInFlight = false
  private var currentHit: AXHit?
  private var currentHighlightRect: CGRect? // hovered element, clipped to its ancestors (sim points)

  // Tree-selected element to outline (simulator points), independent of hover.
  private var selectionRect: CGRect?

  // Click / drag.
  private var mouseDownViewPoint: CGPoint?
  /// The hovered element at the moment the finger went down, for narration after the fact.
  private var mouseDownHit: AXHit?
  /// Touch reports awaiting the wire, and whether one is out. Ordered: a `Task` per report would race,
  /// and a move arriving before its own touch-down is a gesture the device cannot make sense of.
  private var touchQueue: [SimBackend.TouchReport] = []
  private var touchInFlight = false

  // Keyboard typing coalescing (so the action log reads "Typed “hello”" rather than one line per key).
  private var typingBuffer = ""
  private var typingFlush: DispatchWorkItem?

  private static let hoverColor = NSColor.systemGreen
  private static let selectionColor = NSColor.systemBlue
  /// Touch-feedback colors, matching how the action log tags each source.
  private static let agentColor = NSColor.systemBlue
  private static let replayColor = NSColor.systemOrange

  init(backend: SimBackend, session: Session) {
    self.backend = backend
    self.session = session
    self.imageGenerator = SurfaceImageGenerator(purpose: "SimScope", logger: backend.logger)
    super.init(frame: NSRect(origin: .zero, size: backend.pointSize))
    configureLayers()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - Setup

  private func configureLayers() {
    wantsLayer = true
    let root = CALayer()
    root.backgroundColor = NSColor.black.cgColor
    layer = root
    layer?.masksToBounds = true

    screenLayer.contentsGravity = .resizeAspect
    root.addSublayer(screenLayer)

    // Coverage heatmap (below the hover/selection highlights): non-interactive under interactive.
    for (coverageLayer, color) in [(coverageNonInteractiveLayer, NSColor.systemOrange), (coverageInteractiveLayer, Self.hoverColor), (coverageBlockedLayer, NSColor.systemYellow)] {
      coverageLayer.fillColor = color.withAlphaComponent(0.14).cgColor
      coverageLayer.strokeColor = color.withAlphaComponent(0.55).cgColor
      coverageLayer.lineWidth = 1
      coverageLayer.isHidden = true
      root.addSublayer(coverageLayer)
    }

    selectionLayer.fillColor = Self.selectionColor.withAlphaComponent(0.12).cgColor
    selectionLayer.strokeColor = Self.selectionColor.cgColor
    selectionLayer.lineWidth = 2
    selectionLayer.isHidden = true
    root.addSublayer(selectionLayer)

    highlightLayer.fillColor = Self.hoverColor.withAlphaComponent(0.18).cgColor
    highlightLayer.strokeColor = Self.hoverColor.cgColor
    highlightLayer.lineWidth = 1.5
    highlightLayer.isHidden = true
    root.addSublayer(highlightLayer)

    hudLayer.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
    hudLayer.cornerRadius = 5
    hudLayer.isHidden = true
    root.addSublayer(hudLayer)

    hudText.foregroundColor = NSColor.white.cgColor
    hudText.fontSize = 12
    hudText.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    hudText.truncationMode = .end
    hudText.isWrapped = false
    hudLayer.addSublayer(hudText)

    applyContentsScale()
  }

  private func applyContentsScale() {
    let scale = unsafe window?.backingScaleFactor ?? 2
    for l in [layer, screenLayer, coverageNonInteractiveLayer, coverageInteractiveLayer, coverageBlockedLayer, selectionLayer, highlightLayer, hudLayer, hudText] as [CALayer?] {
      l?.contentsScale = scale
    }
  }

  // MARK: - Lifecycle

  /// Begins mirroring the simulator's framebuffer into `screenLayer`.
  func start() {
    do {
      let attachment = try backend.attachFramebuffer()
      self.attachment = attachment
      let initial = attachment.initialSurface
      NSLog("SimScope: framebuffer attached, initialSurface=%@", initial == nil ? "nil" : "present")
      imageGenerator.updateSurface(initial)
      mount(surface: initial)

      eventsTask = Task { [weak self] in
        guard let stream = self?.attachment?.events else { return }
        for await event in stream {
          guard let self else { break }
          switch event {
          case let .surfaceChanged(surface):
            self.imageGenerator.updateSurface(surface)
            self.mount(surface: surface)
          case .frameRendered:
            self.present()
          case .configurationChanged:
            break
          case let .ended(error):
            NSLog("SimScope: framebuffer ended: \(error)")
            return
          @unknown default:
            break
          }
        }
      }
    } catch {
      NSLog("SimScope: failed to attach framebuffer: \(error)")
    }
  }

  func stop() {
    eventsTask?.cancel()
    eventsTask = nil
    attachment?.cancel()
    attachment = nil
  }

  deinit {
    eventsTask?.cancel()
    attachment?.cancel()
  }

  // MARK: - Screenshot

  /// Writes the current simulator frame to `path` as a PNG, and reports the pixel size alongside the
  /// point size the tap verbs use.
  ///
  /// Both numbers are returned because they differ — a 3x simulator renders 3 pixels per point, so
  /// a caller that measures a feature in the image and taps that number lands at three times the
  /// intended depth. Anything working from pixels has to be told the divisor, and the honest place to
  /// tell it is next to the image.
  /// The current frame as an image, for surfaces that want a still of this window's device — the
  /// picker's thumbnail — without attaching a second framebuffer to a device this window already owns.
  func currentScreenImage() -> CGImage? { try? imageGenerator.image() }

  func writeScreenshot(to path: String) throws -> (pixels: CGSize, points: CGSize) {
    guard let image = try imageGenerator.image() else {
      throw SimScopeError.noBootedSimulator
    }
    let url = URL(fileURLWithPath: path)
    guard
      let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { throw SimScopeError.noBootedSimulator }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw SimScopeError.noBootedSimulator }
    return (
      CGSize(width: image.width, height: image.height),
      backend.pointSize
    )
  }

  // MARK: - Framebuffer rendering

  /// Hand the display surface to CoreAnimation directly.
  ///
  /// WHY NOT A `CGImage`. Rendering the surface to an image and assigning that made CoreAnimation
  /// re-render it on every single frame. The image's colour space is not the display's, so
  /// `prepare_contents` could not use it and ran a full-frame CMS conversion — 1206x2622 pixels through
  /// vImage, TRC lookups, matrix multiply, un/premultiply — on the main thread, per frame. Sampling the
  /// app while it was being driven put 13475 of 14835 main-thread samples in exactly that stack, which
  /// is what the beachballing was. An IOSurface is what the layer wants: the GPU samples it, colour
  /// conversion happens where colour conversion belongs, and the main thread does no per-frame work.
  private func mount(surface: IOSurface?) {
    currentSurface = surface
    present()
  }

  private func present() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Cleared first so the assignment always reads as a change. The simulator re-renders into the SAME
    // surface, and CoreAnimation will not re-sample contents it believes it already holds. Both writes
    // land in one transaction, so nothing is ever committed with an empty layer.
    screenLayer.contents = nil
    screenLayer.contents = currentSurface
    CATransaction.commit()
  }

  // MARK: - Layout

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    screenLayer.frame = bounds
    coverageNonInteractiveLayer.frame = bounds
    coverageInteractiveLayer.frame = bounds
    coverageBlockedLayer.frame = bounds
    selectionLayer.frame = bounds
    highlightLayer.frame = bounds
    relayoutOverlay()
    relayoutSelection()
    redrawCoverage()
    CATransaction.commit()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    applyContentsScale()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyContentsScale()
    unsafe window?.acceptsMouseMovedEvents = true
  }

  // MARK: - Coordinate mapping
  //
  // The screen is aspect-fit (letterboxed) inside the view, so mapping is relative to the displayed
  // image rect rather than the full bounds. View coordinates are AppKit bottom-left; simulator points
  // are top-left.

  /// The rect (in view/bottom-left coordinates) the simulator image actually occupies.
  private var displayedImageRect: CGRect {
    let b = bounds
    let point = backend.pointSize
    guard b.width > 0, b.height > 0, point.width > 0, point.height > 0 else { return b }
    let scale = min(b.width / point.width, b.height / point.height)
    let size = CGSize(width: point.width * scale, height: point.height * scale)
    return CGRect(x: (b.width - size.width) / 2, y: (b.height - size.height) / 2, width: size.width, height: size.height)
  }

  /// Maps a view point to a simulator screen point, or nil if it falls in the letterbox margins.
  private func simulatorPoint(fromViewPoint p: CGPoint) -> CGPoint? {
    let rect = displayedImageRect
    guard rect.contains(p), rect.width > 0, rect.height > 0 else { return nil }
    let x = (p.x - rect.minX) / rect.width * backend.pointSize.width
    let y = (rect.maxY - p.y) / rect.height * backend.pointSize.height // flip to top-left
    return CGPoint(x: x, y: y)
  }

  /// Maps a simulator screen point back to a view point — the inverse of `simulatorPoint(fromViewPoint:)`,
  /// for drawing feedback about actions that arrived as coordinates rather than as a mouse event.
  private func viewPoint(fromSimulatorPoint p: CGPoint) -> CGPoint {
    let rect = displayedImageRect
    return CGPoint(
      x: rect.minX + p.x / max(backend.pointSize.width, 1) * rect.width,
      y: rect.maxY - p.y / max(backend.pointSize.height, 1) * rect.height)
  }

  /// Where a simulator point sits in window coordinates — what a scripted human needs in order to post
  /// a mouse event this view will hit-test exactly as it would a real one.
  func windowPoint(forSimulatorPoint p: CGPoint) -> CGPoint {
    convert(viewPoint(fromSimulatorPoint: p), to: nil)
  }

  /// Whether simulator points map onto the window yet. Until the device's size is known and the view is
  /// laid out, every point maps into the letterbox margin, where mouse events are dropped — so a
  /// scripted human has to wait for this before its first beat, or it silently taps nothing.
  var isScreenMapped: Bool {
    let point = backend.pointSize
    return point.width > 0 && point.height > 0 && displayedImageRect.width > 1
  }

  /// Maps a simulator rect (points, top-left) to a view rect (bottom-left) within the image area.
  private func viewRect(fromSimulatorRect r: CGRect) -> CGRect {
    let rect = displayedImageRect
    let sx = rect.width / max(backend.pointSize.width, 1)
    let sy = rect.height / max(backend.pointSize.height, 1)
    let w = r.width * sx
    let h = r.height * sy
    let x = rect.minX + r.minX * sx
    let yFromTop = r.minY * sy
    let yBottomLeft = rect.maxY - yFromTop - h
    return CGRect(x: x, y: yBottomLeft, width: w, height: h)
  }

  // MARK: - Mouse tracking

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    guard isOverlayEnabled else { return }
    requestHover(atViewPoint: convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    clearHover()
  }

  /// Drops the hover highlight and HUD, as if the pointer had left the simulator.
  func clearHover() {
    pendingHoverPoint = nil
    applyHover(nil, rect: nil)
  }

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    unsafe window?.makeFirstResponder(self) // focus for keyboard input
    let viewPoint = convert(event.locationInWindow, from: nil)
    mouseDownViewPoint = viewPoint
    // Whatever the cursor was already resolved onto. Taken here, before the touch lands, so the log
    // names the element that was actually under the finger rather than whatever replaced it.
    mouseDownHit = currentHit
    guard let point = simulatorPoint(fromViewPoint: viewPoint) else { return }
    // Straight onto the wire. Nothing is resolved, narrated or awaited first: the finger is already
    // down on the trackpad, and everything between here and the device is latency a human feels.
    enqueue(.down(point))
  }

  override func mouseDragged(with event: NSEvent) {
    guard mouseDownViewPoint != nil else { return }
    let viewPoint = convert(event.locationInWindow, from: nil)
    guard let point = simulatorPoint(fromViewPoint: viewPoint) else { return }
    enqueue(.move(point))
    // Hover is deliberately not requested mid-drag: it is an axbridge round trip per movement,
    // competing with the gesture for attention, and its answer is not wanted while a finger is down.
  }

  override func mouseUp(with event: NSEvent) {
    flushTyping() // keep the log ordered: any pending "Typed …" lands before this tap/swipe
    guard let downViewPoint = mouseDownViewPoint else { return }
    mouseDownViewPoint = nil
    let hit = mouseDownHit
    mouseDownHit = nil
    let upViewPoint = convert(event.locationInWindow, from: nil)
    guard let start = simulatorPoint(fromViewPoint: downViewPoint) else { return } // outside the screen
    let end = simulatorPoint(fromViewPoint: upViewPoint) ?? start
    enqueue(.up(end))

    // The device has the whole gesture already; what remains is describing it. A tap and a swipe are
    // the same stream of reports and differ only in how far the finger travelled, so the distinction
    // is made here, for the log, rather than by sending two different kinds of input.
    let travelled = hypot(end.x - start.x, end.y - start.y)
    if travelled < 8 {
      showTapRipple(atViewPoint: upViewPoint)
      session.recordTap(source: .human, hit: hit, at: start)
    } else {
      session.recordSwipe(source: .human, from: start, to: end, startHit: hit)
    }
  }

  // MARK: - Touch streaming

  /// Deliver a touch report, in order, without ever blocking the gesture.
  ///
  /// WHAT THIS REPLACED. A drag used to send nothing at all until mouse-up, at which point the whole
  /// path was collapsed to two points and replayed as a synthesized swipe. The screen therefore did not
  /// move under the finger — it jumped once, on release — and the canned swipe deliberately repeats its
  /// final touch-down to suppress inertia, so a flick could never carry momentum. Worse, the send was
  /// gated behind an `await` on an accessibility hit-test taken purely to write a nicer log line, which
  /// put a round trip to the app's AX server in front of every human input.
  ///
  /// Moves are coalesced rather than queued: at most one report is in flight and the newest position
  /// wins. A fast drag would otherwise build a backlog the device replays after the finger has stopped,
  /// which reads as the screen sliding on by itself. Down and up are never coalesced — dropping either
  /// leaves a finger stuck on the glass.
  private func enqueue(_ report: SimBackend.TouchReport) {
    if case .move = report, case .move = touchQueue.last { touchQueue.removeLast() }
    touchQueue.append(report)
    pumpTouches()
  }

  private func pumpTouches() {
    guard !touchInFlight, !touchQueue.isEmpty else { return }
    touchInFlight = true
    let report = touchQueue.removeFirst()
    Task { [weak self, backend] in
      try? await backend.send(report)
      guard let self else { return }
      self.touchInFlight = false
      self.pumpTouches()
    }
  }

  // MARK: - Hover (persistent axbridge)

  private func requestHover(atViewPoint p: CGPoint) {
    pendingHoverPoint = p
    pumpHover()
  }

  private func pumpHover() {
    guard isOverlayEnabled, !hoverInFlight, let viewPoint = pendingHoverPoint else { return }
    pendingHoverPoint = nil
    guard let simPoint = simulatorPoint(fromViewPoint: viewPoint) else {
      applyHover(nil, rect: nil) // cursor in the letterbox margin
      return
    }
    hoverInFlight = true
    Task { [weak self] in
      guard let self else { return }
      let hit = (try? await self.backend.hitTest(atSimulatorPoint: simPoint)) ?? nil
      // Clip the element's frame to its ancestor chain so a child that overflows its container
      // (e.g. a widget's map image) highlights only its visible region.
      let rect = hit.map { self.backend.clippedFrame($0.frame, at: simPoint) }
      self.applyHover(hit, rect: rect)
      // A hover is already a hit-test, so the answer is free — hand it to whoever wants to follow the
      // cursor in the tree. Worth doing because the two panes otherwise describe the same screen
      // without ever pointing at the same thing: you can hover an element on the phone and still have
      // to hunt for its row among two hundred.
      self.onHover?(simPoint, hit)
      self.hoverInFlight = false
      self.pumpHover()
    }
  }

  /// Called with the point hovered and whatever the hit-test found there, on every hover resolution.
  var onHover: ((CGPoint, AXHit?) -> Void)?

  private func applyHover(_ hit: AXHit?, rect: CGRect?) {
    currentHit = hit
    currentHighlightRect = rect
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    relayoutOverlay()
    CATransaction.commit()
  }

  private func relayoutOverlay() {
    guard let hit = currentHit, let simRect = currentHighlightRect else {
      highlightLayer.isHidden = true
      hudLayer.isHidden = true
      return
    }

    let rect = viewRect(fromSimulatorRect: simRect).integral
    highlightLayer.isHidden = false
    highlightLayer.path = unsafe CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil)

    let text = hit.hudTitle
    hudText.string = text
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
    let padding: CGFloat = 7
    let chipHeight: CGFloat = 20
    let chipWidth = min(textWidth + padding * 2, max(bounds.width - 8, 40))

    var chipX = rect.minX
    chipX = max(4, min(chipX, bounds.width - chipWidth - 4))
    var chipY = rect.maxY + 4
    if chipY + chipHeight > bounds.height - 4 {
      chipY = rect.minY - chipHeight - 4
    }
    chipY = max(4, min(chipY, bounds.height - chipHeight - 4))

    hudLayer.isHidden = false
    hudLayer.frame = CGRect(x: chipX, y: chipY, width: chipWidth, height: chipHeight)
    hudText.frame = CGRect(x: padding, y: (chipHeight - 15) / 2, width: chipWidth - padding * 2, height: 15)
  }

  // MARK: - External (tree) selection highlight

  /// Outlines a tree-selected element (simulator points), or clears it when nil.
  func highlightExternal(_ frame: CGRect?) {
    selectionRect = frame
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    relayoutSelection()
    CATransaction.commit()
  }

  private func relayoutSelection() {
    guard let rect = selectionRect else {
      selectionLayer.isHidden = true
      return
    }
    let viewR = viewRect(fromSimulatorRect: rect).integral
    selectionLayer.isHidden = false
    selectionLayer.path = unsafe CGPath(roundedRect: viewR.insetBy(dx: 1, dy: 1), cornerWidth: 4, cornerHeight: 4, transform: nil)
  }

  // MARK: - Keyboard

  override func keyDown(with event: NSEvent) {
    // Let ⌘-shortcuts fall through to the menu; forward everything else to the simulator.
    if event.modifierFlags.contains(.command) {
      super.keyDown(with: event)
      return
    }
    guard let key = Keymap.hidKey(for: event) else { return } // unmapped: swallow (no beep)
    Task { [backend] in try? await backend.sendKey(usage: key.usage, shift: key.shift) }
    narrate(key: key, event: event)
  }

  /// Coalesces printable keystrokes into a single "Typed …" log line, flushing (and naming) on the
  /// discrete keys or after a short idle.
  private func narrate(key: Keymap.Key, event: NSEvent) {
    switch key.usage {
    case Keymap.Usage.delete:
      if !typingBuffer.isEmpty { typingBuffer.removeLast() }
      scheduleTypingFlush()
    case Keymap.Usage.returnKey:
      flushTyping()
      session.recordKey(source: .human, named: "return")
    case Keymap.Usage.tab:
      flushTyping()
      session.recordKey(source: .human, named: "tab")
    case Keymap.Usage.escape:
      flushTyping()
      session.recordKey(source: .human, named: "escape")
    case Keymap.Usage.left, Keymap.Usage.right, Keymap.Usage.up, Keymap.Usage.down:
      flushTyping() // navigation; not logged per-key
    default:
      if let characters = event.characters, !characters.isEmpty { typingBuffer += characters }
      scheduleTypingFlush()
    }
  }

  private func scheduleTypingFlush() {
    typingFlush?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.flushTyping() }
    typingFlush = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
  }

  private func flushTyping() {
    typingFlush?.cancel()
    typingFlush = nil
    guard !typingBuffer.isEmpty else { return }
    session.recordType(source: .human, typingBuffer)
    typingBuffer = ""
  }

  // MARK: - Coverage visualization

  /// Supplies the meaningful nodes (from the latest tree read) for the coverage heatmap.
  ///
  /// `identityHeld` says whether the refresh returned the same elements as the last one. When it did,
  /// the boxes are the same boxes with new geometry and they move to it; when it did not, the screen
  /// changed and they cut. Sliding a box from where one element was to where a different element is
  /// would animate a movement that never happened.
  func setCoverageNodes(_ nodes: [AXNode], identityHeld: Bool = false) {
    coverageNodes = nodes
    coverageIsStale = false
    coverageIdentityHeld = identityHeld
    redrawCoverage()
  }

  /// Whether the boxes on screen and the boxes arriving describe the same elements.
  private var coverageIdentityHeld = false
  /// Rect counts of what each layer currently draws. `CAShapeLayer` interpolates one path into another
  /// only when the two have the same structure; between a 40-rect path and a 39-rect path it produces
  /// garbage, so a change in count has to cut even when identity otherwise held.
  private var coverageRectCounts: [Int] = [0, 0, 0]

  /// Drops the heatmap until a fresh read arrives.
  ///
  /// Called the moment an action is dispatched, because the boxes describe the screen as it was before
  /// the action and the screen has just changed underneath them. Leaving them up draws confident
  /// rectangles over content they no longer correspond to — the same stale-read mistake the overlay
  /// exists to expose, committed by the overlay itself.
  func invalidateCoverage() {
    guard !coverageNodes.isEmpty || !coverageIsStale else { return }
    coverageNodes = []
    coverageIsStale = true
    coverageIdentityHeld = false
    redrawCoverage()
  }

  private func redrawCoverage() {
    CATransaction.begin()
    defer { CATransaction.commit() }
    CATransaction.setDisableActions(true)

    guard overlayMode != .off else {
      coverageInteractiveLayer.isHidden = true
      coverageNonInteractiveLayer.isHidden = true
      coverageBlockedLayer.isHidden = true
      return
    }

    let showInteractive = overlayMode == .interactive || overlayMode == .all
    // "Everything read" means every element the reader returned a frame for, including the ones it
    // gave no verdict on — which is the honest picture of what an agent is working from.
    let showNonInteractive = overlayMode == .all
    coverageInteractiveLayer.isHidden = !showInteractive
    coverageNonInteractiveLayer.isHidden = !showNonInteractive
    coverageBlockedLayer.isHidden = !showInteractive

    let screen = CGRect(origin: .zero, size: backend.pointSize)
    // Assigned through one helper so each layer independently decides whether it may animate. They can
    // differ: a read that adds occlusion verdicts moves elements from the reachable layer to the blocked
    // one, so the reachable count changes and must cut while the untouched layer can still glide.
    func apply(_ layer: CAShapeLayer, _ nodes: [AXNode], _ slot: Int) {
      let (path, rects) = coveragePath(for: nodes, screen: screen)
      let animates = coverageIdentityHeld && rects == coverageRectCounts[slot] && rects > 0
      coverageRectCounts[slot] = rects
      CATransaction.begin()
      CATransaction.setDisableActions(!animates)
      if animates { CATransaction.setAnimationDuration(0.18) }
      layer.path = path
      CATransaction.commit()
    }

    if showInteractive {
      // Blocked controls are drawn separately rather than counted as interactive, so a covered element
      // stops being painted the same colour as one a tap would actually reach.
      apply(coverageInteractiveLayer, coverageNodes.filter(\.isReachableControl), 0)
      apply(coverageBlockedLayer, coverageNodes.filter(\.isOccludedControl), 1)
    }
    if showNonInteractive {
      apply(coverageNonInteractiveLayer, coverageNodes.filter { !$0.isInteractive }, 2)
    }
  }

  /// A path of each node's on-screen frame (matching the coverage metric, which unions screen-clipped
  /// frames), mapped into the view.
  private func coveragePath(for nodes: [AXNode], screen: CGRect) -> (CGPath, Int) {
    let path = CGMutablePath()
    var rects = 0
    for node in nodes {
      guard let frame = node.frame else { continue }
      let onScreen = frame.intersection(screen)
      guard !onScreen.isNull, !onScreen.isEmpty else { continue }
      path.addRect(viewRect(fromSimulatorRect: onScreen).integral)
      rects += 1
    }
    return (path, rects)
  }

  // MARK: - Touch feedback

  /// Draws touch feedback for an action this view did not originate — the agent's taps and swipes, and
  /// replay's — so the human watches the screen being touched rather than inferring it from the log.
  ///
  /// The human's own ripple stays on the mouse-up path rather than coming through here: it has to be
  /// instant, and the session event is only recorded after an axbridge hit-test.
  func showRemoteTouch(for event: SessionEvent) {
    let color: NSColor
    switch event.source {
    case .agent: color = Self.agentColor
    case .replay: color = Self.replayColor
    case .human, .system: return
    }
    switch event.action {
    case let .tap(x, y):
      showTapRipple(atViewPoint: viewPoint(fromSimulatorPoint: CGPoint(x: x, y: y)), color: color)
    case let .swipe(fromX, fromY, toX, toY):
      showSwipeTrail(
        from: viewPoint(fromSimulatorPoint: CGPoint(x: fromX, y: fromY)),
        to: viewPoint(fromSimulatorPoint: CGPoint(x: toX, y: toY)),
        color: color)
    case .type, .key, .device, .chat, .note, .inject:
      return // nothing to point at on the screen
    }
  }

  private func showTapRipple(atViewPoint p: CGPoint, color: NSColor = SimulatorView.hoverColor) {
    let ring = CAShapeLayer()
    let radius: CGFloat = 22
    ring.frame = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
    ring.path = unsafe CGPath(ellipseIn: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2), transform: nil)
    ring.fillColor = color.withAlphaComponent(0.35).cgColor
    ring.strokeColor = color.cgColor
    ring.lineWidth = 2
    ring.contentsScale = unsafe window?.backingScaleFactor ?? 2
    layer?.addSublayer(ring)

    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.3
    scale.toValue = 1.0
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0.9
    fade.toValue = 0.0
    let group = CAAnimationGroup()
    group.animations = [scale, fade]
    group.duration = 0.35
    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
    group.isRemovedOnCompletion = true
    ring.opacity = 0
    ring.add(group, forKey: "ripple")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { ring.removeFromSuperlayer() }
  }

  /// A stroke drawn along a swipe's path, then faded. Longer-lived than the tap ripple because a swipe
  /// moves the screen underneath it — the trail is what tells the human the scroll was not theirs.
  private func showSwipeTrail(from start: CGPoint, to end: CGPoint, color: NSColor) {
    let trail = CAShapeLayer()
    trail.frame = bounds
    let path = CGMutablePath()
    path.move(to: start)
    path.addLine(to: end)
    trail.path = path
    trail.strokeColor = color.cgColor
    trail.fillColor = nil
    trail.lineWidth = 5
    trail.lineCap = .round
    trail.contentsScale = unsafe window?.backingScaleFactor ?? 2
    layer?.addSublayer(trail)

    let draw = CABasicAnimation(keyPath: "strokeEnd")
    draw.fromValue = 0
    draw.toValue = 1
    draw.duration = 0.28
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0.9
    fade.toValue = 0.0
    fade.beginTime = 0.28
    fade.duration = 0.4
    let group = CAAnimationGroup()
    group.animations = [draw, fade]
    group.duration = 0.68
    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
    group.isRemovedOnCompletion = true
    trail.opacity = 0
    trail.add(group, forKey: "trail")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.69) { trail.removeFromSuperlayer() }
  }
}
