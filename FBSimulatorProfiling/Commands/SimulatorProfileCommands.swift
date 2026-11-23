/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import FBProfilingCore
import FBSimulatorControl
import Foundation

/// Profiles simulator processes with the runtime's own memory and sampling tools, which can read a `dyld_sim` process
/// where the host's builds cannot.
public struct SimulatorProfileCommands: ProfileCommands {

  private let simulator: Simulator

  public init(simulator: Simulator) {
    self.simulator = simulator
  }

  public func profile(_ configuration: ProfileConfiguration, target: ProfileTarget) async throws -> ProfileOperation {
    let tools = simulator.runtimeTools
    switch configuration {
    case .leaks:
      let pid = try await resolvePID(target)
      return ProfileOperation {
        // leaks exits 1 when it finds leaks.
        let stdout = try await Self.run("leaks", [String(pid)], acceptingExitCodes: [0, 1], tools: tools)
        return ProfileResult(report: .leaks(try RuntimeToolOutputParser.leaks(Self.text(stdout))), toolOutput: stdout, artifact: nil)
      }
    case let .memgraph(outputPath):
      let pid = try await resolvePID(target)
      let graphPath = Self.graphPath(for: outputPath)
      return ProfileOperation {
        // Writing the graph prints nothing useful, so the report comes from reading the graph back.
        _ = try await Self.run("leaks", ["--outputGraph=\(graphPath)", String(pid)], acceptingExitCodes: [0, 1], tools: tools)
        let stdout = try await Self.run("leaks", [graphPath], acceptingExitCodes: [0, 1], tools: tools)
        return ProfileResult(report: .leaks(try RuntimeToolOutputParser.leaks(Self.text(stdout))), toolOutput: stdout, artifact: URL(fileURLWithPath: graphPath))
      }
    case .heap:
      let pid = try await resolvePID(target)
      return ProfileOperation {
        let stdout = try await Self.run("heap", [String(pid)], tools: tools)
        return ProfileResult(report: .heap(try RuntimeToolOutputParser.heap(Self.text(stdout))), toolOutput: stdout, artifact: nil)
      }
    case let .sample(seconds):
      let pid = try await resolvePID(target)
      return ProfileOperation {
        let stdout = try await Self.run("sample", [String(pid), String(seconds)], tools: tools)
        return ProfileResult(report: .sample(try RuntimeToolOutputParser.sample(Self.text(stdout))), toolOutput: stdout, artifact: nil)
      }
    case .vmmap:
      let pid = try await resolvePID(target)
      return ProfileOperation {
        let stdout = try await Self.run("vmmap", [String(pid), "-summary"], tools: tools)
        return ProfileResult(report: .vmmap(try RuntimeToolOutputParser.vmmap(Self.text(stdout))), toolOutput: stdout, artifact: nil)
      }
    case .footprint:
      let pid = try await resolvePID(target)
      return ProfileOperation {
        // The runtime ships no footprint, and the host's links libraries the runtime may lack, so its vmmap reports it.
        let stdout = try await Self.run("vmmap", [String(pid), "-summary"], tools: tools)
        return ProfileResult(report: .footprint(try RuntimeToolOutputParser.footprint(Self.text(stdout))), toolOutput: stdout, artifact: nil)
      }
    case let .resources(interval, scope):
      let pid = try await resolvePID(target)
      let (samples, continuation) = AsyncStream<ResourceSample>.makeStream()
      let operation = ProfileOperation(samples: samples) { stop in
        await withTaskGroup(of: Void.self) { group in
          group.addTask { await ResourceSampler.sample(pid: pid, interval: interval, scope: scope) { continuation.yield($0) } }
          group.addTask { try? await stop.wait() }
          await group.next()
          group.cancelAll()
        }
        continuation.finish()
        return ProfileResult(report: nil, toolOutput: Data(), artifact: nil)
      }
      continuation.onTermination = { _ in operation.stop() }
      return operation
    case let .trace(trace):
      return XctraceProfiler.operation(trace, process: try await xctraceProcess(target), target: simulator, logger: simulator.logger)
    }
  }

  private func resolvePID(_ target: ProfileTarget) async throws -> pid_t {
    switch target {
    case let .pid(pid):
      return pid
    case let .bundleID(bundleID):
      return try await simulator.application.processID(forBundleID: bundleID)
    case .launch, .allProcesses:
      throw ProfileError.unsupportedTarget(target)
    }
  }

  private func xctraceProcess(_ target: ProfileTarget) async throws -> XctraceProcess {
    switch target {
    case let .launch(bundleID):
      return .launch(bundleID: bundleID)
    case .allProcesses:
      return .allProcesses
    case .pid, .bundleID:
      return .attach(try await resolvePID(target))
    }
  }

  /// leaks runs inside the simulator, where a relative path resolves against a different directory than the host's,
  /// and appends the extension to a path that lacks it.
  static func graphPath(for outputPath: String) -> String {
    let path = URL(fileURLWithPath: outputPath).standardizedFileURL.path
    return path.hasSuffix(".memgraph") ? path : path + ".memgraph"
  }

  private static func run(_ tool: String, _ arguments: [String], acceptingExitCodes: Set<Int32> = [0], tools: SimulatorRuntimeToolCommands) async throws -> Data {
    let output = try await tools.run("usr/bin/\(tool)", arguments: arguments)
    try check(output, tool: tool, acceptingExitCodes: acceptingExitCodes)
    return output.stdout
  }

  private static func check(_ output: InSimulatorToolOutput, tool: String, acceptingExitCodes: Set<Int32>) throws {
    guard acceptingExitCodes.contains(output.exitCode) else {
      throw ProfileError.toolFailed(tool: tool, exitCode: output.exitCode, stderr: text(output.stderr))
    }
  }

  private static func text(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
  }
}
