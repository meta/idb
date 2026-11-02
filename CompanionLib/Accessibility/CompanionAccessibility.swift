/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
import FBControlCore
import FBSimulatorAX
import FBSimulatorControl
import Foundation

/// The accessibility reads and actions the companion serves, on its target's `uiAutomation`.
// SAFETY: holds the same non-Sendable target `IDBCommandExecutor` does, which is itself `@unchecked Sendable`
// for the same reason; the target is a thread-safe handle.
// patternlint-disable-next-line unchecked-sendable
struct CompanionAccessibility: @unchecked Sendable {

  let target: CompanionTarget

  func accessibilityTap(label: String) async throws {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.simulatorOnlyOperation(operation: "tap by accessibility label", targetDescription: String(describing: target))
    }
    try await simulator.uiAutomation(backend: .accessibility).tap(.marker(value: label, key: .label, depth: .max))
  }

  func accessibilityTap(
    query: AccessibilityElementQuery,
    backend: UIAutomationBackend = .accessibility,
    expectedValue: String?,
    expectedKey: AXSearchableKey
  ) async throws {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.simulatorOnlyOperation(operation: "tap by accessibility", targetDescription: String(describing: target))
    }
    let assertion = expectedValue.map { TapOptions.Assertion(key: expectedKey, value: $0) }
    try await simulator.uiAutomation(backend: backend).tap(query, options: TapOptions(assertion: assertion))
  }

  /// The read itself, before it is formatted, so a caller can also report how the read went.
  func accessibilityDescribeResponse(
    query: AccessibilityElementQuery, options: AccessibilityRequestOptions, backend: UIAutomationBackend = .accessibility
  ) async throws -> AccessibilityElementsResponse {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.simulatorOnlyOperation(operation: "describe accessibility", targetDescription: String(describing: target))
    }
    return try await simulator.uiAutomation(backend: backend).describe(query, options: options)
  }

  func accessibilityWait(query: AccessibilityElementQuery, backend: UIAutomationBackend, timeout: TimeInterval, pollInterval: TimeInterval) async throws {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.simulatorOnlyOperation(operation: "wait for accessibility", targetDescription: String(describing: target))
    }
    try await simulator.uiAutomation(backend: backend).wait(query, timeout: timeout, pollInterval: pollInterval)
  }

  func accessibilityQuiescence(
    query: AccessibilityElementQuery,
    parameters: QuiescenceParameters,
    backend: UIAutomationBackend
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, Error> {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.simulatorOnlyOperation(operation: "stream accessibility quiescence", targetDescription: String(describing: target))
    }
    return try await simulator.uiAutomation(backend: backend).quiescence(query, parameters: parameters)
  }

  func shimulatorQuiescence(
    query: AccessibilityElementQuery,
    parameters: QuiescenceParameters
  ) async throws -> AsyncThrowingStream<QuiescenceEvent, Error> {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.simulatorOnlyOperation(operation: "stream shimulator quiescence", targetDescription: String(describing: target))
    }
    return try await simulator.idleSync.quiescence(query, parameters: parameters)
  }

  func processId(forBundleID bundleID: String) async throws -> pid_t {
    try await target.application.processID(forBundleID: bundleID)
  }

  func accessibilityScroll(
    query: AccessibilityElementQuery,
    backend: UIAutomationBackend = .accessibility,
    direction: AccessibilityScrollDirection
  ) async throws {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.simulatorOnlyOperation(operation: "scroll by accessibility", targetDescription: String(describing: target))
    }
    try await simulator.uiAutomation(backend: backend).scroll(query, direction: direction)
  }

  func accessibilitySetValue(
    query: AccessibilityElementQuery,
    backend: UIAutomationBackend = .accessibility,
    value: String
  ) async throws {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.simulatorOnlyOperation(operation: "set value by accessibility", targetDescription: String(describing: target))
    }
    try await simulator.uiAutomation(backend: backend).setValue(value, for: query)
  }

  func accessibilityDrag(
    from source: AccessibilityElementQuery,
    to destination: AccessibilityElementQuery,
    backend: UIAutomationBackend = .accessibility,
    options: DragOptions
  ) async throws {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.simulatorOnlyOperation(operation: "drag by accessibility", targetDescription: String(describing: target))
    }
    try await simulator.uiAutomation(backend: backend).drag(from: source, to: destination, options: options)
  }

  func accessibilityInfoAtPoint(_ value: NSValue?, format: AccessibilityOutputFormat) async throws -> AccessibilityElementsResponse {
    return try await accessibilityInfoAtPoint(
      value, options: AccessibilityRequestOptions(format: format))
  }

  func accessibilityInfoAtPoint(_ value: NSValue?, options: AccessibilityRequestOptions, backend: UIAutomationBackend = .accessibility) async throws -> AccessibilityElementsResponse {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.simulatorOnlyOperation(operation: "provide accessibility commands", targetDescription: String(describing: target))
    }
    let query: AccessibilityElementQuery = value.map { .point($0.pointValue) } ?? .frontmost
    return try await simulator.uiAutomation(backend: backend).describe(query, options: options)
  }

  /// The frame (in screen points) of the frontmost-app accessibility element whose
  /// label contains `label` -- the same lookup as `accessibilityTap`.
  func replAccessibilityFrame(label: String) async throws -> CGRect {
    guard let simulator = target as? Simulator else {
      throw IDBCommandError.simulatorOnlyOperation(operation: "look up an accessibility frame", targetDescription: String(describing: target))
    }
    return try await simulator.uiAutomation(backend: .accessibility)
      .frame(.marker(value: label, key: .label, depth: .max))
  }
}

extension CompanionAccessibility: AccessibilityDescribing, AccessibilityActing, AccessibilityQuiescenceStreaming {}
