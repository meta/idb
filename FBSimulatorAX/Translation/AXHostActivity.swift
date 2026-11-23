/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation
import os

/// A process of the companion's user. Every simulator's processes run as that user, so their counters can be
/// read without privileges; other users' processes cannot be.
struct AXHostProcess {
  let pid: pid_t
  let ppid: pid_t
  let name: String
  /// Microseconds since 1970: tells a process from a later one given the same pid.
  let startMicroseconds: UInt64
  /// User plus system CPU time.
  let cpuNanoseconds: UInt64
}

/// Every process of the companion's user at one moment, with the host's CPU ticks.
struct AXHostSnapshot {
  let processes: [pid_t: AXHostProcess]
  let ticks: AXHostCPUTicks?
  /// When reading began, on `CLOCK_UPTIME_RAW`.
  let uptimeNanoseconds: UInt64
  /// When reading began, in microseconds since 1970, the clock process start times use.
  let wallMicroseconds: UInt64
  let readNanoseconds: UInt64

  /// Reads every process of the companion's user, or nil when `shouldStop` turns true partway, which it is asked
  /// every few processes.
  static func read(shouldStop: () -> Bool = { false }) -> AXHostSnapshot? {
    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let wall = clock_gettime_nsec_np(CLOCK_REALTIME) / 1000
    let ticks = AXHostCPUTicks.read()
    var timebase = mach_timebase_info_data_t()
    unsafe mach_timebase_info(&timebase)
    let pids = pids(ownedBy: geteuid())
    var processes = [pid_t: AXHostProcess](minimumCapacity: pids.count)
    for (index, pid) in pids.enumerated() {
      if index % 32 == 0, shouldStop() {
        return nil
      }
      if let process = process(pid, timebase: timebase) {
        processes[pid] = process
      }
    }
    return AXHostSnapshot(
      processes: processes, ticks: ticks, uptimeNanoseconds: start, wallMicroseconds: wall,
      readNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start)
  }

  static func pids(ownedBy uid: uid_t) -> [pid_t] {
    let estimate = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
    guard estimate > 0 else {
      return []
    }
    // Room for processes started since the estimate.
    var pids = [pid_t](repeating: 0, count: Int(estimate) / MemoryLayout<pid_t>.size + 64)
    let bytes = pids.withUnsafeMutableBytes { buffer in
      unsafe proc_listpids(UInt32(PROC_UID_ONLY), uid, buffer.baseAddress, Int32(buffer.count))
    }
    guard bytes > 0 else {
      return []
    }
    return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
  }

  static func process(_ pid: pid_t, timebase: mach_timebase_info_data_t) -> AXHostProcess? {
    var info = proc_taskallinfo()
    let size = Int32(MemoryLayout<proc_taskallinfo>.size)
    guard unsafe proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size else {
      return nil
    }
    let machTime = info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system
    let name = cString(info.pbsd.pbi_name)
    return AXHostProcess(
      pid: pid, ppid: pid_t(bitPattern: info.pbsd.pbi_ppid), name: name.isEmpty ? cString(info.pbsd.pbi_comm) : name,
      startMicroseconds: info.pbsd.pbi_start_tvsec &* 1_000_000 &+ info.pbsd.pbi_start_tvusec,
      cpuNanoseconds: timebase.denom == 0 ? machTime : machTime &* UInt64(timebase.numer) / UInt64(timebase.denom))
  }

  private static func cString<Tuple>(_ tuple: Tuple) -> String {
    withUnsafeBytes(of: tuple) { raw in
      unsafe String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  /// The arguments `pid` was started with, from `KERN_PROCARGS2`; nil when they cannot be read.
  static func arguments(of pid: pid_t) -> [String]? {
    guard pid > 0 else {
      return nil
    }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard unsafe sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    var bytes = [UInt8](repeating: 0, count: size)
    guard unsafe sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    // The argument count, the executable's path, padding, then the arguments, each ending in a zero byte.
    let count = bytes.withUnsafeBytes { unsafe $0.loadUnaligned(as: Int32.self) }
    var index = MemoryLayout<Int32>.size
    while index < size, bytes[index] != 0 {
      index += 1
    }
    while index < size, bytes[index] == 0 {
      index += 1
    }
    var arguments: [String] = []
    while arguments.count < count, index < size {
      let start = index
      while index < size, bytes[index] != 0 {
        index += 1
      }
      arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
      index += 1
    }
    return arguments
  }

  /// The device a `launchd_sim` serves, from the path of its bootstrap plist in the device's directory:
  /// `<device set>/<udid>/data/var/run/launchd_bootstrap.plist`.
  static func deviceUDID(fromArguments arguments: [String]) -> String? {
    var found: String?
    for argument in arguments {
      let components = argument.split(separator: "/").map(String.init)
      for (index, component) in components.enumerated() where UUID(uuidString: component) != nil {
        if index + 1 < components.count, components[index + 1] == "data" {
          return component
        }
        found = component
      }
    }
    return found
  }
}

/// The device each `launchd_sim` serves, read from its arguments once for the life of the process rather than
/// whenever its CPU is attributed.
enum AXSimulatorDevices {
  private struct Key: Hashable {
    let pid: pid_t
    let startMicroseconds: UInt64
  }

  /// Bounds the cache: every simulator booted while the companion runs adds one.
  private static let capacity = 256
  private static let known = OSAllocatedUnfairLock<[Key: String?]>(initialState: [:])

  static func udid(
    of process: AXHostProcess, arguments: (pid_t) -> [String]? = { AXHostSnapshot.arguments(of: $0) }
  ) -> String? {
    let key = Key(pid: process.pid, startMicroseconds: process.startMicroseconds)
    if let udid = known.withLock({ $0[key] }) {
      return udid
    }
    let udid = AXHostSnapshot.deviceUDID(fromArguments: arguments(process.pid) ?? [])
    known.withLock { known in
      if known.count >= capacity {
        known.removeAll()
      }
      known[key] = udid
    }
    return udid
  }
}

/// What the host's processes did between two snapshots: the CPU each of the user's processes used, the
/// busiest of them, and each simulator's share, its processes being those descended from its `launchd_sim`.
struct AXHostActivity {
  struct ProcessUse {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let cpuMilliseconds: Int
  }

  /// One simulator's processes, or those outside every simulator when `launchdPID` is nil.
  struct Group {
    let launchdPID: pid_t?
    let udid: String?
    let cpuMilliseconds: Int
    let processes: Int
    /// Busiest first.
    let busiest: [ProcessUse]
    /// Whether this is the simulator the request was made to.
    let isOwn: Bool
  }

  struct NameUse {
    let name: String
    let processes: Int
    let cpuMilliseconds: Int
  }

  /// From the start of the request to the earlier snapshot; negative when that was taken before the request.
  let startMilliseconds: Int
  /// From the earlier snapshot to the later.
  let windowMilliseconds: Int
  /// Summed over the user's processes.
  let userCPUMilliseconds: Int
  /// The whole host's busy CPU time and share over the window, from its ticks: other users' processes and the
  /// kernel included. Nil when either snapshot has no ticks, and the time when the CPU count is unknown.
  let busyMilliseconds: Int?
  let busyPercent: Int?
  let processes: Int
  /// Busiest first.
  let busiest: [ProcessUse]
  /// The CPU of all processes of each name, busiest first.
  let names: [NameUse]
  /// Every simulator with a process in the later snapshot, busiest first.
  let simulators: [Group]
  let outside: Group

  /// Simulators whose processes used CPU in the window.
  var activeSimulators: Int { simulators.filter { $0.cpuMilliseconds > 0 }.count }
  /// The request's own simulator's CPU, and every other simulator's together; both nil when the own one is not
  /// known, so another simulator's CPU is never mistaken for a neighbour's.
  var ownSimulatorCPUMilliseconds: Int? { simulators.first { $0.isOwn }?.cpuMilliseconds }
  var otherSimulatorsCPUMilliseconds: Int? {
    ownSimulatorCPUMilliseconds.map { _ in simulators.filter { !$0.isOwn }.reduce(0) { $0 + $1.cpuMilliseconds } }
  }

  static let launchdSimName = "launchd_sim"
  private static let busiestCount = 10
  private static let busiestPerGroup = 3
  private static let nameCount = 12

  /// A process the earlier snapshot lists counts the CPU it used since; one started after the earlier snapshot
  /// counts all of its CPU. One the earlier snapshot missed although it was running is left out, as are
  /// processes that exited in between. The request's own simulator is the one serving `ownUDID`, or, without
  /// one, the one `target` runs in.
  static func between(
    _ before: AXHostSnapshot, _ after: AXHostSnapshot, requestStart: UInt64, ownUDID: String?, target: pid_t,
    cpuCount: Int, udid: (AXHostProcess) -> String? = { AXSimulatorDevices.udid(of: $0) }
  ) -> AXHostActivity {
    var used: [pid_t: UInt64] = [:]
    for process in after.processes.values {
      if let earlier = before.processes[process.pid], earlier.startMicroseconds == process.startMicroseconds {
        used[process.pid] = process.cpuNanoseconds >= earlier.cpuNanoseconds ? process.cpuNanoseconds - earlier.cpuNanoseconds : 0
      } else if process.startMicroseconds >= before.wallMicroseconds {
        used[process.pid] = process.cpuNanoseconds
      }
    }

    var simulatorOf: [pid_t: pid_t] = [:]
    func simulator(of pid: pid_t) -> pid_t? {
      var chain: [pid_t] = []
      var current = pid
      var found: pid_t = 0
      while let process = after.processes[current], chain.count < 64 {
        if let known = simulatorOf[current] {
          found = known
          break
        }
        chain.append(current)
        if process.name == launchdSimName {
          found = current
          break
        }
        guard process.ppid > 0, process.ppid != current else {
          break
        }
        current = process.ppid
      }
      for pid in chain {
        simulatorOf[pid] = found
      }
      return found == 0 ? nil : found
    }

    struct Accumulator {
      var cpuNanoseconds: UInt64 = 0
      var processes = 0
      var uses: [ProcessUse] = []
    }
    var groups: [pid_t: Accumulator] = [:]
    var outside = Accumulator()
    var names: [String: (processes: Int, cpuNanoseconds: UInt64)] = [:]
    var uses: [ProcessUse] = []
    var total: UInt64 = 0
    for process in after.processes.values {
      let launchdPID = simulator(of: process.pid)
      let cpu = used[process.pid]
      let use = cpu.map {
        ProcessUse(pid: process.pid, ppid: process.ppid, name: process.name, cpuMilliseconds: Int(clamping: $0 / 1_000_000))
      }
      func add(_ accumulator: inout Accumulator) {
        accumulator.processes += 1
        if let cpu, let use {
          accumulator.cpuNanoseconds &+= cpu
          accumulator.uses.append(use)
        }
      }
      if let launchdPID {
        add(&groups[launchdPID, default: Accumulator()])
      } else {
        add(&outside)
      }
      guard let cpu, let use else {
        continue
      }
      total &+= cpu
      uses.append(use)
      names[process.name, default: (processes: 0, cpuNanoseconds: 0)].processes += 1
      names[process.name, default: (processes: 0, cpuNanoseconds: 0)].cpuNanoseconds &+= cpu
    }

    var udids: [pid_t: String] = [:]
    for launchdPID in groups.keys {
      udids[launchdPID] = after.processes[launchdPID].flatMap(udid)
    }
    let own: pid_t? =
      if let ownUDID {
        udids.first { $0.value == ownUDID }?.key
      } else {
        target > 0 ? simulator(of: target) : nil
      }
    func makeGroup(_ accumulator: Accumulator, launchdPID: pid_t?) -> Group {
      Group(
        launchdPID: launchdPID, udid: launchdPID.flatMap { udids[$0] },
        cpuMilliseconds: Int(clamping: accumulator.cpuNanoseconds / 1_000_000), processes: accumulator.processes,
        busiest: Array(busiestFirst(accumulator.uses).prefix(busiestPerGroup).filter { $0.cpuMilliseconds > 0 }),
        isOwn: launchdPID != nil && launchdPID == own)
    }
    let window = after.uptimeNanoseconds >= before.uptimeNanoseconds ? after.uptimeNanoseconds - before.uptimeNanoseconds : 0
    let busyShare = after.ticks.flatMap { later in before.ticks.flatMap { later.busyShare(since: $0) } }
    let start = Int64(bitPattern: before.uptimeNanoseconds &- requestStart) / 1_000_000
    return AXHostActivity(
      startMilliseconds: Int(start),
      windowMilliseconds: Int(clamping: window / 1_000_000),
      userCPUMilliseconds: Int(clamping: total / 1_000_000),
      busyMilliseconds: cpuCount > 0
        ? busyShare.map { Int(($0 * Double(cpuCount) * Double(window) / 1_000_000).rounded()) } : nil,
      busyPercent: busyShare.map { Int(($0 * 100).rounded()) },
      processes: after.processes.count,
      busiest: Array(busiestFirst(uses).prefix(busiestCount).filter { $0.cpuMilliseconds > 0 }),
      names: names.map { NameUse(name: $0.key, processes: $0.value.processes, cpuMilliseconds: Int(clamping: $0.value.cpuNanoseconds / 1_000_000)) }
        .filter { $0.cpuMilliseconds > 0 }
        .sorted { $0.cpuMilliseconds != $1.cpuMilliseconds ? $0.cpuMilliseconds > $1.cpuMilliseconds : $0.name < $1.name }
        .prefix(nameCount).map { $0 },
      simulators: groups.map { makeGroup($0.value, launchdPID: $0.key) }
        .sorted { $0.cpuMilliseconds != $1.cpuMilliseconds ? $0.cpuMilliseconds > $1.cpuMilliseconds : ($0.launchdPID ?? 0) < ($1.launchdPID ?? 0) },
      outside: makeGroup(outside, launchdPID: nil))
  }

  /// The activity as `key=value` fields of a log line. `sim_cpu` lists each simulator as
  /// `launchd_sim pid/udid:cpu_ms/processes(busiest name:cpu_ms,…)`, the request's own marked `*`, then the
  /// processes outside every simulator as `host:…`; `host_top` lists processes as `name|pid|ppid:cpu_ms`.
  var logFields: [String] {
    func token(_ text: String) -> String {
      String(text.map { $0.isWhitespace || ",|[]();:#".contains($0) ? "_" : $0 })
    }
    func listed(_ uses: [ProcessUse]) -> String {
      uses.map { "\(token($0.name)):\($0.cpuMilliseconds)" }.joined(separator: ",")
    }
    func group(_ group: Group) -> String {
      let name = group.launchdPID.map { "\(group.isOwn ? "*" : "")\($0)/\(group.udid ?? "-")" } ?? "host"
      return "\(name):\(group.cpuMilliseconds)/\(group.processes)(\(listed(group.busiest)))"
    }
    var fields = ["host_window_start_ms=\(startMilliseconds)", "host_window_ms=\(windowMilliseconds)"]
    if let busy = busyMilliseconds {
      fields.append("host_window_busy_ms=\(busy)")
    }
    if let percent = busyPercent {
      fields.append("host_window_busy_pct=\(percent)")
    }
    fields += [
      "user_cpu_ms=\(userCPUMilliseconds)", "user_procs=\(processes)", "sims=\(simulators.count)",
      "active_sims=\(activeSimulators)",
    ]
    if let own = ownSimulatorCPUMilliseconds, let others = otherSimulatorsCPUMilliseconds {
      fields += ["own_sim_cpu_ms=\(own)", "other_sims_cpu_ms=\(others)"]
    }
    fields += [
      "sim_cpu=[\((simulators + [outside]).map(group).joined(separator: "; "))]",
      "host_top=[\(busiest.map { "\(token($0.name))|\($0.pid)|\($0.ppid):\($0.cpuMilliseconds)" }.joined(separator: "; "))]",
      "host_top_names=[\(names.map { "\(token($0.name))#\($0.processes):\($0.cpuMilliseconds)" }.joined(separator: "; "))]",
    ]
    return fields
  }

  private static func busiestFirst(_ uses: [ProcessUse]) -> [ProcessUse] {
    uses.sorted { $0.cpuMilliseconds != $1.cpuMilliseconds ? $0.cpuMilliseconds > $1.cpuMilliseconds : $0.pid < $1.pid }
  }
}

/// Shares one recent read of the host's processes between the requests waiting at the same time, so several slow
/// requests do not each read every process.
enum AXHostSampler {
  /// A read this recent, in nanoseconds, is shared rather than taken again.
  static let freshness: UInt64 = 500_000_000
  private static let latest = OSAllocatedUnfairLock<AXHostSnapshot?>(initialState: nil)

  static func snapshot(shouldStop: () -> Bool) -> AXHostSnapshot? {
    let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    if let latest = latest.withLock({ $0 }), now &- latest.uptimeNanoseconds < freshness {
      return latest
    }
    guard let snapshot = AXHostSnapshot.read(shouldStop: shouldStop) else {
      return nil
    }
    latest.withLock { $0 = snapshot }
    return snapshot
  }
}
