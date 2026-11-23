/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Darwin
import FBControlCore
import Foundation

private let machTimebase: mach_timebase_info_data_t = {
  var info = mach_timebase_info_data_t()
  unsafe mach_timebase_info(&info)
  return info
}()

/// A single point-in-time snapshot of a process's resource usage. `cpuPct` is nil for the first (baseline) sample of a
/// process, where there is no prior reading to difference against.
public struct ResourceSample: Codable, Equatable, Sendable {
  public let pid: Int32
  public let processName: String
  public let timestampMs: Int64
  public let elapsedMs: Int64
  public let cpuPct: Double?
  public let footprintBytes: UInt64
  public let residentBytes: UInt64
  public let instructions: UInt64
  public let cycles: UInt64
  public let diskBytesRead: UInt64
  public let diskBytesWritten: UInt64
  public let interruptWakeups: UInt64
  public let packageIdleWakeups: UInt64
  public let billedEnergyNanoJoules: UInt64

  public init(
    pid: Int32,
    processName: String,
    timestampMs: Int64,
    elapsedMs: Int64,
    cpuPct: Double?,
    footprintBytes: UInt64,
    residentBytes: UInt64,
    instructions: UInt64,
    cycles: UInt64,
    diskBytesRead: UInt64,
    diskBytesWritten: UInt64,
    interruptWakeups: UInt64,
    packageIdleWakeups: UInt64,
    billedEnergyNanoJoules: UInt64
  ) {
    self.pid = pid
    self.processName = processName
    self.timestampMs = timestampMs
    self.elapsedMs = elapsedMs
    self.cpuPct = cpuPct
    self.footprintBytes = footprintBytes
    self.residentBytes = residentBytes
    self.instructions = instructions
    self.cycles = cycles
    self.diskBytesRead = diskBytesRead
    self.diskBytesWritten = diskBytesWritten
    self.interruptWakeups = interruptWakeups
    self.packageIdleWakeups = packageIdleWakeups
    self.billedEnergyNanoJoules = billedEnergyNanoJoules
  }
}

/// Which processes a resource sampler follows.
public enum ResourceSampleScope: String, Sendable, CaseIterable {
  /// Only the target process.
  case app
  /// The target plus the processes spawned under its `launchd_sim` at or after its launch, a heuristic for its XPC
  /// helpers and app extensions.
  case appAndHelpers = "app-and-helpers"
}

// MARK: - Capture

extension ResourceSample {
  /// Private so the libproc type never appears in any cross-file (or testable) signature.
  private init(pid: Int32, processName: String, timestampMs: Int64, elapsedMs: Int64, cpuPct: Double?, usage: rusage_info_current) {
    self.init(
      pid: pid,
      processName: processName,
      timestampMs: timestampMs,
      elapsedMs: elapsedMs,
      cpuPct: cpuPct,
      footprintBytes: usage.ri_phys_footprint,
      residentBytes: usage.ri_resident_size,
      instructions: usage.ri_instructions,
      cycles: usage.ri_cycles,
      diskBytesRead: usage.ri_diskio_bytesread,
      diskBytesWritten: usage.ri_diskio_byteswritten,
      interruptWakeups: usage.ri_interrupt_wkups,
      packageIdleWakeups: usage.ri_pkg_idle_wkups,
      billedEnergyNanoJoules: usage.ri_billed_energy)
  }

  /// Reads a sample for `pid`, returning the sample plus this reading's cumulative CPU nanoseconds (so callers can
  /// difference it for the next sample). Returns nil if the process can't be read (for example it has exited).
  /// `cpuPct` is computed only when a `previousCPUNanos` is supplied and the wall interval is positive — otherwise it is
  /// nil (the baseline).
  public static func capture(
    pid: Int32,
    processName: String,
    timestampMs: Int64,
    elapsedMs: Int64,
    previousCPUNanos: UInt64?,
    wallIntervalNanos: UInt64
  ) -> (sample: ResourceSample, cpuNanos: UInt64)? {
    guard let usage = readResourceUsage(pid: pid) else {
      return nil
    }
    let cpuMachTicks = usage.ri_user_time &+ usage.ri_system_time
    let cpuNanos = ResourceSample.machTicksToNanos(cpuMachTicks, numer: machTimebase.numer, denom: machTimebase.denom)
    var cpuPct: Double?
    if let previousCPUNanos, wallIntervalNanos > 0 {
      let deltaCPU = cpuNanos > previousCPUNanos ? cpuNanos - previousCPUNanos : 0
      cpuPct = ResourceSample.cpuPercent(cpuDeltaNanos: deltaCPU, wallIntervalNanos: wallIntervalNanos)
    }
    let sample = ResourceSample(pid: pid, processName: processName, timestampMs: timestampMs, elapsedMs: elapsedMs, cpuPct: cpuPct, usage: usage)
    return (sample, cpuNanos)
  }

  /// Reads a baseline sample (no CPU%) for `pid`, or nil if the process can't be read.
  public static func captureBaseline(pid: Int32, processName: String, elapsedMs: Int64, timestampMs: Int64) -> ResourceSample? {
    capture(pid: pid, processName: processName, timestampMs: timestampMs, elapsedMs: elapsedMs, previousCPUNanos: nil, wallIntervalNanos: 0)?.sample
  }

  /// CPU utilization as a percentage of a single core over the interval. Values above 100 indicate work spread across
  /// multiple cores/threads within the interval, which is expected and useful signal.
  static func cpuPercent(cpuDeltaNanos: UInt64, wallIntervalNanos: UInt64) -> Double {
    guard wallIntervalNanos > 0 else { return 0 }
    return Double(cpuDeltaNanos) / Double(wallIntervalNanos) * 100.0
  }

  static func machTicksToNanos(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
    guard denom != 0 else { return ticks }
    guard numer != denom else { return ticks }
    guard numer != 0 else { return 0 }

    let numerator = UInt64(numer)
    let denominator = UInt64(denom)
    let quotient = ticks / denominator
    let remainder = ticks % denominator
    guard quotient <= UInt64.max / numerator else {
      return UInt64.max
    }
    let high = quotient * numerator
    let low = remainder * numerator / denominator
    guard high <= UInt64.max - low else {
      return UInt64.max
    }
    return high + low
  }
}

// MARK: - Sampler

/// Samples the resource usage of host processes, such as a Simulator app from its host pid.
public enum ResourceSampler {

  /// Per tick: resolves the current pid set, drops state for exited pids, then emits one sample per pid. New pids
  /// appear with a baseline (`cpuPct == nil`); known pids get `cpuPct` against the same wall-clock interval. Runs until
  /// cancelled.
  public static func run(
    interval: Duration,
    currentPIDs: @Sendable () -> [pid_t],
    emit: @Sendable (ResourceSample) -> Void
  ) async {
    let startWallNanos = DispatchTime.now().uptimeNanoseconds
    var previousWallNanos = startWallNanos
    var states: [pid_t: PIDState] = [:]

    while !Task.isCancelled {
      let nowWallNanos = DispatchTime.now().uptimeNanoseconds
      let wallNanos = nowWallNanos > previousWallNanos ? nowWallNanos - previousWallNanos : 0
      let elapsedMs = Int64((nowWallNanos - startWallNanos) / 1_000_000)
      let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
      let pids = currentPIDs()
      let pidSet = Set(pids)

      states = states.filter { pidSet.contains($0.key) }

      for pid in pids {
        let previousState = states[pid]
        let isNew = previousState == nil
        let name = previousState?.name ?? processName(pid: pid) ?? String(pid)
        guard let (sample, cpuNanos) = ResourceSample.capture(pid: pid, processName: name, timestampMs: timestampMs, elapsedMs: elapsedMs, previousCPUNanos: previousState?.previousCPUNanos, wallIntervalNanos: isNew ? 0 : wallNanos) else {
          states.removeValue(forKey: pid)
          continue
        }
        emit(sample)
        states[pid] = PIDState(name: name, previousCPUNanos: cpuNanos)
      }

      previousWallNanos = nowWallNanos
      do {
        try await Task.sleep(for: interval)
      } catch {
        break
      }
    }
  }

  /// Samples `pid`, and its helpers for `.appAndHelpers`, until it exits or the task is cancelled. Falls back to `pid`
  /// alone when its parent or start time can't be read.
  public static func sample(
    pid: pid_t,
    interval: Duration,
    scope: ResourceSampleScope,
    emit: @escaping @Sendable (ResourceSample) -> Void
  ) async {
    // A recycled pid has a different start time, so this also catches the pid being reissued to another process.
    let startSeconds = processStartSecondsSince1970(pid: pid)
    let currentPIDs: @Sendable () -> [pid_t]
    switch (scope, parentPID(pid: pid), startSeconds) {
    case let (.appAndHelpers, .some(launchdSimPID), .some(appStartSeconds)):
      currentPIDs = { currentHelperPIDs(appPID: pid, launchdSimPID: launchdSimPID, appStartSeconds: appStartSeconds) }
    case (.app, _, _), (.appAndHelpers, nil, _), (.appAndHelpers, _, nil):
      currentPIDs = { [pid] }
    }

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await run(interval: interval, currentPIDs: currentPIDs, emit: emit)
      }
      group.addTask {
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: interval)
          } catch {
            return
          }
          if hasExited(pid: pid, startSeconds: startSeconds) {
            return
          }
        }
      }
      _ = await group.next()
      group.cancelAll()
    }
  }

  /// Without a start time to compare, a recycled pid can't be told apart from `pid`, so only its disappearance counts.
  static func hasExited(pid: pid_t, startSeconds: Int64?) -> Bool {
    guard let startSeconds else {
      return kill(pid, 0) != 0 && errno == ESRCH
    }
    return processStartSecondsSince1970(pid: pid) != startSeconds
  }

  /// The app plus the processes under `launchdSimPID` that started at or after it.
  public static func currentHelperPIDs(appPID: pid_t, launchdSimPID: pid_t, appStartSeconds: Int64) -> [pid_t] {
    var result: [pid_t] = [appPID]
    for pid in siblingPIDs(under: launchdSimPID) where pid != appPID {
      guard let started = processStartSecondsSince1970(pid: pid), started >= appStartSeconds else { continue }
      result.append(pid)
    }
    return result
  }

  /// Kept across ticks so the process name is resolved at most once per pid.
  private struct PIDState {
    let name: String
    var previousCPUNanos: UInt64
  }

  // MARK: libproc

  /// The short executable name of `pid`, or nil on failure or empty result.
  public static func processName(pid: pid_t) -> String? {
    let capacity = Int(MAXPATHLEN)
    var buffer = [CChar](repeating: 0, count: capacity)
    let written = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
      guard let base = pointer.baseAddress else { return 0 }
      return unsafe proc_name(pid, base, UInt32(capacity))
    }
    guard written > 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
  }

  /// The Unix wall-clock time at which `pid` started. Also identifies a pid across recycling: a reissued pid has a
  /// different start time.
  public static func processStartSecondsSince1970(pid: pid_t) -> Int64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let returned = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
      unsafe proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
    }
    guard returned == size else { return nil }
    return Int64(info.pbi_start_tvsec)
  }

  /// The parent of `pid`; for a Simulator app, its `launchd_sim`.
  public static func parentPID(pid: pid_t) -> pid_t? {
    var info = proc_bsdshortinfo()
    let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
    let returned = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
      unsafe proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, pointer, size)
    }
    guard returned == size else { return nil }
    return pid_t(info.pbsi_ppid)
  }

  /// The pids whose parent is `parentPID`, or empty on failure.
  public static func siblingPIDs(under parentPID: pid_t) -> [pid_t] {
    let sizeBytes = proc_listchildpids(parentPID, nil, 0)
    guard sizeBytes > 0 else { return [] }
    let count = Int(sizeBytes) / MemoryLayout<pid_t>.size
    var pids = [pid_t](repeating: 0, count: count)
    let filledBytes = pids.withUnsafeMutableBufferPointer { pointer -> Int32 in
      guard let base = pointer.baseAddress else { return 0 }
      return unsafe proc_listchildpids(parentPID, base, Int32(count * MemoryLayout<pid_t>.size))
    }
    guard filledBytes > 0 else { return [] }
    let filledCount = Int(filledBytes) / MemoryLayout<pid_t>.size
    return Array(pids.prefix(filledCount)).filter { $0 != 0 }
  }
}

/// Reads `RUSAGE_INFO_CURRENT` via `proc_pid_rusage`, which works for any same-uid process without elevated privileges.
private func readResourceUsage(pid: pid_t) -> rusage_info_current? {
  var info = rusage_info_current()
  let result = withUnsafeMutablePointer(to: &info) { pointer in
    unsafe pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
      unsafe proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, reboundPointer)
    }
  }
  return result == 0 ? info : nil
}
