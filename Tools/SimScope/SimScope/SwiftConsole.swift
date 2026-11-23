/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
import SimScopeProtocol

/// The operator's half of the session REPL: a panel to write Swift in and run it inside the app on
/// screen.
///
/// A floating panel rather than a pane in the window, because the window is what a take records and a
/// code editor would crowd out the tree and the log for the length of one. Nothing is lost from the
/// recording by keeping it outside: every run is echoed into the session log, snippet included, so the
/// take still shows what was written and what came back.
@MainActor
final class SwiftConsole: NSObject {

  private let repl: SessionREPL
  private let panel: NSPanel
  private let bundleField: NSTextField
  private let mainThreadToggle: NSButton
  private let editor: NSTextView
  private let output: NSTextView
  private let runButton: NSButton
  private var isRunning = false

  private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

  init(repl: SessionREPL) {
    self.repl = repl

    let bundleField = NSTextField(string: repl.defaultBundleID ?? "")
    bundleField.placeholderString = "bundle id of the app to run in"
    bundleField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    bundleField.controlSize = .small

    let mainThreadToggle = NSButton(checkboxWithTitle: "Main thread", target: nil, action: nil)
    mainThreadToggle.state = .on
    mainThreadToggle.controlSize = .small
    mainThreadToggle.toolTip =
      "Wrap the snippet in DispatchQueue.main.sync. Injected code runs on a worker thread, and UIKit "
      + "touched from there kills the app."

    let editor = Self.makeTextView(editable: true)
    let editorScroll = Self.makeScrollView(editor)
    let output = Self.makeTextView(editable: false)
    let outputScroll = Self.makeScrollView(output)

    let runButton = NSButton(title: "Run", target: nil, action: nil)
    runButton.bezelStyle = .rounded
    runButton.keyEquivalent = "\r"
    runButton.keyEquivalentModifierMask = [.command]
    runButton.toolTip = "Compile and run this in the app (⌘↩)"

    let header = NSStackView(views: [bundleField, mainThreadToggle])
    header.orientation = .horizontal
    header.spacing = 8
    bundleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    mainThreadToggle.setContentHuggingPriority(.required, for: .horizontal)

    let footer = NSStackView(views: [NSView(), runButton])
    footer.orientation = .horizontal
    runButton.setContentHuggingPriority(.required, for: .horizontal)

    let stack = NSStackView(views: [header, editorScroll, footer, outputScroll])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
    // The editor takes the space; the output pane keeps a readable minimum.
    editorScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    outputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
      styleMask: [.titled, .closable, .resizable, .utilityWindow],
      backing: .buffered,
      defer: false)
    // ast-grep-ignore: common/swift/i18n-hardcoded-ui-property
    panel.title = "Swift Console"
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.contentView = stack

    self.panel = panel
    self.bundleField = bundleField
    self.mainThreadToggle = mainThreadToggle
    self.editor = editor
    self.output = output
    self.runButton = runButton
    super.init()

    runButton.target = self
    runButton.action = #selector(run)
    editor.string = Self.starterSnippet
    write("⌘↩ runs the snippet. The report of this session is at \(repl.reportURL.path).")
  }

  func show() {
    if !panel.isVisible { panel.center() }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(editor)
  }

  // MARK: - Running

  @objc private func run() {
    let code = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty, !isRunning else { return }
    setRunning(true)
    Task { @MainActor in
      defer { setRunning(false) }
      do {
        let outcome = try await repl.run(
          code: code, bundleID: bundleField.stringValue.nonEmpty,
          onMainThread: mainThreadToggle.state == .on, source: .human,
          intent: nil)
        write(outcome.output.nonEmpty ?? (outcome.succeeded ? "(no value)" : "(no diagnostic)"))
      } catch {
        write((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
      }
    }
  }

  private func setRunning(_ running: Bool) {
    isRunning = running
    runButton.isEnabled = !running
    runButton.title = running ? "Running…" : "Run"
  }

  private func write(_ text: String) {
    output.string = text
    output.scrollToBeginningOfDocument(nil)
  }

  // MARK: - Views

  private static func makeTextView(editable: Bool) -> NSTextView {
    let view = NSTextView()
    view.minSize = NSSize(width: 0, height: 0)
    view.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.isEditable = editable
    view.isSelectable = true
    view.isRichText = false
    view.font = font
    view.textContainerInset = NSSize(width: 6, height: 6)
    view.textContainer?.widthTracksTextView = true
    // Every one of these turns a straight quote, a double hyphen or a "misspelled" identifier into
    // something that does not compile.
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isContinuousSpellCheckingEnabled = false
    return view
  }

  private static func makeScrollView(_ documentView: NSTextView) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .bezelBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = documentView
    return scrollView
  }

  /// Enough of a snippet to show the shape of one — the imports at the top, a value returned at the
  /// end — without doing anything to the app on first run.
  private static let starterSnippet = """
    import UIKit

    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
    return String(describing: scene?.keyWindow?.rootViewController)
    """
}
