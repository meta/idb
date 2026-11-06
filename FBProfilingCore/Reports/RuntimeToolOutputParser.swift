/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

public enum ProfileReportParseError: Error, LocalizedError, Equatable {
  case missingSection(tool: String, section: String)

  public var errorDescription: String? {
    switch self {
    case let .missingSection(tool, section):
      return "\(tool) output has no \(section)"
    }
  }
}

/// Parses the text reports of the `leaks`, `heap`, `sample` and `vmmap` tools.
public enum RuntimeToolOutputParser {

  public static func leaks(_ text: String) throws -> LeaksReport {
    let process = try process(text, tool: "leaks")
    guard let totals = text.firstMatch(of: #/(\d+) leaks? for (\d+) total leaked bytes/#) else {
      throw ProfileReportParseError.missingSection(tool: "leaks", section: "leak totals")
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

    var roots: [(kind: LeakKind, typeName: String?, nodes: Int, bytes: UInt64, indent: Int)] = []
    for line in lines {
      // A root leaks could type is `<Type 0xADDRESS>`; one it could not, such as a plain malloc block, is `0xADDRESS [size]`.
      guard
        let match = line.prefixMatch(
          of: #/( *)(\d+) \(([\d.]+ ?[KMG]?)(?: bytes)?\) (ROOT LEAK|ROOT CYCLE): (?:<(.+?) 0x[0-9a-f]+>|0x[0-9a-f]+ \[\d+\])/#),
        let kind = LeakKind(rawValue: String(match.4))
      else { continue }
      roots.append((kind, match.5.map(String.init), Int(match.2) ?? 0, parseSize(match.3), match.1.count))
    }
    let leakCount = Int(totals.1) ?? 0
    // Every leak is reachable from a root, so a count without roots means the tree is in a form this parser cannot read.
    if leakCount > 0, roots.isEmpty {
      throw ProfileReportParseError.missingSection(tool: "leaks", section: "leak roots")
    }
    // The base indent varies between reports; roots nested inside a cycle are indented further and already counted.
    let baseIndent = roots.map(\.indent).min() ?? 0
    var groups: [GroupKey: (roots: Int, nodes: Int, bytes: UInt64)] = [:]
    var groupOrder: [GroupKey] = []
    for root in roots where root.indent == baseIndent {
      let key = GroupKey(kind: root.kind, typeName: root.typeName)
      if groups[key] == nil {
        groupOrder.append(key)
      }
      let existing = groups[key] ?? (0, 0, 0)
      groups[key] = (existing.roots + 1, existing.nodes + root.nodes, existing.bytes + root.bytes)
    }

    var stacks: [LeakAllocationStack] = []
    var current: (kind: LeakKind, typeName: String, instances: Int, frames: [ProfileFrame])?
    for line in lines {
      if let match = line.prefixMatch(of: #/STACK OF (\d+) INSTANCES? OF '(ROOT LEAK|ROOT CYCLE): <(.+?)>':/#), let kind = LeakKind(rawValue: String(match.2)) {
        current = (kind, String(match.3), Int(match.1) ?? 0, [])
      } else if line.hasPrefix("===="), let finished = current {
        // leaks prints the outermost frame first.
        stacks.append(LeakAllocationStack(kind: finished.kind, typeName: finished.typeName, instances: finished.instances, frames: finished.frames.reversed()))
        current = nil
      } else if current != nil, let frame = line.wholeMatch(of: #/\d+\s+(\S+)\s+0x[0-9a-f]+ (.*?)(?: \+ \d+)?\s*/#) {
        current?.frames.append(ProfileFrame(symbol: String(frame.2), binary: String(frame.1)))
      }
    }

    return LeaksReport(
      process: process,
      leakCount: leakCount,
      leakedBytes: UInt64(totals.2) ?? 0,
      groups: stableSorted(
        groupOrder.map { key in
          let group = groups[key, default: (0, 0, 0)]
          return LeakGroup(kind: key.kind, typeName: key.typeName, roots: group.roots, nodes: group.nodes, bytes: group.bytes)
        }, by: { $0.bytes }),
      allocationStacks: stableSorted(stacks, by: { UInt64($0.instances) }))
  }

  public static func heap(_ text: String) throws -> HeapReport {
    let process = try process(text, tool: "heap")
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("COUNT") && $0.contains("CLASS_NAME") }),
      let classColumn = lines[headerIndex].range(of: "CLASS_NAME").map({ lines[headerIndex].distance(from: lines[headerIndex].startIndex, to: $0.lowerBound) }),
      let totals = text.firstMatch(of: #/All zones: (\d+) nodes \((\d+) bytes\)/#)
    else {
      throw ProfileReportParseError.missingSection(tool: "heap", section: "class table")
    }

    var classes: [HeapClass] = []
    for line in lines[(headerIndex + 2)...] {
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
      let split = line.index(line.startIndex, offsetBy: classColumn, limitedBy: line.endIndex) ?? line.endIndex
      let numbers = line[..<split].split(separator: " ")
      // Long class names overflow their column, so split the remainder on column gaps rather than header offsets.
      let columns = line[split...].trimmingCharacters(in: .whitespaces).split(separator: #/\s{2,}/#).map(String.init)
      guard numbers.count >= 2, let count = Int(numbers[0]), let bytes = UInt64(numbers[1]), let className = columns.first else { continue }
      let binary = columns.count > 1 ? columns[columns.count - 1] : nil
      classes.append(
        HeapClass(
          className: className,
          count: count,
          bytes: bytes,
          kind: columns.count == 3 ? columns[1] : nil,
          binary: binary == "<unknown>" ? nil : binary))
    }

    return HeapReport(process: process, nodeCount: Int(totals.1) ?? 0, bytes: UInt64(totals.2) ?? 0, classes: stableSorted(classes, by: { $0.bytes }))
  }

  /// Leaf frames where a thread is parked rather than doing work.
  static let idleLeafSymbols: Set<String> = [
    "mach_msg2_trap", "mach_msg_trap", "__workq_kernreturn", "__psynch_cvwait", "__psynch_mutexwait", "__semwait_signal",
    "kevent", "kevent64", "kevent_id", "__ulock_wait", "__ulock_wait2", "semaphore_wait_trap", "__accept", "__select",
    "poll", "read", "__recvfrom",
  ]

  public static func sample(_ text: String) throws -> SampleReport {
    let process = try process(text, tool: "sample")
    guard let callGraph = text.range(of: "Call graph:") else {
      throw ProfileReportParseError.missingSection(tool: "sample", section: "call graph")
    }
    let body = text[callGraph.upperBound...].components(separatedBy: "\n\n").first ?? ""

    // Each node's own samples are its count less what its children account for.
    var open: [(depth: Int, count: Int, path: [ProfileFrame], childSamples: Int)] = []
    var stackSamples: [[ProfileFrame]: Int] = [:]
    var stackOrder: [[ProfileFrame]] = []
    func close(_ node: (depth: Int, count: Int, path: [ProfileFrame], childSamples: Int)) {
      let own = node.count - node.childSamples
      guard own > 0 else { return }
      if stackSamples[node.path] == nil {
        stackOrder.append(node.path)
      }
      stackSamples[node.path, default: 0] += own
    }
    for line in body.split(separator: "\n") {
      guard let match = line.wholeMatch(of: #/(\s*[+!:| ]*)(\d+) (.*)/#), let count = Int(match.2) else { continue }
      let depth = match.1.count
      while let last = open.last, last.depth >= depth {
        close(open.removeLast())
      }
      if !open.isEmpty {
        open[open.count - 1].childSamples += count
      }
      open.append((depth, count, (open.last?.path ?? []) + [frame(String(match.3))], 0))
    }
    while let last = open.popLast() {
      close(last)
    }

    var threadSamples: [String: Int] = [:]
    var threadOrder: [String] = []
    var leafSamples: [ProfileFrame: Int] = [:]
    var leafOrder: [ProfileFrame] = []
    for path in stackOrder {
      let samples = stackSamples[path, default: 0]
      let thread = path[0].symbol
      if threadSamples[thread] == nil {
        threadOrder.append(thread)
      }
      threadSamples[thread, default: 0] += samples
      if path.count > 1, let leaf = path.last, !idleLeafSymbols.contains(leaf.symbol) {
        if leafSamples[leaf] == nil {
          leafOrder.append(leaf)
        }
        leafSamples[leaf, default: 0] += samples
      }
    }

    return SampleReport(
      process: process,
      totalSamples: stackSamples.values.reduce(0, +),
      busySamples: leafSamples.values.reduce(0, +),
      threads: stableSorted(threadOrder.map { SampledThread(name: $0, samples: threadSamples[$0, default: 0]) }, by: { UInt64($0.samples) }),
      busyFrames: stableSorted(leafOrder.map { SampledFrame(frame: $0, samples: leafSamples[$0, default: 0]) }, by: { UInt64($0.samples) }),
      stacks: stableSorted(stackOrder.map { SampledStack(frames: $0, samples: stackSamples[$0, default: 0]) }, by: { UInt64($0.samples) }))
  }

  /// Parses `vmmap --summary`.
  public static func vmmap(_ text: String) throws -> VmmapReport {
    let process = try process(text, tool: "vmmap")
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let headerIndex = lines.firstIndex(where: { $0.hasPrefix("REGION TYPE") }) else {
      throw ProfileReportParseError.missingSection(tool: "vmmap", section: "region table")
    }

    var regions: [VmmapRegion] = []
    var total: VmmapRegion?
    for line in lines[(headerIndex + 1)...] {
      if line.hasPrefix("TOTAL") {
        total = region(line)
        break
      }
      if let region = region(line) {
        regions.append(region)
      }
    }
    guard let total else {
      throw ProfileReportParseError.missingSection(tool: "vmmap", section: "region total")
    }
    return VmmapReport(process: process, regions: regions, total: total)
  }

  /// Reads the footprint from `vmmap --summary`.
  public static func footprint(_ text: String) throws -> FootprintReport {
    let vmmap = try vmmap(text)
    guard let footprintBytes = vmmap.process.physicalFootprintBytes, let peakFootprintBytes = vmmap.process.peakPhysicalFootprintBytes else {
      throw ProfileReportParseError.missingSection(tool: "vmmap", section: "physical footprint")
    }
    let categories = vmmap.regions
      .filter { $0.dirtyBytes + $0.swappedBytes > 0 }
      .map { FootprintCategory(name: $0.type, dirtyBytes: $0.dirtyBytes, swappedBytes: $0.swappedBytes, regionCount: $0.regionCount) }
    return FootprintReport(
      name: vmmap.process.name,
      pid: vmmap.process.pid,
      footprintBytes: footprintBytes,
      peakFootprintBytes: peakFootprintBytes,
      categories: stableSorted(categories, by: { $0.dirtyBytes + $0.swappedBytes }))
  }

  // MARK: Private

  private struct GroupKey: Hashable {
    let kind: LeakKind
    let typeName: String?
  }

  /// The header every runtime tool prints above its first `----` line.
  private static func process(_ text: String, tool: String) throws -> ProfiledProcess {
    var fields: [String: String] = [:]
    for line in text.split(separator: "\n") {
      if line.hasPrefix("----") {
        break
      }
      if let match = line.wholeMatch(of: #/([A-Za-z ()]+):\s+(.*)/#) {
        fields[match.1.trimmingCharacters(in: .whitespaces)] = match.2.trimmingCharacters(in: .whitespaces)
      }
    }
    guard let process = fields["Process"]?.wholeMatch(of: #/(.*) \[(\d+)\]/#), let pid = Int32(process.2) else {
      throw ProfileReportParseError.missingSection(tool: tool, section: "process header")
    }
    return ProfiledProcess(
      name: String(process.1),
      pid: pid,
      identifier: fields["Identifier"],
      physicalFootprintBytes: fields["Physical footprint"].map { parseSize(Substring($0)) },
      peakPhysicalFootprintBytes: fields["Physical footprint (peak)"].map { parseSize(Substring($0)) })
  }

  /// A size as the tools print it: a number with an optional `K`, `M` or `G` suffix, such as `5294 KB` or `19.0M`.
  static func parseSize(_ text: Substring) -> UInt64 {
    guard let match = text.prefixMatch(of: #/([\d.]+) ?([KMG]?)/#), let value = Double(match.1) else { return 0 }
    let multiplier: Double =
      switch match.2 {
      case "K": 1024
      case "M": 1024 * 1024
      case "G": 1024 * 1024 * 1024
      default: 1
      }
    return UInt64(value * multiplier)
  }

  /// A `sample` call graph frame, `symbol  (in binary) + offset  [address]`, or a thread root with no binary.
  private static func frame(_ text: String) -> ProfileFrame {
    let withoutAddress = text.replacing(#/\s+\[0x[^\]]*\]\s*$/#, with: "")
    let withoutOffset = withoutAddress.replacing(#/\s+\+ [\d,.]+$/#, with: "")
    if let match = withoutOffset.wholeMatch(of: #/(.*?)\s+\(in (.+)\)/#) {
      return ProfileFrame(symbol: String(match.1), binary: String(match.2))
    }
    return ProfileFrame(symbol: withoutOffset.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces), binary: nil)
  }

  /// A summary row: the type, then virtual, resident, dirty, swapped, volatile, non-volatile and empty sizes, the region count, and an optional note.
  private static func region(_ line: Substring) -> VmmapRegion? {
    guard
      let row = line.wholeMatch(
        of: #/(.+?)\s+([\d.]+[KMG]?)\s+([\d.]+[KMG]?)\s+([\d.]+[KMG]?)\s+([\d.]+[KMG]?)\s+[\d.]+[KMG]?\s+[\d.]+[KMG]?\s+[\d.]+[KMG]?\s+(\d+)(?:\s.*)?/#)
    else { return nil }
    return VmmapRegion(
      type: row.1.trimmingCharacters(in: .whitespaces),
      virtualBytes: parseSize(row.2),
      residentBytes: parseSize(row.3),
      dirtyBytes: parseSize(row.4),
      swappedBytes: parseSize(row.5),
      regionCount: Int(row.6) ?? 0)
  }

  /// Largest first, keeping the order the tool printed ties in.
  private static func stableSorted<T>(_ elements: [T], by key: (T) -> UInt64) -> [T] {
    elements.enumerated()
      .sorted { lhs, rhs in
        let (left, right) = (key(lhs.element), key(rhs.element))
        return left != right ? left > right : lhs.offset < rhs.offset
      }
      .map(\.element)
  }
}
