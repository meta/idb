/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unknown platform")
#endif

/// Helper wrapper around `pthread_mutex`
final class Mutex: @unchecked Sendable {

  private var underlyingMutex = pthread_mutex_t()

  init() {
    var attr = pthread_mutexattr_t()
    guard unsafe pthread_mutexattr_init(&attr) == 0 else {
      preconditionFailure()
    }
    unsafe pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_NORMAL)
    guard unsafe pthread_mutex_init(&underlyingMutex, &attr) == 0 else {
      preconditionFailure()
    }
    unsafe pthread_mutexattr_destroy(&attr)
  }

  func sync<R>(execute work: () throws -> R) rethrows -> R {
    unsafe pthread_mutex_lock(&underlyingMutex)
    defer { unsafe pthread_mutex_unlock(&underlyingMutex) }
    return try work()
  }

  deinit {
    unsafe pthread_mutex_destroy(&underlyingMutex)
  }
}
