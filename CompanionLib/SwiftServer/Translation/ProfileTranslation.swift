/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBProfilingCore
import Foundation
import GRPCCore
import IDBGRPCSwift

/// Translates a `profile` request to a `ProfileConfiguration`, and what the profiler reports back to the wire.
/// A zero in the request is unset, and takes the profiler's default.
enum ProfileTranslation {

  static let defaultSampleSeconds: UInt = 10
  static let defaultResourcesInterval: Duration = .seconds(1)
  static let defaultTraceTemplate = "Time Profiler"

  static func target(from target: Idb_ProfileRequest.Target) throws -> ProfileTarget {
    switch target.target {
    case let .pid(pid):
      guard let pid = pid_t(exactly: pid), pid > 0 else {
        throw RPCError(code: .invalidArgument, message: "profile pid \(pid) is not a process identifier")
      }
      return .pid(pid)
    case let .bundleID(bundleID):
      return .bundleID(bundleID)
    case let .launchBundleID(bundleID):
      return .launch(bundleID: bundleID)
    case .allProcesses:
      return .allProcesses
    case nil:
      throw RPCError(code: .invalidArgument, message: "profile requires a target")
    }
  }

  /// The tools name what they write by its extension, appending it when the path lacks it.
  static func artifactExtension(of start: Idb_ProfileRequest.Start) -> String {
    switch start.kind {
    case .memgraph: ".memgraph"
    case .trace: ".trace"
    case .leaks, .heap, .sample, .vmmap, .footprint, .resources, nil: ""
    }
  }

  /// `artifactPath` is where a profiler that writes a file writes it.
  static func configuration(from start: Idb_ProfileRequest.Start, artifactPath: String) throws -> ProfileConfiguration {
    switch start.kind {
    case .leaks:
      return .leaks
    case .memgraph:
      return .memgraph(outputPath: artifactPath)
    case .heap:
      return .heap
    case let .sample(sample):
      return .sample(seconds: sample.seconds > 0 ? UInt(sample.seconds) : defaultSampleSeconds)
    case .vmmap:
      return .vmmap
    case .footprint:
      return .footprint
    case let .resources(resources):
      let interval = resources.intervalMs > 0 ? Duration.milliseconds(Int64(clamping: resources.intervalMs)) : defaultResourcesInterval
      let scope: ResourceSampleScope = resources.scope == .appAndHelpers ? .appAndHelpers : .app
      return .resources(interval: interval, scope: scope)
    case let .trace(trace):
      let seconds = trace.durationSeconds == 0 ? DefaultXCTraceRecordOperationTimeLimit : trace.durationSeconds
      guard seconds > 0, let milliseconds = Int64(exactly: (seconds * 1000).rounded()) else {
        throw RPCError(code: .invalidArgument, message: "profile trace duration_seconds must be a finite, non-negative number of seconds in range, got \(trace.durationSeconds)")
      }
      return .trace(
        TraceConfiguration(
          template: trace.template.isEmpty ? defaultTraceTemplate : trace.template,
          schemas: trace.schemas.isEmpty ? nil : trace.schemas,
          timeLimit: .milliseconds(milliseconds),
          rowLimit: trace.rowLimit > 0 ? Int(clamping: trace.rowLimit) : nil,
          outputPath: start.includeArtifact ? artifactPath : nil))
    case nil:
      throw RPCError(code: .invalidArgument, message: "profile requires a kind of profile")
    }
  }

  static func result(_ result: ProfileResult) -> Idb_ProfileResponse.Result {
    .with {
      if let report = result.report {
        $0.report = self.report(report)
      }
      $0.toolOutput = result.toolOutput
    }
  }

  static func report(_ report: ProfileReport) -> Idb_ProfileReport {
    .with {
      switch report {
      case let .leaks(leaks):
        $0.leaks = self.leaks(leaks)
      case let .heap(heap):
        $0.heap = self.heap(heap)
      case let .sample(sample):
        $0.sample = self.sample(sample)
      case let .vmmap(vmmap):
        $0.vmmap = self.vmmap(vmmap)
      case let .footprint(footprint):
        $0.footprint = self.footprint(footprint)
      case let .trace(trace):
        $0.trace = self.trace(trace)
      }
    }
  }

  static func sample(_ sample: ResourceSample) -> Idb_ProfileResourceSample {
    .with {
      $0.pid = sample.pid
      $0.processName = sample.processName
      $0.timestampMs = sample.timestampMs
      $0.elapsedMs = sample.elapsedMs
      if let cpuPct = sample.cpuPct {
        $0.cpuPct = cpuPct
      }
      $0.footprintBytes = sample.footprintBytes
      $0.residentBytes = sample.residentBytes
      $0.instructions = sample.instructions
      $0.cycles = sample.cycles
      $0.diskBytesRead = sample.diskBytesRead
      $0.diskBytesWritten = sample.diskBytesWritten
      $0.interruptWakeups = sample.interruptWakeups
      $0.packageIdleWakeups = sample.packageIdleWakeups
      $0.billedEnergyNanoJoules = sample.billedEnergyNanoJoules
    }
  }

  private static func process(_ process: ProfiledProcess) -> Idb_ProfiledProcess {
    .with {
      $0.name = process.name
      $0.pid = process.pid
      $0.identifier = process.identifier ?? ""
      if let bytes = process.physicalFootprintBytes {
        $0.physicalFootprintBytes = bytes
      }
      if let bytes = process.peakPhysicalFootprintBytes {
        $0.peakPhysicalFootprintBytes = bytes
      }
    }
  }

  private static func frame(_ frame: ProfileFrame) -> Idb_ProfileFrame {
    .with {
      $0.symbol = frame.symbol
      $0.binary = frame.binary ?? ""
    }
  }

  private static func leakKind(_ kind: LeakKind) -> Idb_ProfileLeaksReport.Kind {
    switch kind {
    case .leak: .leak
    case .cycle: .cycle
    }
  }

  private static func leaks(_ report: LeaksReport) -> Idb_ProfileLeaksReport {
    .with {
      $0.process = process(report.process)
      $0.leakCount = UInt64(report.leakCount)
      $0.leakedBytes = report.leakedBytes
      $0.groups = report.groups.map { group in
        .with {
          $0.kind = leakKind(group.kind)
          $0.typeName = group.typeName ?? ""
          $0.roots = UInt64(group.roots)
          $0.nodes = UInt64(group.nodes)
          $0.bytes = group.bytes
        }
      }
      $0.allocationStacks = report.allocationStacks.map { stack in
        .with {
          $0.kind = leakKind(stack.kind)
          $0.typeName = stack.typeName
          $0.instances = UInt64(stack.instances)
          $0.frames = stack.frames.map(frame)
        }
      }
    }
  }

  private static func heap(_ report: HeapReport) -> Idb_ProfileHeapReport {
    .with {
      $0.process = process(report.process)
      $0.nodeCount = UInt64(report.nodeCount)
      $0.bytes = report.bytes
      $0.classes = report.classes.map { heapClass in
        .with {
          $0.className = heapClass.className
          $0.count = UInt64(heapClass.count)
          $0.bytes = heapClass.bytes
          $0.kind = heapClass.kind ?? ""
          $0.binary = heapClass.binary ?? ""
        }
      }
    }
  }

  private static func sample(_ report: SampleReport) -> Idb_ProfileSampleReport {
    .with {
      $0.process = process(report.process)
      $0.totalSamples = UInt64(report.totalSamples)
      $0.busySamples = UInt64(report.busySamples)
      $0.threads = report.threads.map { thread in
        .with {
          $0.name = thread.name
          $0.samples = UInt64(thread.samples)
        }
      }
      $0.busyFrames = report.busyFrames.map { busy in
        .with {
          $0.frame = frame(busy.frame)
          $0.samples = UInt64(busy.samples)
        }
      }
      $0.stacks = report.stacks.map { stack in
        .with {
          $0.frames = stack.frames.map(frame)
          $0.samples = UInt64(stack.samples)
        }
      }
    }
  }

  private static func region(_ region: VmmapRegion) -> Idb_ProfileVmmapReport.Region {
    .with {
      $0.type = region.type
      $0.virtualBytes = region.virtualBytes
      $0.residentBytes = region.residentBytes
      $0.dirtyBytes = region.dirtyBytes
      $0.swappedBytes = region.swappedBytes
      $0.regionCount = UInt64(region.regionCount)
    }
  }

  private static func vmmap(_ report: VmmapReport) -> Idb_ProfileVmmapReport {
    .with {
      $0.process = process(report.process)
      $0.regions = report.regions.map(region)
      $0.total = region(report.total)
    }
  }

  private static func footprint(_ report: FootprintReport) -> Idb_ProfileFootprintReport {
    .with {
      $0.name = report.name
      $0.pid = report.pid
      $0.footprintBytes = report.footprintBytes
      $0.peakFootprintBytes = report.peakFootprintBytes
      $0.categories = report.categories.map { category in
        .with {
          $0.name = category.name
          $0.dirtyBytes = category.dirtyBytes
          $0.swappedBytes = category.swappedBytes
          $0.regionCount = UInt64(category.regionCount)
        }
      }
    }
  }

  private static func trace(_ report: TraceReport) -> Idb_ProfileTraceReport {
    .with {
      $0.runs = report.runs.map { run in
        .with {
          $0.number = UInt64(run.number)
          $0.templateName = run.templateName ?? ""
          if let duration = run.durationSeconds {
            $0.durationSeconds = duration
          }
          $0.endReason = run.endReason ?? ""
          $0.processes = run.processes.map { process in
            .with {
              $0.name = process.name
              $0.pid = process.pid
              $0.path = process.path ?? ""
            }
          }
          $0.schemas = run.schemas
        }
      }
      $0.tables = report.tables.map { table in
        .with {
          $0.schema = table.schema
          $0.columns = table.columns.map { column in
            .with {
              $0.mnemonic = column.mnemonic
              $0.name = column.name
              $0.engineeringType = column.engineeringType
            }
          }
          $0.rowCount = UInt64(table.rowCount)
          $0.rows = table.rows.map { row in
            .with { $0.values = row.map(value) }
          }
        }
      }
    }
  }

  private static func value(_ value: TraceValue) -> Idb_ProfileTraceReport.Value {
    .with {
      switch value {
      case .empty:
        $0.empty = true
      case let .text(text):
        $0.text = text
      case let .backtrace(frames):
        $0.backtrace = .with { $0.frames = frames.map(frame) }
      }
    }
  }
}
