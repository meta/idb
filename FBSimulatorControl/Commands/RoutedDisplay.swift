/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import Foundation

/// Accessibility requests name a display by the identity the guest's accessibility inventory assigns it.
package enum AccessibilityRoute {}
/// Touches name a display by the digitizer target that reaches it.
enum DigitizerRoute {}

/// A display snapshot captured together with the identity that routes one kind of interaction to it. `Route`
/// keeps an accessibility identity from being sent as a digitizer target, and the reverse.
package enum RoutedDisplay<Route>: Equatable, Sendable {
  /// The only integrated display, which interactions reach without naming it.
  case sole(SimulatorInteractionDisplay)
  /// The active one of several integrated displays, and the identity that reaches it.
  case selected(SimulatorDisplay, id: UInt32)

  package var interactionDisplay: SimulatorInteractionDisplay {
    switch self {
    case let .sole(display): display
    case let .selected(display, _): .identified(display)
    }
  }

  var id: UInt32? {
    switch self {
    case .sole: nil
    case let .selected(_, id): id
    }
  }

  package var geometry: SimulatorDisplayGeometry { interactionDisplay.geometry }

  package var bounds: CGRect { CGRect(origin: .zero, size: geometry.pointSize) }

  func hasSameConfiguration(as other: Self) -> Bool {
    interactionDisplay.hasSameConfiguration(as: other.interactionDisplay) && id == other.id
  }
}

package typealias AXTranslationDisplay = RoutedDisplay<AccessibilityRoute>
typealias SimulatorHIDDisplay = RoutedDisplay<DigitizerRoute>

extension RoutedDisplay where Route == AccessibilityRoute {
  package var accessibilityID: UInt32? { id }
}

extension RoutedDisplay where Route == DigitizerRoute {
  var digitizerTarget: UInt64 { UInt64(id ?? 0) }
}

extension DisplaySelection {
  /// Refuses an interaction routed to `display` unless it is the display this selection names. A nil display
  /// means the interaction falls back to the main display, which names no display.
  package func confirm(routedTo display: SimulatorInteractionDisplay?, latest: SimulatorDisplayConfiguration?) throws {
    switch self {
    case .active:
      return
    case let .display(uniqueID):
      guard case let .identified(identified)? = display, identified.uniqueID == uniqueID else {
        throw SimulatorDisplayInteractionError.inactiveDisplay(uniqueID)
      }
    case let .configuration(generation):
      guard latest?.generation == generation else { throw SimulatorDisplayError.changed }
    case .main:
      throw SimulatorDisplayInteractionError.unsupportedCapability("an interaction bound to the main display")
    }
  }
}
