/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import ArgumentParser
import Foundation

/// Two labels' measurements, case by case, with a verdict on each.
///
/// The thresholds are fixed rather than tuned to the numbers: a case regresses when the head's median throughput falls,
/// or its median CPU time rises, by more than 5% or three times the noise (the larger of the two sides' median absolute
/// deviation), whichever is larger; or when its median peak memory rises by more than 10%.
struct Comparison {

  struct Row {
    let benchCase: BenchCase
    let base: Summary
    let head: Summary
    let verdicts: [String]

    var regressed: Bool { !verdicts.isEmpty }
  }

  struct Summary {
    let throughput: Statistic
    let cpu: Statistic
    let peakRSS: Statistic
    let failures: Int

    init(_ measurements: [Measurement]) {
      let succeeded = measurements.filter { $0.failure == nil }
      throughput = Statistic(succeeded.map(\.megabytesPerSecond))
      cpu = Statistic(succeeded.map(\.cpuSeconds))
      peakRSS = Statistic(succeeded.map { Double($0.peakRSSBytes) })
      failures = measurements.count - succeeded.count
    }
  }

  struct Statistic {
    let median: Double
    let mad: Double

    init(_ values: [Double]) {
      let median = Self.median(values)
      self.median = median
      mad = Self.median(values.map { abs($0 - median) })
    }

    static func median(_ values: [Double]) -> Double {
      let sorted = values.sorted()
      guard !sorted.isEmpty else {
        return .nan
      }
      return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
  }

  /// Fewer runs than this make the median and its deviation noise; a same-binary comparison of two runs a side
  /// "regresses" by 15-40%.
  static let minimumRuns = 5
  static let minimumRegression = 0.05
  static let noiseMultiple = 3.0
  static let peakRSSRegression = 0.10

  let rows: [Row]

  var regressions: [Row] { rows.filter(\.regressed) }

  init(results: [Measurement], base: String, head: String, allowFewRuns: Bool = false) throws {
    guard !results.isEmpty else {
      throw ValidationError("There are no results to compare")
    }
    let byCase = Dictionary(grouping: results, by: \.benchCase)
    rows = try byCase.keys.sorted { $0.name < $1.name }.compactMap { benchCase in
      let measurements = byCase[benchCase] ?? []
      let baseRuns = measurements.filter { $0.label == base }
      let headRuns = measurements.filter { $0.label == head }
      guard !baseRuns.isEmpty || !headRuns.isEmpty else {
        return nil
      }
      guard !baseRuns.isEmpty, !headRuns.isEmpty else {
        throw ValidationError("\(benchCase.name) has runs for only one of \(base) and \(head)")
      }
      guard allowFewRuns || min(baseRuns.count, headRuns.count) >= Self.minimumRuns else {
        throw ValidationError("\(benchCase.name) has \(baseRuns.count) and \(headRuns.count) runs; a verdict needs \(Self.minimumRuns) a side")
      }
      let baseSummary = Summary(baseRuns)
      let headSummary = Summary(headRuns)
      return Row(benchCase: benchCase, base: baseSummary, head: headSummary, verdicts: Self.verdicts(base: baseSummary, head: headSummary))
    }
  }

  static func verdicts(base: Summary, head: Summary) -> [String] {
    var verdicts: [String] = []
    // With no successful runs on either side there is nothing to compare, and every comparison with NaN is false.
    guard base.throughput.median.isFinite, head.throughput.median.isFinite else {
      return ["no successful runs to compare (\(base.failures) failed before, \(head.failures) after)"]
    }
    if head.failures > base.failures {
      verdicts.append("\(head.failures) failed runs, \(base.failures) before")
    }
    let throughputAllowance = allowance(base.throughput, head.throughput)
    if head.throughput.median < base.throughput.median * (1 - throughputAllowance) {
      unsafe verdicts.append(String(format: "throughput -%.1f%% (allowed %.1f%%)", (1 - head.throughput.median / base.throughput.median) * 100, throughputAllowance * 100))
    }
    let cpuAllowance = allowance(base.cpu, head.cpu)
    if head.cpu.median > base.cpu.median * (1 + cpuAllowance) {
      unsafe verdicts.append(String(format: "CPU +%.1f%% (allowed %.1f%%)", (head.cpu.median / base.cpu.median - 1) * 100, cpuAllowance * 100))
    }
    if head.peakRSS.median > base.peakRSS.median * (1 + peakRSSRegression) {
      unsafe verdicts.append(String(format: "peak memory +%.1f%%", (head.peakRSS.median / base.peakRSS.median - 1) * 100))
    }
    return verdicts
  }

  /// The relative change that counts as a regression: 5%, or three times the noise relative to the base, if larger.
  static func allowance(_ base: Statistic, _ head: Statistic) -> Double {
    // Noise relative to a base of nothing is no measure, and would let any change through.
    guard base.median > 0 else {
      return minimumRegression
    }
    return max(minimumRegression, noiseMultiple * max(base.mad, head.mad) / base.median)
  }

  var table: String {
    let header = "| case | base MB/s | head MB/s | base CPU s | head CPU s | base peak MB | head peak MB | verdict |\n|---|---|---|---|---|---|---|---|"
    let lines = rows.map { row in
      unsafe String(
        format: "| %@ | %.0f ±%.0f | %.0f ±%.0f | %.2f | %.2f | %.0f | %.0f | %@ |", row.benchCase.name, row.base.throughput.median, row.base.throughput.mad,
        row.head.throughput.median, row.head.throughput.mad, row.base.cpu.median, row.head.cpu.median, row.base.peakRSS.median / 1_048_576,
        row.head.peakRSS.median / 1_048_576, row.regressed ? "REGRESSED: " + row.verdicts.joined(separator: "; ") : "ok")
    }
    return ([header] + lines).joined(separator: "\n")
  }
}
