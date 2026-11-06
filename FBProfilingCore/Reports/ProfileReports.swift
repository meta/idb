/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

public enum ProfileReport: Equatable, Sendable {
  case leaks(LeaksReport)
  case heap(HeapReport)
  case sample(SampleReport)
  case vmmap(VmmapReport)
  case footprint(FootprintReport)
  case trace(TraceReport)
}

/// The process a report describes, from the header the runtime tools print.
public struct ProfiledProcess: Codable, Equatable, Sendable {
  public let name: String
  public let pid: Int32
  public let identifier: String?
  public let physicalFootprintBytes: UInt64?
  public let peakPhysicalFootprintBytes: UInt64?
}

/// One frame of a backtrace.
public struct ProfileFrame: Codable, Hashable, Sendable {
  public let symbol: String
  /// The image the symbol is in. Absent for frames the tool could not attribute, such as thread roots.
  public let binary: String?

  public init(symbol: String, binary: String?) {
    self.symbol = symbol
    self.binary = binary
  }
}

// MARK: leaks

public enum LeakKind: String, Codable, Sendable {
  case leak = "ROOT LEAK"
  case cycle = "ROOT CYCLE"
}

public struct LeaksReport: Codable, Equatable, Sendable {
  public let process: ProfiledProcess
  public let leakCount: Int
  public let leakedBytes: UInt64
  /// Leaked roots grouped by kind and type, largest first.
  public let groups: [LeakGroup]
  /// Where each group was allocated, most instances first. Empty unless the process ran with `MallocStackLogging`.
  public let allocationStacks: [LeakAllocationStack]
}

public struct LeakGroup: Codable, Equatable, Sendable {
  public let kind: LeakKind
  /// The type leaks names the roots by. Absent for roots it could not type, such as plain malloc blocks, which it
  /// prints by address alone.
  public let typeName: String?
  public let roots: Int
  /// Allocations reachable from the roots, the roots included.
  public let nodes: Int
  public let bytes: UInt64
}

public struct LeakAllocationStack: Codable, Equatable, Sendable {
  public let kind: LeakKind
  public let typeName: String
  public let instances: Int
  /// Innermost first, as in a backtrace: the allocator, then the code that called it.
  public let frames: [ProfileFrame]
}

// MARK: heap

public struct HeapReport: Codable, Equatable, Sendable {
  public let process: ProfiledProcess
  public let nodeCount: Int
  public let bytes: UInt64
  /// Largest first.
  public let classes: [HeapClass]
}

public struct HeapClass: Codable, Equatable, Sendable {
  public let className: String
  public let count: Int
  public let bytes: UInt64
  /// `ObjC`, `Swift`, `C`, `C++` or `CFType`, when heap could tell.
  public let kind: String?
  public let binary: String?
}

// MARK: sample

public struct SampleReport: Codable, Equatable, Sendable {
  public let process: ProfiledProcess
  public let totalSamples: Int
  /// Samples whose leaf frame was doing work rather than parked waiting.
  public let busySamples: Int
  /// Most samples first.
  public let threads: [SampledThread]
  /// Leaf frames that were doing work, most samples first.
  public let busyFrames: [SampledFrame]
  /// Every distinct stack with the samples spent at its leaf, most samples first.
  public let stacks: [SampledStack]
}

public struct SampledThread: Codable, Equatable, Sendable {
  public let name: String
  public let samples: Int
}

public struct SampledFrame: Codable, Equatable, Sendable {
  public let frame: ProfileFrame
  public let samples: Int
}

public struct SampledStack: Codable, Equatable, Sendable {
  /// The thread first, the leaf last.
  public let frames: [ProfileFrame]
  public let samples: Int
}

// MARK: vmmap

public struct VmmapReport: Codable, Equatable, Sendable {
  public let process: ProfiledProcess
  public let regions: [VmmapRegion]
  public let total: VmmapRegion
}

public struct VmmapRegion: Codable, Equatable, Sendable {
  public let type: String
  public let virtualBytes: UInt64
  public let residentBytes: UInt64
  public let dirtyBytes: UInt64
  public let swappedBytes: UInt64
  public let regionCount: Int
}

// MARK: footprint

public struct FootprintReport: Codable, Equatable, Sendable {
  public let name: String
  public let pid: Int32
  public let footprintBytes: UInt64
  public let peakFootprintBytes: UInt64
  /// vmmap's dirty and swapped memory per region type, largest first. These count shared library pages that the
  /// footprint attributes elsewhere, so they need not sum to it.
  public let categories: [FootprintCategory]
}

public struct FootprintCategory: Codable, Equatable, Sendable {
  public let name: String
  public let dirtyBytes: UInt64
  public let swappedBytes: UInt64
  public let regionCount: Int
}
