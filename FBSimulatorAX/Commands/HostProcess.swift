/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation

/// Facts about a process on the host. A simulator's processes are host processes, so these apply to them too.
enum HostProcess {
  /// When `pid` started; nil when it is not running or cannot be read.
  static func startDate(of pid: pid_t) -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
      return nil
    }
    let start = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
  }

  /// Whether `pid` is running.
  static func isRunning(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }
}
