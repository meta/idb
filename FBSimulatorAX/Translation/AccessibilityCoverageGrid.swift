/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import FBSimulatorControl
import Foundation

/// Grid-based coverage tracking for accessibility elements. Uses a coarse grid
/// (default 10pt cells) to track which areas of the screen are covered by
/// accessibility element frames; overlap cannot double-count, as a cell is
/// filled or not.
///
/// Filled from a serialized read rather than during the walk that produced it, so every backend gets
/// the same calculation from the same input. It stays mutable because remote-content discovery marks
/// into a live grid as it hit-tests, and asks it which points are already covered.
final class AccessibilityCoverageGrid {

  let screenBounds: CGRect
  let cellSize: CGFloat
  let width: UInt
  let height: UInt

  private var grid: [UInt8]

  /// Default grid cell size in points.
  static let defaultCellSize: CGFloat = 10.0

  /// Initialize with screen bounds and cell size (default 10pt). Returns nil if
  /// the bounds produce a zero-dimension grid.
  init?(screenBounds: CGRect, cellSize: CGFloat = AccessibilityCoverageGrid.defaultCellSize) {
    let resolvedCellSize = cellSize > 0 ? cellSize : Self.defaultCellSize
    let computedWidth = UInt(ceil(screenBounds.size.width / resolvedCellSize))
    let computedHeight = UInt(ceil(screenBounds.size.height / resolvedCellSize))
    guard computedWidth > 0, computedHeight > 0 else {
      return nil
    }
    self.screenBounds = screenBounds
    self.cellSize = resolvedCellSize
    self.width = computedWidth
    self.height = computedHeight
    self.grid = [UInt8](repeating: 0, count: Int(computedWidth * computedHeight))
  }

  /// Mark cells covered by the given frame.
  func markFilled(with frame: CGRect) {
    guard !frame.isEmpty, !frame.isNull else {
      return
    }

    let relativeX = frame.origin.x - screenBounds.origin.x
    let relativeY = frame.origin.y - screenBounds.origin.y
    let relativeMaxX = relativeX + frame.size.width
    let relativeMaxY = relativeY + frame.size.height

    var minX = Int(floor(relativeX / cellSize))
    var minY = Int(floor(relativeY / cellSize))
    var maxX = Int(floor(relativeMaxX / cellSize))
    var maxY = Int(floor(relativeMaxY / cellSize))
    minX = max(0, minX)
    minY = max(0, minY)
    maxX = min(Int(width) - 1, maxX)
    maxY = min(Int(height) - 1, maxY)

    guard minX <= maxX, minY <= maxY else {
      return
    }

    let rowWidth = Int(width)
    for y in minY...maxY {
      let rowStart = y * rowWidth
      for x in minX...maxX {
        grid[rowStart + x] = 1
      }
    }
  }

  /// Whether the cell containing `point` is filled; `false` when out of bounds.
  func isFilled(at point: CGPoint) -> Bool {
    let relativeX = point.x - screenBounds.origin.x
    let relativeY = point.y - screenBounds.origin.y
    let cellX = Int(floor(relativeX / cellSize))
    let cellY = Int(floor(relativeY / cellSize))
    guard cellX >= 0, cellX < Int(width), cellY >= 0, cellY < Int(height) else {
      return false
    }
    return grid[cellY * Int(width) + cellX] != 0
  }

  /// Mark every element's frame, and its descendants'.
  ///
  /// The application root is skipped: it spans the screen by definition, so counting it would pin
  /// every read at full coverage. Coverage measures how much of the screen the app's *content*
  /// accounts for.
  ///
  /// A read that did not serialize the type cannot recognise the root, and one that did not serialize
  /// frames has nothing to mark; requesting coverage widens the key set so that neither happens
  /// (`AccessibilityRequestOptions.serializationKeys`).
  func markFilled(withElements elements: [AccessibilityDocumentElement]) {
    for element in elements {
      if (element.type ?? nil) != Self.applicationType, let rect = (element.frame ?? nil)?.rect {
        markFilled(with: rect)
      }
      markFilled(withElements: element.children ?? [])
    }
  }

  /// The normalized type of an application root — `AXRoleVocabulary.normalizeRole` strips the `AX`
  /// prefix, so this one spelling covers the `AXApplication` the accessibility backend reports and the
  /// `Application` the guest backends do.
  private static let applicationType = "Application"

  /// The proportion of `screenBounds` that `elements` cover, or `nil` when the bounds do not make a
  /// usable grid.
  static func ratio(of elements: [AccessibilityDocumentElement], screenBounds: CGRect) -> Double? {
    guard let grid = AccessibilityCoverageGrid(screenBounds: screenBounds) else {
      return nil
    }
    grid.markFilled(withElements: elements)
    return grid.ratio
  }

  /// This grid's coverage as a proportion, or `nil` for a degenerate grid with nothing to report.
  var ratio: Double? {
    let ratio = coverageRatio()
    return ratio >= 0 ? Double(ratio) : nil
  }

  /// Coverage ratio for the entire screen (0.0–1.0), or -1 if the grid is invalid.
  func coverageRatio() -> CGFloat {
    let totalCells = Int(width * height)
    guard totalCells > 0 else {
      return -1
    }
    let filledCells = grid.reduce(into: 0) { count, cell in
      if cell != 0 { count += 1 }
    }
    return CGFloat(filledCells) / CGFloat(totalCells)
  }
}

extension AccessibilityCoverage {

  /// The coverage a read reports, measured over its serialized elements.
  ///
  /// `nil` when the bounds are unusable, so an unmeasurable read reports nothing rather than zero.
  ///
  /// `nested` says whether the walk carries `children`. A flat read does not, so it cannot say which of
  /// its elements are leaves and reports no `leaf` ratio rather than one that would call every element
  /// a leaf.
  static func measured(
    reported: [AccessibilityDocumentElement],
    walked: [AccessibilityDocumentElement],
    screenBounds: CGRect,
    nested: Bool,
    additional: Double? = nil
  ) -> AccessibilityCoverage? {
    guard let frame = AccessibilityCoverageGrid.ratio(of: reported, screenBounds: screenBounds),
      let walkedRatio = AccessibilityCoverageGrid.ratio(of: walked, screenBounds: screenBounds)
    else {
      return nil
    }
    // Both leaf-based dimensions are measured over the walk rather than over `reported`, so the
    // dimension a caller filtered by does not change the dimension they are told about.
    let leaf =
      nested ? AccessibilityCoverageGrid.ratio(of: Self.leaves(of: walked), screenBounds: screenBounds) : nil
    let content =
      nested
      ? AccessibilityCoverageGrid.ratio(of: Self.innermostLabelled(in: walked), screenBounds: screenBounds) : nil
    return AccessibilityCoverage(
      frame: frame, walked: walkedRatio, content: content, leaf: leaf, additional: additional
    )
  }

  /// The innermost labelled elements: those carrying a label with no labelled descendant.
  /// Counting an element and its labelled descendant would count the same region twice.
  private static func innermostLabelled(
    in elements: [AccessibilityDocumentElement]
  ) -> [AccessibilityDocumentElement] {
    elements.flatMap { element -> [AccessibilityDocumentElement] in
      let inner = innermostLabelled(in: element.children ?? [])
      guard inner.isEmpty, isLabelled(element) else {
        return inner
      }
      var innermost = element
      innermost.children = nil
      return [innermost]
    }
  }

  /// Whether an element carries a non-empty label — user-perceived, unlike an identifier.
  private static func isLabelled(_ element: AccessibilityDocumentElement) -> Bool {
    guard let label = element.label ?? nil else {
      return false
    }
    return !label.isEmpty
  }

  /// The childless elements of a nested walk, flattened. Reported without `children` so the grid marks
  /// each one and recurses no further.
  private static func leaves(of elements: [AccessibilityDocumentElement]) -> [AccessibilityDocumentElement] {
    elements.flatMap { element -> [AccessibilityDocumentElement] in
      let children = element.children ?? []
      guard !children.isEmpty else {
        var leaf = element
        leaf.children = nil
        return [leaf]
      }
      return leaves(of: children)
    }
  }

  /// The bounds a read's screen info describes. The frames the calculation measures are in screen
  /// space, so the rectangle is anchored at the origin.
  static func bounds(of screen: AccessibilityScreenInfo) -> CGRect {
    CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
  }
}
