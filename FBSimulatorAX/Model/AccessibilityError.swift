/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSimulatorControl
import Foundation

/// Errors thrown by the simulator accessibility command surface.
public enum AccessibilityError: LocalizedError, Sendable {

  /// An operation was attempted on an element handle that has been closed.
  /// `operation` is the verb phrase, e.g. "serialize", "tap", "set value on".
  case closedElement(operation: String)

  case noStringValue(key: String)

  /// The element does not support an accessibility press.
  case pressUnsupported(supportedActions: String)

  /// The requested custom action name is not advertised by the element.
  case customActionUnsupported(name: String, supportedActions: String)

  /// More than one advertised custom action has the requested name.
  case customActionAmbiguous(name: String, count: Int)

  /// The advertised custom action ran but reported failure.
  case customActionFailed(name: String)

  case pressFailed

  /// No descendant matched the search within the depth bound.
  case elementNotFound(key: String, value: String, depth: UInt)

  case simulatorNotBooted(description: String)

  /// The host lacks the CoreSimulator accessibility API (Xcode 12+ required).
  case accessibilityUnavailable

  case dispatcherUnavailable

  /// The simulator's accessibility service named no element for the query; nil when an element read
  /// earlier is no longer there to act on.
  /// The simulator's accessibility service did not answer in time, so the read stopped rather than report a
  /// tree with values missing. Retrying is safe. `behindAbandoned` counts the read's requests sent while one
  /// abandoned earlier was still unanswered, which the service answers first.
  case serviceNotAnswering(AccessibilityServiceSilence, elapsed: TimeInterval, behindAbandoned: Int64)

  case noTranslationObject(AccessibilityElementQuery?)

  /// SpringBoard restarted `restartedAgo` seconds ago and the simulator's accessibility service still answers
  /// for the SpringBoard that exited, as it does for a few seconds until it refreshes. Temporary: the same read
  /// succeeds once it has.
  case springBoardRestarting(exitedProcessIdentifier: pid_t, restartedAgo: TimeInterval)

  /// A frontmost-application accessibility hierarchy was requested but SpringBoard
  /// (the provider of the frontmost application) is not running on the simulator.
  case springBoardNotRunning

  public var errorDescription: String? {
    switch self {
    case .closedElement(let operation):
      return "Cannot \(operation) a closed element"
    case .noStringValue(let key):
      return "No string value for key \(key)"
    case .pressUnsupported(let supportedActions):
      return "Element does not support pressing. Supported: \(supportedActions)"
    case .customActionUnsupported(let name, let supportedActions):
      return "Element does not expose custom action '\(name)'. Supported: \(supportedActions)"
    case .customActionAmbiguous(let name, let count):
      return "Element exposes \(count) custom actions named '\(name)'; the action is ambiguous"
    case .customActionFailed(let name):
      return "Custom action '\(name)' reported failure"
    case .pressFailed:
      return "accessibilityPerformPress did not succeed"
    case .elementNotFound(let key, let value, let depth):
      return "Element with \(key) containing '\(value)' not found within depth \(depth)"
    case .simulatorNotBooted(let description):
      return "Cannot run accessibility commands against \(description) as it is not booted"
    case .accessibilityUnavailable:
      return "-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:] is not present on this host, you must install and/or use Xcode 12 to use accessibility."
    case .dispatcherUnavailable:
      return "Accessibility translation dispatcher is unavailable"
    case .noTranslationObject(.point(let point)):
      return "No accessibility element at (\(point.x), \(point.y)): the point may be off-screen or covered by a fullscreen dialog"
    case .noTranslationObject(.frontmost), .noTranslationObject(.marker):
      return "The simulator's accessibility service named no frontmost application"
    case .noTranslationObject(.application(let pid)):
      return "The simulator's accessibility service has no application with pid \(pid)"
    case .noTranslationObject(nil):
      return "The simulator's accessibility service no longer has this element"
    case let .springBoardRestarting(exitedProcessIdentifier, restartedAgo):
      return unsafe String(
        format: "SpringBoard restarted %.1f seconds ago. The simulator's accessibility service still answers for the SpringBoard that exited (pid %d) until it refreshes, which takes a few seconds; retry the read.",
        restartedAgo, exitedProcessIdentifier)
    case let .serviceNotAnswering(.request(kind, timeout), elapsed, _):
      return unsafe String(
        format: "The simulator's accessibility service did not answer a %@ request within %.1fs, %.1fs into the read; retry the read.",
        kind, timeout, elapsed)
    case let .serviceNotAnswering(.query(timeout), elapsed, _):
      return unsafe String(
        format: "The simulator's accessibility service did not answer within the query's %.1fs timeout, %.1fs into the read; retry the read.",
        timeout, elapsed)
    case .springBoardNotRunning:
      return "SpringBoard is not running on the simulator, so there is no frontmost application to describe. Boot/relaunch the simulator (or restart SpringBoard) and retry."
    }
  }
}

extension AccessibilityError: CustomStringConvertible {
  /// Mirrors `errorDescription` so string interpolation (`"\(error)"`) and logs
  /// surface the human-readable message rather than the synthesized case name.
  public var description: String { errorDescription ?? "AccessibilityError" }
}

/// What the accessibility service left unanswered.
public enum AccessibilityServiceSilence: Sendable, Equatable {
  /// One request, named by its kind as telemetry spells it (`frontmost`, `multiple_attribute`, …), went
  /// unanswered for `timeout`.
  case request(kind: String, timeout: TimeInterval)
  /// The whole query ran out of its `timeout` before the service had answered everything it needed.
  case query(timeout: TimeInterval)
}
