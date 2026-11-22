/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import SwiftUI
import UIKit

/// A screen whose accessibility tree is the same on every launch, for tests of
/// idb's accessibility commands.
///
/// It has what those tests would otherwise find in a system app -- a search
/// field, a list long enough to scroll, and a row that opens a page -- without
/// anything that loads, animates or rearranges itself on its own schedule. Every
/// element carries a fixed identifier, and the page opens without an animation,
/// so the tree changes once, when the row is tapped.
struct AccessibilityFixture: UIViewControllerRepresentable {
  /// The launch argument that shows this screen instead of `ContentView`. Other
  /// launches, such as the REPL's, don't pass it and so see the app unchanged.
  static let launchArgument = "--accessibility-fixture"

  static var isRequested: Bool {
    ProcessInfo.processInfo.arguments.contains(launchArgument)
  }

  func makeUIViewController(context: Context) -> UINavigationController {
    let navigation = UINavigationController(rootViewController: FixtureListController())
    // A large title collapses as the list scrolls, which would move every row
    // by a different amount than the scroll did.
    navigation.navigationBar.prefersLargeTitles = false
    return navigation
  }

  func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

private enum FixtureIdentifier {
  static let rowPrefix = "com.facebook.idb.replhost.row."
  static let search = "com.facebook.idb.replhost.search"
  static let page = "com.facebook.idb.replhost.page"
}

private struct FixtureRow {
  let label: String

  /// Only the first row opens a page, so a tap anywhere else changes nothing.
  var opensPage: Bool { label == FixtureListController.openingRowLabel }

  var identifier: String {
    FixtureIdentifier.rowPrefix + label.lowercased().replacingOccurrences(of: " ", with: "-")
  }
}

// This open-source fixture cannot depend on internal METAUIKit.
// ast-grep-ignore: ig-core/swift/meta-no-coding-uikit-subclass
private final class FixtureListController: UITableViewController {
  static let openingRowLabel = "General"
  static let customActionName = "Mark complete"
  static let customActionPendingValue = "Pending"
  static let customActionCompletedValue = "Completed"
  private static let cellReuseIdentifier = "row"
  private static let rows =
    [FixtureRow(label: openingRowLabel)] + (2...40).map { FixtureRow(label: "Row \($0)") }

  private var customActionCompleted = false

  init() {
    super.init(style: .insetGrouped)
    title = "ReplHost"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellReuseIdentifier)
    // In the header rather than the navigation item, so that writing to it
    // doesn't raise a search controller that moves the list under it.
    let search = UISearchBar()
    // Stable English text keeps the accessibility fixture deterministic.
    // ast-grep-ignore: common/swift/i18n-hardcoded-ui-property
    search.placeholder = "Search"
    search.searchTextField.accessibilityIdentifier = FixtureIdentifier.search
    // Typing tests compare the field with exactly what they typed, so it must
    // not capitalize, correct or otherwise rewrite what arrives.
    search.autocapitalizationType = .none
    search.autocorrectionType = .no
    search.spellCheckingType = .no
    search.smartQuotesType = .no
    search.smartDashesType = .no
    search.smartInsertDeleteType = .no
    search.inlinePredictionType = .no
    search.sizeToFit()
    tableView.tableHeaderView = search
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.accessibilityIdentifier = title
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    Self.rows.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = Self.rows[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellReuseIdentifier, for: indexPath)
    var content = cell.defaultContentConfiguration()
    content.text = row.label
    cell.contentConfiguration = content
    // `--api ax` derives a cell's label from its text, but `--api axbridge`
    // reports the cell's own label, which UIKit leaves empty for a cell whose
    // text comes from a content configuration.
    cell.accessibilityLabel = row.label
    cell.accessibilityIdentifier = row.identifier
    cell.accessoryType = row.opensPage ? .disclosureIndicator : .none
    cell.selectionStyle = row.opensPage ? .default : .none
    if row.opensPage {
      cell.accessibilityValue =
        customActionCompleted ? Self.customActionCompletedValue : Self.customActionPendingValue
      cell.accessibilityCustomActions = [
        UIAccessibilityCustomAction(
          name: Self.customActionName,
          target: self,
          selector: #selector(markOpeningRowComplete(_:)))
      ]
    } else {
      cell.accessibilityValue = nil
      cell.accessibilityCustomActions = nil
    }
    return cell
  }

  @objc private func markOpeningRowComplete(_ action: UIAccessibilityCustomAction) -> Bool {
    guard action.name == Self.customActionName else {
      return false
    }
    customActionCompleted = true
    tableView.cellForRow(at: IndexPath(row: 0, section: 0))?.accessibilityValue = Self.customActionCompletedValue
    return true
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    let row = Self.rows[indexPath.row]
    guard row.opensPage else {
      return
    }
    navigationController?.pushViewController(FixturePageController(title: row.label), animated: false)
  }
}

// This open-source fixture cannot depend on internal METAUIKit.
// ast-grep-ignore: ig-core/swift/meta-no-coding-uiviewcontroller-subclass
private final class FixturePageController: UIViewController {
  init(title: String) {
    super.init(nibName: nil, bundle: nil)
    self.title = title
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let label = UILabel()
    // Stable English text keeps the accessibility fixture deterministic.
    // ast-grep-ignore: common/swift/i18n-hardcoded-ui-property
    label.text = "The \(title ?? "") page"
    label.accessibilityIdentifier = FixtureIdentifier.page
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
    ])
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // UIKit names the bar after the title too, but only as a default; a test
    // waits on this, so it is set rather than left to UIKit.
    navigationController?.navigationBar.accessibilityIdentifier = title
  }
}
