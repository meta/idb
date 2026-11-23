/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import Foundation

/// What a process was doing while a translator request to it went unanswered.
///
/// A simulator's processes are host processes owned by the same user as the companion, so their task and
/// thread counters can be read with `proc_pidinfo` without attaching to them. Comparing the counters from
/// before and after a slow request tells a process that was busy from one that did not run at all, and
/// which of its threads was busy.
struct AXProcessCounters {
  /// User plus system CPU time, in nanoseconds.
  let cpuNanoseconds: UInt64
  /// The kernel keeps these as 32-bit counts that wrap, so a change between two reads is taken modulo 2^32.
  let contextSwitches: UInt32
  let syscalls: UInt32
  let pageins: UInt32
  let threads: Int32
  let runningThreads: Int32
  /// Microseconds since 1970: tells the process from a later one given the same pid.
  let startMicroseconds: UInt64
  /// The BSD status: `SRUN`, `SSLEEP`, `SSTOP`, …
  let status: UInt32
  /// Oldest first; empty when the threads could not be listed.
  let threadCPU: [AXThreadCPU]

  /// The counters of `pid` now, or nil when they cannot be read, as for a process that has exited.
  static func read(_ pid: pid_t) -> AXProcessCounters? {
    guard pid > 0 else {
      return nil
    }
    var info = proc_taskallinfo()
    let size = Int32(MemoryLayout<proc_taskallinfo>.size)
    guard unsafe proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size else {
      return nil
    }
    let task = info.ptinfo
    return AXProcessCounters(
      cpuNanoseconds: AXStallProbe.nanoseconds(machTime: task.pti_total_user &+ task.pti_total_system),
      contextSwitches: UInt32(bitPattern: task.pti_csw),
      syscalls: UInt32(bitPattern: task.pti_syscalls_mach) &+ UInt32(bitPattern: task.pti_syscalls_unix),
      pageins: UInt32(bitPattern: task.pti_pageins),
      threads: task.pti_threadnum,
      runningThreads: task.pti_numrunning,
      startMicroseconds: info.pbsd.pbi_start_tvsec &* 1_000_000 &+ info.pbsd.pbi_start_tvusec,
      status: info.pbsd.pbi_status,
      threadCPU: AXThreadCPU.read(pid, expecting: Int(task.pti_threadnum)))
  }
}

/// One of a process's threads and the CPU time it has used.
struct AXThreadCPU {
  /// The thread as `PROC_PIDLISTTHREADS` lists it.
  let id: UInt64
  let name: String
  let cpuNanoseconds: UInt64
  let runState: Int32

  /// The threads of `pid` in the kernel's order, which is oldest first, so the main thread leads. Empty when
  /// they cannot be listed.
  static func read(_ pid: pid_t, expecting count: Int) -> [AXThreadCPU] {
    // Room for threads started since `count` was read.
    var ids = [UInt64](repeating: 0, count: min(max(count, 0), 4096) + 64)
    let bytes = ids.withUnsafeMutableBytes { buffer in
      unsafe proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard bytes > 0 else {
      return []
    }
    return ids.prefix(Int(bytes) / MemoryLayout<UInt64>.size).compactMap { id in
      var info = proc_threadinfo()
      let size = Int32(MemoryLayout<proc_threadinfo>.size)
      guard unsafe proc_pidinfo(pid, PROC_PIDTHREADINFO, id, &info, size) == size else {
        return nil
      }
      return AXThreadCPU(
        id: id, name: AXStallProbe.name(of: info), cpuNanoseconds: info.pth_user_time &+ info.pth_system_time,
        runState: info.pth_run_state)
    }
  }
}

/// A thread of a probed process and the CPU time it used while a request waited.
struct AXThreadUse {
  let id: UInt64
  let name: String
  let cpuMilliseconds: Int
  /// Its run state afterwards.
  let runState: Int32
  /// Its place among the process's threads by that CPU time, from 1.
  let rank: Int

  /// The threads `after` lists, by the CPU time each used since `before`, busiest first. A thread `before`
  /// does not list started in between and counts all of its time, as does one `before` lists with more time
  /// than it has now: a new thread at an exited one's address. Empty when either list is.
  static func ranked(before: [AXThreadCPU], after: [AXThreadCPU]) -> [AXThreadUse] {
    guard !before.isEmpty, !after.isEmpty else {
      return []
    }
    let earlier = Dictionary(before.map { ($0.id, $0.cpuNanoseconds) }, uniquingKeysWith: { first, _ in first })
    let used = after.map { thread in
      let start = earlier[thread.id].flatMap { $0 <= thread.cpuNanoseconds ? $0 : nil } ?? 0
      return thread.cpuNanoseconds - start
    }
    let order = after.indices.sorted { used[$0] != used[$1] ? used[$0] > used[$1] : $0 < $1 }
    return order.enumerated().map { place, index in
      AXThreadUse(
        id: after[index].id, name: after[index].name, cpuMilliseconds: Int(clamping: used[index] / 1_000_000),
        runState: after[index].runState, rank: place + 1)
    }
  }
}

/// The host's CPU time summed over its CPUs, in scheduler ticks. Each count wraps at 32 bits.
struct AXHostCPUTicks {
  let user: UInt32
  let system: UInt32
  let idle: UInt32
  let nice: UInt32

  private static let host = mach_host_self()

  static func read() -> AXHostCPUTicks? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      unsafe pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        unsafe host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return nil
    }
    return AXHostCPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
  }

  /// The share of the host's CPU time that was busy since `earlier`, from 0 to 1; nil when no tick passed.
  func busyShare(since earlier: AXHostCPUTicks) -> Double? {
    let busy = UInt64(user &- earlier.user) + UInt64(system &- earlier.system) + UInt64(nice &- earlier.nice)
    let total = busy + UInt64(idle &- earlier.idle)
    return total == 0 ? nil : Double(busy) / Double(total)
  }
}

/// The host the simulators run on. In a virtual machine `hw.model` names the virtual machine; the CPU's
/// brand string still names the chip.
struct AXHostFacts {
  let name: String
  let model: String
  let cpu: String
  let cpuCount: Int
  let memoryGigabytes: Int

  /// Read once: none of it changes while the companion runs.
  static let current = AXHostFacts(
    name: AXSysctl.string("kern.hostname") ?? "unknown",
    // A Mac's model identifier, which macOS still reports here.
    // patternlint-disable-next-line sysctl-hw-machine-model-are-deprecated
    model: AXSysctl.string("hw.model") ?? "unknown",
    cpu: AXSysctl.string("machdep.cpu.brand_string") ?? "unknown",
    cpuCount: AXSysctl.integer("hw.ncpu", as: Int32.self).map { Int($0) } ?? 0,
    memoryGigabytes: AXSysctl.integer("hw.memsize", as: UInt64.self).map {
      Int((Double($0) / 1_073_741_824).rounded())
    } ?? 0)
}

/// The host's memory now, as far as an unprivileged process can read it.
struct AXMemoryState {
  /// `normal`, `warn` or `critical`: the level the system's memory pressure notifications report.
  let pressure: String?
  /// The share of memory the system counts as available.
  let freePercent: Int?
  let swapUsedMegabytes: Int?

  static func read() -> AXMemoryState {
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    let swapped = unsafe sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 && size == MemoryLayout<xsw_usage>.size
    return AXMemoryState(
      pressure: AXSysctl.integer("kern.memorystatus_vm_pressure_level", as: Int32.self).map(pressureName),
      freePercent: AXSysctl.integer("kern.memorystatus_level", as: UInt32.self).map { Int($0) },
      swapUsedMegabytes: swapped ? Int(clamping: swap.xsu_used / 1_048_576) : nil)
  }

  static func pressureName(_ level: Int32) -> String {
    switch level {
    case 1: "normal"
    case 2: "warn"
    case 4: "critical"
    default: "level\(level)"
    }
  }
}

enum AXSysctl {
  static func string(_ name: String) -> String? {
    var size = 0
    guard unsafe sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
      return nil
    }
    var bytes = [UInt8](repeating: 0, count: size)
    guard unsafe sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
      return nil
    }
    return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
  }

  static func integer<Value: FixedWidthInteger>(_ name: String, as type: Value.Type) -> Value? {
    var value = Value.zero
    var size = MemoryLayout<Value>.size
    guard unsafe sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Value>.size else {
      return nil
    }
    return value
  }
}

/// The target process and the host's CPU ticks, as read at one moment of a request's wait.
struct AXStallReading {
  /// When reading began, on `CLOCK_UPTIME_RAW`.
  let uptimeNanoseconds: UInt64
  /// Nil when the request names no process, or it could not be read.
  let counters: AXProcessCounters?
  let ticks: AXHostCPUTicks?

  static func read(_ pid: pid_t) -> AXStallReading {
    AXStallReading(
      uptimeNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), counters: AXProcessCounters.read(pid),
      ticks: AXHostCPUTicks.read())
  }
}

/// Everything read of the target and the host once a slow request has ended, so describing it reads nothing.
struct AXStallEndReading {
  let reading: AXStallReading
  /// The target's resource usage, for its footprint; nil when it could not be read.
  let usage: rusage_info_v4?
  /// The host's one-minute load average.
  let hostLoad: Double?
  let memory: AXMemoryState

  static func read(_ pid: pid_t) -> AXStallEndReading {
    var load = [Double](repeating: 0, count: 3)
    return unsafe AXStallEndReading(
      reading: .read(pid), usage: pid > 0 ? AXStallProbe.usage(pid) : nil,
      hostLoad: getloadavg(&load, 3) == 3 ? load[0] : nil, memory: .read())
  }
}

enum AXStallProbe {
  /// A request that waits this long is described.
  static let threshold: TimeInterval = 1
  /// Whether requests may be watched at all: `IDB_AX_STALL_PROBE` set to `0`, `false`, `no` or `off` in the
  /// process's environment turns watching off.
  static let isEnabled = unsafe isEnabled(environmentValue: getenv("IDB_AX_STALL_PROBE").map { unsafe String(cString: $0) })
  /// Writes `ax_stall_probe` lines off the request's thread.
  static let logQueue = DispatchQueue(label: "com.facebook.FBSimulatorAX.AXStallProbe.log", qos: .utility)
  private static let busiestThreadCount = 3

  static func isEnabled(environmentValue value: String?) -> Bool {
    guard let value else {
      return true
    }
    return !["0", "false", "no", "off"].contains(value.lowercased())
  }

  /// What `pid` did during a request that began at `requestStart` (on `CLOCK_UPTIME_RAW`) and took `duration`:
  /// the change in its counters and in the host's ticks from `baseline`, read while the request waited, to
  /// `end`, read once it ended. Counter changes are nil without a baseline, and when the pid names a different
  /// process at the end than it did at the baseline. `host` is what the host's processes did in a window of the
  /// wait. `baselineReadNanoseconds` and `sweepNanoseconds` are how long reading the baseline and the host took,
  /// and `inlineNanoseconds` how long the probe held the request's thread, reading `end` included.
  static func observe(
    kind: String, pid: pid_t, requestStart: UInt64, duration: CFAbsoluteTime, outcome: AccessibilityStallOutcome,
    baseline: AXStallReading?, end: AXStallEndReading, host: AXHostActivity? = nil, baselineReadNanoseconds: UInt64 = 0,
    sweepNanoseconds: UInt64 = 0, inlineNanoseconds: UInt64 = 0
  ) -> AccessibilityStallObservation {
    let before = baseline?.counters
    let after = end.reading.counters
    let replaced = before.flatMap { before in after.map { before.startMicroseconds != $0.startMicroseconds } } ?? false
    let both = replaced ? nil : before.flatMap { before in after.map { (before: before, after: $0) } }
    let ranked = both.map { AXThreadUse.ranked(before: $0.before.threadCPU, after: $0.after.threadCPU) } ?? []
    let mainThreadID = after?.threadCPU.first?.id
    let tickShare = end.reading.ticks.flatMap { later in baseline?.ticks.flatMap { later.busyShare(since: $0) } }
    return AccessibilityStallObservation(
      requestKind: kind, pid: pid, duration: duration, outcome: outcome,
      baselineMilliseconds: baseline.map {
        Int(clamping: ($0.uptimeNanoseconds >= requestStart ? $0.uptimeNanoseconds - requestStart : 0) / 1_000_000)
      },
      cpuMilliseconds: both.flatMap {
        $0.after.cpuNanoseconds >= $0.before.cpuNanoseconds
          ? Int(clamping: ($0.after.cpuNanoseconds - $0.before.cpuNanoseconds) / 1_000_000) : nil
      },
      contextSwitches: both.map { Int($0.after.contextSwitches &- $0.before.contextSwitches) },
      syscalls: both.map { Int($0.after.syscalls &- $0.before.syscalls) },
      pageins: both.map { Int($0.after.pageins &- $0.before.pageins) },
      runningThreads: after.map { Int($0.runningThreads) },
      threads: after.map { Int($0.threads) },
      processStatus: after.map { statusName($0.status) } ?? "unknown",
      hostLoad: end.hostLoad,
      hostBusyPercent: tickShare.map { Int(($0 * 100).rounded()) },
      busiestThreads: ranked.isEmpty ? nil : ranked.prefix(busiestThreadCount).filter { $0.cpuMilliseconds > 0 },
      mainThread: ranked.first { $0.id == mainThreadID },
      footprintMegabytes: after == nil ? nil : end.usage.map { Int(clamping: $0.ri_phys_footprint / 1_048_576) },
      residentMegabytes: after == nil ? nil : end.usage.map { Int(clamping: $0.ri_resident_size / 1_048_576) },
      host: .current, memory: end.memory,
      probeMicroseconds: Int(clamping: baselineReadNanoseconds / 1000),
      probeInlineMicroseconds: Int(clamping: inlineNanoseconds / 1000),
      sweepMicroseconds: Int(clamping: sweepNanoseconds / 1000),
      probedBefore: before != nil, targetReplaced: replaced, hostActivity: host)
  }

  /// One log line for `observation`.
  static func describe(_ observation: AccessibilityStallObservation) -> String {
    var fields = [
      "kind=\(observation.requestKind)", "pid=\(observation.pid)",
      "duration_ms=\(Int(observation.duration * 1000))", "outcome=\(observation.outcome.rawValue)",
    ]
    if let baseline = observation.baselineMilliseconds {
      fields.append("baseline_ms=\(baseline)")
    }
    if let switches = observation.contextSwitches, let syscalls = observation.syscalls, let pageins = observation.pageins {
      if let cpu = observation.cpuMilliseconds {
        fields.append("cpu_ms=\(cpu)")
      }
      fields += ["context_switches=\(switches)", "syscalls=\(syscalls)", "pageins=\(pageins)"]
    } else if observation.targetReplaced {
      fields.append("process=replaced")
    } else if observation.probedBefore, observation.threads == nil {
      fields.append("process=gone")
    }
    if let running = observation.runningThreads, let threads = observation.threads {
      fields += ["running_threads=\(running)", "threads=\(threads)"]
    }
    if let busiest = observation.busiestThreads {
      let main = observation.mainThread
      fields.append("busy_threads=[\(busiest.map { label($0, isMain: $0.id == main?.id) }.joined(separator: ", "))]")
    }
    if let main = observation.mainThread {
      fields += [
        "main_thread_cpu_ms=\(main.cpuMilliseconds)", "main_thread_rank=\(main.rank)",
        "main_thread_state=\(runState(main.runState))",
      ]
    }
    if let footprint = observation.footprintMegabytes, let resident = observation.residentMegabytes {
      fields += ["footprint_mb=\(footprint)", "resident_mb=\(resident)"]
    }
    if let load = observation.hostLoad {
      unsafe fields.append(String(format: "host_load=%.1f", load))
    }
    fields.append(describe(observation.host))
    if let pressure = observation.memory.pressure {
      fields.append("memory_pressure=\(pressure)")
    }
    if let free = observation.memory.freePercent {
      fields.append("mem_free_pct=\(free)")
    }
    if let swap = observation.memory.swapUsedMegabytes {
      fields.append("swap_used_mb=\(swap)")
    }
    fields += [
      "probe_us=\(observation.probeMicroseconds)", "probe_inline_us=\(observation.probeInlineMicroseconds)",
      "process_status=\(observation.processStatus)",
    ]
    if let busy = observation.hostBusyPercent {
      fields.append("host_busy_pct=\(busy)")
    }
    fields.append("sweep_us=\(observation.sweepMicroseconds)")
    if let activity = observation.hostActivity {
      fields += activity.logFields
    }
    return "ax_stall_probe " + fields.joined(separator: " ")
  }

  static func describe(_ host: AXHostFacts) -> String {
    "ax_host=\(oneWord(host.name)) hw_model=\(oneWord(host.model)) cpu=\(oneWord(host.cpu)) ncpu=\(host.cpuCount) "
      + "mem_gb=\(host.memoryGigabytes)"
  }

  /// `name|0xid:cpu_ms`, naming an unnamed main thread `main` and any other unnamed thread `-`.
  static func label(_ thread: AXThreadUse, isMain: Bool) -> String {
    let name =
      thread.name.isEmpty
      ? (isMain ? "main" : "-")
      : String(thread.name.map { $0.isWhitespace || ",|[]".contains($0) ? "_" : $0 })
    return "\(name)|0x\(String(thread.id, radix: 16)):\(thread.cpuMilliseconds)"
  }

  private static func oneWord(_ text: String) -> String {
    String(text.map { $0.isWhitespace ? "_" : $0 })
  }

  static func name(of thread: proc_threadinfo) -> String {
    withUnsafeBytes(of: thread.pth_name) { raw in
      unsafe String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  /// `pid`'s resource usage now, for its physical footprint and resident size.
  static func usage(_ pid: pid_t) -> rusage_info_v4? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      unsafe pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { unsafe proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? usage : nil
  }

  /// A BSD process status: `stopped` for a process held by `SIGSTOP`, which its thread states do not show.
  static func statusName(_ status: UInt32) -> String {
    switch Int32(bitPattern: status) {
    case SIDL: "idle"
    case SRUN: "runnable"
    case SSLEEP: "sleeping"
    case SSTOP: "stopped"
    case SZOMB: "zombie"
    default: "status\(status)"
    }
  }

  static func runState(_ state: Int32) -> String {
    switch state {
    case TH_STATE_RUNNING: "running"
    case TH_STATE_STOPPED: "stopped"
    case TH_STATE_WAITING: "waiting"
    case TH_STATE_UNINTERRUPTIBLE: "uninterruptible"
    case TH_STATE_HALTED: "halted"
    default: "state\(state)"
    }
  }

  static func nanoseconds(machTime: UInt64) -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    unsafe mach_timebase_info(&timebase)
    guard timebase.denom != 0 else {
      return machTime
    }
    return machTime &* UInt64(timebase.numer) / UInt64(timebase.denom)
  }
}
