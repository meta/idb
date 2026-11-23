/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import ObjectiveC

/// `+alloc` and `+new`, sent to a class resolved from the runtime by name.
@objc private protocol RuntimeClassAllocating {
  @objc(alloc) func alloc() -> AnyObject
  @objc(new) func new() -> AnyObject
}

/// Instances of XCTest's and DTX's private classes, made the way Objective-C makes them: through the
/// class's own `+alloc` or `+new`, which some of them override and `class_createInstance` would skip.
/// The classes are looked up by name, since naming them as types would link against the private
/// frameworks that vend them.
enum RuntimeClassAllocation {

  /// An allocated, uninitialized instance, for an `init`-family send to consume; nil when no class of
  /// that name is loaded.
  static func alloc(_ className: String) -> AnyObject? {
    classObject(className)?.alloc()
  }

  /// A new instance from `+new`; nil when no class of that name is loaded.
  static func new(_ className: String) -> AnyObject? {
    classObject(className)?.new()
  }

  /// The class itself, as the object `+alloc` and `+new` are sent to. Converted through `AnyObject`:
  /// a Swift metatype for an Objective-C class can be a wrapper around the class, not the class.
  private static func classObject(_ className: String) -> (any RuntimeClassAllocating)? {
    objc_lookUpClass(className).map { unsafeBitCast($0 as AnyObject, to: (any RuntimeClassAllocating).self) }
  }
}
