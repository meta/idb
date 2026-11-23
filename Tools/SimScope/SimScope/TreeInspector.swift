/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
import FBControlCore
import FBSimulatorAX
import QuartzCore

/// An embeddable **outline table** showing the frontmost app's accessibility tree, refreshed on an
/// interval. Selecting a row reports the element, which highlights it on the mirrored screen.
///
/// The table does not act on the device. It is the record of what was seen, and a surface that both
/// reads and taps makes it impossible to tell, watching a recording, whether a row moved because the
/// screen changed or because this window touched it.
///
/// Three properties this is built around, none of which the previous flat table had:
///
/// **Real columns.** One pre-rendered `type "label" #id = value` string per row looks like a table
/// and is not one — it cannot be aligned, resized or read down. Separate columns let the eye scan a
/// single attribute across many rows, which is how anyone actually looks for the odd one out.
///
/// **Disclosure.** The tree is genuinely nested, so structural containers can be collapsed instead of
/// padding the list with rows nobody is reading. On a screen that dumps hundreds of elements this is
/// the difference between a usable table and a wall.
///
/// **Stable identity across refreshes.** The model is rebuilt every second; keying rows by
/// `AXOutlineNode.key` means expansion and selection survive that, and only genuinely changed rows
/// animate. Without it every refresh collapses the tree and drops the selection, which makes an
/// expandable view worthless on a screen being driven.
@MainActor
final class TreeInspector: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {

  /// The container (table + status line) to embed in the window layout.
  let contentView: NSView
  private let outlineView: NSOutlineView
  private let statusLabel: NSTextField
  private let spinner: NSProgressIndicator

  /// Why a read was issued. Carried through so the status line can say what the pane is doing and,
  /// when a read is superseded, why — a tree that changes for an invisible reason is indistinguishable
  /// from one that changed because the screen did.
  enum RefreshReason: Equatable {
    case tick
    case traversal(String)
    case detail(Bool)

    var label: String? {
      switch self {
      case .tick: return nil
      case let .traversal(name): return "re-reading as \(name)"
      case let .detail(all): return all ? "including every element" : "pruning to meaningful elements"
      }
    }
  }

  private let read: (Bool, AXTraversalStrategy) async throws -> TreeSnapshot
  private var roots: [AXOutlineNode] = []
  /// Rebuilt by each merge. Every lookup into the tree goes through these: a hover resolves an element
  /// on every crossing and a refresh restores a selection, and both used to search the whole tree for
  /// something the merge had just had in its hand.
  private var nodesByKey: [String: AXOutlineNode] = [:]
  private var nodesByCentre: [PointKey: [AXOutlineNode]] = [:]
  /// The single in-flight read. One at a time, by construction: a new request cancels the previous
  /// one rather than racing it, because two reads landing out of order let a stale answer overwrite a
  /// fresh one — which presents as a control that moves while the table does not.
  private var readTask: Task<Void, Never>?
  private var loopTask: Task<Void, Never>?

  /// Keys the user has collapsed. Tracked as the exception rather than the rule because the useful
  /// default is expanded — a collapsed tree hides the thing you are looking for — so a fresh subtree
  /// appears open and only what was deliberately shut stays shut.
  private var collapsedKeys: Set<String> = []

  /// How the tree is read. Switchable live because the two strategies can return different SCREENS,
  /// and which is correct depends on what is on screen — see the control's comment in AppDelegate.
  var traversal: AXTraversalStrategy = SimBackend.traversalStrategyArgument ?? .viewHierarchy {
    didSet {
      guard oldValue != traversal else { return }
      request(.traversal(traversal.rawValue))
    }
  }

  /// When false (default), only meaningful elements are shown; when true, every element (including
  /// bare structural containers) is listed. Toggling refreshes immediately.
  var showAll: Bool = false {
    didSet {
      guard oldValue != showAll else { return }
      request(.detail(showAll))
    }
  }

  var onSelect: ((AXNode?) -> Void)?
  /// The elements to draw on the mirrored screen, and whether identity survived this refresh — which is
  /// the overlay's licence to animate between the two states rather than cut to the new one.
  var onNodes: (([AXNode], Bool) -> Void)?

  private enum Column: String, CaseIterable {
    case identifier, type, content, point

    var title: String {
      switch self {
      case .identifier: return "Identifier"
      case .type: return "Type"
      case .content: return "Label / value"
      case .point: return "Tap point"
      }
    }

    var width: CGFloat {
      switch self {
      case .identifier: return 210
      case .type: return 86
      // Pulled back in favour of the point column, which carries the coordinate AND the reason it will
      // not work. A truncated label still reads; a truncated "under <what>" loses the whole finding.
      case .content: return 250
      case .point: return 300
      }
    }

    /// Only the label column earns the remaining width; the others are fixed-ish, so the columns stay
    /// aligned down the table instead of redistributing every time the window resizes.
    var isElastic: Bool { self == .content }
  }

  init(read: @escaping (Bool, AXTraversalStrategy) async throws -> TreeSnapshot) {
    self.read = read

    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let outlineView = NSOutlineView()
    outlineView.rowSizeStyle = .small
    outlineView.usesAlternatingRowBackgroundColors = true
    outlineView.allowsEmptySelection = true
    outlineView.allowsMultipleSelection = false
    outlineView.style = .plain
    outlineView.indentationPerLevel = 12
    outlineView.usesAutomaticRowHeights = false
    outlineView.headerView = NSTableHeaderView()

    for column in Column.allCases {
      let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
      tableColumn.title = column.title
      tableColumn.width = column.width
      tableColumn.minWidth = 40
      tableColumn.resizingMask = column.isElastic ? .autoresizingMask : .userResizingMask
      outlineView.addTableColumn(tableColumn)
      // Disclosure rides the leading column, which is the identifier — the one value that is unique
      // per element, so hierarchy and identity read down the same edge.
      if column == .identifier { unsafe outlineView.outlineTableColumn = tableColumn }
    }
    outlineView.columnAutoresizingStyle = .noColumnAutoresizing

    scrollView.documentView = outlineView
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let statusLabel = NSTextField(labelWithString: "")
    statusLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(scrollView)
    container.addSubview(statusLabel)
    container.addSubview(spinner)
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -3),
      statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
      spinner.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 6),
      spinner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
      spinner.widthAnchor.constraint(equalToConstant: 12),
      spinner.heightAnchor.constraint(equalToConstant: 12),
    ])

    self.outlineView = outlineView
    self.statusLabel = statusLabel
    self.spinner = spinner
    self.contentView = container
    super.init()

    outlineView.dataSource = self
    outlineView.delegate = self
    // Row views need layers of their own for a changed row to crossfade.
    outlineView.wantsLayer = true
  }

  // MARK: - Refresh

  /// Poll the tree, backing off to match what a read actually costs.
  ///
  /// The interval is a floor, not a rate. When a tree read takes longer than the requested interval,
  /// polling continuously would leave no time for input or agent requests on the same transport.
  ///
  /// Sleeping for at least as long as the last read took holds the duty cycle near half whatever the
  /// app costs, which leaves room for the reads someone is actually waiting on. Ticks are dropped rather
  /// than queued while a read is in flight (see `request`), so this cannot build a backlog either way.
  func startAutoRefresh(interval: TimeInterval = 1.0) {
    loopTask?.cancel()
    loopTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.request(.tick)
        let lastRead = self?.lastReadDuration ?? 0
        try? await Task.sleep(nanoseconds: UInt64(max(interval, lastRead) * 1_000_000_000))
      }
    }
  }

  /// Stop polling without tearing down the read in flight — the "Off" position of the refresh control.
  /// Distinct from `stop()`, which also cancels the current read and is for teardown.
  func stopAutoRefresh() {
    loopTask?.cancel()
    loopTask = nil
  }

  /// How long the last completed read took, so polling can back off to match it.
  private(set) var lastReadDuration: TimeInterval = 0

  func stop() {
    loopTask?.cancel()
    loopTask = nil
    readTask?.cancel()
    readTask = nil
    isReading = false
  }

  /// Re-read because the reader itself changed, not the strategy.
  ///
  /// `traversal`'s setter refreshes only when the value differs, which is right for a strategy switch
  /// and wrong for an automation-mode switch: the strategy is unchanged, the reader is not, and without
  /// this the pane keeps showing the previous reader's answer.
  func rereadForReaderChange() { request(.traversal(traversal.rawValue)) }

  /// Issue a read, superseding whatever was in flight.
  ///
  /// A tick is the lowest-priority reason and never displaces a read already running — including
  /// another tick. Cancelling an in-flight tick to start a fresh one starves the table outright on
  /// any screen whose read takes longer than the interval: each tick kills the read before it can
  /// render, so the pane stays empty for as long as reads stay slow. A deliberate reason (a strategy
  /// switch, a detail toggle) still supersedes whatever is in flight, because the answer on screen is
  /// then answering the wrong question.
  func request(_ reason: RefreshReason) {
    if reason == .tick, isReading { return }
    readTask?.cancel()
    pendingReason = reason
    if let label = reason.label { statusLabel.stringValue = "\(label)…" }
    readGeneration += 1
    let generation = readGeneration
    isReading = true
    readTask = Task { [weak self] in
      await self?.perform(reason)
      // Only the newest read clears the flag. A superseded read finishing after its replacement
      // started would otherwise mark the inspector idle while a read is still running, which lets a
      // tick cancel it and reopens the starvation this guard exists to close.
      guard let self, self.readGeneration == generation else { return }
      self.isReading = false
    }
  }

  private var pendingReason: RefreshReason = .tick
  /// Whether a read is in flight, as distinct from `readTask != nil` — a finished task is neither nil
  /// nor cancelled, so testing the task alone locks ticks out forever after the first deliberate read.
  private var isReading = false
  private var readGeneration = 0

  /// Compatibility shim for callers that just want a read now.
  func refresh() async { request(.tick) }

  private func perform(_ reason: RefreshReason) async {
    spinner.startAnimation(nil)
    defer { spinner.stopAnimation(nil) }
    let start = DispatchTime.now().uptimeNanoseconds
    // A read is issued under one strategy and lands a second or two later. If the strategy changed
    // while it was in flight, its answer describes a question nobody is asking any more and must be
    // dropped rather than rendered.
    let issuedUnder = traversal
    let snapshot: TreeSnapshot
    do {
      snapshot = try await read(showAll, traversal)
    } catch {
      // Surface the failure rather than freezing silently. The most common cause is the simulator's
      // ApplicationAccessibilityEnabled being off (so the frontmost app's AX server isn't running);
      // the error's own message explains the fix and is shown in full on hover.
      let detail = (error as? any LocalizedError)?.errorDescription ?? "\(error)"
      let brief = detail.split(separator: ".").first.map(String.init) ?? detail
      statusLabel.stringValue = "⚠ \(brief)"
      statusLabel.toolTip = detail
      onNodes?([], false)
      return
    }
    // The read was issued under one strategy and may have landed after another was chosen. Dropping
    // it here is what stops a stale answer painting over a fresh one.
    if Task.isCancelled || issuedUnder != traversal { return }
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    lastReadDuration = elapsedMs / 1000

    let selectedKey = selectedNode()?.key
    let hadTree = !roots.isEmpty
    let merge = AXOutlineNode.reconcile(roots, with: snapshot.tree)
    let delta = merge.delta
    roots = merge.roots
    nodesByKey = merge.byKey
    nodesByCentre = merge.byCentre

    // What this refresh DID, which is the question actually being asked of something that re-reads on a
    // timer. An element count says how big the screen is; new/changed/same says whether anything moved,
    // and it is the number that shows a switch of read mode returning the same tree with more in it.
    let took =
      unsafe elapsedMs >= 1000
      ? String(format: "%.1f s", elapsedMs / 1000) : "\(Int(elapsedMs.rounded())) ms"
    let churn = hadTree ? "  ·  \(delta.summary)" : ""
    let why = reason.label.map { "  ·  \($0)" } ?? ""
    statusLabel.stringValue = "\(snapshot.coverage.summary)  ·  read in \(took)\(churn)\(why)"
    // Where the time went, plus the counts too fussy for the bar. Kept, because the breakdown is the
    // evidence for why one read mode costs milliseconds and another costs seconds — just not on screen
    // by default, where it crowded out the figures a viewer can check for themselves.
    statusLabel.toolTip = [snapshot.coverage.detail, snapshot.cost]
      .compactMap { $0 }.joined(separator: "\n\n")

    onNodes?(snapshot.coverageNodes, hadTree && delta.structureHeld)

    if hadTree && delta.structureHeld {
      // Identity held: these are the same rows carrying new values, so the change can be shown as a
      // change. Only the rows whose text actually differs are touched — a screen merely being watched
      // stays completely still — and they crossfade rather than snap, which is what makes a switch of
      // read mode legible as the same tree gaining detail.
      guard !delta.changedKeys.isEmpty else { return }
      let rows = IndexSet(
        (0..<outlineView.numberOfRows).filter { row in
          guard let node = outlineView.item(atRow: row) as? AXOutlineNode else { return false }
          return delta.changedKeys.contains(node.key)
        })
      for row in rows {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.18
        outlineView.rowView(atRow: row, makeIfNecessary: false)?.layer?.add(fade, forKey: "rowChange")
      }
      outlineView.reloadData(
        forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
      return
    }

    // Identity did not hold: rows arrived or departed, so this is a different screen rather than a
    // transition between two states of one. It snaps deliberately — fading between two unrelated tables
    // draws a movement that never happened on the device, which is the exact class of confident fiction
    // this window exists to expose.
    outlineView.reloadData()
    applyExpansion(roots)
    if let selectedKey, let row = rowForKey(selectedKey) {
      outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
  }

  /// Restore expansion from identity, so a rebuilt model does not collapse the user's tree. Expanded
  /// is the default; only keys explicitly collapsed stay shut.
  private func applyExpansion(_ nodes: [AXOutlineNode]) {
    for node in nodes where !node.children.isEmpty {
      let shouldBeExpanded = !collapsedKeys.contains(node.key)
      // Only when the row is not already in the state being asked for. `expandItem` on an
      // already-expanded row is not a no-op: it runs a full `NSOutlineView` batch update and rebuilds
      // the visible row views, and it was the largest remaining main-thread cost in a sample of the
      // window being driven. Now that a refresh reuses the node objects rather than building new ones,
      // the outline view keeps its expansion across a reload — so nearly every one of these calls was
      // asking a row to enter the state it was already in.
      if outlineView.isItemExpanded(node) != shouldBeExpanded {
        if shouldBeExpanded {
          outlineView.expandItem(node)
        } else {
          outlineView.collapseItem(node)
        }
      }
      // Descend only into what is on screen: the children of a collapsed row are not displayed, so
      // their expansion is not a question the table is asking yet.
      if shouldBeExpanded { applyExpansion(node.children) }
    }
  }

  private func selectedNode() -> AXOutlineNode? {
    let row = outlineView.selectedRow
    guard row >= 0 else { return nil }
    return outlineView.item(atRow: row) as? AXOutlineNode
  }

  private func rowForKey(_ key: String) -> Int? {
    guard let node = nodesByKey[key] else { return nil }
    let row = outlineView.row(forItem: node)
    return row >= 0 ? row : nil
  }

  // MARK: - NSOutlineViewDataSource

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    (item as? AXOutlineNode)?.children.count ?? roots.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    (item as? AXOutlineNode)?.children[index] ?? roots[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    !((item as? AXOutlineNode)?.children.isEmpty ?? true)
  }

  // MARK: - NSOutlineViewDelegate

  func outlineView(
    _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
  )
    -> NSView?
  {
    guard
      let outline = item as? AXOutlineNode,
      let raw = tableColumn?.identifier.rawValue,
      let column = Column(rawValue: raw)
    else { return nil }

    let identifier = NSUserInterfaceItemIdentifier("cell.\(raw)")
    let cell: NSTableCellView
    if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
      cell = reused
    } else {
      cell = NSTableCellView()
      cell.identifier = identifier
      let textField = NSTextField(labelWithString: "")
      textField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      textField.lineBreakMode = .byTruncatingTail
      textField.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(textField)
      unsafe cell.textField = textField
      NSLayoutConstraint.activate([
        textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
        textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
        textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
    }

    let node = outline.node
    let text: String
    switch column {
    case .type: text = node.typeColumn
    case .content: text = node.contentColumn
    case .identifier: text = node.identifierColumn
    case .point: text = node.pointColumn
    }
    unsafe cell.textField?.stringValue = text
    // Secondary columns are dimmed so the label column reads as the content and the rest as context.
    let unreachable = node.tapPoint == nil
    switch column {
    case .point:
      // Both describe reachability, so both carry its colour — the point because it is what gets
      // acted on, the state because it is what explains the point.
      unsafe cell.textField?.textColor = node.pointTint
    case .content, .identifier:
      unsafe cell.textField?.textColor = unreachable ? .secondaryLabelColor : .labelColor
    case .type:
      unsafe cell.textField?.textColor = .secondaryLabelColor
    }
    unsafe cell.textField?.alignment = .left
    cell.toolTip = node.interactabilityBadge
    return cell
  }

  func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
    let node = (outlineView.item(atRow: row) as? AXOutlineNode)?.node
    rowView.backgroundColor = node?.rowTint ?? .clear
  }

  /// Scroll the row a tap landed on into view and select it.
  ///
  /// Without this a tap is invisible in the tree: on a screen of two hundred elements the row that was
  /// acted on is usually off-screen, so the table and the simulator look like they are describing
  /// unrelated events. Selection rather than a momentary flash, for two reasons — it survives the next
  /// refresh, and it drives `onSelect`, which outlines the same element on the mirrored screen. One
  /// action, highlighted in both panes at once.
  ///
  /// Matched on the tap point rather than the label because the point is what was actually sent to the
  /// device. A label can be ambiguous; a coordinate cannot.
  func reveal(tapAt point: CGPoint) {
    reveal(at: point) { node in
      guard let candidate = node.tapPoint else { return false }
      return abs(candidate.x - point.x) < 1 && abs(candidate.y - point.y) < 1
    }
  }

  /// Scroll to the row for an element a hit-test just returned — the cursor's element, not a tap's.
  ///
  /// A separate entry point from `reveal(tapAt:)` on purpose. That one matches an element's tap point,
  /// which is its centre; the cursor is almost never on a centre, so pointing the hover at it walked the
  /// whole tree on every hover resolution and matched nothing at all. The hit-test already names the
  /// element, so match on the element.
  func reveal(element hit: AXHit) {
    reveal(at: CGPoint(x: hit.frame.midX, y: hit.frame.midY)) { $0.matches(hit) }
  }

  /// Find the node at a screen point and bring its row into view.
  ///
  /// Looked up rather than searched for. Both callers know a coordinate — a hit-test's frame or a tap's
  /// destination — and every positioned node is indexed by the centre of its frame, which is the same
  /// coordinate from the other side. This used to walk the tree from the roots on every hover crossing,
  /// which on a screen of two hundred elements is a full traversal per mouse movement to find something
  /// the last merge had already visited. The predicate still decides between the handful of nodes that
  /// share a centre exactly.
  private func reveal(at point: CGPoint, _ isMatch: (AXNode) -> Bool) {
    guard let match = nodesByCentre[PointKey(point)]?.first(where: { isMatch($0.node) }) else { return }

    // Walk up to what it is nested inside; there is no row to scroll to while an ancestor is shut.
    var ancestors: [AXOutlineNode] = []
    var cursor = match.parent
    while let node = cursor {
      ancestors.append(node)
      cursor = node.parent
    }
    for ancestor in ancestors.reversed() {
      collapsedKeys.remove(ancestor.key)
      outlineView.expandItem(ancestor)
    }
    let row = outlineView.row(forItem: match)
    guard row >= 0 else { return }
    outlineView.selectRowIndexes([row], byExtendingSelection: false)
    outlineView.scrollRowToVisible(row)
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    onSelect?(selectedNode()?.node)
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    guard let node = notification.userInfo?["NSObject"] as? AXOutlineNode else { return }
    collapsedKeys.insert(node.key)
  }

  func outlineViewItemDidExpand(_ notification: Notification) {
    guard let node = notification.userInfo?["NSObject"] as? AXOutlineNode else { return }
    collapsedKeys.remove(node.key)
  }

}
