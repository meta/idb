/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
import FBControlCore
import FBSimulatorAX
import FBSimulatorControl
import SimScopeProtocol

/// One simulator's window: the mirrored screen, the tree, the log, the toolbar, the recorders, the
/// REPL and the agent socket, owned together because they live and die with the device they show.
///
/// An `NSWindowController` rather than a plain object so the responder chain does the routing: menu
/// items carry nil targets, and AppKit resolves their actions to the key window's controller. That is
/// what makes every window-scoped action land on the window it was invoked from — the property that
/// matters the moment there is more than one of these.
@MainActor
final class DeviceWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation,
  NSWindowDelegate
{

  let backend: SimBackend
  private let controlSocketPaths: [String]
  private var simView: SimulatorView?
  private var treeInspector: TreeInspector?
  private var refreshControl: NSPopUpButton?
  /// The element the cursor was last resolved onto, so the tree only jumps when it changes.
  private var lastHoveredElement: AXHit?
  private var refreshIntervals: [TimeInterval] = []
  private weak var traversalControl: NSSegmentedControl?
  private weak var overlayControl: NSSegmentedControl?
  private let session = Session()
  private let actionLog = ActionLog()

  private var overlayEnabled = true
  private weak var overlayItem: NSToolbarItem?
  private weak var treeFilterItem: NSToolbarItem?
  private var hardwareKeyboardEnabled = true
  private weak var hwKeyboardItem: NSToolbarItem?
  private var recorder: SessionRecorder?
  private weak var recordItem: NSToolbarItem?
  private var replayFromIndex = 0
  private var repl: SessionREPL?
  /// Built on first use and kept, so the operator's snippet survives closing the panel.
  private var swiftConsole: SwiftConsole?
  private var controlChannels: [ControlChannel] = []
  private var windowRecorder: WindowRecorder?
  /// Where the take in flight is being written, and the flag for whether there is one at all.
  private var windowRecordingURL: URL?
  /// Held for the length of a take. An idle display composites nothing, so a movie recorded while
  /// the machine dozes off is blank from that point on — and a scripted human is, to the system,
  /// exactly as idle as no human at all.
  private var recordingActivity: (any NSObjectProtocol)?
  private var deviceSubtitle = ""
  /// Bumped on every agent action; a pending clear only fires if it still matches, so a burst of
  /// agent activity extends the indicator instead of each action scheduling its own expiry.
  private var agentActivityToken = 0
  private var agentIsActive = false
  /// How long after an agent's last action the title bar keeps saying it is here. Long enough to span
  /// a `describe`-then-`tap` pause, short enough that a finished agent stops claiming the session.
  private static let agentIdleTimeout: TimeInterval = 12

  /// Called when this window closes, after its take is finalized and its socket unlinked — the
  /// registry's cue to forget the controller.
  var onClose: ((DeviceWindowController) -> Void)?

  /// Every window listens on its own UDID-keyed socket; the first window also binds the app's base
  /// path, so an agent that never chose a device keeps talking to the launch window. One path per
  /// window is what makes "which device does this verb hit" a property of the socket an agent dialed,
  /// rather than of whichever window happens to be frontmost.
  init(backend: SimBackend, controlSocketPaths: [String]) {
    self.backend = backend
    self.controlSocketPaths = controlSocketPaths
    let (window, simPaneWidth) = Self.makeWindow(pointSize: backend.pointSize, name: backend.simulator.name)
    super.init(window: window)
    deviceSubtitle = backend.simulator.udid
    window.subtitle = deviceSubtitle
    window.delegate = self
    populate(window: window, simPaneWidth: simPaneWidth)

    Task { @MainActor in
      do {
        try await backend.prepare()
        NSLog("SimScope: HID connected")
        // Connect the hardware keyboard so Mac keystrokes reach the focused field out of the box.
        try? await backend.setHardwareKeyboard(self.hardwareKeyboardEnabled)
      } catch {
        presentSimScopeError(error, message: "Connected to the simulator, but could not open a HID input channel. Hover/inspection will work; input may not.")
      }
    }
  }

  required init?(coder: NSCoder) { fatalError("DeviceWindowController is built in code") }

  // MARK: - Ending the session

  /// Finalizes a take in flight, blocking until the file is playable.
  ///
  /// An h264 file is unplayable until the writer has finalized it, so the quit path calls this on the
  /// way out — otherwise quitting hands the operator a movie no player will open. Blocking rather than
  /// async because the run loop AppKit spins while it waits for a `.terminateLater` reply does not
  /// service the main actor's queue, so an async finalize would never run and the app would hang.
  func finalizeWindowRecordingBlocking() {
    guard let recorder = windowRecorder else { return }
    clearWindowRecording()
    if let url = recorder.stopBlocking() { NSLog("SimScope: window recording written to %@", url.path) }
  }

  /// Unlinks the socket files, so the next run's bind does not have to reclaim them.
  func shutdown() {
    for channel in controlChannels { channel.stop() }
    controlChannels = []
  }

  /// A still of this window's device, from the surface the window is already mirroring.
  func currentScreenImage() -> CGImage? { simView?.currentScreenImage() }

  /// A window that closes takes its session with it: the take is finalized while there is still a
  /// window to read it from, the socket is unlinked so an agent dialing it gets "no SimScope here"
  /// rather than silence, and the registry is told to let go.
  func windowWillClose(_ notification: Notification) {
    finalizeWindowRecordingBlocking()
    shutdown()
    onClose?(self)
  }

  // MARK: - Window construction

  private static func makeWindow(pointSize: CGSize, name: String) -> (NSWindow, simPaneWidth: CGFloat) {
    // Size the simulator pane to fit a comfortable height; the side panel is a fixed-ish width.
    // Shape the whole window to 16:9, the aspect these recordings are presented at. Both dimensions are
    // derived from that, rather than sizing the simulator pane first and letting the panel take what is
    // left: a phone-width pane beside a narrow panel gives a near-square window, which letterboxes on a
    // slide and truncates the tree and the action log — the two things a viewer actually reads.
    // Whatever width is left over after the phone goes to the panel, which is where the detail is.
    // The recorded frame is the whole window, title bar included, so the 16:9 target applies there and
    // the content is sized a title bar shorter. Capped rather than screen-relative: on a large display
    // "as wide as will fit" produces a window that swallows the desktop and records at a needlessly
    // large size, and the panel only needs enough room to make the tree and the log readable.
    let slideAspect: CGFloat = 16.0 / 9.0
    let titleBarHeight: CGFloat = 28
    // Prefer the built-in display. It is the high-density one, so the capture is sharper per recorded
    // pixel, and it keeps the window off whatever large external display the operator is working on.
    let targetScreen = NSScreen.builtInOrMain
    let visible = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
    let framedWidth = min(1280, visible.width - 120, (visible.height - 120) * slideAspect)
    let contentHeight = framedWidth / slideAspect - titleBarHeight
    let displayScale = min(1, contentHeight / max(pointSize.height, 1))
    let simPaneSize = NSSize(width: pointSize.width * displayScale, height: contentHeight)
    let panelWidth = max(420, framedWidth - simPaneSize.width - 1)
    let contentSize = NSSize(width: simPaneSize.width + panelWidth + 1, height: simPaneSize.height)

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    // ast-grep-ignore: common/swift/i18n-hardcoded-ui-property
    window.title = "SimScope — \(name)"
    window.acceptsMouseMovedEvents = true
    if let targetScreen {
      let f = targetScreen.visibleFrame
      window.setFrameOrigin(
        NSPoint(
          x: f.midX - contentSize.width / 2,
          y: f.midY - contentSize.height / 2))
    } else {
      window.center()
    }
    return (window, simPaneSize.width)
  }

  private func populate(window: NSWindow, simPaneWidth: CGFloat) {
    let backend = backend
    let toolbar = NSToolbar(identifier: "SimScopeToolbar-\(backend.simulator.udid)")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.toolbarStyle = .unified

    // The action-log pane renders every event on the session bus; the recorder captures it to a bundle.
    session.observe { [actionLog] event in actionLog.append(event) }
    let recorder = SessionRecorder(backend: backend, session: session)
    self.recorder = recorder
    let repl = SessionREPL(
      injector: CodeInjector(
        udid: backend.simulator.udid,
        defaultBundleID: LaunchArguments.argument("--repl-bundle-id")
          ?? ProcessInfo.processInfo.environment["SIMSCOPE_REPL_BUNDLE_ID"],
        reportURL: Self.defaultReplReportURL()),
      session: session)
    self.repl = repl
    openControlChannel(backend: backend, recorder: recorder, repl: repl, window: window)

    // Left: the simulator surface.
    let simView = SimulatorView(backend: backend, session: session)
    simView.isOverlayEnabled = overlayEnabled

    // The collaboration surface: the agent's touches are drawn on the screen it shares with the human,
    // the title bar says when it is active, and the log's reply field puts the human back on the bus.
    session.observe { [weak self, weak simView] event in
      simView?.showRemoteTouch(for: event)
      if event.source == .agent { self?.noteAgentActivity() }
    }
    actionLog.onSend = { [session] text in session.recordChat(source: .human, text) }

    // Right: the live accessibility tree (top) over the action log (bottom).
    let treeInspector = TreeInspector(read: { [backend] includeAll, traversal in
      try await backend.readTree(includeAll: includeAll, traversal: traversal)
    })
    treeInspector.onSelect = { [weak simView, backend] node in
      guard let node, let frame = node.frame else {
        simView?.highlightExternal(nil)
        return
      }
      simView?.highlightExternal(backend.clippedFrame(frame))
    }
    // Hovering the phone reveals the element's row in the tree. The hover has already paid for a
    // hit-test, so this costs nothing extra, and it makes the two panes point at the same thing —
    // which is also what shows a viewer WHICH row an agent just acted on, before the next refresh
    // rewrites the table.
    simView.onHover = { [weak self, weak treeInspector] _, hit in
      // Only when the cursor crosses into a DIFFERENT element. A hover resolves as fast as the hit-tests
      // return, and expanding ancestors, moving the selection and scrolling the table on each one is
      // main-thread work at cursor rate for a row that is already showing.
      guard let self, let hit, hit != self.lastHoveredElement else { return }
      self.lastHoveredElement = hit
      treeInspector?.reveal(element: hit)
    }
    treeInspector.onNodes = { [weak simView] nodes, identityHeld in
      simView?.setCoverageNodes(nodes, identityHeld: identityHeld)
    }
    // Any action invalidates the heatmap: it describes the screen before the action, and the screen has
    // just changed. Cleared here rather than in each command path so nothing can dispatch and forget.
    session.observe { [weak simView, weak treeInspector] event in
      // A tap is shown in the tree as well as on the phone: scroll to the row it landed on and flash
      // it. On a screen of two hundred elements the acted-on row is almost always out of view, so
      // without this the table and the simulator appear to be describing unrelated events. Hooked on
      // the session rather than in each command path, so every touch gets it whoever sent it.
      if case let .tap(x, y) = event.action {
        treeInspector?.reveal(tapAt: CGPoint(x: x, y: y))
      }
      // Anything that mutates the screen: the replayable inputs, plus an injection, which can repaint
      // the app just as thoroughly as a tap.
      let mutates: Bool
      switch event.action {
      case .chat, .note: mutates = false
      default: mutates = true
      }
      guard mutates else { return }
      simView?.invalidateCoverage()
    }
    // `--poll-interval 0` stops the periodic read entirely. Needed for measurement: a read takes
    // seconds on a large app, the poller holds the transport while it runs, and a second read issued
    // over the socket then waits behind it — so a naive timing measures SimScope's own queueing rather
    // than the operation it is trying to time.
    if Self.pollIntervalArgument > 0 {
      treeInspector.startAutoRefresh(interval: Self.pollIntervalArgument)
    }

    // Coverage-visualization mode selector, shown alongside the tree; drives the heatmap on the sim.
    let modeControl = NSSegmentedControl(
      labels: OverlayMode.allCases.map(\.title),
      trackingMode: .selectOne,
      target: self,
      action: #selector(overlayModeChanged(_:)))
    // `--overlay interactive|non-interactive|all` selects the mode at launch, so a recorded take can
    // start with the visualization already on rather than needing someone to click it mid-capture.
    let initialMode = Self.overlayModeArgument ?? .off
    simView.overlayMode = initialMode
    modeControl.selectedSegment = initialMode.rawValue
    modeControl.controlSize = .small
    modeControl.toolTip = "Visualize accessibility coverage on the simulator (interactive is the meaningful category)"

    // Reachability asks the application to hit-test every element; semantic traversal uses the
    // accessibility translator's vocabulary. Neither has the same cost or coverage as a basic read.
    let traversalControl = NSSegmentedControl(
      labels: ["Fast", "Reachability", "VoiceOver"],
      trackingMode: .selectOne,
      target: self,
      action: #selector(traversalChanged(_:)))
    traversalControl.selectedSegment =
      (SimBackend.traversalStrategyArgument == .semantic)
      ? 2 : (SimBackend.reachabilityArgument ? 1 : 0)
    traversalControl.controlSize = .small
    traversalControl.toolTip = """
      What each read asks for. Fast is the default and costs milliseconds. Reachability adds whether \
      each element can actually be touched and what covers it when it cannot — worth asking for \
      deliberately, because the application hit-tests every node to answer and that is seconds on a \
      large app. VoiceOver reads through the accessibility translator — the same vocabulary an assistive \
      technology is served — which reaches content hosted in a collection-view cell and omits \
      interactive elements the other reads report.
      """

    // How often the tree re-reads itself, exposed rather than fixed because the right answer is a
    // property of the app on screen and not of this window. A read of an ordinary app costs a few
    // hundred milliseconds and once a second is comfortable; a read of a large one costs seconds, and a
    // poll that never stops holds the transport so an agent's own read queues behind it. Off is offered
    // for exactly that reason: it is what makes a timing measure the operation rather than this
    // window's queueing.
    let refreshControl = NSPopUpButton(frame: .zero, pullsDown: false)
    var intervals = Self.refreshChoices
    if !intervals.contains(Self.pollIntervalArgument) {
      intervals.append(Self.pollIntervalArgument)
      intervals.sort()
    }
    self.refreshIntervals = intervals
    refreshControl.addItems(withTitles: intervals.map(Self.refreshTitle))
    refreshControl.selectItem(at: intervals.firstIndex(of: Self.pollIntervalArgument) ?? 0)
    refreshControl.target = self
    refreshControl.action = #selector(refreshIntervalChanged(_:))
    refreshControl.controlSize = .small
    refreshControl.font = .systemFont(ofSize: 11)
    refreshControl.toolTip = """
      How long to wait between tree reads. This is a floor rather than a rate: the next read starts \
      once this interval has passed AND the previous one has finished, so a slow app polls more slowly \
      instead of building a backlog. Off stops polling entirely, leaving the tree as it was until \
      something asks for a read.
      """
    self.refreshControl = refreshControl

    func caption(_ text: String) -> NSTextField {
      let field = NSTextField(labelWithString: text)
      field.font = .systemFont(ofSize: 10, weight: .regular)
      field.textColor = .tertiaryLabelColor
      return field
    }
    // Read strategy on the left, screen overlay on the right, each captioned. Two bare segmented
    // controls side by side read as one four-way choice; they are unrelated axes and should not.
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    self.traversalControl = traversalControl
    self.overlayControl = modeControl
    let treeAccessories = NSStackView(views: [
      caption("Read as"), traversalControl, caption("Refresh"), refreshControl,
      spacer, caption("Show on screen"), modeControl,
    ])
    treeAccessories.orientation = .horizontal
    treeAccessories.spacing = 6
    treeAccessories.setHuggingPriority(.defaultLow, for: .horizontal)

    let rightSplit = NSSplitView()
    rightSplit.isVertical = false // horizontal divider → tree over log
    rightSplit.dividerStyle = .thin
    rightSplit.addArrangedSubview(Self.sectionWithAccessory(title: "Accessibility Tree", accessory: treeAccessories, content: treeInspector.contentView))
    rightSplit.addArrangedSubview(Self.section("Session Log — actions from both of you, and chat", actionLog.contentView))

    let mainSplit = NSSplitView()
    mainSplit.isVertical = true // vertical divider → simulator | panel
    mainSplit.dividerStyle = .thin
    mainSplit.addArrangedSubview(simView)
    mainSplit.addArrangedSubview(rightSplit)
    window.contentView = mainSplit

    // Background captures must not redirect the operator's keystrokes into the simulator.
    if LaunchArguments.flag("--background") {
      window.orderFrontRegardless()
      simView.start()
    } else {
      window.makeKeyAndOrderFront(nil)
      simView.start()
      window.makeFirstResponder(simView) // so the Mac keyboard types into the simulator immediately
      NSApp.activate(ignoringOtherApps: true)
    }

    // Position dividers once the split views have their real sizes.
    DispatchQueue.main.async {
      mainSplit.setPosition(simPaneWidth, ofDividerAt: 0)
      rightSplit.setPosition(rightSplit.bounds.height * 0.62, ofDividerAt: 0)
    }

    self.simView = simView
    self.treeInspector = treeInspector

    // The device switcher, next to the device's own name and UDID in the title bar: the same list
    // the Simulator menu shows, one click from the place that says which device this window is.
    let switcher = NSButton(
      image: NSImage(systemSymbolName: "iphone", accessibilityDescription: "Open another simulator")
        ?? NSImage(),
      target: nil, action: #selector(AppDelegate.popUpSimulatorMenu(_:)))
    switcher.bezelStyle = .texturedRounded
    switcher.toolTip = "Open another simulator"
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = switcher
    // Leading, beside the title and UDID: the switcher lives where the window says which device it
    // is, so "which device" and "another device" are the same corner.
    accessory.layoutAttribute = .left
    window.addTitlebarAccessoryViewController(accessory)

    startUnattendedRun(window: window, simView: simView)
  }

  /// Wraps a content view with a small section header, filling the rest.
  private static func section(_ title: String, _ content: NSView) -> NSView {
    let container = NSView()
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    container.addSubview(content)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
      content.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
      content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
  }

  /// A section like `section(_:_:)` but with a trailing accessory view (e.g. a control) in the header.
  private static func sectionWithAccessory(title: String, accessory: NSView, content: NSView) -> NSView {
    let container = NSView()
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.translatesAutoresizingMaskIntoConstraints = false
    accessory.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    container.addSubview(accessory)
    container.addSubview(content)
    NSLayoutConstraint.activate([
      accessory.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
      accessory.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      accessory.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      label.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
      content.topAnchor.constraint(equalTo: accessory.bottomAnchor, constant: 4),
      content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
  }

  /// The overlay mode named by `--overlay`, if the argument is present and recognised.
  private static func overlayMode(named raw: String) -> OverlayMode? {
    switch raw.lowercased() {
    case "off": return .off
    case "interactive", "reachable": return .interactive
    case "non-interactive", "noninteractive", "all", "everything": return .all
    default: return nil
    }
  }

  private static var overlayModeArgument: OverlayMode? {
    guard let raw = LaunchArguments.argument("--overlay")?.lowercased() else { return nil }
    switch raw {
    case "off": return .off
    case "interactive": return .interactive
    // `non-interactive` used to be a fourth mode that drew nothing. Kept as an accepted spelling so
    // existing scripts do not fail at launch, mapped to the mode that actually shows everything.
    case "non-interactive", "noninteractive", "all": return .all
    default:
      NSLog("SimScope: unrecognised --overlay value %@; leaving the overlay off", raw)
      return nil
    }
  }

  @objc private func traversalChanged(_ sender: NSSegmentedControl) {
    // Segments 0 and 1 are one vocabulary either side of the automation mode; 2 is the other
    // vocabulary. Automation mode is applied first so the reader is rebuilt before the tree is re-read,
    // otherwise the refresh races the reader it is meant to be using.
    // Reachability is a property of the request, so it is set before the re-read is issued; otherwise
    // the refresh goes out asking for the previous mode's key set.
    backend.wantsReachability = sender.selectedSegment == 1
    treeInspector?.traversal = sender.selectedSegment == 2 ? .semantic : .viewHierarchy
    // The traversal setter only refreshes when the strategy actually changed, so switching between the
    // two XCTest segments would otherwise move the reader and leave the old tree on screen.
    treeInspector?.rereadForReaderChange()
  }

  @objc private func overlayModeChanged(_ sender: NSSegmentedControl) {
    simView?.overlayMode = OverlayMode(rawValue: sender.selectedSegment) ?? .off
  }

  /// The offered refresh intervals. `--poll-interval` is added to this list when it is something else,
  /// so the control always states the interval actually in force rather than the nearest one it knows.
  private static let refreshChoices: [TimeInterval] = [0, 0.5, 1, 2, 5]

  private static func refreshTitle(_ interval: TimeInterval) -> String {
    guard interval > 0 else { return "Off" }
    return unsafe interval < 1 || interval != interval.rounded()
      ? String(format: "%.1f s", interval) : "\(Int(interval)) s"
  }

  @objc private func refreshIntervalChanged(_ sender: NSPopUpButton) {
    let index = sender.indexOfSelectedItem
    guard index >= 0, index < refreshIntervals.count else { return }
    let interval = refreshIntervals[index]
    guard interval > 0 else {
      treeInspector?.stopAutoRefresh()
      return
    }
    treeInspector?.startAutoRefresh(interval: interval)
  }

  /// Seconds between periodic tree reads; 0 disables polling so a read can be timed on its own.
  private static var pollIntervalArgument: TimeInterval {
    guard let raw = LaunchArguments.argument("--poll-interval"), let value = TimeInterval(raw) else { return 1.0 }
    return value
  }

  // MARK: - Recording the window

  /// Records this window — both parties' halves of the session, the log and the title bar included —
  /// to `path`, or to a dated file beside the session bundles if the caller did not name one.
  ///
  /// Distinct from `SessionRecorder`, which keeps the simulator's own video stream: that one shows
  /// what the device did, this one shows what the two of you did.
  @discardableResult
  private func startWindowRecording(window: NSWindow, to path: String?) async throws -> URL {
    let url = path.map { URL(fileURLWithPath: $0) } ?? Self.defaultRecordingURL()
    let recorder = WindowRecorder(window: window, url: url)
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleDisplaySleepDisabled], reason: "recording the SimScope window")
    do {
      try await recorder.start()
    } catch {
      ProcessInfo.processInfo.endActivity(activity)
      throw error
    }
    windowRecorder = recorder
    windowRecordingURL = url
    recordingActivity = activity
    session.recordNote("Recording this window to \(url.path).")
    updateSubtitle()
    return url
  }

  /// Finishes the take and returns the finalized file, or nil if nothing was recording.
  private func stopWindowRecording() async -> URL? {
    guard let recorder = windowRecorder else { return nil }
    clearWindowRecording()
    return await recorder.stop()
  }

  /// Notes the end of the take on the session and drops everything the app holds for it — everything
  /// but the recorder, which the caller still has to close.
  ///
  /// Separate from the closing so the quit path, which cannot await, narrates and tidies up in exactly
  /// the way the menu and the agent do.
  private func clearWindowRecording() {
    if let url = windowRecordingURL {
      session.recordNote("Stopped recording. The window recording is at \(url.path).")
    }
    windowRecorder = nil
    windowRecordingURL = nil
    if let activity = recordingActivity {
      ProcessInfo.processInfo.endActivity(activity)
      recordingActivity = nil
    }
    updateSubtitle()
  }

  /// Beside the session bundles rather than in `~/Movies`, where a movie would more naturally go: the
  /// app is ad-hoc signed and launched out of a build tree, which is not the sort of thing macOS hands
  /// the media folders to — writing there fails with a permission error before the take even starts.
  private static func defaultRecordingURL() -> URL {
    SessionRecorder.recordingsDirectory.appendingPathComponent("simscope-\(timestamp()).mp4")
  }

  /// The Markdown report `idb-repl` accumulates across this run of SimScope, beside the recordings for
  /// the same reason they live there — and, like them, an artifact of the session rather than of one
  /// command. `idb-repl replay` re-runs it.
  private static func defaultReplReportURL() -> URL {
    SessionRecorder.recordingsDirectory.appendingPathComponent("simscope-repl-\(timestamp()).md")
  }

  private static func timestamp() -> String {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd-HHmmss"
    return stamp.string(from: Date())
  }

  @objc func toggleWindowRecording() {
    guard let window else { return }
    Task { @MainActor in
      if windowRecordingURL != nil {
        if let url = await stopWindowRecording() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        return
      }
      do {
        try await startWindowRecording(window: window, to: nil)
      } catch {
        presentSimScopeError(error, message: "Couldn't start recording the window.")
      }
    }
  }

  // MARK: - Unattended run

  /// The two flags that let SimScope run without anyone in front of it.
  ///
  /// `--record <file>` records the window from launch — which is all an operator driving the session
  /// themselves needs, since the agent and the human both show up in one frame. `--demo-script <file>`
  /// additionally plays a scripted stand-in for the human, and `--demo-quit` closes the app when the
  /// script runs out. The script is the only part that is a stand-in: with `--record` alone, the person
  /// at the keyboard is real and the recording is theirs to stop, from the Session menu or by quitting.
  private func startUnattendedRun(window: NSWindow, simView: SimulatorView) {
    let scriptPath = LaunchArguments.argument("--demo-script")
    let recordPath = LaunchArguments.argument("--record")
    guard scriptPath != nil || recordPath != nil else { return }

    var autopilot: HumanAutopilot?
    if let scriptPath {
      do {
        autopilot = HumanAutopilot(
          window: window, simulatorView: simView, actionLog: actionLog,
          beats: try HumanAutopilot.beats(fromFile: scriptPath))
      } catch {
        presentSimScopeError(error, message: "Couldn't read the demo script at \(scriptPath).")
        return
      }
    }

    Task { @MainActor in
      // The first framebuffer and the axbridge connection both land a beat after launch; starting into
      // a black window would put the least interesting seconds at the front of the recording — and
      // beats posted before the mirrored screen has a size land in the letterbox margin, where the view
      // drops them. Waiting on the mapping rather than on a fixed pause is what makes the capture
      // reproducible on a machine that is busy booting a simulator.
      let deadline = ContinuousClock.now + .seconds(30)
      while !simView.isScreenMapped, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(100))
      }
      try? await Task.sleep(for: .seconds(2))
      if let recordPath {
        do {
          try await startWindowRecording(window: window, to: recordPath)
        } catch {
          // Not fatal: a scripted run is still worth playing, and an operator can retry from the menu.
          NSLog("SimScope: could not record the window — %@", String(describing: error))
          session.recordNote("Window recording unavailable: \((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
      }
      guard let autopilot else { return } // an operator takes it from here; they end the take themselves
      session.recordNote("Demo script running — \(autopilot.beatCount) beats.")
      await autopilot.play()
      session.recordNote("Demo script finished.")
      try? await Task.sleep(for: .seconds(2)) // let the last action land on screen before cutting
      if let url = await stopWindowRecording() {
        NSLog("SimScope: demo recorded to %@", url.path)
      }
      if LaunchArguments.flag("--demo-quit") { NSApp.terminate(nil) }
    }
  }

  // MARK: - Agent control channel

  /// Opens the socket an agent drives SimScope through. A failure here is reported but not fatal —
  /// the app is still perfectly usable by the human alone.
  private func openControlChannel(
    backend: SimBackend, recorder: SessionRecorder, repl: SessionREPL, window: NSWindow
  ) {
    let dispatcher = AgentDispatcher(
      backend: backend, session: session, isRecording: { [weak recorder] in recorder?.isRecording ?? false },
      repl: repl,
      windowRecording: WindowRecordingControl(
        currentURL: { [weak self] in self?.windowRecordingURL },
        start: { [weak self] path in
          guard let self else { throw AgentDispatchError.appIsClosing }
          return try await self.startWindowRecording(window: window, to: path)
        },
        stop: { [weak self] in await self?.stopWindowRecording() ?? nil }),
      // Lets a session move the same controls the human can, so the window is the demonstration
      // rather than the backdrop to one.
      // Resolved through `self` at call time, not captured. Capturing the inspector weakly here bound
      // it before the property was assigned, so the reference was nil, the assignment silently did
      // nothing, and the log still reported success — the control moved and the tree never re-read.
      viewControls: { [weak self] traversal, overlay in
        guard let self else { return "SimScope is closing." }
        var changed: [String] = []
        var refused: [String] = []
        if let raw = traversal {
          if let strategy = AXTraversalStrategy(rawValue: raw), let inspector = self.treeInspector {
            inspector.traversal = strategy
            self.traversalControl?.selectedSegment = strategy == .semantic ? 2 : 1
            changed.append("reading the tree as \(raw)")
          } else {
            refused.append("could not read the tree as \(raw)")
          }
        }
        if let raw = overlay {
          if let mode = Self.overlayMode(named: raw), let view = self.simView {
            view.overlayMode = mode
            self.overlayControl?.selectedSegment = mode.rawValue
            changed.append("overlay \(mode.title.lowercased())")
          } else {
            refused.append("could not set the overlay to \(raw)")
          }
        }
        // Report what was applied and what was not. A confirmation that is emitted whether or not the
        // change landed is worse than no confirmation: it is what let this bug survive a recording.
        if changed.isEmpty && refused.isEmpty { return "No view change requested." }
        if refused.isEmpty { return "Switched to \(changed.joined(separator: ", "))." }
        if changed.isEmpty { return "REFUSED: \(refused.joined(separator: ", "))." }
        return "Switched to \(changed.joined(separator: ", ")); REFUSED: \(refused.joined(separator: ", "))."
      },
      captureScreen: { [weak self] path in
        guard let view = self?.simView else { throw AgentDispatchError.appIsClosing }
        return try view.writeScreenshot(to: path)
      })
    for socketPath in controlSocketPaths {
      let channel = ControlChannel(path: socketPath, dispatcher: dispatcher)
      do {
        let path = try channel.start()
        controlChannels.append(channel)
        NSLog("SimScope: agent control channel listening on %@", path)
        session.recordNote("Agent channel open at \(path)")
      } catch {
        NSLog("SimScope: could not open the agent control channel — %@", String(describing: error))
        session.recordNote("Agent channel unavailable: \((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)")
      }
    }
  }

  /// Marks the agent as present in the title bar, and schedules the mark to lapse if it goes quiet.
  private func noteAgentActivity() {
    agentIsActive = true
    updateSubtitle()
    agentActivityToken += 1
    let token = agentActivityToken
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.agentIdleTimeout) { [weak self] in
      guard let self, self.agentActivityToken == token else { return }
      self.agentIsActive = false
      self.updateSubtitle()
    }
  }

  /// The title bar's second line: whether a take is rolling, whether the agent is here, and which
  /// device this is. In that order, because the subtitle truncates from the tail and at the window's
  /// natural width the UDID alone already fills it.
  private func updateSubtitle() {
    var parts: [String] = []
    if windowRecordingURL != nil { parts.append("● recording") }
    if agentIsActive { parts.append("agent active") }
    parts.append(deviceSubtitle)
    window?.subtitle = parts.joined(separator: "  ·  ")
  }

  // MARK: - Toolbar (hardware buttons + controls)

  private var toolbarIdentifiers: [NSToolbarItem.Identifier] {
    DeviceAction.all.map(\.toolbarIdentifier)
      + [.flexibleSpace, .record, .repeatActions, .hwKeyboard, .treeFilter, .overlay]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarIdentifiers }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarIdentifiers }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    if let spec = DeviceAction.all.first(where: { $0.toolbarIdentifier == itemIdentifier }) {
      return makeItem(
        id: spec.toolbarIdentifier, label: spec.label, symbol: spec.symbol, tooltip: spec.prose,
        action: #selector(deviceButtonPressed(_:)))
    }
    if itemIdentifier == .overlay {
      let item = makeItem(id: .overlay, label: "Overlay", symbol: "eye.fill", tooltip: "Toggle the hover overlay", action: #selector(toggleOverlay))
      overlayItem = item
      updateOverlayItem()
      return item
    }
    if itemIdentifier == .treeFilter {
      let item = makeItem(id: .treeFilter, label: "Filter", symbol: "line.3.horizontal.decrease.circle", tooltip: "Toggle showing all tree elements", action: #selector(toggleTreeFilter))
      treeFilterItem = item
      updateTreeFilterUI()
      return item
    }
    if itemIdentifier == .record {
      let item = makeItem(id: .record, label: "Record", symbol: "record.circle", tooltip: "Record a session bundle (video + transcript)", action: #selector(toggleRecording))
      recordItem = item
      updateRecordItem()
      return item
    }
    if itemIdentifier == .repeatActions {
      return makeItem(id: .repeatActions, label: "Repeat", symbol: "arrow.clockwise", tooltip: "Repeat the actions I performed since the last repeat", action: #selector(repeatMyActions))
    }
    if itemIdentifier == .hwKeyboard {
      let item = makeItem(id: .hwKeyboard, label: "Keyboard", symbol: "keyboard", tooltip: "Toggle the hardware keyboard", action: #selector(toggleHardwareKeyboard))
      hwKeyboardItem = item
      updateHardwareKeyboardUI()
      return item
    }
    return nil
  }

  private func makeItem(id: NSToolbarItem.Identifier, label: String, symbol: String, tooltip: String, action: Selector) -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: id)
    item.label = label
    item.paletteLabel = label
    item.toolTip = tooltip
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    item.isBordered = true
    item.target = self
    item.action = action
    return item
  }

  // MARK: - Actions

  /// Menu state lives here rather than in stored menu-item references: items carry nil targets so the
  /// responder chain can route them to the key window's controller, and an item shared by every window
  /// cannot belong to any one of them. AppKit asks the controller that would receive the action, so
  /// each window answers with its own state.
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(toggleTreeFilter):
      menuItem.state = (treeInspector?.showAll ?? false) ? .on : .off
    case #selector(toggleHardwareKeyboard):
      menuItem.state = hardwareKeyboardEnabled ? .on : .off
    case #selector(toggleRecording):
      menuItem.title = (recorder?.isRecording ?? false) ? "Stop Recording" : "Start Recording"
    case #selector(toggleWindowRecording):
      menuItem.title = windowRecordingURL == nil ? "Record This Window" : "Stop Recording This Window"
    default:
      break
    }
    return true
  }

  @objc private func deviceButtonPressed(_ sender: NSToolbarItem) {
    guard let spec = DeviceAction.all.first(where: { $0.toolbarIdentifier == sender.itemIdentifier }) else { return }
    runDevice(spec)
  }

  @objc func deviceMenuSelected(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let spec = DeviceAction.named(raw) else { return }
    runDevice(spec)
  }

  private func runDevice(_ spec: DeviceAction) {
    session.recordDevice(source: .human, name: spec.name, prose: spec.prose)
    Task { try? await backend.perform(deviceAction: spec.name) }
  }

  @objc func toggleOverlay() {
    overlayEnabled.toggle()
    simView?.isOverlayEnabled = overlayEnabled
    updateOverlayItem()
    session.recordNote(overlayEnabled ? "Enabled the hover overlay." : "Disabled the hover overlay.")
  }

  private func updateOverlayItem() {
    overlayItem?.image = NSImage(
      systemSymbolName: overlayEnabled ? "eye.fill" : "eye.slash.fill",
      accessibilityDescription: "Toggle overlay")
    overlayItem?.label = overlayEnabled ? "Overlay On" : "Overlay Off"
    overlayItem?.toolTip = overlayEnabled ? "Hide the hover overlay" : "Show the hover overlay"
  }

  @objc func toggleTreeFilter() {
    guard let treeInspector else { return }
    treeInspector.showAll.toggle()
    updateTreeFilterUI()
  }

  private func updateTreeFilterUI() {
    let showAll = treeInspector?.showAll ?? false
    treeFilterItem?.image = NSImage(
      systemSymbolName: showAll ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill",
      accessibilityDescription: "Tree filter")
    treeFilterItem?.label = showAll ? "All" : "Important"
    treeFilterItem?.toolTip =
      showAll
      ? "Showing all elements — click to show only meaningful ones"
      : "Showing meaningful elements only — click to show all"
  }

  @objc func toggleHardwareKeyboard() {
    hardwareKeyboardEnabled.toggle()
    updateHardwareKeyboardUI()
    let enabled = hardwareKeyboardEnabled
    session.recordNote(enabled ? "Connected the hardware keyboard." : "Disconnected the hardware keyboard (software keyboard shown).")
    Task { try? await backend.setHardwareKeyboard(enabled) }
  }

  private func updateHardwareKeyboardUI() {
    hwKeyboardItem?.image = NSImage(
      systemSymbolName: hardwareKeyboardEnabled ? "keyboard.fill" : "keyboard",
      accessibilityDescription: "Hardware keyboard")
    hwKeyboardItem?.toolTip =
      hardwareKeyboardEnabled
      ? "Hardware keyboard connected — click to show the software keyboard"
      : "Software keyboard shown — click to connect the hardware keyboard"
  }

  // MARK: - Recording

  @objc func toggleRecording() {
    guard let recorder else { return }
    if recorder.isRecording {
      Task {
        let url = await recorder.stop()
        self.updateRecordItem()
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
    } else {
      Task {
        do { _ = try await recorder.start() } catch { presentSimScopeError(error, message: "Couldn't start recording.") }
        self.updateRecordItem()
      }
    }
    updateRecordItem()
  }

  private func updateRecordItem() {
    let on = recorder?.isRecording ?? false
    recordItem?.image = NSImage(
      systemSymbolName: on ? "stop.circle.fill" : "record.circle",
      accessibilityDescription: "Record")
    recordItem?.label = on ? "Stop" : "Record"
    recordItem?.toolTip = on ? "Stop recording and reveal the bundle" : "Record a session bundle (video + transcript)"
  }

  // MARK: - Repeat after me

  /// Replays the human actions performed since the last repeat — SimScope re-issues them to the sim
  /// from the same structured events an agent would consume. Each is logged as a `.replay` event.
  @objc func repeatMyActions() {
    let toReplay = session.events[replayFromIndex...].filter { $0.source == .human && $0.action.isReplayable }
    replayFromIndex = session.events.count
    guard !toReplay.isEmpty else {
      session.recordNote("Nothing new to repeat.")
      return
    }
    session.recordNote("Repeating \(toReplay.count) action\(toReplay.count == 1 ? "" : "s")…")
    Task {
      for event in toReplay {
        session.record(source: .replay, action: event.action, prose: event.prose, element: event.element)
        try? await backend.perform(event.action)
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
      session.recordNote("Repeat complete.")
    }
  }

  /// Opens the operator's side of the session REPL. The agent's side is the control channel's
  /// `inject`; both land in the same app process and on the same timeline.
  @objc func showSwiftConsole() {
    guard let repl else { return }
    let console = swiftConsole ?? SwiftConsole(repl: repl)
    swiftConsole = console
    console.show()
  }
}

// MARK: - Launch arguments

/// The process's launch arguments, read where they are needed rather than parsed up front — the app
/// predates any notion of per-window configuration, and every consumer treats absence as its default.
enum LaunchArguments {
  static func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
  }

  static func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

  /// Every value the flag was passed with, in order, for arguments that repeat.
  static func values(_ name: String) -> [String] {
    let args = CommandLine.arguments
    return args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] }
  }
}

// MARK: - Errors

/// Logged as well as shown: a modal alert is invisible to anyone reading the app's output.
@MainActor
func presentSimScopeError(_ error: any Error, message: String, fatal: Bool = false) {
  NSLog("SimScope: %@ — %@", message, String(describing: error))
  let alert = NSAlert()
  alert.alertStyle = fatal ? .critical : .warning
  alert.messageText = message
  alert.informativeText = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
  alert.addButton(withTitle: fatal ? "Quit" : "OK")
  NSApp.activate(ignoringOtherApps: true)
  alert.runModal()
  if fatal { NSApp.terminate(nil) }
}

private extension DeviceAction {
  /// The toolbar item is identified by the action's own name, so the toolbar, the Device menu, and
  /// the agent channel's `button` method all key off one string.
  var toolbarIdentifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier(name) }
}

private extension NSToolbarItem.Identifier {
  static let overlay = NSToolbarItem.Identifier("overlay")
  static let treeFilter = NSToolbarItem.Identifier("treeFilter")
  static let hwKeyboard = NSToolbarItem.Identifier("hwKeyboard")
  static let record = NSToolbarItem.Identifier("record")
  static let repeatActions = NSToolbarItem.Identifier("repeatActions")
}

// MARK: - Screen selection

extension NSScreen {
  /// The built-in display when there is one, else the main display.
  ///
  /// Recordings are sharper on the built-in panel because it is the high-density one, and putting the
  /// window there keeps it clear of whatever large external display the operator is actually working on.
  static var builtInOrMain: NSScreen? {
    let builtIn = screens.first { screen in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        return false
      }
      return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
    return builtIn ?? main
  }
}
