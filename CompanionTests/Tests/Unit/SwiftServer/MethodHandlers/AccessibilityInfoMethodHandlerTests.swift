/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
@preconcurrency import FBControlCore
@testable import FBSimulatorAX
import FBSimulatorBridgeProtocol
import FBSimulatorControl
import Foundation
import GRPCCore
import IDBGRPCSwift
import IDBTelemetry
import Testing

/// Records the options the handler hands the command executor, so a test can read them without a
/// simulator. `IDBCommandExecutor` is a `public final class`; `AccessibilityDescribing` is the seam
/// the handler is written against, and this double stands in for it.
// SAFETY: each test makes one call at a time and reads the recording after it returns.
// patternlint-disable-next-line unchecked-sendable
private final class RecordingAccessibilityExecutor: AccessibilityDescribing, @unchecked Sendable {
  private(set) var describeOptions: AccessibilityRequestOptions?
  private(set) var describeQuery: AccessibilityElementQuery?
  private(set) var pointReadCount = 0
  private let response: AccessibilityElementsResponse

  init(response: AccessibilityElementsResponse = AccessibilityElementsResponse(elements: .single(AccessibilityDocumentElement()))) {
    self.response = response
  }

  func accessibilityDescribeResponse(
    query: AccessibilityElementQuery,
    options: AccessibilityRequestOptions,
    backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse {
    describeQuery = query
    describeOptions = options
    return response
  }

  func accessibilityInfoAtPoint(
    _ value: NSValue?,
    options: AccessibilityRequestOptions,
    backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse {
    pointReadCount += 1
    return response
  }
}

/// Takes `delay` to answer every read, and counts the reads it finished.
private actor SlowAccessibilityExecutor: AccessibilityDescribing {
  private let delay: UInt64
  private(set) var finishedReads = 0

  init(delayNanoseconds: UInt64) {
    self.delay = delayNanoseconds
  }

  func accessibilityDescribeResponse(
    query: AccessibilityElementQuery, options: AccessibilityRequestOptions, backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse {
    try await read()
  }

  func accessibilityInfoAtPoint(
    _ value: NSValue?, options: AccessibilityRequestOptions, backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse {
    try await read()
  }

  private func read() async throws -> AccessibilityElementsResponse {
    // Stands in for a read that keeps going: an unstructured task does not inherit the caller's cancellation.
    let delay = self.delay
    await Task { try? await Task.sleep(nanoseconds: delay) }.value
    finishedReads += 1
    return AccessibilityElementsResponse(elements: .single(AccessibilityDocumentElement()))
  }
}

/// Tells the read's stall observer about `stalls`, in order, then answers or throws `failure`.
private struct StallingAccessibilityExecutor: AccessibilityDescribing {
  let stalls: [AccessibilityStallObservation]
  var failure: AccessibilityError?

  func accessibilityDescribeResponse(
    query: AccessibilityElementQuery, options: AccessibilityRequestOptions, backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse {
    try read(options)
  }

  func accessibilityInfoAtPoint(
    _ value: NSValue?, options: AccessibilityRequestOptions, backend: UIAutomationBackend
  ) async throws -> AccessibilityElementsResponse {
    try read(options)
  }

  private func read(_ options: AccessibilityRequestOptions) throws -> AccessibilityElementsResponse {
    for stall in stalls {
      options.stallObserver?(stall)
    }
    if let failure {
      throw failure
    }
    return AccessibilityElementsResponse(elements: .single(AccessibilityDocumentElement()))
  }
}

/// Asserts what the *handler* hands the executor, which is where a describe-by-marker can silently
/// lose the request's `--key`/`--profile`/`--collect-frame-coverage` by reaching the executor with a
/// format-only options set. `AccessibilityInfoRequestTranslation.options(from:)` carries them for
/// both paths, so coverage on that translation alone does not guard the marker path.
@Suite
struct AccessibilityInfoMethodHandlerTests {

  @Test
  func markerReadCarriesTheRequestedKeysToTheExecutor() async throws {
    let executor = RecordingAccessibilityExecutor()
    var request = Idb_AccessibilityInfoRequest()
    request.marker = "OK"
    request.keys = ["AXLabel"]

    _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)

    let options = try #require(
      executor.describeOptions, "a marker read must reach the describe executor, not the at-point path")
    let label = try #require(AXKeys(rawValue: "AXLabel"))
    #expect(
      options.keys == Set([label]),
      "the request's --key must reach the executor on the marker path, not a format-only default set")
    #expect(executor.pointReadCount == 0, "a marker read must not fall through to the at-point read")
  }

  @Test
  func markerReadCarriesTheRequestedClientToTheExecutor() async throws {
    let executor = RecordingAccessibilityExecutor()
    var request = Idb_AccessibilityInfoRequest()
    request.marker = "OK"
    request.clientType = .xctest

    _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)

    let options = try #require(executor.describeOptions, "a marker read must reach the describe executor")
    #expect(options.clientType == .xctest, "the request's client must reach the executor on the marker path")
  }

  @Test
  func markerReadCarriesProfilingAndFrameCoverageToTheExecutor() async throws {
    let executor = RecordingAccessibilityExecutor()
    var request = Idb_AccessibilityInfoRequest()
    request.marker = "OK"
    request.profile = true
    request.collectFrameCoverage = true

    _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)

    let options = try #require(executor.describeOptions)
    #expect(options.enableProfiling, "--profile is a read option and a marker read is a read")
    #expect(
      options.collectFrameCoverage, "--collect-frame-coverage is a read option and a marker read is a read")
  }

  // MARK: - Read telemetry

  private static let translatorResponse = AccessibilityElementsResponse(
    elements: .single(AccessibilityDocumentElement()),
    backend: .ax,
    translatorMetrics: AccessibilityTranslatorReadMetrics(
      elementCount: 114, roundTrips: 225, readDuration: 0.072, totalDuration: 0.081,
      transport: .bridge, acquireDuration: 0.004, springBoardCheckDuration: 0.002,
      acquireRoundTrips: 2,
      slowestRequest: AccessibilityTranslatorRequestTiming(requestType: 4, duration: 0.031), requestsBehindAbandoned: 3))

  @Test(arguments: [false, true])
  func everyReadRecordsHowItWentWithoutAskingForAProfile(byMarker: Bool) async throws {
    let executor = RecordingAccessibilityExecutor(response: Self.translatorResponse)
    var request = Idb_AccessibilityInfoRequest()
    if byMarker {
      request.marker = "OK"
    }
    let call = CallTelemetry()

    let response = try await CallTelemetry.$current.withValue(call) {
      try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)
    }

    #expect(
      call.ints == [
        "ax_element_count": 114, "ax_round_trips": 225, "ax_profile_read_ms": 72, "ax_profile_total_ms": 81,
        "ax_profile_acquire_ms": 4, "ax_springboard_check_ms": 2, "ax_acquire_round_trips": 2,
        "ax_slowest_request_ms": 31, "ax_requests_behind_abandoned": 3,
      ])
    var normals = [
      "ax_backend": "ax", "ax_transport": "bridge", "ax_read_outcome": "complete",
      "ax_slowest_request_type": "frontmost",
    ]
    normals["ax_host"] = HostName.kernel
    #expect(call.normals == normals)
    #expect(!response.json.contains("profile"), "the caller did not ask for a profile, so none is reported")
  }

  @Test
  func everyReadRecordsItsHostEvenWhenItFails() async throws {
    let hostName = try #require(HostName.kernel)
    var request = Idb_AccessibilityInfoRequest()
    request.marker = "OK"
    request.match = "OK"
    let call = CallTelemetry()

    await #expect(throws: (any Error).self) {
      try await CallTelemetry.$current.withValue(call) {
        try await AccessibilityInfoMethodHandler.respond(to: request, using: RecordingAccessibilityExecutor(response: Self.translatorResponse))
      }
    }

    #expect(call.normals["ax_host"] == hostName)
  }

  @Test
  func cancellingTheRPCStopsTheRead() async throws {
    let executor = SlowAccessibilityExecutor(delayNanoseconds: 300_000_000)
    let cancellation = ServerContext.RPCCancellationHandle()
    let read = Task {
      try await AccessibilityInfoMethodHandler.respond(to: Idb_AccessibilityInfoRequest(), using: executor, cancellation: cancellation)
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    cancellation.cancel()
    await #expect(throws: CancellationError.self) { _ = try await read.value }
  }

  @Test
  func aReadThatRanOutOfTimeRecordsHowItEnded() {
    let unanswered = CallTelemetry()
    AccessibilityReadTelemetry.record(
      failure: AccessibilityError.serviceNotAnswering(.request(kind: "frontmost", timeout: 5), elapsed: 5, behindAbandoned: 2), into: unanswered)
    #expect(unanswered.normals == ["ax_read_outcome": "aborted_unanswered"])
    #expect(unanswered.ints == ["ax_requests_behind_abandoned": 2], "how many of its requests queued behind an abandoned one")

    let deadline = CallTelemetry()
    AccessibilityReadTelemetry.record(
      failure: AccessibilityError.serviceNotAnswering(.query(timeout: 10), elapsed: 10, behindAbandoned: 0), into: deadline)
    #expect(deadline.normals == ["ax_read_outcome": "aborted_deadline"])

    let other = CallTelemetry()
    AccessibilityReadTelemetry.record(failure: AccessibilityError.springBoardNotRunning, into: other)
    #expect(other.normals.isEmpty, "a failure that is not about time says nothing about the outcome")
  }

  @Test
  func aReadWithoutTranslatorMetricsRecordsOnlyItsBackend() {
    let call = CallTelemetry()
    AccessibilityReadTelemetry.record(
      AccessibilityElementsResponse(elements: .single(AccessibilityDocumentElement()), backend: .axBridgeExclusive), into: call)
    #expect(call.ints.isEmpty)
    #expect(call.normals == ["ax_backend": "axbridge-exclusive"])
  }

  // MARK: - Stalls

  @Test
  func theSlowestStallOfAReadHasItsColumnsToItself() async throws {
    let call = CallTelemetry()
    let executor = StallingAccessibilityExecutor(stalls: [
      Self.stall(1.5, baselineMilliseconds: 250, cpuMilliseconds: 900),
      Self.stall(2.4, kind: "frontmost", outcome: .unanswered),
    ])

    _ = try await CallTelemetry.$current.withValue(call) {
      try await AccessibilityInfoMethodHandler.respond(to: Idb_AccessibilityInfoRequest(), using: executor)
    }

    #expect(call.ints["ax_stall_ms"] == 2400)
    #expect(call.normals["ax_stall_request_type"] == "frontmost")
    #expect(call.normals["ax_stall_outcome"] == "unanswered")
    #expect(call.ints["ax_stall_target_cpu_ms"] == nil, "the faster stall's counters are not carried over")
    #expect(call.ints["ax_stall_baseline_ms"] == nil)
    #expect(call.ints["ax_stall_host_busy_pct"] == nil)
  }

  @Test
  func aFasterStallAfterTheSlowestDoesNotReplaceIt() async throws {
    let call = CallTelemetry()
    let executor = StallingAccessibilityExecutor(stalls: [
      Self.stall(2.4, baselineMilliseconds: 250, cpuMilliseconds: 900), Self.stall(1.1),
    ])

    _ = try await CallTelemetry.$current.withValue(call) {
      try await AccessibilityInfoMethodHandler.respond(to: Idb_AccessibilityInfoRequest(), using: executor)
    }

    #expect(call.ints["ax_stall_ms"] == 2400)
    #expect(call.ints["ax_stall_target_cpu_ms"] == 900)
  }

  @Test
  func everyColumnOfAStallIsRecorded() async throws {
    let call = CallTelemetry()
    let executor = StallingAccessibilityExecutor(stalls: [Self.stall(1.25, baselineMilliseconds: 250, cpuMilliseconds: 900)])

    _ = try await CallTelemetry.$current.withValue(call) {
      try await AccessibilityInfoMethodHandler.respond(to: Idb_AccessibilityInfoRequest(), using: executor)
    }

    #expect(
      call.ints.filter { $0.key.hasPrefix("ax_stall_") } == [
        "ax_stall_ms": 1250, "ax_stall_probe_inline_us": 230, "ax_stall_baseline_ms": 250, "ax_stall_target_cpu_ms": 900,
        "ax_stall_target_context_switches": 30, "ax_stall_target_syscalls": 400, "ax_stall_target_running_threads": 2,
        "ax_stall_main_thread_cpu_ms": 850, "ax_stall_host_load_x10": 813, "ax_stall_host_busy_pct": 97,
      ])
    #expect(
      call.normals.filter { $0.key.hasPrefix("ax_stall_") } == [
        "ax_stall_request_type": "multiple_attribute", "ax_stall_outcome": "answered", "ax_stall_process_status": "runnable",
      ])
  }

  @Test
  func aStallRecordsWhatTheHostsSimulatorsDidInItsWindow() async throws {
    func simulator(_ pid: pid_t, cpu: Int, own: Bool = false) -> AXHostActivity.Group {
      AXHostActivity.Group(launchdPID: pid, udid: nil, cpuMilliseconds: cpu, processes: 4, busiest: [], isOwn: own)
    }
    let host = AXHostActivity(
      startMilliseconds: 253, windowMilliseconds: 1000, userCPUMilliseconds: 4310, busyMilliseconds: 11900,
      busyPercent: 92, processes: 640, busiest: [], names: [],
      simulators: [simulator(100, cpu: 2950, own: true), simulator(200, cpu: 950), simulator(400, cpu: 0)],
      outside: AXHostActivity.Group(launchdPID: nil, udid: nil, cpuMilliseconds: 410, processes: 3, busiest: [], isOwn: false))
    let call = CallTelemetry()

    _ = try await CallTelemetry.$current.withValue(call) {
      try await AccessibilityInfoMethodHandler.respond(
        to: Idb_AccessibilityInfoRequest(), using: StallingAccessibilityExecutor(stalls: [Self.stall(2.4, host: host)]))
    }

    #expect(call.ints["ax_stall_host_window_start_ms"] == 253)
    #expect(call.ints["ax_stall_host_window_ms"] == 1000)
    #expect(call.ints["ax_stall_host_window_busy_pct"] == 92)
    #expect(call.ints["ax_stall_user_cpu_ms"] == 4310)
    #expect(call.ints["ax_stall_active_sims"] == 2)
    #expect(call.ints["ax_stall_own_sim_cpu_ms"] == 2950)
    #expect(call.ints["ax_stall_other_sims_cpu_ms"] == 950)
  }

  @Test
  func aReadThatFailsStillRecordsItsSlowestStall() async throws {
    let call = CallTelemetry()
    let executor = StallingAccessibilityExecutor(
      stalls: [Self.stall(5.0, outcome: .unanswered)],
      failure: .serviceNotAnswering(.request(kind: "multiple_attribute", timeout: 5), elapsed: 5, behindAbandoned: 0))

    await #expect(throws: AccessibilityError.self) {
      try await CallTelemetry.$current.withValue(call) {
        try await AccessibilityInfoMethodHandler.respond(to: Idb_AccessibilityInfoRequest(), using: executor)
      }
    }

    #expect(call.ints["ax_stall_ms"] == 5000)
    #expect(call.normals["ax_stall_outcome"] == "unanswered")
    #expect(call.normals["ax_read_outcome"] == "aborted_unanswered")
  }

  @Test(arguments: [nil, 0.0012] as [CFAbsoluteTime?])
  func aCompleteReadRecordsTheProbesCostOnlyWhenItWatchedARequest(probeDuration: CFAbsoluteTime?) async throws {
    let executor = RecordingAccessibilityExecutor(
      response: AccessibilityElementsResponse(
        elements: .single(AccessibilityDocumentElement()), backend: .ax,
        translatorMetrics: AccessibilityTranslatorReadMetrics(
          elementCount: 1, roundTrips: 1, readDuration: 0.01, totalDuration: 0.01, transport: .bridge,
          probeDuration: probeDuration)))
    let call = CallTelemetry()

    _ = try await CallTelemetry.$current.withValue(call) {
      try await AccessibilityInfoMethodHandler.respond(to: Idb_AccessibilityInfoRequest(), using: executor)
    }

    #expect(call.ints["ax_probe_overhead_us"] == probeDuration.map { Int($0 * 1_000_000) })
  }

  @Test
  func aReadWithoutTelemetryWatchesNoRequests() async throws {
    let executor = RecordingAccessibilityExecutor()
    var request = Idb_AccessibilityInfoRequest()
    request.marker = "OK"

    _ = try await AccessibilityInfoMethodHandler.respond(to: request, using: executor)

    #expect(executor.describeOptions != nil)
    #expect(executor.describeOptions?.stallObserver == nil)
  }

  private static func stall(
    _ duration: CFAbsoluteTime, kind: String = "multiple_attribute", outcome: AccessibilityStallOutcome = .answered,
    baselineMilliseconds: Int? = nil, cpuMilliseconds: Int? = nil, host: AXHostActivity? = nil
  ) -> AccessibilityStallObservation {
    let main = cpuMilliseconds.map { _ in AXThreadUse(id: 0x10, name: "", cpuMilliseconds: 850, runState: TH_STATE_RUNNING, rank: 1) }
    return AccessibilityStallObservation(
      requestKind: kind, pid: 4321, duration: duration, outcome: outcome, baselineMilliseconds: baselineMilliseconds,
      cpuMilliseconds: cpuMilliseconds, contextSwitches: cpuMilliseconds.map { _ in 30 },
      syscalls: cpuMilliseconds.map { _ in 400 }, pageins: cpuMilliseconds.map { _ in 0 }, runningThreads: 2, threads: 10,
      processStatus: "runnable", hostLoad: 81.34, hostBusyPercent: baselineMilliseconds.map { _ in 97 },
      busiestThreads: main.map { [$0] }, mainThread: main, footprintMegabytes: nil, residentMegabytes: nil,
      host: AXHostFacts(name: "host", model: "VirtualMac2,1", cpu: "Apple M4 (Virtual)", cpuCount: 13, memoryGigabytes: 48),
      memory: AXMemoryState(pressure: nil, freePercent: nil, swapUsedMegabytes: nil), probeMicroseconds: 0,
      probeInlineMicroseconds: 230, sweepMicroseconds: 0, probedBefore: baselineMilliseconds != nil, targetReplaced: false,
      hostActivity: host)
  }
}
