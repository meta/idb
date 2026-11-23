/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCoreObjC
import Foundation

extension FBObjCExceptionGuard {

  /// Runs `closure` under an Objective-C `@try`/`@catch`. A Swift `Error` thrown by the closure is
  /// rethrown unchanged; an `NSException` is thrown as an `NSError` in `FBObjCExceptionGuardErrorDomain`.
  /// Use wherever Swift messages an Objective-C API that may raise.
  public static func guarded<T>(_ closure: () throws -> T) throws -> T {
    // swiftlint:disable:next implicitly_unwrapped_optional
    var capturedResult: T!
    var capturedSwiftError: (any Error)?
    try self.run {
      do {
        capturedResult = try closure()
      } catch {
        capturedSwiftError = error
      }
    }
    if let capturedSwiftError {
      throw capturedSwiftError
    }
    return capturedResult
  }
}
