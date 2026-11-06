/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import CompanionLib
import FBControlCore
import FBProfilingCore
import Foundation
import GRPCCore
import IDBGRPCSwift
import Testing

@Suite
struct ProfileTranslationTests {

  @Test
  func eachTargetTranslates() throws {
    #expect(try ProfileTranslation.target(from: .with { $0.pid = 42 }) == .pid(42))
    #expect(try ProfileTranslation.target(from: .with { $0.bundleID = "com.example" }) == .bundleID("com.example"))
    #expect(try ProfileTranslation.target(from: .with { $0.launchBundleID = "com.example" }) == .launch(bundleID: "com.example"))
    #expect(try ProfileTranslation.target(from: .with { $0.allProcesses = true }) == .allProcesses)
  }

  @Test
  func aMissingOrImpossibleTargetIsRejected() {
    #expect(throws: RPCError.self) { try ProfileTranslation.target(from: .init()) }
    #expect(throws: RPCError.self) { try ProfileTranslation.target(from: .with { $0.pid = UInt64(Int32.max) + 1 }) }
  }

  @Test
  func unsetValuesTakeTheDefaults() throws {
    #expect(try ProfileTranslation.configuration(from: .with { $0.sample = .init() }, artifactPath: "/a") == .sample(seconds: 10))
    #expect(try ProfileTranslation.configuration(from: .with { $0.resources = .init() }, artifactPath: "/a") == .resources(interval: .seconds(1), scope: .app))
    let trace = TraceConfiguration(template: "Time Profiler", schemas: nil, timeLimit: .seconds(4 * 60 * 60), rowLimit: nil, outputPath: nil)
    #expect(try ProfileTranslation.configuration(from: .with { $0.trace = .init() }, artifactPath: "/a") == .trace(trace))
  }

  @Test
  func aTraceRecordsToTheArtifactPathOnlyWhenTheArtifactIsWanted() throws {
    let start = Idb_ProfileRequest.Start.with {
      $0.trace = .with {
        $0.template = "Hangs"
        $0.schemas = ["potential-hangs"]
        $0.durationSeconds = 2.5
        $0.rowLimit = 5
      }
      $0.includeArtifact = true
    }

    let trace = TraceConfiguration(template: "Hangs", schemas: ["potential-hangs"], timeLimit: .milliseconds(2500), rowLimit: 5, outputPath: "/a")
    #expect(try ProfileTranslation.configuration(from: start, artifactPath: "/a") == .trace(trace))
  }

  @Test
  func aMemgraphAlwaysWritesToTheArtifactPath() throws {
    #expect(try ProfileTranslation.configuration(from: .with { $0.memgraph = .init() }, artifactPath: "/a") == .memgraph(outputPath: "/a"))
  }

  @Test
  func artifactsCarryTheExtensionTheirToolExpects() {
    #expect(ProfileTranslation.artifactExtension(of: .with { $0.memgraph = .init() }) == ".memgraph")
    #expect(ProfileTranslation.artifactExtension(of: .with { $0.trace = .init() }) == ".trace")
    #expect(ProfileTranslation.artifactExtension(of: .with { $0.leaks = .init() }) == "")
  }

  @Test(arguments: [Double.infinity, .nan, -1, 1e300])
  func anUnrepresentableTraceDurationIsRejected(seconds: Double) {
    #expect(throws: RPCError.self) {
      try ProfileTranslation.configuration(from: .with { $0.trace = .with { $0.durationSeconds = seconds } }, artifactPath: "/a")
    }
  }

  @Test
  func traceValuesKeepTheirKind() throws {
    let json = #"""
      {"runs": [], "tables": [{"schema": "time-profile", "columns": [{"mnemonic": "stack", "name": "Backtrace", "engineeringType": "backtrace"}],
        "rowCount": 3, "rows": [[null], ["Main Thread"], [[{"symbol": "main", "binary": "Probe"}, {"symbol": "start"}]]]}]}
      """#
    let trace = try JSONDecoder().decode(TraceReport.self, from: Data(json.utf8))

    let report = ProfileTranslation.report(.trace(trace)).trace

    let values = report.tables[0].rows.map { $0.values[0].value }
    #expect(values[0] == .empty(true))
    #expect(values[1] == .text("Main Thread"))
    #expect(report.tables[0].rows[2].values[0].backtrace.frames.map(\.symbol) == ["main", "start"])
    #expect(report.tables[0].rows[2].values[0].backtrace.frames.map(\.binary) == ["Probe", ""])
    #expect(report.tables[0].rowCount == 3)
  }

  @Test
  func anUntypedLeakGroupHasAnEmptyTypeName() throws {
    let json = #"""
      {"process": {"name": "Probe", "pid": 42}, "leakCount": 3, "leakedBytes": 96, "allocationStacks": [],
        "groups": [{"kind": "ROOT LEAK", "roots": 1, "nodes": 2, "bytes": 64}, {"kind": "ROOT CYCLE", "typeName": "Node", "roots": 1, "nodes": 1, "bytes": 32}]}
      """#
    let leaks = try JSONDecoder().decode(LeaksReport.self, from: Data(json.utf8))

    let report = ProfileTranslation.report(.leaks(leaks)).leaks

    #expect(report.groups.map(\.typeName) == ["", "Node"])
    #expect(report.groups.map(\.kind) == [.leak, .cycle])
    #expect(report.groups.map(\.nodes) == [2, 1])
  }

  @Test
  func aMeasuredCPUPercentageIsPresent() {
    let sample = ResourceSample(
      pid: 42, processName: "Probe", timestampMs: 0, elapsedMs: 100, cpuPct: 0, footprintBytes: 1, residentBytes: 2,
      instructions: 3, cycles: 4, diskBytesRead: 5, diskBytesWritten: 6, interruptWakeups: 7, packageIdleWakeups: 8, billedEnergyNanoJoules: 9)

    let translated = ProfileTranslation.sample(sample)

    #expect(translated.hasCpuPct)
    #expect(translated.billedEnergyNanoJoules == 9)
  }
}
