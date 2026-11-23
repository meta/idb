/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import IDBConcurrency
import os

enum MockStreamError: Error {
  case completionIsNil
}

final class MockStreamWriter: AsyncStreamWriter, Sendable {

  private struct State {
    var storage: [Int] = []
    var completion: (@Sendable () -> Void)?
  }

  let terminator: Int

  private let state = OSAllocatedUnfairLock(initialState: State())

  var storage: [Int] {
    state.withLock { $0.storage }
  }

  var completion: (@Sendable () -> Void)? {
    get { state.withLock { $0.completion } }
    set { state.withLock { $0.completion = newValue } }
  }

  init(terminator: Int) {
    self.terminator = terminator
  }

  func send(_ value: Int) async throws {
    let completion = state.withLock { state in
      state.storage.append(value)
      return state.completion
    }

    if value == terminator {
      guard let completion else {
        throw MockStreamError.completionIsNil
      }
      completion()
    }
  }
}
