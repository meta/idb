/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
import SimScopeProtocol

/// The session pane: the timeline as plain, agent-readable prose — one timestamped line per event,
/// tagged and colored by source (human / agent / replay) — over a field for replying to the agent.
///
///     [14:22:07] Tapped the Button “Continue” (id: continue_button) at (201, 760).
///     [14:22:09] [replay] Swiped up from (201, 700) to (201, 220).
///     [14:22:11] [agent] Tapped the Cell “Wi-Fi” at (201, 320). — check whether Wi-Fi is already on
///     [14:22:14] agent ▸ Wi-Fi is on. Anywhere else you want me to look?
///     [14:22:21] you ▸ try Bluetooth next
///
/// Actions and conversation share one column deliberately: what the agent said and what it then did
/// are the same story, and reading them interleaved is how the human follows it. The reply goes back
/// onto the same timeline, which is where the agent picks it up.
@MainActor
final class ActionLog: NSObject {

  let contentView: NSView
  /// Invoked when the human sends a reply. Wire to `Session.recordChat(source: .human, _:)`.
  var onSend: ((String) -> Void)?

  private let textView: NSTextView
  private let input: NSTextField

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  private static let bodyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  private static let chatFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
  private static let codeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

  override init() {
    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true

    let textView = NSTextView()
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.isEditable = false
    textView.isSelectable = true
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.font = Self.bodyFont
    unsafe textView.textContainer?.widthTracksTextView = true
    scrollView.documentView = textView

    let input = NSTextField()
    input.placeholderString = "Message the agent…"
    input.font = .systemFont(ofSize: 11)
    input.controlSize = .small
    input.bezelStyle = .roundedBezel
    input.isBordered = true
    // Return sends; clicking away must not.
    (input.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false

    let stack = NSStackView(views: [scrollView, input])
    stack.orientation = .vertical
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
    // The log takes every point the input row does not.
    scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
    input.setContentHuggingPriority(.required, for: .vertical)

    self.contentView = stack
    self.textView = textView
    self.input = input
    super.init()

    input.target = self
    input.action = #selector(send(_:))

    appendLine(
      "SimScope session log. Each line is a human or agent action in plain language; type below to reply to the agent.",
      color: .secondaryLabelColor, font: Self.bodyFont)
  }

  /// Renders one session event. Wire via `session.observe(log.append)`.
  func append(_ event: SessionEvent) {
    let stamp = Self.timeFormatter.string(from: Date())
    let color: NSColor
    switch event.source {
    case .human: color = .labelColor
    case .agent: color = .systemBlue
    case .replay: color = .systemOrange
    case .system: color = .secondaryLabelColor
    }

    // Conversation is set in the second person and in semibold: it is addressed to the reader, where
    // an action line merely describes something that happened.
    if case .chat = event.action {
      let who = event.source == .agent ? "agent" : "you"
      appendLine("[\(stamp)] \(who) ▸ \(event.prose)", color: color, font: Self.chatFont)
      return
    }

    let tag: String
    switch event.source {
    case .agent: tag = "[agent] "
    case .replay: tag = "[replay] "
    case .human, .system: tag = ""
    }
    appendLine("[\(stamp)] \(tag)\(event.prose)", color: color, font: Self.bodyFont)

    // An injection's summary says how much Swift ran and why; the snippet itself is the interesting
    // part, and the log is the only place either party — or a viewer of the recording — sees it.
    if case let .inject(code, _) = event.action {
      appendLine(
        code.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }
          .joined(separator: "\n"),
        color: .secondaryLabelColor, font: Self.codeFont)
    }
  }

  /// Types a reply the way a person would — one character at a time into the field editor, then send —
  /// so a scripted human's message reaches the session bus by the path a typed one takes, and the
  /// recording shows it being written rather than appearing whole.
  func typeReply(_ text: String) async {
    guard let window = unsafe contentView.window else { return }
    window.makeFirstResponder(input)
    for character in text {
      input.currentEditor()?.insertText(String(character))
      try? await Task.sleep(for: .milliseconds(30))
    }
    try? await Task.sleep(for: .milliseconds(300))
    send(input)
  }

  @objc private func send(_ sender: NSTextField) {
    let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    sender.stringValue = ""
    onSend?(text)
  }

  private func appendLine(_ line: String, color: NSColor, font: NSFont) {
    let attributed = NSAttributedString(
      string: line + "\n",
      attributes: [.font: font, .foregroundColor: color])
    unsafe textView.textStorage?.append(attributed)
    textView.scrollToEndOfDocument(nil)
  }
}
