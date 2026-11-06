/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
@testable import FBProfilingCore
import Foundation
import Testing

private func fixture(_ path: String) throws -> String {
  try String(contentsOfFile: path, encoding: .utf8)
}

@Suite
struct RuntimeToolOutputParserTests {

  @Test
  func leaksReadsTheProcessAndTotals() throws {
    let report = try RuntimeToolOutputParser.leaks(fixture(TestFixtures.probeLeaksPath))

    #expect(report.process.name == "Probe")
    #expect(report.process.pid == 70010)
    #expect(report.process.identifier == "com.example.probe")
    #expect(report.process.physicalFootprintBytes == UInt64(19.0 * 1024 * 1024))
    #expect(report.leakCount == 605)
    #expect(report.leakedBytes == 1835408)
  }

  @Test
  func leaksGroupsRootsWithoutCountingCycleMembersTwice() throws {
    let report = try RuntimeToolOutputParser.leaks(fixture(TestFixtures.probeLeaksPath))

    let controller = try #require(report.groups.first { $0.typeName == "LeakyController" })
    #expect(controller.kind == .leak)
    #expect(controller.roots == 3)
    #expect(controller.nodes == 9)
    let node = try #require(report.groups.first { $0.typeName == "Node" })
    #expect(node.kind == .cycle)
    #expect(node.roots == 3)
    #expect(node.nodes == 12)
    #expect(report.groups.first?.typeName == "LeakyController")
  }

  @Test
  func leaksAllocationStacksStartAtTheAllocator() throws {
    let report = try RuntimeToolOutputParser.leaks(fixture(TestFixtures.probeLeaksPath))

    #expect(report.allocationStacks.map(\.typeName) == ["Node", "LeakyController"])
    let controller = try #require(report.allocationStacks.first { $0.typeName == "LeakyController" })
    #expect(controller.instances == 3)
    #expect(controller.frames.count == 19)
    #expect(controller.frames.first == ProfileFrame(symbol: "_malloc_zone_malloc_instrumented_or_legacy", binary: "libsystem_malloc.dylib"))
    #expect(controller.frames[4] == ProfileFrame(symbol: "LeakyController.__allocating_init()", binary: "com.example.probe"))
    #expect(controller.frames.last == ProfileFrame(symbol: "start", binary: "dyld"))
  }

  @Test
  func leaksGroupsRootsItCouldNotTypeWithoutATypeName() throws {
    let report = try RuntimeToolOutputParser.leaks(fixture(TestFixtures.replhostLeaksUntypedPath))

    #expect(report.process.identifier == "com.facebook.idb.replhost")
    #expect(report.leakCount == 39)
    #expect(report.leakedBytes == 1248)
    #expect(report.groups == [LeakGroup(kind: .leak, typeName: nil, roots: 17, nodes: 39, bytes: 1248)])
    #expect(report.allocationStacks.isEmpty)
  }

  @Test
  func leaksWithoutLeaksHasNoGroups() throws {
    let text = try fixture(TestFixtures.replhostLeaksUntypedPath)
    let header = try #require(text.components(separatedBy: "leaks Report Version").first)

    let report = try RuntimeToolOutputParser.leaks(header + "Process 81473: 0 leaks for 0 total leaked bytes.\n")

    #expect(report.leakCount == 0)
    #expect(report.groups.isEmpty)
  }

  @Test
  func leaksCountedButNoRootReadableIsAnError() throws {
    let text = try fixture(TestFixtures.replhostLeaksUntypedPath).replacingOccurrences(of: "ROOT LEAK: ", with: "LEAK ROOT: ")

    #expect(throws: ProfileReportParseError.missingSection(tool: "leaks", section: "leak roots")) {
      try RuntimeToolOutputParser.leaks(text)
    }
  }

  @Test
  func heapListsClassesLargestFirst() throws {
    let report = try RuntimeToolOutputParser.heap(fixture(TestFixtures.probeHeapPath))

    #expect(report.process.pid == 70010)
    #expect(report.nodeCount == 23906)
    #expect(report.classes.first?.className == "Swift._ContiguousArrayStorage<Swift.UInt8>")
    #expect(report.classes.first?.bytes == 2560256)
    #expect(report.classes.map(\.bytes) == report.classes.map(\.bytes).sorted(by: >))
    let node = try #require(report.classes.first { $0.className == "Node" })
    #expect(node == HeapClass(className: "Node", count: 500, bytes: 24000, kind: "Swift", binary: "Probe"))
  }

  @Test
  func sampleSeparatesBusyFramesFromIdleOnes() throws {
    let report = try RuntimeToolOutputParser.sample(fixture(TestFixtures.probeSamplePath))

    #expect(report.process.pid == 41310)
    #expect(report.busyFrames.first == SampledFrame(frame: ProfileFrame(symbol: "static Hot.isPrime(_:)", binary: "Probe"), samples: 437))
    #expect(report.busyFrames.allSatisfy { !RuntimeToolOutputParser.idleLeafSymbols.contains($0.frame.symbol) })
    #expect(report.busySamples <= report.totalSamples)
    #expect(report.threads.reduce(0) { $0 + $1.samples } == report.totalSamples)
    #expect(report.stacks.reduce(0) { $0 + $1.samples } == report.totalSamples)
  }

  @Test
  func sampleNamesThreadsAfterTheirRoot() throws {
    let report = try RuntimeToolOutputParser.sample(fixture(TestFixtures.probeSamplePath))

    #expect(report.threads.contains { $0.name == "Thread_609366 DispatchQueue_1: com.apple.main-thread (serial)" })
    let hot = try #require(report.stacks.first { $0.frames.last?.symbol == "static Hot.isPrime(_:)" })
    #expect(hot.samples == 437)
    #expect(hot.frames.first?.binary == nil)
  }

  @Test
  func vmmapReadsRegionsAndTotal() throws {
    let report = try RuntimeToolOutputParser.vmmap(fixture(TestFixtures.probeVmmapPath))

    let small = try #require(report.regions.first { $0.type == "MALLOC_SMALL" })
    #expect(small.dirtyBytes == 7040 * 1024)
    #expect(small.regionCount == 41)
    #expect(report.total.regionCount == 1982)
    #expect(report.total.dirtyBytes == UInt64(20.0 * 1024 * 1024))
    #expect(!report.regions.contains { $0.type.hasPrefix("TOTAL") })
  }

  @Test
  func footprintReadsTheProcessAndSortsCategories() throws {
    let report = try RuntimeToolOutputParser.footprint(fixture(TestFixtures.probeVmmapPath))

    #expect(report.name == "Probe")
    #expect(report.pid == 70010)
    #expect(report.footprintBytes == UInt64(20.1 * 1024 * 1024))
    #expect(report.peakFootprintBytes == UInt64(20.1 * 1024 * 1024))
    let small = try #require(report.categories.first { $0.name == "MALLOC_SMALL" })
    #expect(small.dirtyBytes == 7040 * 1024)
    #expect(small.regionCount == 41)
    #expect(!report.categories.contains { $0.name == "MALLOC guard page" })
    let sizes = report.categories.map { $0.dirtyBytes + $0.swappedBytes }
    #expect(sizes == sizes.sorted(by: >))
  }

  @Test
  func vmmapWithoutAPhysicalFootprintHasNoFootprint() throws {
    let text = try fixture(TestFixtures.probeVmmapPath).replacing(#/Physical footprint.*\n/#, with: "")

    #expect(throws: ProfileReportParseError.missingSection(tool: "vmmap", section: "physical footprint")) {
      try RuntimeToolOutputParser.footprint(text)
    }
  }

  @Test
  func outputWithoutAProcessHeaderIsRejected() {
    #expect(throws: ProfileReportParseError.missingSection(tool: "heap", section: "process header")) {
      try RuntimeToolOutputParser.heap("nothing here\n")
    }
  }

  @Test(arguments: [
    ("5294 KB", UInt64(5294 * 1024)),
    ("19.0M", UInt64(19 * 1024 * 1024)),
    ("1.5G", UInt64(1.5 * 1024 * 1024 * 1024)),
    ("288", UInt64(288)),
  ])
  func sizesHonourTheirSuffix(text: String, bytes: UInt64) {
    #expect(RuntimeToolOutputParser.parseSize(Substring(text)) == bytes)
  }
}
