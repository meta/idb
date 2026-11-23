/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

internal import AccessibilityPlatformTranslation
import AppKit
import FBControlCore
import FBSimulatorControl
import Foundation
import ObjectiveC

/// A translator element's identity on the wire: what a raw request names, and what an element's children
/// answer with. `AXPTranslationObject` is a private-framework class tests cannot subclass; the protocol admits
/// test doubles.
protocol AXTranslationReference: AnyObject {
  var pid: pid_t { get }
  var objectID: UInt64 { get }
  // Spelled as the private header imports it, so `AXPTranslationObject` conforms as declared.
  // swiftlint:disable:next implicitly_unwrapped_optional
  var bridgeDelegateToken: String! { get set }
}

extension AXPTranslationObject: AXTranslationReference {}

/// What an action on a translator element goes through: the translator's platform element, built from the
/// element's translation only when something acts on it. Reads never build one.
///
/// `AXPMacPlatformElement` is a private-framework class tests cannot subclass; the protocol admits test
/// doubles without unsafe casts.
protocol AXWritableElement: AnyObject {
  func axCustomActionNames() -> [String]
  func axActionNames() -> [String]
  /// Sets the backing translation object's bridge-delegate token (no-op when absent).
  func axSetBridgeDelegateToken(_ token: String?)
  func axPerformPress() -> Bool
  func axPerformCustomAction(named name: String) -> Bool
  func axScroll(_ direction: AccessibilityScrollDirection)
  func axSetValue(_ value: Any?)
}

func invokeAccessibilityCustomAction(_ action: NSAccessibilityCustomAction) -> Bool {
  if let handler = action.handler {
    return handler()
  }
  guard
    let target = action.target,
    let selector = action.selector
  else {
    return false
  }
  let object = target as AnyObject
  guard
    object.responds(to: selector),
    let cls = object_getClass(object),
    let method = unsafe class_getInstanceMethod(cls, selector)
  else {
    return false
  }
  let implementation = unsafe method_getImplementation(method)
  var returnType = [CChar](repeating: 0, count: 16)
  unsafe method_getReturnType(method, &returnType, returnType.count)
  let returnTypeName = String(
    decoding: returnType.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
    as: UTF8.self
  )
  let argumentCount = unsafe method_getNumberOfArguments(method)
  if argumentCount == 3 {
    guard let argumentType = unsafe method_copyArgumentType(method, 2) else {
      return false
    }
    defer { unsafe free(argumentType) }
    guard unsafe String(cString: argumentType) == "@" else {
      return false
    }
  }
  switch (argumentCount, returnTypeName) {
  case (2, "B"), (2, "c"):
    typealias Action = @convention(c) (AnyObject, Selector) -> Bool
    return unsafe unsafeBitCast(implementation, to: Action.self)(object, selector)
  case (3, "B"), (3, "c"):
    typealias Action = @convention(c) (AnyObject, Selector, NSAccessibilityCustomAction) -> Bool
    return unsafe unsafeBitCast(implementation, to: Action.self)(object, selector, action)
  case (2, "v"):
    typealias Action = @convention(c) (AnyObject, Selector) -> Void
    unsafe unsafeBitCast(implementation, to: Action.self)(object, selector)
    return true
  case (3, "v"):
    typealias Action = @convention(c) (AnyObject, Selector, NSAccessibilityCustomAction) -> Void
    unsafe unsafeBitCast(implementation, to: Action.self)(object, selector, action)
    return true
  default:
    return false
  }
}

extension AXPMacPlatformElement: AXWritableElement {
  func axCustomActionNames() -> [String] { (accessibilityCustomActions() ?? []).map { $0.name } }
  func axActionNames() -> [String] {
    // Read by message: the instance `accessibilityActionNames` is shadowed by a
    // class member of the same name on `AXPMacPlatformElement` in this context.
    let selector = NSSelectorFromString("accessibilityActionNames")
    guard responds(to: selector),
      let raw = unsafe perform(selector)?.takeUnretainedValue() as? NSArray
    else {
      return []
    }
    return raw.compactMap { $0 as? String }
  }

  func axSetBridgeDelegateToken(_ token: String?) { translation?.bridgeDelegateToken = token }

  func axPerformPress() -> Bool { accessibilityPerformPress() }

  func axPerformCustomAction(named name: String) -> Bool {
    guard let action = accessibilityCustomActions()?.first(where: { $0.name == name }) else {
      return false
    }
    return invokeAccessibilityCustomAction(action)
  }

  func axScroll(_ direction: AccessibilityScrollDirection) {
    switch direction {
    case .down:
      performScrollDownByPageAction()
    case .up:
      performScrollUpByPageAction()
    case .left:
      performScrollLeftByPageAction()
    case .right:
      performScrollRightByPageAction()
    case .visible:
      performScrollToVisible()
    }
  }

  func axSetValue(_ value: Any?) { setAccessibilityValue(value) }
}
