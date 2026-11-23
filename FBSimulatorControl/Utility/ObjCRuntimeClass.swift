/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBControlCoreObjC
import Foundation
import ObjectiveC

/// The ways instantiating a runtime-resolved class can fail.
public enum ObjCRuntimeClassError: Error, LocalizedError {
  /// The instance could not be allocated, so no initializer was ever sent.
  case allocationFailed(className: String)
  /// The designated initializer raised an `NSException` instead of returning.
  case initializerRaised(className: String, underlying: any Error)
  case initializerReturnedNil(className: String)

  public var errorDescription: String? {
    switch self {
    case let .allocationFailed(className):
      return "An instance of \(className) could not be allocated"
    case let .initializerRaised(className, underlying):
      return "The initializer of \(className) raised: \(underlying.localizedDescription)"
    case let .initializerReturnedNil(className):
      return "The initializer of \(className) returned nil"
    }
  }
}

/**
 A class resolved from the Objective-C runtime by name. Naming a private-framework class as a type
 emits a link-time `_OBJC_CLASS_$_Name` reference to whichever binary vended it at build time, and the
 process fails to launch once Apple moves it. `instantiate` routes the initializer send through
 `FBObjCExceptionGuard`, since an `NSException` unwinding through a Swift frame aborts the process.
 */
public struct ObjCRuntimeClass {

  /// The name the class was resolved under.
  public let name: String
  /// The resolved class.
  public let cls: AnyClass

  /// Looks a class up in the Objective-C runtime, returning nil when no class of that name is
  /// registered. Loading whatever vends the class is the caller's responsibility — a lookup only
  /// sees classes belonging to images that are already in the process.
  public init?(name: String) {
    guard let cls = unsafe objc_lookUpClass(name) else {
      return nil
    }
    self.name = name
    self.cls = cls
  }

  /// Wraps a class that has already been resolved.
  public init(_ cls: AnyClass) {
    self.name = NSStringFromClass(cls)
    self.cls = cls
  }

  /**
   Allocates an instance and sends it its designated initializer.

   `Messaging` is an `@objc` protocol declaring the initializer's selector; the allocation is
   `unsafeBitCast` to it so `initialize` can express the send without naming the class as a type.
   The cast is only defined for object-pointer layouts, which the `AnyObject` constraint enforces.

   - Parameter initialize: Sends the designated initializer and returns its result. Must not let the
     instance escape: until the initializer returns the object is not fully formed.
   */
  public func instantiate<Messaging: AnyObject>(
    as _: Messaging.Type,
    _ initialize: (Messaging) -> AnyObject?
  ) throws -> AnyObject {
    // Unwrapped rather than bridged: `Optional.none as AnyObject` boxes into a non-nil `NSNull`, so a
    // failed allocation would go on to be messaged and be reported as a raising initializer.
    guard let instance = class_createInstance(cls, 0) else {
      throw ObjCRuntimeClassError.allocationFailed(className: name)
    }
    let allocated = unsafe unsafeBitCast(instance as AnyObject, to: Messaging.self)
    let initialized: AnyObject?
    do {
      initialized = try FBObjCExceptionGuard.guarded { initialize(allocated) }
    } catch {
      // A method in the `init` family consumes its receiver, so a raise leaves the allocation owned
      // by an initializer that never returned. Nothing releases it and one object leaks — the
      // deliberate trade against running `dealloc` over ivars that were never set.
      throw ObjCRuntimeClassError.initializerRaised(className: name, underlying: error)
    }
    guard let initialized else {
      throw ObjCRuntimeClassError.initializerReturnedNil(className: name)
    }
    return initialized
  }
}
