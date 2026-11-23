/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation

public final class IPCDirectoryWatch {
  private let watchedDescriptor: Int32
  private let queue: Int32
  private let registered: Bool

  public init(directory: String) {
    var descriptor = unsafe open(directory, O_EVTONLY)
    if descriptor < 0 {
      descriptor = unsafe open((directory as NSString).deletingLastPathComponent, O_EVTONLY)
    }
    watchedDescriptor = descriptor
    queue = kqueue()
    guard descriptor >= 0, queue >= 0 else {
      registered = false
      return
    }
    var change = unsafe kevent(
      ident: UInt(descriptor),
      filter: Int16(EVFILT_VNODE),
      flags: UInt16(EV_ADD | EV_CLEAR),
      fflags: UInt32(NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE),
      data: 0,
      udata: nil)
    registered = unsafe kevent(queue, &change, 1, nil, 0, nil) == 0
  }

  deinit {
    if watchedDescriptor >= 0 { close(watchedDescriptor) }
    if queue >= 0 { close(queue) }
  }
  public func wait(timeoutMilliseconds: Int32) -> Bool {
    guard registered else {
      usleep(useconds_t(timeoutMilliseconds) * 1_000)
      return false
    }
    var timeout = timespec(tv_sec: Int(timeoutMilliseconds / 1_000), tv_nsec: Int(timeoutMilliseconds % 1_000) * 1_000_000)
    var event = unsafe kevent()
    while true {
      let count = unsafe kevent(queue, nil, 0, &event, 1, &timeout)
      if count < 0, errno == EINTR { continue }
      return count > 0
    }
  }
}
