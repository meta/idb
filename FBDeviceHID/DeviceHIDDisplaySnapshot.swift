/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import Foundation

struct DeviceHIDDisplaySnapshot: Sendable {
  enum Orientation: Equatable, Sendable { case portrait, faceUp, unsupported }

  struct Display: Equatable, Sendable {
    var identifier: UInt32
    var primary: Bool
    var integrated: Bool
    var bounds: CGRect
    var nativeSize: CGSize
    var pointScale: Double
    var nativeOrientation: String
    var currentOrientation: String
  }

  var displays: [Display]
  var orientation: Orientation?
  var nonFlatOrientation: Orientation?

  func primaryDisplay() throws -> Display {
    let primary = displays.filter(\.primary)
    guard displays.count <= 64, Set(displays.map(\.identifier)).count == displays.count,
      primary.count == 1, let display = primary.first, display.identifier > 0, display.integrated
    else { throw DeviceHIDError.preparationFailed("Expected complete, unique display metadata with one primary integrated display") }
    guard display.bounds.origin == .zero,
      display.nativeOrientation == "rot0", display.currentOrientation == "rot0",
      nonFlatOrientation == .portrait, orientation == .portrait || orientation == .faceUp
    else { throw DeviceHIDError.preparationFailed("Physical taps require a portrait display basis") }
    let width = display.bounds.size.width
    let height = display.bounds.size.height
    let scale = display.pointScale
    guard width.isFinite, height.isFinite, scale.isFinite,
      width >= 1, height >= width, width.rounded() == width, height.rounded() == height,
      scale > 0, (width / scale).isFinite, (height / scale).isFinite,
      width / scale >= 1, height / scale >= 1, display.nativeSize == display.bounds.size
    else { throw DeviceHIDError.preparationFailed("Expected matching pixel bounds/native size and a positive point scale") }
    return display
  }

  func validatePreparation(against prepared: DeviceHIDDisplaySnapshot) throws {
    _ = try primaryDisplay()
    var projection = self
    projection.displays.removeAll { $0.bounds.isEmpty }
    try projection.validate(against: prepared)
  }

  func validate(against prepared: DeviceHIDDisplaySnapshot) throws {
    _ = try primaryDisplay()
    let observed = displays.sorted { $0.identifier < $1.identifier }
    let expected = prepared.displays.sorted { $0.identifier < $1.identifier }
    guard observed == expected else {
      throw DeviceHIDError.preparationFailed("The selected-device display basis changed after touch preparation: \(Self.firstDifference(expected: expected, observed: observed))")
    }
  }

  private static func firstDifference(expected: [Display], observed: [Display]) -> String {
    let expectedIDs = expected.map(\.identifier)
    let observedIDs = observed.map(\.identifier)
    guard expectedIDs == observedIDs else {
      func inventory(_ ids: [UInt32]) -> String {
        let values = ids.prefix(8).map(String.init).joined(separator: ",")
        return "[\(values)\(ids.count > 8 ? ",..." : "")] (count=\(ids.count))"
      }
      let missing = expectedIDs.filter { !observedIDs.contains($0) }
      let added = observedIDs.filter { !expectedIDs.contains($0) }
      return "inventory expected.count=\(expectedIDs.count), observed.count=\(observedIDs.count), missing=\(inventory(missing)), added=\(inventory(added))"
    }
    return firstFieldDifference(expected: expected, observed: observed) ?? "display inventory differs"
  }

  private static func firstFieldDifference(expected: [Display], observed: [Display]) -> String? {
    for (before, after) in zip(expected, observed) where before != after {
      func difference(_ field: String, _ expected: String, _ observed: String) -> String {
        "display \(before.identifier) \(field) expected=\(expected), observed=\(observed)"
      }
      if before.primary != after.primary { return difference("primary", String(before.primary), String(after.primary)) }
      if before.integrated != after.integrated { return difference("integrated", String(before.integrated), String(after.integrated)) }
      if before.bounds != after.bounds {
        func bounds(_ value: CGRect) -> String {
          "(x=\(value.origin.x),y=\(value.origin.y),width=\(value.size.width),height=\(value.size.height))"
        }
        return difference("bounds", bounds(before.bounds), bounds(after.bounds))
      }
      if before.nativeSize != after.nativeSize {
        func size(_ value: CGSize) -> String { "(width=\(value.width),height=\(value.height))" }
        return difference("nativeSize", size(before.nativeSize), size(after.nativeSize))
      }
      if before.pointScale != after.pointScale { return difference("pointScale", String(before.pointScale), String(after.pointScale)) }
      if before.nativeOrientation != after.nativeOrientation {
        return difference("nativeOrientation", rotation(before.nativeOrientation), rotation(after.nativeOrientation))
      }
      if before.currentOrientation != after.currentOrientation {
        return difference("currentOrientation", rotation(before.currentOrientation), rotation(after.currentOrientation))
      }
      return "display \(before.identifier) has unequal display fields"
    }
    return nil
  }

  private static func rotation(_ value: String) -> String {
    switch value {
    case "rot0", "rot90", "rot180", "rot270": return value
    default: return "<unrecognized rotation; \(value.utf8.count) bytes>"
    }
  }
}
