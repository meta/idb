/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBSimulatorAX
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import IDBTelemetry
import SwiftProtobuf
import Synchronization

/// Seam over the two `CompanionAccessibility` reads this handler drives, so the request-to-options wiring
/// can be tested against a double.
protocol AccessibilityDescribing: Sendable {
  func accessibilityDescribeResponse(
    query: AccessibilityElementQuery,
    options: AccessibilityRequestOptions,
    backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse

  func accessibilityInfoAtPoint(
    _ value: NSValue?,
    options: AccessibilityRequestOptions,
    backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse
}

struct AccessibilityInfoMethodHandler {

  let commandExecutor: IDBCommandExecutor

  func handle(request: Idb_AccessibilityInfoRequest, context: ServerContext) async throws -> Idb_AccessibilityInfoResponse {
    try await Self.respond(to: request, using: commandExecutor.accessibility, cancellation: context.cancellation)
  }

  /// Lifted out of `handle` so it can be tested without a `ServerContext`. `cancellation` is the RPC's.
  static func respond(
    to request: Idb_AccessibilityInfoRequest,
    using commandExecutor: any AccessibilityDescribing,
    cancellation: ServerContext.RPCCancellationHandle? = nil
  ) async throws -> Idb_AccessibilityInfoResponse {
    let call = CallTelemetry.current
    AccessibilityReadTelemetry.recordHost(into: call)
    let stalls = call.map { _ in SlowestStall() }
    // Written once the read has ended, whether it completed or not, so every `ax_stall_*` column is the same
    // request's.
    defer {
      if let call, let stall = stalls?.observation {
        AccessibilityReadTelemetry.record(stall, into: call)
      }
    }
    do {
      guard let cancellation else {
        return try await read(request, using: commandExecutor, stalls: stalls)
      }
      // The read stops when the client goes away, rather than reading to the end for no one.
      return try await withRPCCancellation(cancellation) {
        try await read(request, using: commandExecutor, stalls: stalls)
      }
    } catch {
      AccessibilityReadTelemetry.record(failure: error, into: CallTelemetry.current)
      throw error
    }
  }

  private static func read(
    _ request: Idb_AccessibilityInfoRequest,
    using commandExecutor: any AccessibilityDescribing,
    stalls: SlowestStall?
  ) async throws -> Idb_AccessibilityInfoResponse {
    try AccessibilityInfoRequestTranslation.validate(request)
    let format = AccessibilityInfoRequestTranslation.outputFormat(from: request.format)
    let backend = AccessibilityInfoRequestTranslation.backend(from: request.backend)
    // Built before the branch: both paths are reads of the same tree with the same options, so the
    // marker path honours the request's keys, profiling and frame coverage too.
    var options = try AccessibilityInfoRequestTranslation.options(from: request, format: format)
    if let stalls {
      options.stallObserver = { stalls.keepIfSlowest($0) }
    }
    // A marker selects a single element to describe; without one the request
    // describes the element at a point, or the whole frontmost app.
    if let query = AccessibilityInfoRequestTranslation.markerQuery(from: request) {
      let response = try await commandExecutor.accessibilityDescribeResponse(query: query, options: options, backend: backend)
      AccessibilityReadTelemetry.record(response, into: CallTelemetry.current)
      let data = try response.formattedOutputJSON(format: options.format)
      return .with {
        $0.json = String(data: data, encoding: .utf8) ?? ""
      }
    }
    let response = try await commandExecutor.accessibilityInfoAtPoint(
      AccessibilityInfoRequestTranslation.point(from: request), options: options, backend: backend)
    AccessibilityReadTelemetry.record(response, into: CallTelemetry.current)
    let jsonData = try AccessibilityInfoRequestTranslation.responseJSON(from: response, format: format)
    return .with {
      $0.json = String(data: jsonData, encoding: .utf8) ?? ""
    }
  }
}

/// The longest request a read has reported as stalled, so its telemetry describes one request: the worst.
final class SlowestStall: Sendable {
  private let slowest = Mutex<AccessibilityStallObservation?>(nil)

  func keepIfSlowest(_ observation: AccessibilityStallObservation) {
    slowest.withLock { slowest in
      if observation.duration > slowest?.duration ?? 0 {
        slowest = observation
      }
    }
  }

  var observation: AccessibilityStallObservation? {
    slowest.withLock { $0 }
  }
}

/// How each read went, on the call's own row, whether or not the caller asked for a profile — so a
/// change to how reads are made can be measured across every read rather than the few that profile.
///
/// The element count, durations and backend use the column names the CLI already logs from complete
/// documents, so one query reads both. Translator-backed reads are the only ones that report metrics.
enum AccessibilityReadTelemetry {
  static func recordHost(into call: CallTelemetry?) {
    guard let call, let hostName = HostName.kernel else { return }
    call.setNormal(hostName, forKey: "ax_host")
  }

  /// The slowest stalled request of a read: how long it waited and how it ended, and what its target process
  /// and the host did from its baseline to its end. A column is absent when that request has no value for it.
  static func record(_ observation: AccessibilityStallObservation, into call: CallTelemetry) {
    call.setInt(Int(observation.duration * 1000), forKey: "ax_stall_ms")
    call.setNormal(observation.requestKind, forKey: "ax_stall_request_type")
    call.setNormal(observation.outcome.rawValue, forKey: "ax_stall_outcome")
    call.setNormal(observation.processStatus, forKey: "ax_stall_process_status")
    call.setInt(observation.probeInlineMicroseconds, forKey: "ax_stall_probe_inline_us")
    let ints: [(String, Int?)] = [
      ("ax_stall_baseline_ms", observation.baselineMilliseconds),
      ("ax_stall_target_cpu_ms", observation.cpuMilliseconds),
      ("ax_stall_target_context_switches", observation.contextSwitches),
      ("ax_stall_target_syscalls", observation.syscalls),
      ("ax_stall_target_running_threads", observation.runningThreads),
      ("ax_stall_main_thread_cpu_ms", observation.mainThreadCPUMilliseconds),
      ("ax_stall_host_load_x10", observation.hostLoad.map { Int(($0 * 10).rounded()) }),
      ("ax_stall_host_busy_pct", observation.hostBusyPercent),
      ("ax_stall_host_window_start_ms", observation.hostWindowStartMilliseconds),
      ("ax_stall_host_window_ms", observation.hostWindowMilliseconds),
      ("ax_stall_host_window_busy_pct", observation.hostWindowBusyPercent),
      ("ax_stall_user_cpu_ms", observation.userCPUMilliseconds),
      ("ax_stall_active_sims", observation.activeSimulators),
      ("ax_stall_own_sim_cpu_ms", observation.ownSimulatorCPUMilliseconds),
      ("ax_stall_other_sims_cpu_ms", observation.otherSimulatorsCPUMilliseconds),
    ]
    for case let (key, value?) in ints {
      call.setInt(value, forKey: key)
    }
  }

  /// A read that failed records how it ended, when the failure says.
  static func record(failure error: Error, into call: CallTelemetry?) {
    guard let call, let outcome = AccessibilityReadOutcome(failure: error) else { return }
    call.setNormal(outcome.rawValue, forKey: "ax_read_outcome")
    if case let AccessibilityError.serviceNotAnswering(_, _, behindAbandoned) = error {
      call.setInt(Int(behindAbandoned), forKey: "ax_requests_behind_abandoned")
    }
  }

  static func record(_ response: AccessibilityElementsResponse, into call: CallTelemetry?) {
    guard let call else { return }
    if let backend = response.backend {
      call.setNormal(backend.rawValue, forKey: "ax_backend")
    }
    guard let metrics = response.translatorMetrics else { return }
    call.setInt(Int(metrics.elementCount), forKey: "ax_element_count")
    call.setInt(Int(metrics.roundTrips), forKey: "ax_round_trips")
    call.setInt(Int(metrics.readDuration * 1000), forKey: "ax_profile_read_ms")
    call.setInt(Int(metrics.totalDuration * 1000), forKey: "ax_profile_total_ms")
    call.setNormal(metrics.transport.rawValue, forKey: "ax_transport")
    call.setNormal(AccessibilityReadOutcome.complete.rawValue, forKey: "ax_read_outcome")
    call.setInt(Int(metrics.acquireDuration * 1000), forKey: "ax_profile_acquire_ms")
    call.setInt(Int(metrics.springBoardCheckDuration * 1000), forKey: "ax_springboard_check_ms")
    call.setInt(Int(metrics.acquireRoundTrips), forKey: "ax_acquire_round_trips")
    call.setInt(Int(metrics.requestsBehindAbandoned), forKey: "ax_requests_behind_abandoned")
    if let probe = metrics.probeDuration {
      call.setInt(Int(probe * 1_000_000), forKey: "ax_probe_overhead_us")
    }
    if let slowest = metrics.slowestRequest {
      call.setInt(Int(slowest.duration * 1000), forKey: "ax_slowest_request_ms")
      call.setNormal(slowest.kindName, forKey: "ax_slowest_request_type")
    }
  }
}
